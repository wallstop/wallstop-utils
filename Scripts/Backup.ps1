Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptsDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
$pwshCommand = (Get-Command -Name "pwsh" -ErrorAction Stop).Source

function Get-LastExitCodeOrDefault {
    $lecValue = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $lecValue) {
        return [int]$lecValue
    }

    return 0
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
    if ($IsWindows) {
        return "Windows"
    }

    if ($IsMacOS) {
        return "macOS"
    }

    if ($IsLinux) {
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

$stepResults = New-Object System.Collections.Generic.List[object]
$steps = @(
    @{ Name = "ConfigBackup"; RelativeScriptPath = "Config/ConfigBackup.ps1"; SupportedPlatforms = @("All") },
    @{ Name = "FormatPowershellScripts"; RelativeScriptPath = "Utils/FormatPowershellScripts.ps1"; SupportedPlatforms = @("All") },
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

    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        throw "E_BACKUP_GIT_NOT_AVAILABLE: git executable was not found on PATH. Install git and retry backup git operations."
    }

    $gitExecutable = $gitCommand.Source

    Write-Verbose (
        "Backup git availability diagnostics: gitPath='{0}'; scriptsDirectory='{1}'" -f
        $gitCommand.Source,
        $scriptsDirectory
    )

    $insideWorkTreeOutput = @(& $gitExecutable rev-parse --is-inside-work-tree 2>$null)
    $insideWorkTreeExitCode = Get-LastExitCodeOrDefault
    $insideWorkTree = if ($insideWorkTreeOutput.Count -gt 0) { ([string]$insideWorkTreeOutput[0]).Trim() } else { "" }
    Write-Verbose (
        "Backup git preflight diagnostics: insideWorkTreeExitCode={0}; insideWorkTree='{1}'; hasBackupStepFailures={2}" -f
        $insideWorkTreeExitCode,
        $insideWorkTree,
        $hasBackupStepFailures
    )

    if ($insideWorkTreeExitCode -ne 0 -or $insideWorkTree -ne "true") {
        throw (
            "E_BACKUP_GIT_NOT_REPOSITORY: expected a git work tree at '{0}' but rev-parse returned exitCode={1} value='{2}'." -f
            $scriptsDirectory,
            $insideWorkTreeExitCode,
            $insideWorkTree
        )
    }

    # Pull before staging: ff-only succeeds only when local HEAD is an ancestor of remote.
    # If we stage first, any overlap with remote changes will cause pull to fail with
    # "local changes would be overwritten". Pulling before git add keeps the working tree clean.
    if (-not $hasGitFailure) {
        & $gitExecutable pull --ff-only origin main
        $gitPullExitCode = Get-LastExitCodeOrDefault
        if ($gitPullExitCode -ne 0) {
            Write-Warning ("E_BACKUP_GIT_PULL_FAILED: git pull --ff-only origin main exited with code {0}." -f $gitPullExitCode)
            $hasGitFailure = $true
        }
    }
    else {
        Write-Warning "W_BACKUP_GIT_PULL_SKIPPED_PRIOR_GIT_FAILURE: Skipping git pull --ff-only origin main because a previous git operation failed."
    }

    $date = Get-Date
    $dateString = "{0:yyyy/MM/dd HH:mm:ss zzz}" -f $date

    if (-not $hasGitFailure) {
        & $gitExecutable add --all
        $gitAddExitCode = Get-LastExitCodeOrDefault
        if ($gitAddExitCode -ne 0) {
            Write-Warning ("E_BACKUP_GIT_ADD_FAILED: git add --all exited with code {0}." -f $gitAddExitCode)
            $hasGitFailure = $true
        }
    }
    else {
        Write-Warning "W_BACKUP_GIT_ADD_SKIPPED_PRIOR_GIT_FAILURE: Skipping git add --all because a previous git operation failed."
    }

    # Initialize to empty so $stagedFiles.Count references below are safe under Set-StrictMode
    # when the git diff step is skipped due to a prior failure.
    $stagedFiles = @()
    if (-not $hasGitFailure) {
        $stagedFiles = @(& $gitExecutable diff --cached --name-only 2>&1)
        $stagedFilesExitCode = Get-LastExitCodeOrDefault
        if ($stagedFilesExitCode -ne 0) {
            Write-Warning ("E_BACKUP_GIT_DIFF_FAILED: git diff --cached --name-only exited with code {0}." -f $stagedFilesExitCode)
            $hasGitFailure = $true
        }
    }

    Write-Verbose (
        "Backup git staging diagnostics: stagedFilesCount={0}; hasGitFailure={1}; hasBackupStepFailures={2}" -f
        $stagedFiles.Count,
        $hasGitFailure,
        $hasBackupStepFailures
    )

    if (-not $hasGitFailure) {
        if ($stagedFiles.Count -gt 0) {
            if ($hasBackupStepFailures) {
                $commitMessage = "Backup for $dateString (partial success: $succeededCount/$totalCount)"
            }
            else {
                $commitMessage = "Backup for $dateString ($succeededCount/$totalCount)"
            }

            Write-Verbose (
                "Backup git commit diagnostics: hasBackupStepFailures={0}; commitMessage='{1}'" -f
                $hasBackupStepFailures,
                $commitMessage
            )

            & $gitExecutable commit -m $commitMessage
            $commitExitCode = Get-LastExitCodeOrDefault
            if ($commitExitCode -ne 0) {
                Write-Warning ("E_BACKUP_GIT_COMMIT_FAILED: git commit exited with code {0}." -f $commitExitCode)
                $hasGitFailure = $true
            }
        }
        else {
            Write-Host "No file changes detected. Skipping git commit." -ForegroundColor DarkYellow
        }
    }
    else {
        Write-Warning "W_BACKUP_GIT_COMMIT_SKIPPED_PRIOR_GIT_FAILURE: Skipping git commit because a previous git operation failed."
    }

    if (-not $hasGitFailure) {
        & $gitExecutable push origin main
        $gitPushExitCode = Get-LastExitCodeOrDefault
        if ($gitPushExitCode -ne 0) {
            Write-Warning ("E_BACKUP_GIT_PUSH_FAILED: git push origin main exited with code {0}." -f $gitPushExitCode)
            $hasGitFailure = $true
        }
    }
    else {
        Write-Warning "W_BACKUP_GIT_PUSH_SKIPPED_PRIOR_GIT_FAILURE: Skipping git push origin main because a previous git operation failed."
    }

    if ($hasBackupStepFailures -or $hasGitFailure) {
        exit 1
    }
}
finally {
    Pop-Location
}
