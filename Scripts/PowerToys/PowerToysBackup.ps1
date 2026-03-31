Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
$scriptsDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
$rootDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $scriptsDirectory -ChildPath "..") -ErrorAction Stop).Path
Push-Location -LiteralPath $baseDirectory
try {
    $sourcePath = "$env:LOCALAPPDATA\Microsoft\PowerToys"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        Write-Error "E_POWERTOYS_BACKUP_SOURCE_MISSING: Failed to detect PowerToys config directory at '$sourcePath'."
        exit 1
    }

    $backupFolder = Join-Path -Path $rootDirectory -ChildPath "Config"
    $backupFolder = Join-Path -Path $backupFolder -ChildPath "PowerToys"
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
    }
    else {
        $backupEntries = @(Get-ChildItem -LiteralPath $backupFolder -Force -ErrorAction Stop)
        if ($backupEntries.Count -gt 0) {
            foreach ($backupEntry in $backupEntries) {
                Remove-Item -LiteralPath $backupEntry.FullName -Recurse -Force -ErrorAction Stop
            }
        }
    }

    Write-Verbose (
        "PowerToys backup path diagnostics: sourcePath='{0}', backupFolder='{1}'" -f
        $sourcePath,
        $backupFolder
    )

    Robocopy.exe $sourcePath $backupFolder *.json /S > $null 2>&1
    $robocopyExitCodeVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    $robocopyExitCode = if ($null -ne $robocopyExitCodeVariable) { [int]$robocopyExitCodeVariable } else { 0 }

    # Robocopy semantics: exit codes 0-7 indicate success classes, >=8 indicates failure.
    if ($robocopyExitCode -ge 8) {
        Write-Error ("E_POWERTOYS_BACKUP_ROBOCOPY_FAILED: Robocopy failed with exit code {0}." -f $robocopyExitCode)
        exit 1
    }

    if ($robocopyExitCode -ge 2) {
        Write-Warning ("W_POWERTOYS_BACKUP_ROBOCOPY_CLASS_{0}: Robocopy reported non-fatal differences." -f $robocopyExitCode)
    }

    Write-Host "PowerToys configuration settings have been backed up to $backupFolder." -ForegroundColor Green
}
finally {
    Pop-Location
}
