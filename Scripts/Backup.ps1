param(
    [Parameter(Mandatory = $false)]
    [switch]$Unattended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
        [string]$RepositoryRoot
    )

    $statusLines = @(Get-GitStatusLinesOrThrow -GitExecutable $GitExecutable -RepositoryRoot $RepositoryRoot)
    if ($statusLines.Count -eq 0) {
        return
    }

    $statusSummary = Get-GitStatusSummary -StatusLines $statusLines
    throw (
        "E_BACKUP_GIT_TREE_DIRTY_PREFLIGHT: Repository has pre-existing changes before backup begins. " +
        "Commit or discard local changes before running backup.`nSummary: tracked={0}, untracked={1}, total={2}`nDetails:`n{3}" -f
        $statusSummary.TrackedCount,
        $statusSummary.UntrackedCount,
        $statusSummary.TotalCount,
        $statusSummary.Details
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

    $trackedChangedArgs = @("-C", $RepositoryRoot, "diff", "--name-only", "--diff-filter=AM", "--")
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

    Write-Host ("Starting: {0}" -f $Name) -ForegroundColor Cyan
    & $pwshCommand -NoLogo -NoProfile -File $scriptPath

    $exitCode = Get-LastExitCodeOrDefault
    if ($exitCode -ne 0) {
        throw ("E_BACKUP_STEP_FAILED({0}): script '{1}' at '{2}' exited with code {3}." -f $Name, $RelativeScriptPath, $scriptPath, $exitCode)
    }

    Write-Host ("Completed: {0}" -f $Name) -ForegroundColor Green
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
$steps = @(
    @{ Name = "ConfigBackup"; RelativeScriptPath = "Config/ConfigBackup.ps1"; SupportedPlatforms = @("All") },
    @{ Name = "WindowsTerminalBackup"; RelativeScriptPath = "WindowsTerminal/WindowsTerminalBackup.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "PowershellBackup"; RelativeScriptPath = "Powershell/PowershellBackup.ps1"; SupportedPlatforms = @("All") },
    @{ Name = "StopKomorebi"; RelativeScriptPath = "Komorebi/StopKomorebi.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "ScoopUpdate"; RelativeScriptPath = "Scoop/ScoopUpdate.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "ScoopBackup"; RelativeScriptPath = "Scoop/ScoopBackup.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "KomorebiBackup"; RelativeScriptPath = "Komorebi/KomorebiBackup.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "PowerToysBackup"; RelativeScriptPath = "PowerToys/PowerToysBackup.ps1"; SupportedPlatforms = @("Windows") },
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
    Assert-BackupGitTreeCleanPreflight -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot
    Assert-BackupGitBranchOrThrow -GitExecutable $gitExecutable -RepositoryRoot $repositoryRoot -ExpectedBranch "main"
    Write-Host "Git tree is clean before backup mutations." -ForegroundColor Green

    # Pull before backup mutations so backup never starts from an out-of-date branch.
    $gitPullPreflightOutput = @(& $gitExecutable -C $repositoryRoot pull --ff-only origin main 2>&1)
    $gitPullPreflightExitCode = Get-LastExitCodeOrDefault
    if ($gitPullPreflightExitCode -ne 0) {
        $gitPullPreflightPreview = Get-OutputPreview -OutputLines $gitPullPreflightOutput
        throw (
            "E_BACKUP_GIT_PULL_FAILED: git pull --ff-only origin main exited with code {0} (repositoryRoot='{1}'; outputPreview={2})." -f
            $gitPullPreflightExitCode,
            $repositoryRoot,
            $gitPullPreflightPreview
        )
    }

    Write-Host "Git preflight completed. Starting backup steps..." -ForegroundColor Green

    foreach ($step in $applicableSteps) {
        try {
            Invoke-BackupStep -Name $step.Name -RelativeScriptPath $step.RelativeScriptPath
            [void]$stepResults.Add([pscustomobject]@{
                    Name    = $step.Name
                    Success = $true
                    Error   = ""
                })
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Warning ("{0}: {1}" -f $step.Name, $errorMessage)
            [void]$stepResults.Add([pscustomobject]@{
                    Name    = $step.Name
                    Success = $false
                    Error   = $errorMessage
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

        if ($managedChangedFiles.Count -gt 0) {
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
                $commitMessage = "Backup for $dateString (partial success: $succeededCount/$totalCount)"
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
