param(
    [Parameter(Mandatory = $false)]
    [switch]$Unattended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Redirected native stderr must never escalate to a terminating error during output capture
# (no-op on Windows PowerShell 5.1, which lacks this preference variable).
$PSNativeCommandUseErrorActionPreference = $false

$scriptsDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
$diagnosticsHelpersPath = Join-Path -Path $scriptsDirectory -ChildPath "Utils/Common/DiagnosticsHelpers.ps1"
if (-not (Test-Path -LiteralPath $diagnosticsHelpersPath -PathType Leaf)) {
    throw "E_BACKUP_DIAGNOSTICS_HELPER_MISSING: diagnostics helper file not found at '$diagnosticsHelpersPath'."
}

. $diagnosticsHelpersPath

$compatibilityHelpersPath = Join-Path -Path $scriptsDirectory -ChildPath "Utils/Common/CompatibilityHelpers.ps1"
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_BACKUP_COMPATIBILITY_HELPER_MISSING: compatibility helper file not found at '$compatibilityHelpersPath'."
}

. $compatibilityHelpersPath

$backupSecretHygieneHelpersPath = Join-Path -Path $scriptsDirectory -ChildPath "Utils/Common/BackupSecretHygieneHelpers.ps1"
if (-not (Test-Path -LiteralPath $backupSecretHygieneHelpersPath -PathType Leaf)) {
    throw "E_BACKUP_SECRET_HYGIENE_HELPER_MISSING: backup secret hygiene helper file not found at '$backupSecretHygieneHelpersPath'."
}

. $backupSecretHygieneHelpersPath

$canonicalJsonHelpersPath = Join-Path -Path $scriptsDirectory -ChildPath "Utils/Common/CanonicalJsonHelpers.ps1"
if (-not (Test-Path -LiteralPath $canonicalJsonHelpersPath -PathType Leaf)) {
    throw "E_BACKUP_CANONICAL_JSON_HELPER_MISSING: canonical JSON helper file not found at '$canonicalJsonHelpersPath'."
}

. $canonicalJsonHelpersPath

$pwshCommand = Resolve-PowerShellExecutablePath

function Get-LastExitCodeOrDefault {
    $lecValue = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $lecValue) {
        return [int]$lecValue
    }

    return 0
}

function Test-BackupTruthySettingValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return ($Value.Trim() -match '^(?i:1|true|yes|on)$')
}

function Get-PathspecDiagnosticsText {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$Pathspec = @()
    )

    if (@($Pathspec).Count -eq 0) {
        return "(none)"
    }

    return (@($Pathspec | ForEach-Object { "'{0}'" -f $_ }) -join ', ')
}

function Get-GitCommandDiagnosticsOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string[]]$GitArguments
    )

    return @(& $GitExecutable @GitArguments 2>&1) # array-unwrap-safe: callers always wrap with @()
}

function Get-GitExecutableOrThrow {
    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "E_BACKUP_GIT_NOT_AVAILABLE: git executable was not found on PATH. Install git and retry backup git operations."
    }

    Write-Verbose (
        "Backup git availability diagnostics: gitPath='{0}'; scriptsDirectory='{1}'" -f
        $gitCommand.Source,
        $scriptsDirectory
    )

    return $gitCommand.Source
}

function Get-GitRepositoryRootOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$StartDirectory
    )

    $repoRootArgs = @("-C", $StartDirectory, "rev-parse", "--show-toplevel")
    $repoRootOutput = @(& $GitExecutable @repoRootArgs 2>$null)
    $repoRootExitCode = Get-LastExitCodeOrDefault
    if ($repoRootExitCode -ne 0 -or $repoRootOutput.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$repoRootOutput[0])) {
        $repoRootDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $GitExecutable -GitArguments $repoRootArgs)
        $repoRootPreview = Get-OutputPreview -OutputLines $repoRootDiagnostics
        throw (
            "E_BACKUP_GIT_NOT_REPOSITORY: expected a git work tree at '{0}' but rev-parse --show-toplevel returned exitCode={1} value='{2}' outputPreview={3}." -f
            $StartDirectory,
            $repoRootExitCode,
            (($repoRootOutput -join ' ').Trim()),
            $repoRootPreview
        )
    }

    return (Resolve-Path -LiteralPath ([string]$repoRootOutput[0]).Trim() -ErrorAction Stop).Path
}

function Assert-BackupGitBranchOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedBranch
    )

    $branchArgs = @("-C", $RepositoryRoot, "rev-parse", "--abbrev-ref", "HEAD")
    $branchOutput = @(& $GitExecutable @branchArgs 2>$null)
    $branchExitCode = Get-LastExitCodeOrDefault
    if ($branchExitCode -ne 0 -or $branchOutput.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$branchOutput[0])) {
        $branchDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $GitExecutable -GitArguments $branchArgs)
        $branchPreview = Get-OutputPreview -OutputLines $branchDiagnostics
        throw (
            "E_BACKUP_GIT_BRANCH_DETECTION_FAILED: git rev-parse --abbrev-ref HEAD failed (exitCode={0}; repositoryRoot='{1}'; outputPreview={2})." -f
            $branchExitCode,
            $RepositoryRoot,
            $branchPreview
        )
    }

    $currentBranch = ([string]$branchOutput[0]).Trim()
    if ($currentBranch -eq "HEAD") {
        throw (
            "E_BACKUP_GIT_DETACHED_HEAD: git HEAD is detached at repositoryRoot='{0}'. Backup requires branch '{1}'." -f
            $RepositoryRoot,
            $ExpectedBranch
        )
    }

    if ($currentBranch -ne $ExpectedBranch) {
        throw (
            "E_BACKUP_GIT_BRANCH_MISMATCH: current branch is '{0}' but backup requires '{1}' (repositoryRoot='{2}')." -f
            $currentBranch,
            $ExpectedBranch,
            $RepositoryRoot
        )
    }

    Write-Verbose (
        "Backup git branch diagnostics: currentBranch='{0}'; expectedBranch='{1}'; repositoryRoot='{2}'" -f
        $currentBranch,
        $ExpectedBranch,
        $RepositoryRoot
    )
}

function Assert-BackupGitRemoteHeadOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$RemoteName,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $localHeadArgs = @("-C", $RepositoryRoot, "rev-parse", "HEAD")
    $localHeadOutput = @(& $GitExecutable @localHeadArgs 2>$null)
    $localHeadExitCode = Get-LastExitCodeOrDefault
    if ($localHeadExitCode -ne 0 -or $localHeadOutput.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$localHeadOutput[0])) {
        $localHeadDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $GitExecutable -GitArguments $localHeadArgs)
        throw (
            "E_BACKUP_GIT_REMOTE_VERIFY_FAILED: local HEAD verification failed after push (exitCode={0}; repositoryRoot='{1}'; outputPreview={2})." -f
            $localHeadExitCode,
            $RepositoryRoot,
            (Get-OutputPreview -OutputLines $localHeadDiagnostics)
        )
    }

    $remoteRef = "refs/heads/{0}" -f $BranchName
    $remoteHeadArgs = @("-C", $RepositoryRoot, "ls-remote", "--exit-code", "--refs", $RemoteName, $remoteRef)
    $remoteHeadOutput = @(& $GitExecutable @remoteHeadArgs 2>$null)
    $remoteHeadExitCode = Get-LastExitCodeOrDefault
    if ($remoteHeadExitCode -ne 0 -or $remoteHeadOutput.Count -eq 0 -or [string]$remoteHeadOutput[0] -notmatch '^([0-9a-fA-F]{40})\s+') {
        $remoteHeadDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $GitExecutable -GitArguments $remoteHeadArgs)
        throw (
            "E_BACKUP_GIT_REMOTE_VERIFY_FAILED: remote branch verification failed after push (exitCode={0}; repositoryRoot='{1}'; remote='{2}'; branch='{3}'; outputPreview={4})." -f
            $remoteHeadExitCode,
            $RepositoryRoot,
            $RemoteName,
            $BranchName,
            (Get-OutputPreview -OutputLines $remoteHeadDiagnostics)
        )
    }

    $localHead = ([string]$localHeadOutput[0]).Trim()
    $remoteHead = ([regex]::Match([string]$remoteHeadOutput[0], '^([0-9a-fA-F]{40})\s+')).Groups[1].Value
    if (-not [string]::Equals($localHead, $remoteHead, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (
            "E_BACKUP_GIT_REMOTE_HEAD_MISMATCH: remote branch does not point to the pushed commit (repositoryRoot='{0}'; remote='{1}'; branch='{2}'; localHead='{3}'; remoteHead='{4}')." -f
            $RepositoryRoot,
            $RemoteName,
            $BranchName,
            $localHead,
            $remoteHead
        )
    }

    Write-Verbose (
        "Backup git remote verification diagnostics: remote='{0}'; branch='{1}'; verifiedHead='{2}'; repositoryRoot='{3}'" -f
        $RemoteName,
        $BranchName,
        $localHead,
        $RepositoryRoot
    )
}

function Get-GitStatusLinesOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$Pathspec = @()
    )

    $statusArgs = @("-C", $RepositoryRoot, "status", "--porcelain=v1", "--untracked-files=all")
    if ($Pathspec.Count -gt 0) {
        $statusArgs += "--"
        $statusArgs += $Pathspec
    }

    $statusOutput = @(& $GitExecutable @statusArgs 2>$null)
    $statusExitCode = Get-LastExitCodeOrDefault
    if ($statusExitCode -ne 0) {
        $statusDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $GitExecutable -GitArguments $statusArgs)
        $statusPreview = Get-OutputPreview -OutputLines $statusDiagnostics
        $pathspecText = Get-PathspecDiagnosticsText -Pathspec $Pathspec
        throw (
            "E_BACKUP_GIT_STATUS_FAILED: git status --porcelain=v1 --untracked-files=all failed (exitCode={0}; repositoryRoot='{1}'; pathspec={2}; outputPreview={3})." -f
            $statusExitCode,
            $RepositoryRoot,
            $pathspecText,
            $statusPreview
        )
    }

    return @($statusOutput) # array-unwrap-safe: callers always wrap with @()
}

function Get-GitStatusSummary {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$StatusLines = @()
    )

    $trackedChanges = @($StatusLines | Where-Object { $_ -notmatch '^\?\?' })
    $untrackedChanges = @($StatusLines | Where-Object { $_ -match '^\?\?' })

    return [pscustomobject]@{
        TrackedCount   = $trackedChanges.Count
        UntrackedCount = $untrackedChanges.Count
        TotalCount     = @($StatusLines).Count
        Details        = ($StatusLines -join [Environment]::NewLine)
    }
}

function Assert-BackupGitTreeCleanPreflight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$ManagedPathspecs
    )

    $statusLines = @(Get-GitStatusLinesOrThrow -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot)
    if ($statusLines.Count -eq 0) {
        return $false
    }

    $statusSummary = Get-GitStatusSummary -StatusLines $statusLines
    $outsideManagedPathspec = @(".")
    foreach ($managedPathspec in $ManagedPathspecs) {
        $outsideManagedPathspec += ":(exclude)$managedPathspec"
    }

    $outsideManagedChanges = @(Get-GitStatusLinesOrThrow -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Pathspec $outsideManagedPathspec)
    if ($outsideManagedChanges.Count -gt 0) {
        $outsideSummary = Get-GitStatusSummary -StatusLines $outsideManagedChanges
        throw ((
                "E_BACKUP_GIT_TREE_DIRTY_PREFLIGHT: Repository has pre-existing changes before backup begins, including changes outside managed pathspecs ({0}). " +
                "Commit or discard out-of-scope changes before running backup.`nSummary: tracked={1}, untracked={2}, total={3}`nDetails:`n{4}`nOut-of-scope details:`n{5}") -f
            ($ManagedPathspecs -join ', '),
            $statusSummary.TrackedCount,
            $statusSummary.UntrackedCount,
            $statusSummary.TotalCount,
            $statusSummary.Details,
            $outsideSummary.Details)
    }

    Write-Warning ((
            "W_BACKUP_GIT_MANAGED_DIRTY_PREFLIGHT: Preserving pre-existing changes under managed pathspecs ({0}) through git pull and backup regeneration. " +
            "These files remain eligible for the managed backup commit. tracked={1}; untracked={2}; total={3}; details={4}") -f
        ($ManagedPathspecs -join ', '),
        $statusSummary.TrackedCount,
        $statusSummary.UntrackedCount,
        $statusSummary.TotalCount,
        ($statusSummary.Details -replace "`r?`n", '; '))

    return $true
}

function Invoke-BackupGitPullWithManagedChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$ManagedPathspecs
    )

    $managedStatus = @(Get-GitStatusLinesOrThrow -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot -Pathspec $ManagedPathspecs)
    $stashCreated = $false
    $stashReference = ""

    if ($managedStatus.Count -gt 0) {
        $stashMessage = "wallstop-backup-managed-preflight-{0}" -f ([DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ", [System.Globalization.CultureInfo]::InvariantCulture))
        $stashArgs = @("-C", $RepositoryRoot, "stash", "push", "--include-untracked", "--message", $stashMessage, "--")
        $stashArgs += $ManagedPathspecs
        $stashOutput = @(& $GitExecutable @stashArgs 2>&1)
        $stashExitCode = Get-LastExitCodeOrDefault
        if ($stashExitCode -ne 0) {
            throw (
                "E_BACKUP_GIT_MANAGED_STASH_FAILED: git stash push for pre-existing managed changes exited with code {0} (repositoryRoot='{1}'; pathspec={2}; outputPreview={3})." -f
                $stashExitCode,
                $RepositoryRoot,
                (Get-PathspecDiagnosticsText -Pathspec $ManagedPathspecs),
                (Get-OutputPreview -OutputLines $stashOutput)
            )
        }

        $stashReferenceOutput = @(& $GitExecutable -C $RepositoryRoot rev-parse --verify refs/stash 2>$null)
        $stashReferenceExitCode = Get-LastExitCodeOrDefault
        if ($stashReferenceExitCode -ne 0 -or $stashReferenceOutput.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$stashReferenceOutput[0])) {
            throw "E_BACKUP_GIT_MANAGED_STASH_REFERENCE_FAILED: managed changes were stashed but refs/stash could not be verified; do not continue until the stash is recovered manually."
        }

        $stashReference = ([string]$stashReferenceOutput[0]).Trim()
        $stashCreated = $true
        Write-Verbose (
            "Backup managed-change stash diagnostics: stashReference='{0}'; repositoryRoot='{1}'; pathspec={2}" -f
            $stashReference,
            $RepositoryRoot,
            (Get-PathspecDiagnosticsText -Pathspec $ManagedPathspecs)
        )
    }

    $gitPullOutput = @(& $GitExecutable -C $RepositoryRoot pull --ff-only origin main 2>&1)
    $gitPullExitCode = Get-LastExitCodeOrDefault
    if ($gitPullExitCode -ne 0) {
        if ($stashCreated) {
            $restoreOutput = @(& $GitExecutable -C $RepositoryRoot stash pop --index 2>&1)
            $restoreExitCode = Get-LastExitCodeOrDefault
            if ($restoreExitCode -ne 0) {
                throw (
                    "E_BACKUP_GIT_MANAGED_RESTORE_FAILED: git pull failed and restoring managed pre-existing changes also failed (restoreExitCode={0}; stashReference='{1}'; repositoryRoot='{2}'; outputPreview={3})." -f
                    $restoreExitCode,
                    $stashReference,
                    $RepositoryRoot,
                    (Get-OutputPreview -OutputLines $restoreOutput)
                )
            }
        }

        throw (
            "E_BACKUP_GIT_PULL_FAILED: git pull --ff-only origin main exited with code {0} (repositoryRoot='{1}'; managedChangesStashed={2}; outputPreview={3})." -f
            $gitPullExitCode,
            $RepositoryRoot,
            $stashCreated,
            (Get-OutputPreview -OutputLines $gitPullOutput)
        )
    }

    if ($stashCreated) {
        $restoreOutput = @(& $GitExecutable -C $RepositoryRoot stash pop --index 2>&1)
        $restoreExitCode = Get-LastExitCodeOrDefault
        if ($restoreExitCode -ne 0) {
            throw (
                "E_BACKUP_GIT_MANAGED_RESTORE_FAILED: git pull succeeded but restoring managed pre-existing changes failed (restoreExitCode={0}; stashReference='{1}'; repositoryRoot='{2}'; outputPreview={3}). The stash remains available for manual recovery." -f
                $restoreExitCode,
                $stashReference,
                $RepositoryRoot,
                (Get-OutputPreview -OutputLines $restoreOutput)
            )
        }

        Write-Verbose (
            "Backup managed-change restore diagnostics: restoredStash='{0}'; repositoryRoot='{1}'" -f
            $stashReference,
            $RepositoryRoot
        )
    }

    Write-Verbose (
        "Backup git pull diagnostics: repositoryRoot='{0}'; managedChangesStashed={1}; outputPreview={2}" -f
        $RepositoryRoot,
        $stashCreated,
        (Get-OutputPreview -OutputLines $gitPullOutput)
    )
}

function Get-BackupManagedPathspecs {
    # All backup step scripts in this orchestrator are contractually constrained to write repository outputs under Config/.
    return @("Config/") # array-unwrap-safe: callers always wrap with @()
}

function Assert-BackupManagedPathspecs {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ManagedPathspecs
    )

    if (@($ManagedPathspecs).Count -eq 0) {
        throw "E_BACKUP_GIT_SCOPE_PATHSPEC_EMPTY: Backup managed pathspec list must not be empty."
    }

    foreach ($managedPathspec in $ManagedPathspecs) {
        if ([string]::IsNullOrWhiteSpace($managedPathspec)) {
            throw "E_BACKUP_GIT_SCOPE_PATHSPEC_INVALID: Backup managed pathspec list contains an empty value."
        }
    }
}

function Get-BackupManagedChangedFilesOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$ManagedPathspecs
    )

    # Diff against HEAD (not the index): pre-existing STAGED managed changes survive the pull
    # via stash --index, so index-relative diffs would hide them from oversize/AHK/secret
    # guards while `git add Config/` would happily commit them.
    $trackedChangedArgs = @("-C", $RepositoryRoot, "diff", "HEAD", "--name-only", "--diff-filter=AM", "--")
    $trackedChangedArgs += $ManagedPathspecs
    $trackedChangedOutput = @(& $GitExecutable @trackedChangedArgs 2>$null)
    $trackedChangedExitCode = Get-LastExitCodeOrDefault
    if ($trackedChangedExitCode -ne 0) {
        $trackedChangedDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $GitExecutable -GitArguments $trackedChangedArgs)
        $trackedChangedPreview = Get-OutputPreview -OutputLines $trackedChangedDiagnostics
        throw (
            "E_BACKUP_GIT_CHANGED_FILE_DISCOVERY_FAILED: git diff --name-only --diff-filter=AM failed (exitCode={0}; repositoryRoot='{1}'; pathspec={2}; outputPreview={3})." -f
            $trackedChangedExitCode,
            $RepositoryRoot,
            (Get-PathspecDiagnosticsText -Pathspec $ManagedPathspecs),
            $trackedChangedPreview
        )
    }

    $untrackedChangedArgs = @("-C", $RepositoryRoot, "ls-files", "--others", "--exclude-standard", "--")
    $untrackedChangedArgs += $ManagedPathspecs
    $untrackedChangedOutput = @(& $GitExecutable @untrackedChangedArgs 2>$null)
    $untrackedChangedExitCode = Get-LastExitCodeOrDefault
    if ($untrackedChangedExitCode -ne 0) {
        $untrackedChangedDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $GitExecutable -GitArguments $untrackedChangedArgs)
        $untrackedChangedPreview = Get-OutputPreview -OutputLines $untrackedChangedDiagnostics
        throw (
            "E_BACKUP_GIT_CHANGED_FILE_DISCOVERY_FAILED: git ls-files --others --exclude-standard failed (exitCode={0}; repositoryRoot='{1}'; pathspec={2}; outputPreview={3})." -f
            $untrackedChangedExitCode,
            $RepositoryRoot,
            (Get-PathspecDiagnosticsText -Pathspec $ManagedPathspecs),
            $untrackedChangedPreview
        )
    }

    $pathComparer = if (Test-IsWindowsPlatform) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    $managedChangedFiles = New-Object System.Collections.Generic.List[string]

    foreach ($candidatePath in @($trackedChangedOutput + $untrackedChangedOutput)) {
        $relativePath = [string]$candidatePath
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $relativePath = $relativePath.Trim()
        if (-not $seenPaths.Add($relativePath)) {
            continue
        }

        $fullPath = Join-Path -Path $RepositoryRoot -ChildPath $relativePath
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [void]$managedChangedFiles.Add($relativePath)
        }
    }

    return $managedChangedFiles.ToArray()
}

function Repair-BackupManagedAhkSnapshots {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$ManagedChangedFiles = @()
    )

    # Unattended backup commits bypass pre-commit hooks (--no-verify), including the auto-repair
    # hook that keeps Config/.config AutoHotkey snapshots synced to their Scripts/AutoHotKey v2
    # sources. Without this gate, host-side drift regresses committed snapshots to AHK v1
    # (observed twice: session-020 and the 2026-08-23 backup), breaking main CI even though the
    # attended commit path self-heals the same drift.
    $snapshotPattern = '(?i)^Config/\.config/.+\.ahk$'
    $snapshotTargets = @($ManagedChangedFiles | Where-Object { $_ -match $snapshotPattern } | Sort-Object -Unique)
    if ($snapshotTargets.Count -eq 0) {
        return ""
    }

    $windowsLanguageChecksPath = Join-Path -Path $scriptsDirectory -ChildPath "Utils/Quality/Invoke-WindowsLanguageChecks.ps1"
    if (-not (Test-Path -LiteralPath $windowsLanguageChecksPath -PathType Leaf)) {
        throw "E_BACKUP_SNAPSHOT_REFRESH_CHECKER_MISSING: Windows language checker not found at '$windowsLanguageChecksPath'."
    }

    $absoluteTargets = @($snapshotTargets | ForEach-Object { Join-Path -Path $RepositoryRoot -ChildPath $_ })
    # `pwsh -File` misbinds a second array element to a positional parameter, so pass the
    # targets as one semicolon-joined token; the checker splits inputs on ';' and newlines.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $checkerOutput = @(& $pwshCommand -NoLogo -NoProfile -File $windowsLanguageChecksPath -TargetFiles ($absoluteTargets -join ';') -Fix -StaticOnly 2>&1 | ForEach-Object { [string]$_ })
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($outputLine in $checkerOutput) {
        Write-Host $outputLine
    }

    $checkerExitCode = Get-LastExitCodeOrDefault
    if ($checkerExitCode -ne 0) {
        return (
            "E_BACKUP_SNAPSHOT_REFRESH_FAILED: AutoHotkey snapshot source-refresh failed (exitCode={0}; targets={1}; outputPreview={2})." -f
            $checkerExitCode,
            (Get-PathspecDiagnosticsText -Pathspec $snapshotTargets),
            (Get-OutputPreview -OutputLines $checkerOutput -MaxLines 20 -MaxCharacters 2000 -HeadTailWhenTruncated)
        )
    }

    Write-Verbose ("Backup snapshot refresh diagnostics: refreshedTargets={0}." -f (Get-PathspecDiagnosticsText -Pathspec $snapshotTargets))
    return ""
}

function Get-BackupOversizedManagedFileErrors {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RelativePaths = @(),

        [Parameter(Mandatory = $true)]
        [long]$FailLimitBytes,

        [Parameter(Mandatory = $true)]
        [long]$WarnLimitBytes
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in @($RelativePaths)) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $fullPath = Join-Path -Path $RepositoryRoot -ChildPath $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            continue
        }

        $length = (Get-Item -LiteralPath $fullPath -Force).Length
        if ($length -gt $FailLimitBytes) {
            # GitHub hard-rejects blobs above 100MiB at push time, which strands the entire
            # backup push while every later backup stacks on top of the unpushable commit.
            # Fail closed here so oversize artifacts never enter a commit.
            $errors.Add((
                    "E_BACKUP_MANAGED_FILE_OVERSIZE: '{0}' is {1} bytes which exceeds the {2}-byte backup fail limit; GitHub rejects blobs over 100MiB, which would strand the whole backup push." -f
                    $relativePath,
                    $length,
                    $FailLimitBytes
                ))
            continue
        }

        if ($length -gt $WarnLimitBytes) {
            Write-Warning (
                "W_BACKUP_MANAGED_FILE_LARGE: '{0}' is {1} bytes (above the {2}-byte advisory limit)." -f
                $relativePath,
                $length,
                $WarnLimitBytes
            )
        }
    }

    return $errors.ToArray()
}

function Set-BackupStepFailuresArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$FailedEntries = @(),

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$SucceededStepNames = @(),

        [Parameter(Mandatory = $true)]
        [int]$TotalSteps,

        [Parameter(Mandatory = $false)]
        [switch]$RedactOutputPreviews
    )

    # Persistent counterpart to the console-only backup summary: partial-failure runs record the
    # failing step names, error messages, and bounded output previews under Config/ so future
    # failures are diagnosable from git history alone (issue #46). The document carries no
    # timestamps (the commit date provides timing) so schema/order stay deterministic; volatile
    # preview text updates on each failing run by design. It is removed again after a fully
    # successful run. I/O faults here fail OPEN with stable diagnostics: losing or failing to
    # remove a diagnostics file must never abort the backup run itself.
    $artifactPath = Join-Path -Path $RepositoryRoot -ChildPath "Config/backup-step-failures.json"
    if (@($FailedEntries).Count -eq 0) {
        if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $artifactPath -Force -ErrorAction Stop
                Write-Host "Removed stale backup failure artifact after a fully successful run: '$artifactPath'." -ForegroundColor Green
            }
            catch {
                Write-Warning (
                    "W_BACKUP_FAILURE_ARTIFACT_REMOVE_FAILED: a fully successful run could not remove the stale failure artifact '{0}' ({1}); it will be retried on the next run." -f
                    $artifactPath,
                    $_.Exception.Message
                )
            }
        }
        return
    }

    $failedStepEntries = @(@($FailedEntries) | Where-Object { $_ -isnot [string] })
    $phaseFailureTexts = @(@($FailedEntries) | Where-Object { $_ -is [string] })

    $artifactDocument = [ordered]@{
        failedSteps = @(
            foreach ($failedEntry in $failedStepEntries) {
                [ordered]@{
                    name          = [string]$failedEntry.Name
                    error         = [string]$failedEntry.Error
                    outputPreview = $(if ($RedactOutputPreviews) { "(redacted: secret pattern detected in captured output)" } else { [string]$failedEntry.OutputPreview })
                }
            }
        )
        phaseFailures  = @($phaseFailureTexts)
        succeededSteps = @($SucceededStepNames)
        totalSteps     = $TotalSteps
    }

    $rawJson = ConvertTo-Json -InputObject $artifactDocument -Depth 6
    $canonicalJson = ConvertTo-CanonicalJsonText -RawJson $rawJson
    try {
        [System.IO.File]::WriteAllText($artifactPath, $canonicalJson, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-Warning (
            "E_BACKUP_FAILURE_ARTIFACT_WRITE_FAILED: could not persist failure reasons to '{0}' ({1})." -f
            $artifactPath,
            $_.Exception.Message
        )
        return
    }

    Write-Warning (
        "W_BACKUP_FAILURE_ARTIFACT_WRITTEN: recorded {0} failure entr(y|ies) in persistent artifact '{1}' so the reasons are diagnosable from git history." -f
        @($FailedEntries).Count,
        $artifactPath
    )
}

function Invoke-BackupKnownSecretSanitization {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RelativePaths = @()
    )

    return (Invoke-BackupSecretHygieneSanitizeKnownSecrets -RepositoryRoot $RepositoryRoot -RelativePaths $RelativePaths)
}

function Find-BackupUnknownSecretFindings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$RelativePaths = @()
    )

    return (Find-BackupSecretHygieneUnknownSecretFindings -RepositoryRoot $RepositoryRoot -RelativePaths $RelativePaths)
}

function Invoke-BackupStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$RelativeScriptPath
    )

    $scriptPath = Join-Path -Path $scriptsDirectory -ChildPath $RelativeScriptPath
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "E_BACKUP_STEP_SCRIPT_MISSING: Backup step '$Name' script not found at '$scriptPath'."
    }

    # Step output is captured and then echoed so failed-step diagnostics can be persisted into
    # Config/backup-step-failures.json. Unattended hosts lose console-only output, which is the
    # same diagnosability gap that issue #46 identified for step names: without capture, the
    # reason a step failed (for example winget's failing package output) never reaches git history.
    Write-Host ("Starting: {0}" -f $Name) -ForegroundColor Cyan
    # Redirected native stderr becomes a terminating NativeCommandError under EAP=Stop on
    # Windows PowerShell 5.1, so scope the capture to EAP=Continue.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $stepOutput = @(& $pwshCommand -NoLogo -NoProfile -File $scriptPath 2>&1 | ForEach-Object { [string]$_ })
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($outputLine in $stepOutput) {
        Write-Host $outputLine
    }

    $exitCode = Get-LastExitCodeOrDefault
    $failureMessage = $null
    if ($exitCode -ne 0) {
        $failureMessage = ("E_BACKUP_STEP_FAILED({0}): script '{1}' at '{2}' exited with code {3}." -f $Name, $RelativeScriptPath, $scriptPath, $exitCode)
        Write-Warning ("{0}: {1}" -f $Name, $failureMessage)
    }
    else {
        Write-Host ("Completed: {0}" -f $Name) -ForegroundColor Green
    }

    return [pscustomobject]@{
        Succeeded    = ($null -eq $failureMessage)
        Error        = $(if ($null -eq $failureMessage) { "" } else { $failureMessage })
        OutputLines  = $stepOutput
    }
}

function Assert-BackupStepScriptsExist {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Steps
    )

    $missingSteps = New-Object System.Collections.Generic.List[object]
    foreach ($step in $Steps) {
        $scriptPath = Join-Path -Path $scriptsDirectory -ChildPath $step.RelativeScriptPath
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            [void]$missingSteps.Add([pscustomobject]@{
                    Name               = $step.Name
                    RelativeScriptPath = $step.RelativeScriptPath
                    ScriptPath         = $scriptPath
                })
        }
    }

    if ($missingSteps.Count -eq 0) {
        return
    }

    Write-Warning ("E_BACKUP_PRE_FLIGHT_STEP_SCRIPT_MISSING: Found {0} missing backup step script(s)." -f $missingSteps.Count)
    Write-Warning ("Backup step root path diagnostics: scriptsDirectory='{0}'" -f $scriptsDirectory)
    foreach ($missingStep in $missingSteps) {
        Write-Warning ("Missing step '{0}' ({1}) expected at '{2}'." -f $missingStep.Name, $missingStep.RelativeScriptPath, $missingStep.ScriptPath)
    }

    throw "E_BACKUP_PRE_FLIGHT_FAILED: Backup step script validation failed."
}

function Get-CurrentPlatformName {
    if (Test-IsWindowsPlatform) {
        return "Windows"
    }

    if (Test-IsMacOSPlatform) {
        return "macOS"
    }

    if (Test-IsLinuxPlatform) {
        return "Linux"
    }

    return "Unknown"
}

function Get-ApplicableBackupSteps {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Steps,

        [Parameter(Mandatory = $true)]
        [string]$CurrentPlatformName
    )

    $applicableSteps = New-Object System.Collections.Generic.List[object]
    foreach ($step in $Steps) {
        $supportedPlatforms = @($step.SupportedPlatforms)
        if ($supportedPlatforms.Count -eq 0) {
            throw (
                "E_BACKUP_STEP_METADATA_INVALID({0}): Step '{1}' must define SupportedPlatforms metadata." -f
                $step.Name,
                $step.Name
            )
        }

        if ($supportedPlatforms -contains "All" -or $supportedPlatforms -contains $CurrentPlatformName) {
            [void]$applicableSteps.Add($step)
            continue
        }

        Write-Warning (
            "W_BACKUP_STEP_SKIPPED_PLATFORM: Skipping step '{0}' ({1}) on platform '{2}'. SupportedPlatforms={3}." -f
            $step.Name,
            $step.RelativeScriptPath,
            $CurrentPlatformName,
            ($supportedPlatforms -join ', ')
        )
    }

    return $applicableSteps.ToArray()
}

function Assert-ApplicableBackupStepsFlat {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ApplicableSteps,

        [Parameter(Mandatory = $true)]
        [string]$CurrentPlatformName
    )

    $nestedStepContainers = @($ApplicableSteps | Where-Object { $_ -is [System.Array] })
    Write-Verbose (
        "Backup step selection diagnostics: currentPlatform='{0}', applicableSteps={1}, nestedStepContainers={2}" -f
        $CurrentPlatformName,
        $ApplicableSteps.Count,
        $nestedStepContainers.Count
    )

    if ($nestedStepContainers.Count -gt 0) {
        throw (
            "E_BACKUP_STEP_SELECTION_INVALID: Applicable step selection contains nested array value(s) ({0}) on platform '{1}'. Ensure Get-ApplicableBackupSteps returns a flat step list and callers use @(...)." -f
            $nestedStepContainers.Count,
            $CurrentPlatformName
        )
    }
}

$unattendedEnvironmentValue = [string]$env:WALLSTOP_BACKUP_UNATTENDED
$isUnattendedMode = $false
$unattendedModeSource = 'default'

if ($PSBoundParameters.ContainsKey('Unattended')) {
    if ($Unattended.IsPresent) {
        $isUnattendedMode = $true
        $unattendedModeSource = 'parameter'
    }
}
elseif (Test-BackupTruthySettingValue -Value $unattendedEnvironmentValue) {
    $isUnattendedMode = $true
    $unattendedModeSource = 'environment'
}

Write-Verbose (
    "Backup unattended diagnostics: isUnattended={0}; source='{1}'; environmentValue='{2}'" -f
    $isUnattendedMode,
    $unattendedModeSource,
    $unattendedEnvironmentValue
)

$stepResults = New-Object System.Collections.Generic.List[object]
$phaseFailures = New-Object System.Collections.Generic.List[string]
$steps = @(
    @{ Name = "ConfigBackup"; RelativeScriptPath = "Config/ConfigBackup.ps1"; SupportedPlatforms = @("All") },
    @{ Name = "WindowsTerminalBackup"; RelativeScriptPath = "WindowsTerminal/WindowsTerminalBackup.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "PowershellBackup"; RelativeScriptPath = "Powershell/PowershellBackup.ps1"; SupportedPlatforms = @("All") },
    @{ Name = "StopKomorebi"; RelativeScriptPath = "Komorebi/StopKomorebi.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "ScoopHealthCheck"; RelativeScriptPath = "Scoop/Invoke-ScoopHealthCheck.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "ScoopUpdate"; RelativeScriptPath = "Scoop/ScoopUpdate.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "ScoopBackup"; RelativeScriptPath = "Scoop/ScoopBackup.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "KomorebiBackup"; RelativeScriptPath = "Komorebi/KomorebiBackup.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "PowerToysBackup"; RelativeScriptPath = "PowerToys/PowerToysBackup.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "ThunderbirdBackup"; RelativeScriptPath = "Thunderbird/ThunderbirdBackup.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "WinGetUpdate"; RelativeScriptPath = "WinGet/WinGetUpdate.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "RestartKomorebi"; RelativeScriptPath = "Komorebi/RestartKomorebi.ps1"; SupportedPlatforms = @("Windows") }
)

$currentPlatformName = Get-CurrentPlatformName
$applicableSteps = @(Get-ApplicableBackupSteps -Steps $steps -CurrentPlatformName $currentPlatformName)
Assert-ApplicableBackupStepsFlat -ApplicableSteps $applicableSteps -CurrentPlatformName $currentPlatformName

Write-Verbose ("Backup path diagnostics: scriptsDirectory='{0}'" -f $scriptsDirectory)
Write-Verbose ("Backup platform diagnostics: currentPlatform='{0}', totalSteps={1}, applicableSteps={2}" -f $currentPlatformName, $steps.Count, $applicableSteps.Count)
Assert-BackupStepScriptsExist -Steps $applicableSteps

Push-Location -LiteralPath $scriptsDirectory
try {
    $gitExecutable = Get-GitExecutableOrThrow
    $repositoryRoot = Get-GitRepositoryRootOrThrow -GitExecutable $gitExecutable -StartDirectory $scriptsDirectory
    $managedPathspecs = @(Get-BackupManagedPathspecs)
    Assert-BackupManagedPathspecs -ManagedPathspecs $managedPathspecs

    $insideWorkTreeArgs = @("-C", $repositoryRoot, "rev-parse", "--is-inside-work-tree")
    $insideWorkTreeOutput = @(& $gitExecutable @insideWorkTreeArgs 2>$null)
    $insideWorkTreeExitCode = Get-LastExitCodeOrDefault
    $insideWorkTree = if ($insideWorkTreeOutput.Count -gt 0) { ([string]$insideWorkTreeOutput[0]).Trim() } else { "" }
    if ($insideWorkTreeExitCode -ne 0 -or $insideWorkTree -ne "true") {
        $insideWorkTreeDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $gitExecutable -GitArguments $insideWorkTreeArgs)
        $insideWorkTreePreview = Get-OutputPreview -OutputLines $insideWorkTreeDiagnostics
        throw (
            "E_BACKUP_GIT_NOT_REPOSITORY: expected a git work tree at '{0}' but rev-parse returned exitCode={1} value='{2}' outputPreview={3}." -f
            $repositoryRoot,
            $insideWorkTreeExitCode,
            $insideWorkTree,
            $insideWorkTreePreview
        )
    }

    Write-Verbose (
        "Backup git preflight diagnostics: repositoryRoot='{0}'; insideWorkTreeExitCode={1}; insideWorkTree='{2}'" -f
        $repositoryRoot,
        $insideWorkTreeExitCode,
        $insideWorkTree
    )

    Write-Host ""
    Write-Host "========== BACKUP GIT PREFLIGHT ==========" -ForegroundColor Cyan
    $hasPreExistingManagedChanges = Assert-BackupGitTreeCleanPreflight -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -ManagedPathspecs $managedPathspecs
    Assert-BackupGitBranchOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -ExpectedBranch "main"
    if ($hasPreExistingManagedChanges) {
        Write-Host "Managed snapshot changes will be preserved through pull and regenerated before commit." -ForegroundColor Yellow
    }
    else {
        Write-Host "Git tree is clean before backup mutations." -ForegroundColor Green
    }

    # Pull before backup mutations so backup never starts from an out-of-date branch.
    Invoke-BackupGitPullWithManagedChanges -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -ManagedPathspecs $managedPathspecs

    Write-Host "Git preflight completed. Starting backup steps..." -ForegroundColor Green

    foreach ($step in $applicableSteps) {
        try {
            $stepOutcome = Invoke-BackupStep -Name $step.Name -RelativeScriptPath $step.RelativeScriptPath
            [void]$stepResults.Add([pscustomobject]@{
                    Name        = $step.Name
                    Success     = [bool]$stepOutcome.Succeeded
                    Error       = [string]$stepOutcome.Error
                    OutputLines = @($stepOutcome.OutputLines)
                })
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Warning ("{0}: {1}" -f $step.Name, $errorMessage)
            [void]$stepResults.Add([pscustomobject]@{
                    Name        = $step.Name
                    Success     = $false
                    Error       = $errorMessage
                    OutputLines = @()
                })
        }
    }

    $failedSteps = @($stepResults | Where-Object { -not $_.Success })
    $failedCount = $failedSteps.Count
    $totalCount = $stepResults.Count
    $succeededCount = $totalCount - $failedCount
    $hasBackupStepFailures = $failedCount -gt 0
    $hasGitFailure = $false

    Write-Host ""
    Write-Host "========== BACKUP SUMMARY ==========" -ForegroundColor Cyan
    Write-Host ("Planned steps: {0}, Applicable on {1}: {2}, Skipped by platform: {3}" -f $steps.Count, $currentPlatformName, $applicableSteps.Count, ($steps.Count - $applicableSteps.Count))
    Write-Host ("Total steps: {0}, Successful: {1}, Failed: {2}" -f $totalCount, $succeededCount, $failedCount)

    if ($failedCount -gt 0) {
        Write-Host "Failed steps:" -ForegroundColor Yellow
        foreach ($failedStep in $failedSteps) {
            Write-Host ("  - {0}: {1}" -f $failedStep.Name, $failedStep.Error) -ForegroundColor Yellow
        }

        Write-Warning ("E_BACKUP_PARTIAL_FAILURE: One or more backup steps failed ({0}/{1} succeeded)." -f $succeededCount, $totalCount)
    }

    Write-Host ""
    Write-Host "Proceeding with git operations (best-effort mode)." -ForegroundColor Cyan
    Write-Host "INFO_BACKUP_FORMATTER_BOUNDARY: FormatPowershellScripts is no longer run automatically by Backup.ps1. Source code formatting is enforced by pre-commit hooks. Run 'pre-commit run --all-files' when manual formatting is needed." -ForegroundColor DarkYellow
    if ($isUnattendedMode) {
        Write-Warning (
            "W_BACKUP_UNATTENDED_MODE_ACTIVE: unattended mode is active (source='{0}'). Backup commit hooks will be bypassed with --no-verify when a managed commit is required." -f
            $unattendedModeSource
        )
    }

    if (-not $hasGitFailure) {
        $outsideManagedPathspec = @(".")
        foreach ($managedPathspec in $managedPathspecs) {
            $outsideManagedPathspec += ":(exclude)$managedPathspec"
        }

        $outsideManagedChanges = @(Get-GitStatusLinesOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -Pathspec $outsideManagedPathspec)
        if ($outsideManagedChanges.Count -gt 0) {
            $outsideSummary = Get-GitStatusSummary -StatusLines $outsideManagedChanges
            Write-Warning (
                "E_BACKUP_GIT_SCOPE_VIOLATION: Backup run produced out-of-scope repository changes that are not under managed pathspecs ({0}).`nSummary: tracked={1}, untracked={2}, total={3}`nDetails:`n{4}" -f
                ($managedPathspecs -join ', '),
                $outsideSummary.TrackedCount,
                $outsideSummary.UntrackedCount,
                $outsideSummary.TotalCount,
                $outsideSummary.Details
            )
            $hasGitFailure = $true
        }
    }

    $managedChangedFiles = @()
    if (-not $hasGitFailure) {
        $managedChangedFiles = @(Get-BackupManagedChangedFilesOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -ManagedPathspecs $managedPathspecs)
        Write-Verbose (
            "Backup secret hygiene diagnostics: managedChangedFilesCount={0}; managedPathspecs={1}" -f
            $managedChangedFiles.Count,
            (Get-PathspecDiagnosticsText -Pathspec $managedPathspecs)
        )

        $snapshotRefreshError = Repair-BackupManagedAhkSnapshots -RepositoryRoot $repositoryRoot -ManagedChangedFiles $managedChangedFiles
        if (-not [string]::IsNullOrWhiteSpace($snapshotRefreshError)) {
            Write-Warning $snapshotRefreshError
            [void]$phaseFailures.Add($snapshotRefreshError)
            $hasGitFailure = $true
        }

        if (-not $hasGitFailure) {
            # Fail closed before staging: an oversize artifact can never be pushed, so committing it
            # would strand the whole backup push while later backups stack on the unpushable commit.
            $oversizeErrors = @(Get-BackupOversizedManagedFileErrors -RepositoryRoot $repositoryRoot -RelativePaths $managedChangedFiles -FailLimitBytes (95MB) -WarnLimitBytes (10MB))
            foreach ($oversizeError in $oversizeErrors) {
                Write-Warning $oversizeError
                [void]$phaseFailures.Add($oversizeError)
            }

            if ($oversizeErrors.Count -gt 0) {
                $hasGitFailure = $true
            }
        }

        if (-not $hasGitFailure) {
            $sanitizationResult = Invoke-BackupKnownSecretSanitization -RepositoryRoot $repositoryRoot -RelativePaths $managedChangedFiles
            $redactedFiles = @($sanitizationResult.RedactedFiles)
            $skippedBinaryFiles = @($sanitizationResult.SkippedBinaryFiles)

            if ($redactedFiles.Count -gt 0) {
                Write-Warning (
                    "W_BACKUP_SECRET_SANITIZED: redacted known secret fields in {0} managed file(s). files={1}" -f
                    $redactedFiles.Count,
                    (Get-PathspecDiagnosticsText -Pathspec $redactedFiles)
                )
            }

            if ($skippedBinaryFiles.Count -gt 0) {
                Write-Verbose (
                    "Backup secret sanitization diagnostics: skippedBinaryFiles={0}; files={1}" -f
                    $skippedBinaryFiles.Count,
                    (Get-PathspecDiagnosticsText -Pathspec $skippedBinaryFiles)
                )
            }

            $secretFindings = @(Find-BackupUnknownSecretFindings -RepositoryRoot $repositoryRoot -RelativePaths $managedChangedFiles)
            if ($secretFindings.Count -gt 0) {
                $secretFindingFiles = @($secretFindings | ForEach-Object { $_.FilePath } | Sort-Object -Unique)
                $secretFindingPreviewLines = @(
                    $secretFindings |
                        Select-Object -First 10 |
                        ForEach-Object {
                            "{0}:{1} pattern={2} [REDACTED]" -f $_.FilePath, $_.LineNumber, $_.PatternName
                        }
                )
                $secretFindingPreview = Get-OutputPreview -OutputLines $secretFindingPreviewLines -MaxLines 5 -MaxCharacters 640 -HeadTailWhenTruncated
                Write-Warning (
                    "E_BACKUP_SECRET_SCAN_FAILED: high-confidence secret patterns remain in managed backup files after sanitization. fileCount={0}; files={1}; outputPreview={2}." -f
                    $secretFindingFiles.Count,
                    (Get-PathspecDiagnosticsText -Pathspec $secretFindingFiles),
                    $secretFindingPreview
                )
                $hasGitFailure = $true
            }
        }
    }
    else {
        Write-Warning "W_BACKUP_SECRET_SCAN_SKIPPED_PRIOR_GIT_FAILURE: Skipping managed secret sanitization and unknown-secret scan because a previous git operation failed."
    }

    $date = Get-Date
    $dateString = "{0:yyyy/MM/dd HH:mm:ss zzz}" -f $date

    $failedStepEntries = @(
        $stepResults |
            Where-Object { -not $_.Success } |
            ForEach-Object {
                [pscustomobject]@{
                    Name          = $_.Name
                    Error         = $_.Error
                    OutputPreview = (Get-OutputPreview -OutputLines @($_.OutputLines) -MaxLines 40 -MaxCharacters 4000 -HeadTailWhenTruncated)
                }
            }
    )
    Set-BackupStepFailuresArtifact -RepositoryRoot $repositoryRoot `
        -FailedEntries @($failedStepEntries + @($phaseFailures)) `
        -SucceededStepNames @($stepResults | Where-Object { $_.Success } | ForEach-Object { $_.Name }) `
        -TotalSteps $stepResults.Count

    $backupFailureArtifactRelativePath = "Config/backup-step-failures.json"
    $backupFailureArtifactPath = Join-Path -Path $repositoryRoot -ChildPath $backupFailureArtifactRelativePath
    if (Test-Path -LiteralPath $backupFailureArtifactPath -PathType Leaf) {
        # The artifact embeds captured step output, so it must pass the same secret hygiene as
        # any other managed file: known-secret fields are redacted in place, and if an unknown
        # secret pattern survives, previews are rewritten redacted; a second finding deletes the
        # artifact rather than ever committing suspected secrets.
        $artifactKnownRedactions = Invoke-BackupKnownSecretSanitization -RepositoryRoot $repositoryRoot -RelativePaths @($backupFailureArtifactRelativePath)
        if (@($artifactKnownRedactions.RedactedFiles).Count -gt 0) {
            Write-Warning (
                "W_BACKUP_FAILURE_ARTIFACT_SECRET_SANITIZED: redacted known secret field(s) in '{0}'." -f
                $backupFailureArtifactRelativePath
            )
        }

        $artifactSecretFindings = @(Find-BackupUnknownSecretFindings -RepositoryRoot $repositoryRoot -RelativePaths @($backupFailureArtifactRelativePath))
        if ($artifactSecretFindings.Count -gt 0) {
            Set-BackupStepFailuresArtifact -RepositoryRoot $repositoryRoot `
                -FailedEntries @($failedStepEntries + @($phaseFailures)) `
                -SucceededStepNames @($stepResults | Where-Object { $_.Success } | ForEach-Object { $_.Name }) `
                -TotalSteps $stepResults.Count `
                -RedactOutputPreviews
            $artifactSecretFindingsAfterRedaction = @(Find-BackupUnknownSecretFindings -RepositoryRoot $repositoryRoot -RelativePaths @($backupFailureArtifactRelativePath))
            if ($artifactSecretFindingsAfterRedaction.Count -gt 0) {
                Remove-Item -LiteralPath $backupFailureArtifactPath -Force -ErrorAction SilentlyContinue
                Write-Warning (
                    "E_BACKUP_FAILURE_ARTIFACT_SECRETS_DETECTED: unknown secret patterns remained in '{0}' even after preview redaction; the artifact was deleted instead of being committed. fileCount={1}." -f
                    $backupFailureArtifactRelativePath,
                    $artifactSecretFindingsAfterRedaction.Count
                )
            }
            else {
                Write-Warning (
                    "W_BACKUP_FAILURE_ARTIFACT_PREVIEWS_REDACTED: output previews in '{0}' were replaced with a redaction placeholder because captured step output matched unknown secret patterns." -f
                    $backupFailureArtifactRelativePath
                )
            }
        }
    }

    if ($hasGitFailure -and @($phaseFailures).Count -gt 0) {
        # Git-phase guards (oversize / snapshot refresh) fail closed without staging managed
        # outputs, so persist the failure artifact BY ITSELF: it is small pushable JSON, which
        # keeps the failure reasons in history instead of stranding them on host disk until a
        # fully green run would delete them uncommitted.
        $artifactAddArgs = @("-C", $repositoryRoot, "add", "--", $backupFailureArtifactRelativePath)
        $artifactAddOutput = @(& $gitExecutable @artifactAddArgs 2>&1 | ForEach-Object { [string]$_ })
        $artifactAddExitCode = Get-LastExitCodeOrDefault
        $artifactCommitPushed = $false
        if ($artifactAddExitCode -eq 0) {
            $artifactStagedArgs = @("-C", $repositoryRoot, "diff", "--cached", "--name-only", "--", $backupFailureArtifactRelativePath)
            $artifactStagedFiles = @(& $gitExecutable @artifactStagedArgs 2>$null)
            $artifactStagedExitCode = Get-LastExitCodeOrDefault
            if ($artifactStagedExitCode -eq 0 -and @($artifactStagedFiles).Count -gt 0) {
                $phaseGuardNames = @($phaseFailures | ForEach-Object { ($_ -split ':')[0] })
                $artifactCommitMessage = "Backup failure diagnostics for $dateString (git-phase guards failed: [$($phaseGuardNames -join ', ')])"
                $artifactCommitArgs = @("-C", $repositoryRoot, "commit")
                if ($isUnattendedMode) {
                    $artifactCommitArgs += "--no-verify"
                }

                $artifactCommitArgs += @("-m", $artifactCommitMessage)
                $artifactCommitOutput = @(& $gitExecutable @artifactCommitArgs 2>&1 | ForEach-Object { [string]$_ })
                $artifactCommitExitCode = Get-LastExitCodeOrDefault
                if ($artifactCommitExitCode -eq 0) {
                    Assert-BackupGitBranchOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -ExpectedBranch "main"
                    $artifactPushOutput = @(& $gitExecutable -C $repositoryRoot push origin main 2>&1 | ForEach-Object { [string]$_ })
                    $artifactPushExitCode = Get-LastExitCodeOrDefault
                    if ($artifactPushExitCode -eq 0) {
                        try {
                            Assert-BackupGitRemoteHeadOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -RemoteName "origin" -BranchName "main"
                            $artifactCommitPushed = $true
                            Write-Host "Backup failure diagnostics committed and pushed." -ForegroundColor Yellow
                        }
                        catch {
                            Write-Warning ("W_BACKUP_GIT_REMOTE_VERIFY_FAILED: {0}" -f $_.Exception.Message)
                        }
                    }
                    else {
                        Write-Warning (
                            "E_BACKUP_GIT_PUSH_FAILED: git push origin main exited with code {0} while persisting failure diagnostics (outputPreview={1})." -f
                            $artifactPushExitCode,
                            (Get-OutputPreview -OutputLines $artifactPushOutput)
                        )
                    }
                }
                else {
                    Write-Warning (
                        "E_BACKUP_GIT_COMMIT_FAILED: git commit exited with code {0} while persisting failure diagnostics (outputPreview={1})." -f
                        $artifactCommitExitCode,
                        (Get-OutputPreview -OutputLines $artifactCommitOutput)
                    )
                }
            }
        }
        else {
            Write-Warning (
                "E_BACKUP_GIT_ADD_FAILED: git add of the failure artifact exited with code {0} (pathspec='{1}'; outputPreview={2})." -f
                $artifactAddExitCode,
                $backupFailureArtifactRelativePath,
                (Get-OutputPreview -OutputLines $artifactAddOutput)
            )
        }

        if (-not $artifactCommitPushed) {
            # Keep the working tree consistent for the next run: unstage the artifact so the
            # managed-preflight stash/pull path continues to behave predictably.
            & $gitExecutable -C $repositoryRoot reset --quiet -- $backupFailureArtifactRelativePath 2>$null
        }
    }

    if (-not $hasGitFailure) {
        $gitAddArgs = @("-C", $repositoryRoot, "add", "--")
        $gitAddArgs += $managedPathspecs
        $gitAddOutput = @(& $gitExecutable @gitAddArgs 2>&1)
        $gitAddExitCode = Get-LastExitCodeOrDefault
        if ($gitAddExitCode -ne 0) {
            $gitAddPreview = Get-OutputPreview -OutputLines $gitAddOutput
            Write-Warning (
                "E_BACKUP_GIT_ADD_FAILED: git add managed pathspecs exited with code {0} (repositoryRoot='{1}'; pathspec={2}; outputPreview={3})." -f
                $gitAddExitCode,
                $repositoryRoot,
                (Get-PathspecDiagnosticsText -Pathspec $managedPathspecs),
                $gitAddPreview
            )
            $hasGitFailure = $true
        }
    }
    else {
        Write-Warning "W_BACKUP_GIT_ADD_SKIPPED_PRIOR_GIT_FAILURE: Skipping git add managed pathspecs because a previous git operation failed."
    }

    $stagedFiles = @()
    if (-not $hasGitFailure) {
        $gitDiffArgs = @("-C", $repositoryRoot, "diff", "--cached", "--name-only", "--")
        $gitDiffArgs += $managedPathspecs
        $stagedFiles = @(& $gitExecutable @gitDiffArgs 2>$null)
        $stagedFilesExitCode = Get-LastExitCodeOrDefault
        if ($stagedFilesExitCode -ne 0) {
            $stagedFilesDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $gitExecutable -GitArguments $gitDiffArgs)
            $stagedFilesPreview = Get-OutputPreview -OutputLines $stagedFilesDiagnostics
            Write-Warning (
                "E_BACKUP_GIT_DIFF_FAILED: git diff --cached --name-only (managed pathspecs) exited with code {0}; repositoryRoot='{1}'; pathspec={2}; outputPreview={3}." -f
                $stagedFilesExitCode,
                $repositoryRoot,
                (Get-PathspecDiagnosticsText -Pathspec $managedPathspecs),
                $stagedFilesPreview
            )
            $hasGitFailure = $true
        }
    }

    Write-Verbose (
        "Backup git staging diagnostics: stagedFilesCount={0}; hasGitFailure={1}; hasBackupStepFailures={2}; managedPathspecs={3}" -f
        $stagedFiles.Count,
        $hasGitFailure,
        $hasBackupStepFailures,
        ($managedPathspecs -join ', ')
    )

    if (-not $hasGitFailure) {
        if ($stagedFiles.Count -gt 0) {
            if ($hasBackupStepFailures) {
                # Name the failing steps in the commit message itself: the summary above is console-only,
                # while this message persists in git history, so partial-failure runs remain diagnosable
                # from the log alone instead of requiring access to the host console.
                $failedStepNames = @($failedSteps | ForEach-Object { $_.Name })
                $failedStepsText = $failedStepNames -join ', '
                $commitMessage = "Backup for $dateString (backup steps failed: $failedCount [$failedStepsText]; $succeededCount/$totalCount succeeded)"
            }
            else {
                $commitMessage = "Backup for $dateString ($succeededCount/$totalCount)"
            }

            if ($isUnattendedMode) {
                Write-Warning "W_BACKUP_GIT_COMMIT_NO_VERIFY: unattended mode bypassing git hook verification via --no-verify."
                $commitOutput = @(& $gitExecutable -C $repositoryRoot commit --no-verify -m $commitMessage 2>&1)
                $commitExitCode = Get-LastExitCodeOrDefault
                if ($commitExitCode -ne 0) {
                    $commitOutputPreview = Get-OutputPreview -OutputLines $commitOutput
                    Write-Warning (
                        "E_BACKUP_GIT_COMMIT_FAILED: git commit --no-verify exited with code {0} in unattended mode. outputPreview={1}" -f
                        $commitExitCode,
                        $commitOutputPreview
                    )
                    $hasGitFailure = $true
                }
            }
            else {
                $maxCommitAttempts = 5
                $maxAutofixRetries = [Math]::Max(0, $maxCommitAttempts - 1)
                $commitAttempt = 0
                $commitSucceeded = $false

                while (-not $commitSucceeded -and $commitAttempt -lt $maxCommitAttempts) {
                    $commitAttempt++
                    $commitOutput = @(& $gitExecutable -C $repositoryRoot commit -m $commitMessage 2>&1)
                    $commitExitCode = Get-LastExitCodeOrDefault

                    if ($commitExitCode -eq 0) {
                        $commitSucceeded = $true
                        Write-Verbose ("Backup git commit diagnostics: succeeded on attempt {0} of {1}." -f $commitAttempt, $maxCommitAttempts)
                        break
                    }

                    $commitOutputText = $commitOutput -join [Environment]::NewLine
                    $autofixDetected = $commitOutputText -match '(?im)(files were modified by this hook|modified by this hook|hook.+modified)'
                    if (-not $autofixDetected) {
                        $commitOutputPreview = Get-OutputPreview -OutputLines $commitOutput

                        Write-Warning (
                            "E_BACKUP_GIT_COMMIT_FAILED: git commit exited with code {0} on attempt {1}. outputPreview={2}" -f
                            $commitExitCode,
                            $commitAttempt,
                            $commitOutputPreview
                        )
                        $hasGitFailure = $true
                        break
                    }

                    if ($commitAttempt -ge $maxCommitAttempts) {
                        $commitOutputPreview = Get-OutputPreview -OutputLines $commitOutput
                        Write-Warning (
                            "E_BACKUP_GIT_COMMIT_RETRY_LIMIT: git commit did not succeed after {0} total commit attempt(s) (maxAttempts={1}; maxAutofixRetries={2}); lastOutputPreview={3}." -f
                            $commitAttempt,
                            $maxCommitAttempts,
                            $maxAutofixRetries,
                            $commitOutputPreview
                        )
                        $hasGitFailure = $true
                        break
                    }

                    $nextCommitAttempt = $commitAttempt + 1

                    Write-Warning (
                        "W_BACKUP_GIT_COMMIT_RETRY_AUTOFIX: commit hook modified files; restaging managed pathspecs before retry attempt {0} of {1} (maxAutofixRetries={2})." -f
                        $nextCommitAttempt,
                        $maxCommitAttempts,
                        $maxAutofixRetries
                    )

                    $restageArgs = @("-C", $repositoryRoot, "add", "--")
                    $restageArgs += $managedPathspecs
                    $restageOutput = @(& $gitExecutable @restageArgs 2>&1)
                    $restageExitCode = Get-LastExitCodeOrDefault
                    if ($restageExitCode -ne 0) {
                        $restagePreview = Get-OutputPreview -OutputLines $restageOutput
                        Write-Warning (
                            "E_BACKUP_GIT_RESTAGE_FAILED: git add managed pathspecs for commit retry exited with code {0} on attempt {1} (repositoryRoot='{2}'; pathspec={3}; outputPreview={4})." -f
                            $restageExitCode,
                            $commitAttempt,
                            $repositoryRoot,
                            (Get-PathspecDiagnosticsText -Pathspec $managedPathspecs),
                            $restagePreview
                        )
                        $hasGitFailure = $true
                        break
                    }

                    $retryDiffArgs = @("-C", $repositoryRoot, "diff", "--cached", "--name-only", "--")
                    $retryDiffArgs += $managedPathspecs
                    $retryStagedFiles = @(& $gitExecutable @retryDiffArgs 2>$null)
                    $retryDiffExitCode = Get-LastExitCodeOrDefault
                    if ($retryDiffExitCode -ne 0) {
                        $retryDiffDiagnostics = @(Get-GitCommandDiagnosticsOutput -GitExecutable $gitExecutable -GitArguments $retryDiffArgs)
                        $retryDiffPreview = Get-OutputPreview -OutputLines $retryDiffDiagnostics
                        Write-Warning (
                            "E_BACKUP_GIT_DIFF_FAILED: git diff --cached --name-only (managed pathspecs) failed during commit retry (attempt {0}) with code {1}; repositoryRoot='{2}'; pathspec={3}; outputPreview={4}." -f
                            $commitAttempt,
                            $retryDiffExitCode,
                            $repositoryRoot,
                            (Get-PathspecDiagnosticsText -Pathspec $managedPathspecs),
                            $retryDiffPreview
                        )
                        $hasGitFailure = $true
                        break
                    }

                    if ($retryStagedFiles.Count -eq 0) {
                        Write-Warning (
                            "E_BACKUP_GIT_COMMIT_RETRY_EMPTY_STAGE: hook autofix removed all staged managed files on attempt {0}; aborting retry to avoid non-deterministic empty commits." -f
                            $commitAttempt
                        )
                        $hasGitFailure = $true
                        break
                    }
                }
            }
        }
        else {
            Write-Host "No managed backup file changes detected. Skipping git commit." -ForegroundColor DarkYellow
        }
    }
    else {
        Write-Warning "W_BACKUP_GIT_COMMIT_SKIPPED_PRIOR_GIT_FAILURE: Skipping git commit because a previous git operation failed."
    }

    if (-not $hasGitFailure) {
        Assert-BackupGitBranchOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -ExpectedBranch "main"
        $gitPushOutput = @(& $gitExecutable -C $repositoryRoot push origin main 2>&1)
        $gitPushExitCode = Get-LastExitCodeOrDefault
        if ($gitPushExitCode -ne 0) {
            $gitPushPreview = Get-OutputPreview -OutputLines $gitPushOutput
            Write-Warning (
                "E_BACKUP_GIT_PUSH_FAILED: git push origin main exited with code {0} (repositoryRoot='{1}'; outputPreview={2})." -f
                $gitPushExitCode,
                $repositoryRoot,
                $gitPushPreview
            )
            $hasGitFailure = $true
        }
    }
    else {
        Write-Warning "W_BACKUP_GIT_PUSH_SKIPPED_PRIOR_GIT_FAILURE: Skipping git push origin main because a previous git operation failed."
    }

    if (-not $hasGitFailure) {
        Assert-BackupGitRemoteHeadOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -RemoteName "origin" -BranchName "main"
        $postPushStatus = @(Get-GitStatusLinesOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot)
        if ($postPushStatus.Count -gt 0) {
            $postPushSummary = Get-GitStatusSummary -StatusLines $postPushStatus
            Write-Warning (
                "E_BACKUP_GIT_TREE_DIRTY_POSTPUSH: Repository has residual changes after backup push completed.`nSummary: tracked={0}, untracked={1}, total={2}`nDetails:`n{3}" -f
                $postPushSummary.TrackedCount,
                $postPushSummary.UntrackedCount,
                $postPushSummary.TotalCount,
                $postPushSummary.Details
            )
            $hasGitFailure = $true
        }
        else {
            Write-Host "Git tree remains clean after push." -ForegroundColor Green
        }
    }

    if ($hasBackupStepFailures -or $hasGitFailure) {
        exit 1
    }
}
finally {
    Pop-Location
}
