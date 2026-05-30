Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
Push-Location -LiteralPath $baseDirectory

try {
    $windowsTerminalConfigPath = "$HOME\scoop\apps\windows-terminal\current\settings"
    $windowsTerminalSettings = "$windowsTerminalConfigPath\settings.json"
    if (-not (Test-Path -LiteralPath $windowsTerminalConfigPath -PathType Container)) {
        Write-Host "Windows Terminal settings directory not found at $windowsTerminalConfigPath, creating..."
        [System.IO.Directory]::CreateDirectory($windowsTerminalConfigPath) | Out-Null
    }

    $settingsPath = Join-Path -Path $baseDirectory -ChildPath 'Config'
    $settingsPath = Join-Path -Path $settingsPath -ChildPath 'WindowsTerminal'
    $settingsPath = Join-Path -Path $settingsPath -ChildPath 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        Write-Error "E_WT_RESTORE_SOURCE_MISSING: Windows Terminal settings backup not found at '$settingsPath'."
        exit 1
    }

    # Make a backup of the current settings before overwriting
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupFolder = Join-Path -Path $HOME -ChildPath "Documents"
    $backupFolder = Join-Path -Path $backupFolder -ChildPath "WT_Settings_Backup"
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($backupFolder) | Out-Null
    }

    $currentBackupFile = Join-Path -Path $backupFolder -ChildPath "settings_backup_$timestamp.json"
    if (Test-Path -LiteralPath $windowsTerminalSettings -PathType Leaf) {
        Copy-Item -LiteralPath $windowsTerminalSettings -Destination $currentBackupFile -Force
        Write-Host "Current settings backed up to $currentBackupFile"
    }
    else {
        Write-Warning "W_WT_RESTORE_NO_LIVE_SETTINGS: No live Windows Terminal settings found at '$windowsTerminalSettings'; skipping safety backup."
    }

    # Replace the current settings with the backup file
    Copy-Item -LiteralPath $settingsPath -Destination $windowsTerminalSettings -Force

    Write-Host "Windows Terminal settings restored from $settingsPath."
}
finally {
    Pop-Location
}
