$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$baseDirectory = "$baseDirectory\.."
Push-Location "$baseDirectory"

try {
  $windowsTerminalConfigPath = "$HOME\scoop\apps\windows-terminal\current\settings"
  $windowsTerminalSettings = "$windowsTerminalConfigPath\settings.json"
  if (-not (Test-Path -Path $windowsTerminalConfigPath)) {
    Write-Host "Windows Terminal settings directory not found at $windowsTerminalConfigPath, creating..."
    New-Item -ItemType Directory -Path $windowsTerminalConfigPath -Force
  }

  $settingsPath = "$baseDirectory/Config/WindowsTerminal/settings.json"
  if (-not (Test-Path -Path $settingsPath)) {
    Write-Host "Windows Terminal settings backup not found at $settingsPath"
    exit 1
  }

  # Make a backup of the current settings before overwriting
  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $backupFolder = "$env:USERPROFILE\Documents\WT_Settings_Backup"
  if (-not (Test-Path -Path $backupFolder)) {
    New-Item -Path $backupFolder -ItemType Directory
  }

  $currentBackupFile = Join-Path -Path $backupFolder -ChildPath "settings_backup_$timestamp.json"
  Copy-Item -Path $settingsPath -Destination $currentBackupFile

  Write-Host "Current settings backed up to $currentBackupFile"

  # Replace the current settings with the backup file
  Copy-Item -Path $settingsPath -Destination $windowsTerminalSettings -Force

  Write-Host "Windows Terminal settings restored from $settingsPath."
}
finally {
  Pop-Location
}
