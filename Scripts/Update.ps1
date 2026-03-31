Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

$scriptsDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
$steps = @(
    @{ Name = "FormatPowershellScripts"; RelativeScriptPath = "Utils/FormatPowershellScripts.ps1"; SupportedPlatforms = @("All") },
    @{ Name = "StopKomorebi"; RelativeScriptPath = "Komorebi/StopKomorebi.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "ScoopUpdate"; RelativeScriptPath = "Scoop/ScoopUpdate.ps1"; SupportedPlatforms = @("Windows") },
    @{ Name = "WinGetUpdate"; RelativeScriptPath = "WinGet/WinGetUpdate.ps1"; SupportedPlatforms = @("Windows") }
)

$currentPlatformName = Get-CurrentPlatformName
$applicableSteps = @(Get-ApplicableUpdateSteps -Steps $steps -CurrentPlatformName $currentPlatformName)
Assert-ApplicableUpdateStepsFlat -ApplicableSteps $applicableSteps -CurrentPlatformName $currentPlatformName

Write-Verbose ("Update platform diagnostics: currentPlatform='{0}', totalSteps={1}, applicableSteps={2}" -f $currentPlatformName, $steps.Count, $applicableSteps.Count)

Push-Location -LiteralPath $scriptsDirectory
try {
    foreach ($step in $applicableSteps) {
        & (Join-Path -Path $scriptsDirectory -ChildPath $step.RelativeScriptPath)
    }
}
finally {
    Pop-Location
}
