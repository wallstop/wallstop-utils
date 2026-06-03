[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$NoInvokeMain
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$diagnosticsHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/DiagnosticsHelpers.ps1"
if (-not (Test-Path -LiteralPath $diagnosticsHelpersPath -PathType Leaf)) {
    throw "E_PRECOMMIT_AUTOREPAIR_DIAGNOSTICS_HELPER_MISSING: diagnostics helper file not found at '$diagnosticsHelpersPath'."
}

. $diagnosticsHelpersPath

function Get-LastExitCodeOrDefault {
    $lastExitCode = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $lastExitCode) {
        return 0
    }

    return [int]$lastExitCode
}

function Get-GitExecutableOrThrow {
    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "E_PRECOMMIT_AUTOREPAIR_GIT_NOT_AVAILABLE: git is required for pre-hook auto-repair but was not found on PATH."
    }

    Write-Verbose ("Pre-commit auto-repair git diagnostics: gitPath='{0}'" -f $gitCommand.Source)
    return $gitCommand.Source
}

function Invoke-GitCommandOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureCode,

        [Parameter(Mandatory = $true)]
        [string]$FailureContext
    )

    $gitArgs = @("-C", $RepositoryRoot) + $Arguments
    $gitOutput = @(& $GitExecutable @gitArgs 2>&1)
    $gitExitCode = Get-LastExitCodeOrDefault
    if ($gitExitCode -ne 0 -and (Test-IsGitIndexLockFailure -OutputLines $gitOutput)) {
        Write-Warning (
            "W_PRECOMMIT_GIT_INDEX_LOCK_DETECTED: failureCode={0}; failureContext={1}; repositoryRoot='{2}'." -f
            $FailureCode,
            $FailureContext,
            $RepositoryRoot
        )

        $lockRecovery = Invoke-SafeGitIndexLockRecovery -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -OutputLines $gitOutput -Context $FailureContext
        if ($lockRecovery.ElapsedMilliseconds -gt $lockRecovery.SlowPathThresholdMs) {
            Write-Warning (
                "W_PRECOMMIT_GIT_INDEX_LOCK_SLOW_PATH: context={0}; elapsedMs={1}; thresholdMs={2}." -f
                $FailureContext,
                [int]$lockRecovery.ElapsedMilliseconds,
                [int]$lockRecovery.SlowPathThresholdMs
            )
        }

        if ($lockRecovery.Recovered) {
            Write-Warning (
                "W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_RETRYING: context={0}; lockPath='{1}'; lockAgeSeconds={2}." -f
                $FailureContext,
                [string]$lockRecovery.LockPath,
                [int]$lockRecovery.LockAgeSeconds
            )

            $gitOutput = @(& $GitExecutable @gitArgs 2>&1)
            $gitExitCode = Get-LastExitCodeOrDefault
            if ($gitExitCode -eq 0) {
                return @(
                    $gitOutput |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { [string]$_ } |
                        Sort-Object -Unique
                )
            }

            if (Test-IsGitIndexLockFailure -OutputLines $gitOutput) {
                $retryPreview = Get-OutputPreview -OutputLines $gitOutput
                throw (
                    "E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED: {0} (repositoryRoot='{1}'; lockPath='{2}'; outputPreview={3})." -f
                    $FailureContext,
                    $RepositoryRoot,
                    [string]$lockRecovery.LockPath,
                    $retryPreview
                )
            }
        }
        else {
            $skipReason = if ([string]::IsNullOrWhiteSpace([string]$lockRecovery.SkippedReason)) {
                'unknown'
            }
            else {
                [string]$lockRecovery.SkippedReason
            }

            Write-Warning (
                "W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_SKIPPED: context={0}; reason={1}; lockPath='{2}'; lockAgeSeconds={3}; activeGitProcessCount={4}; processScanDegraded={5}." -f
                $FailureContext,
                $skipReason,
                [string]$lockRecovery.LockPath,
                [int]$lockRecovery.LockAgeSeconds,
                [int]$lockRecovery.ActiveGitProcessCount,
                [bool]$lockRecovery.ProcessScanDegraded
            )

            if ($skipReason -eq 'recovery_failed') {
                throw (
                    "E_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_FAILED: {0} (repositoryRoot='{1}'; lockPath='{2}'; error={3})." -f
                    $FailureContext,
                    $RepositoryRoot,
                    [string]$lockRecovery.LockPath,
                    [string]$lockRecovery.ErrorMessage
                )
            }
        }
    }

    if ($gitExitCode -ne 0) {
        $outputPreview = Get-OutputPreview -OutputLines $gitOutput
        throw ("{0}: {1} (exitCode={2}; repositoryRoot='{3}'; outputPreview={4})." -f $FailureCode, $FailureContext, $gitExitCode, $RepositoryRoot, $outputPreview)
    }

    return @(
        $gitOutput |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
}

function Get-GitRepositoryRootOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$StartDirectory
    )

    $repoRootOutput = @(& $GitExecutable -C $StartDirectory rev-parse --show-toplevel 2>&1)
    $repoRootExitCode = Get-LastExitCodeOrDefault
    if ($repoRootExitCode -ne 0 -or $repoRootOutput.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$repoRootOutput[0])) {
        $outputPreview = Get-OutputPreview -OutputLines $repoRootOutput
        throw (
            "E_PRECOMMIT_AUTOREPAIR_GIT_NOT_REPOSITORY: unable to determine repository root from '{0}' (exitCode={1}; outputPreview={2})." -f
            $StartDirectory,
            $repoRootExitCode,
            $outputPreview
        )
    }

    return (Resolve-Path -LiteralPath ([string]$repoRootOutput[0]).Trim() -ErrorAction Stop).Path
}

function Invoke-WindowsLanguageCheckerForAutoRepair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$RepairTargets
    )

    $windowsLanguageScriptPath = Join-Path -Path $RepositoryRoot -ChildPath "Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1"
    if (-not (Test-Path -LiteralPath $windowsLanguageScriptPath -PathType Leaf)) {
        throw "E_PRECOMMIT_AUTOREPAIR_CONFIG_ERROR: Windows language checker is missing at '$windowsLanguageScriptPath'."
    }

    & $windowsLanguageScriptPath -TargetFiles $RepairTargets -Fix -StaticOnly
}

function Invoke-PreCommitAutoRepairMain {
    $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $gitExecutable = Get-GitExecutableOrThrow
    $repositoryRoot = Get-GitRepositoryRootOrThrow -GitExecutable $gitExecutable -StartDirectory (Get-Location).Path

    $stagedFiles = @(Invoke-GitCommandOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -Arguments @("diff", "--cached", "--name-only", "--diff-filter=ACMR") -FailureCode "E_PRECOMMIT_AUTOREPAIR_STAGED_DISCOVERY_FAILED" -FailureContext "failed to discover staged files")
    if ($stagedFiles.Count -eq 0) {
        Write-Verbose "Pre-commit auto-repair: no staged files found; skipping."
        return
    }

    $windowsLanguagePattern = '^(Scripts/AutoHotKey/.+\.ahk|Config/\.config/.+\.ahk|Scripts/.+\.bat)$'
    $windowsLanguageTargets = @($stagedFiles | Where-Object { $_ -match $windowsLanguagePattern } | Sort-Object -Unique)
    if ($windowsLanguageTargets.Count -eq 0) {
        Write-Verbose "Pre-commit auto-repair: no staged Windows language targets found; skipping."
        return
    }

    $unstagedTargets = @(Invoke-GitCommandOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -Arguments (@("diff", "--name-only", "--") + $windowsLanguageTargets) -FailureCode "E_PRECOMMIT_AUTOREPAIR_UNSTAGED_DISCOVERY_FAILED" -FailureContext "failed to detect unstaged Windows language drift")
    $unstagedTargetLookup = @{}
    foreach ($unstagedTarget in $unstagedTargets) {
        $unstagedTargetLookup[$unstagedTarget] = $true
    }

    $repairTargets = @(
        foreach ($target in $windowsLanguageTargets) {
            if (-not $unstagedTargetLookup.ContainsKey($target)) {
                $target
            }
        }
    )

    $skippedUnstagedTargets = @(
        foreach ($target in $windowsLanguageTargets) {
            if ($unstagedTargetLookup.ContainsKey($target)) {
                $target
            }
        }
    )

    if ($skippedUnstagedTargets.Count -gt 0) {
        Write-Warning (
            "W_PRECOMMIT_AUTOREPAIR_WINDOWS_LANGUAGE_SKIPPED_UNSTAGED: skipping auto-repair for staged Windows language files with unstaged drift: {0}." -f
            ($skippedUnstagedTargets -join ', ')
        )
    }

    $sourceMappedTargets = @{}
    $sourceCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($target in $repairTargets) {
        if ($target -notmatch '^Config/\.config/(.+\.ahk)$') {
            continue
        }

        $sourceRelativePath = "Scripts/AutoHotKey/$($Matches[1])"
        $sourceAbsolutePath = Join-Path -Path $repositoryRoot -ChildPath $sourceRelativePath
        if (-not (Test-Path -LiteralPath $sourceAbsolutePath -PathType Leaf)) {
            continue
        }

        $sourceMappedTargets[$target] = $sourceRelativePath
        [void]$sourceCandidates.Add($sourceRelativePath)
    }

    $sourceSkippedTargets = @()
    if ($sourceCandidates.Count -gt 0) {
        $sourceUnstagedTargets = @(Invoke-GitCommandOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -Arguments (@("diff", "--name-only", "--") + @($sourceCandidates.ToArray())) -FailureCode "E_PRECOMMIT_AUTOREPAIR_SOURCE_UNSTAGED_DISCOVERY_FAILED" -FailureContext "failed to detect unstaged source drift for config snapshot repair")
        $sourceUnstagedLookup = @{}
        foreach ($sourceUnstagedTarget in $sourceUnstagedTargets) {
            $sourceUnstagedLookup[$sourceUnstagedTarget] = $true
        }

        $sourceSkippedTargets = @(
            foreach ($target in $repairTargets) {
                if (-not $sourceMappedTargets.ContainsKey($target)) {
                    continue
                }

                $sourceRelativePath = [string]$sourceMappedTargets[$target]
                if ($sourceUnstagedLookup.ContainsKey($sourceRelativePath)) {
                    $target
                }
            }
        )

        if ($sourceSkippedTargets.Count -gt 0) {
            $sourceSkipDetails = @(
                foreach ($target in $sourceSkippedTargets) {
                    "{0} <- {1}" -f $target, [string]$sourceMappedTargets[$target]
                }
            )

            Write-Warning (
                "W_PRECOMMIT_AUTOREPAIR_WINDOWS_LANGUAGE_SOURCE_UNSTAGED: skipping config snapshot auto-repair because mapped source files have unstaged drift: {0}." -f
                ($sourceSkipDetails -join ', ')
            )

            $repairTargets = @(
                $repairTargets |
                    Where-Object { $sourceSkippedTargets -notcontains $_ }
            )
        }
    }

    if ($repairTargets.Count -eq 0) {
        Write-Verbose "Pre-commit auto-repair: no safe staged Windows language targets were eligible for auto-repair."
        return
    }

    Write-Host ("Running pre-hook Windows language safe auto-repair for {0} file(s)..." -f $repairTargets.Count)
    Invoke-WindowsLanguageCheckerForAutoRepair -RepositoryRoot $repositoryRoot -RepairTargets $repairTargets

    $changedRepairTargets = @(Invoke-GitCommandOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -Arguments (@("diff", "--name-only", "--") + $repairTargets) -FailureCode "E_PRECOMMIT_AUTOREPAIR_POSTCHECK_FAILED" -FailureContext "failed to detect post-repair Windows language drift")
    if ($changedRepairTargets.Count -eq 0) {
        Write-Verbose "Pre-commit auto-repair: no file content changes were produced by safe auto-repair."
        Write-Verbose ("Pre-commit auto-repair timing: totalMs={0}" -f [int]$totalStopwatch.ElapsedMilliseconds)
        return
    }

    $null = Invoke-GitCommandOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -Arguments (@("add", "--") + $changedRepairTargets) -FailureCode "E_PRECOMMIT_AUTOREPAIR_GIT_ADD_FAILED" -FailureContext "failed to stage auto-repaired Windows language files"

    Write-Host ("Auto-repaired and staged Windows language file(s): {0}" -f ($changedRepairTargets -join ', '))
    Write-Verbose ("Pre-commit auto-repair timing: totalMs={0}" -f [int]$totalStopwatch.ElapsedMilliseconds)
}

if (-not $NoInvokeMain) {
    Invoke-PreCommitAutoRepairMain
}
