Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Get-ApplicableUpdateSteps {
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
                "E_UPDATE_STEP_METADATA_INVALID({0}): Step '{1}' must define SupportedPlatforms metadata." -f
                $step.Name,
                $step.Name
            )
        }

        if ($supportedPlatforms -contains "All" -or $supportedPlatforms -contains $CurrentPlatformName) {
            [void]$applicableSteps.Add($step)
            continue
        }

        Write-Warning (
            "W_UPDATE_STEP_SKIPPED_PLATFORM: Skipping step '{0}' ({1}) on platform '{2}'. SupportedPlatforms={3}." -f
            $step.Name,
            $step.RelativeScriptPath,
            $CurrentPlatformName,
            ($supportedPlatforms -join ', ')
        )
    }

    return $applicableSteps.ToArray()
}

function Assert-ApplicableUpdateStepsFlat {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ApplicableSteps,

        [Parameter(Mandatory = $true)]
        [string]$CurrentPlatformName
    )

    $nestedStepContainers = @($ApplicableSteps | Where-Object { $_ -is [System.Array] })
    Write-Verbose (
        "Update step selection diagnostics: currentPlatform='{0}', applicableSteps={1}, nestedStepContainers={2}" -f
        $CurrentPlatformName,
        $ApplicableSteps.Count,
        $nestedStepContainers.Count
    )

    if ($nestedStepContainers.Count -gt 0) {
        throw (
            "E_UPDATE_STEP_SELECTION_INVALID: Applicable step selection contains nested array value(s) ({0}) on platform '{1}'. Ensure Get-ApplicableUpdateSteps returns a flat step list and callers use @(...)." -f
            $nestedStepContainers.Count,
            $CurrentPlatformName
        )
    }
}

function Get-LastExitCodeOrDefault {
    $lastExitCode = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $lastExitCode) {
        return [int]$lastExitCode
    }

    return 0
}

function Invoke-UpdateStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$StepName
    )

    & $ScriptPath
    $stepSucceeded = $?
    $stepExitCode = Get-LastExitCodeOrDefault
    if (-not $stepSucceeded -or $stepExitCode -ne 0) {
        throw (
            "E_UPDATE_STEP_FAILED: Step '{0}' failed (exitCode={1}; scriptPath='{2}')." -f
            $StepName,
            $stepExitCode,
            $ScriptPath
        )
    }
}

$scriptsDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
$compatibilityHelpersPath = Join-Path -Path $scriptsDirectory -ChildPath "Utils/Common/CompatibilityHelpers.ps1"
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_UPDATE_COMPATIBILITY_HELPER_MISSING: compatibility helper file not found at '$compatibilityHelpersPath'."
}

. $compatibilityHelpersPath
$steps = @(
    @{ Name = "StopKomorebi"; RelativeScriptPath = "Komorebi/StopKomorebi.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "ScoopUpdate"; RelativeScriptPath = "Scoop/ScoopUpdate.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "WinGetUpdate"; RelativeScriptPath = "WinGet/WinGetUpdate.ps1"; SupportedPlatforms = @("Windows") }
)

$currentPlatformName = Get-CurrentPlatformName
$applicableSteps = @(Get-ApplicableUpdateSteps -Steps $steps -CurrentPlatformName $currentPlatformName)
Assert-ApplicableUpdateStepsFlat -ApplicableSteps $applicableSteps -CurrentPlatformName $currentPlatformName

Write-Verbose ("Update platform diagnostics: currentPlatform='{0}', totalSteps={1}, applicableSteps={2}" -f $currentPlatformName, $steps.Count, $applicableSteps.Count)
Write-Host "INFO_UPDATE_FORMATTER_BOUNDARY: FormatPowershellScripts is no longer run automatically by Update.ps1. Source code formatting is enforced by pre-commit hooks. Run 'pre-commit run --all-files' when manual formatting is needed." -ForegroundColor DarkYellow

Push-Location -LiteralPath $scriptsDirectory
try {
    $stepResults = New-Object System.Collections.Generic.List[object]
    foreach ($step in $applicableSteps) {
        $stepPath = Join-Path -Path $scriptsDirectory -ChildPath $step.RelativeScriptPath
        try {
            Invoke-UpdateStep -ScriptPath $stepPath -StepName $step.Name
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

    Write-Host ""
    Write-Host "========== UPDATE SUMMARY ==========" -ForegroundColor Cyan
    Write-Host ("Planned steps: {0}, Applicable on {1}: {2}, Skipped by platform: {3}" -f $steps.Count, $currentPlatformName, $applicableSteps.Count, ($steps.Count - $applicableSteps.Count))
    Write-Host ("Total steps: {0}, Successful: {1}, Failed: {2}" -f $totalCount, $succeededCount, $failedCount)

    if ($failedCount -gt 0) {
        Write-Host "Failed steps:" -ForegroundColor Yellow
        foreach ($failedStep in $failedSteps) {
            Write-Host ("  - {0}: {1}" -f $failedStep.Name, $failedStep.Error) -ForegroundColor Yellow
        }

        throw ("E_UPDATE_PARTIAL_FAILURE: One or more update steps failed ({0}/{1} succeeded)." -f $succeededCount, $totalCount)
    }
}
finally {
    Pop-Location
}
