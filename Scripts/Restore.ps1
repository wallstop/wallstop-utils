Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$scriptsDirectory = Join-Path -Path $baseDirectory -ChildPath "Scripts"
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
    if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
        throw "E_RESTORE_STEP_SCRIPT_MISSING: Restore step '$Name' script not found at '$scriptPath'."
    }

    Write-Host ("Starting: {0}" -f $Name) -ForegroundColor Cyan
    & $pwshCommand -NoLogo -NoProfile -File $scriptPath

    $exitCode = Get-LastExitCodeOrDefault
    if ($exitCode -ne 0) {
        throw ("E_RESTORE_STEP_FAILED({0}): script '{1}' exited with code {2}." -f $Name, $RelativeScriptPath, $exitCode)
    }

    Write-Host ("Completed: {0}" -f $Name) -ForegroundColor Green
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

Push-Location -Path $scriptsDirectory
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
