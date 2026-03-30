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

function Invoke-RestoreStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$RelativeScriptPath
    )

    $scriptPath = Join-Path -Path $scriptsDirectory -ChildPath $RelativeScriptPath
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "E_RESTORE_STEP_SCRIPT_MISSING: Restore step '$Name' script not found at '$scriptPath'."
    }

    Write-Host ("Starting: {0}" -f $Name) -ForegroundColor Cyan
    & $pwshCommand -NoLogo -NoProfile -File $scriptPath

    $exitCode = Get-LastExitCodeOrDefault
    if ($exitCode -ne 0) {
        throw ("E_RESTORE_STEP_FAILED({0}): script '{1}' at '{2}' exited with code {3}." -f $Name, $RelativeScriptPath, $scriptPath, $exitCode)
    }

    Write-Host ("Completed: {0}" -f $Name) -ForegroundColor Green
}

function Assert-RestoreStepScriptsExist {
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

    Write-Warning ("E_RESTORE_PRE_FLIGHT_STEP_SCRIPT_MISSING: Found {0} missing restore step script(s)." -f $missingSteps.Count)
    Write-Warning ("Restore step root path diagnostics: scriptsDirectory='{0}'" -f $scriptsDirectory)
    foreach ($missingStep in $missingSteps) {
        Write-Warning ("Missing step '{0}' ({1}) expected at '{2}'." -f $missingStep.Name, $missingStep.RelativeScriptPath, $missingStep.ScriptPath)
    }

    throw "E_RESTORE_PRE_FLIGHT_FAILED: Restore step script validation failed."
}

$stepResults = New-Object System.Collections.Generic.List[object]
$steps = @(
    @{ Name = "ScoopRestore"; RelativeScriptPath = "Scoop/ScoopRestore.ps1" },
    @{ Name = "PowershellRestore"; RelativeScriptPath = "Powershell/PowershellRestore.ps1" },
    @{ Name = "PowerToysRestore"; RelativeScriptPath = "PowerToys/PowerToysRestore.ps1" },
    @{ Name = "ConfigRestore"; RelativeScriptPath = "Config/ConfigRestore.ps1" },
    @{ Name = "KomorebiRestore"; RelativeScriptPath = "Komorebi/KomorebiRestore.ps1" },
    @{ Name = "WindowsTerminalRestore"; RelativeScriptPath = "WindowsTerminal/WindowsTerminalRestore.ps1" }
)

Write-Verbose ("Restore path diagnostics: scriptsDirectory='{0}'" -f $scriptsDirectory)
Assert-RestoreStepScriptsExist -Steps $steps

Push-Location -LiteralPath $scriptsDirectory
try {
    foreach ($step in $steps) {
        try {
            Invoke-RestoreStep -Name $step.Name -RelativeScriptPath $step.RelativeScriptPath
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
    Write-Host "========== RESTORE SUMMARY ==========" -ForegroundColor Cyan
    Write-Host ("Total steps: {0}, Successful: {1}, Failed: {2}" -f $totalCount, $succeededCount, $failedCount)

    if ($failedCount -gt 0) {
        Write-Host "Failed steps:" -ForegroundColor Yellow
        foreach ($failedStep in $failedSteps) {
            Write-Host ("  - {0}: {1}" -f $failedStep.Name, $failedStep.Error) -ForegroundColor Yellow
        }

        Write-Error ("E_RESTORE_PARTIAL_FAILURE: One or more restore steps failed ({0}/{1} succeeded)." -f $succeededCount, $totalCount)
        exit 1
    }

    Write-Host "Restore completed successfully." -ForegroundColor Green
}
finally {
    Pop-Location
}
