Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
Push-Location -LiteralPath $baseDirectory
try {
    $scriptsDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
    $rootDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $scriptsDirectory -ChildPath "..") -ErrorAction Stop).Path
    $copyFrom = Join-Path -Path $rootDirectory -ChildPath "Config"
    $copyFrom = Join-Path -Path $copyFrom -ChildPath "PowerToys"

    if (-not (Test-Path -Path $copyFrom -PathType Container)) {
        Write-Error "E_POWERTOYS_RESTORE_SOURCE_MISSING: Failed to find PowerToys settings at '$copyFrom'."
        exit 1
    }

    $targetPath = "$env:LOCALAPPDATA\Microsoft\PowerToys"
    if (-not (Test-Path -Path $targetPath -PathType Container)) {
        Write-Error "E_POWERTOYS_RESTORE_TARGET_MISSING: Failed to detect PowerToys config directory at '$targetPath'."
        exit 1
    }

    Robocopy.exe $copyFrom $targetPath *.json /S > $null 2>&1
    $robocopyExitCodeVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    $robocopyExitCode = if ($null -ne $robocopyExitCodeVariable) { [int]$robocopyExitCodeVariable } else { 0 }

    # Robocopy semantics: exit codes 0-7 indicate success classes, >=8 indicates failure.
    if ($robocopyExitCode -ge 8) {
        Write-Error ("E_POWERTOYS_RESTORE_ROBOCOPY_FAILED: Robocopy failed with exit code {0}." -f $robocopyExitCode)
        exit 1
    }

    if ($robocopyExitCode -ge 2) {
        Write-Warning ("W_POWERTOYS_RESTORE_ROBOCOPY_CLASS_{0}: Robocopy reported non-fatal differences." -f $robocopyExitCode)
    }

    Write-Host "PowerToys configuration settings restored from $copyFrom to $targetPath." -ForegroundColor Green
}
finally {
    Pop-Location
}
