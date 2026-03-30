Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path

Push-Location -Path $baseDirectory
try {
    $configDir = Join-Path -Path $env:USERPROFILE -ChildPath ".config"
    $backupDir = Join-Path -Path (Join-Path -Path $baseDirectory -ChildPath "Config") -ChildPath ".config"

    if (-not (Test-Path -Path $backupDir -PathType Container)) {
        Write-Error "E_CONFIG_RESTORE_BACKUP_MISSING: Backup directory not found at '$backupDir'."
        exit 1
    }

    if (-not (Test-Path -Path $configDir -PathType Container)) {
        Write-Host ".config directory not found, creating it at: $configDir"
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }

    $backupItems = @(Get-ChildItem -Path $backupDir -Force -ErrorAction Stop)
    if ($backupItems.Count -eq 0) {
        Write-Error "E_CONFIG_RESTORE_EMPTY_BACKUP: Backup directory is empty: $backupDir"
        exit 1
    }

    try {
        Copy-Item -Path (Join-Path -Path $backupDir -ChildPath '*') -Destination $configDir -Recurse -Force
        Write-Host ".config directory restored from backup successfully." -ForegroundColor Green
    }
    catch {
        Write-Error ("E_CONFIG_RESTORE_COPY_FAILED: Failed to restore .config from '{0}' to '{1}': {2}" -f $backupDir, $configDir, $_.Exception.Message)
        exit 1
    }
}
finally {
    Pop-Location
}
