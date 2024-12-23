$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$baseDirectory = "$baseDirectory\.."
Push-Location "$baseDirectory"

try {
  $settingsPath = "$baseDirectory/Config/Powershell/Microsoft.Powershell_profile.ps1"
  if (-not (Test-Path -Path $settingsPath)) {
    Write-Host "Powershell settings backup not found at $settingsPath"
    exit 1
  }

  $powershellConfigPath = "$HOME\Documents\Powershell"
  if (-not (Test-Path -Path $powershellConfigPath)) {
    Write-Host "Powershell settings directory not found at $powershellConfigPath, creating..."
    New-Item -ItemType Directory -Path $powershellConfigPath -Force
  }

  $windowsPowershellConfigPath = "$HOME\Documents\WindowsPowerShell"
  if (-not (Test-Path -Path $windowsPowershellConfigPath)) {
    Write-Host "Windows Powershell settings directory not found at $windowsPowershellConfigPath, creating..."
    New-Item -ItemType Directory -Path $windowsPowershellConfigPath -Force
  }

  $powershellSettings = "$powershellConfigPath\Microsoft.Powershell_profile.ps1"
  $windowsPowershellSettings = "$windowsPowershellConfigPath\Microsoft.Powershell_profile.ps1"

  # Make a backup of the current settings before overwriting
  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $backupFolder = "$env:USERPROFILE\Documents\PowerShell_Settings_Backup"
  if (-not (Test-Path -Path $backupFolder)) {
    New-Item -Path $backupFolder -ItemType Directory
  }

  $currentBackupFile = Join-Path -Path $backupFolder -ChildPath "powershell_settings_backup_$timestamp.ps1"
  Copy-Item -Path $powershellSettings -Destination $currentBackupFile

  Write-Host "Current PowerShell settings backed up to $currentBackupFile"

  $currentBackupFile = Join-Path -Path $backupFolder -ChildPath "windows_powershell_settings_backup_$timestamp.ps1"
  Copy-Item -Path $windowsPowershellSettings -Destination $currentBackupFile

  Write-Host "Current Windows PowerShell settings backed up to $currentBackupFile"

  Copy-Item -Path $settingsPath -Destination $powershellSettings -Force
  Copy-Item -Path $settingsPath -Destination $windowsPowershellSettings -Force

  Write-Host "PowerShell settings restored from $settingsPath."
}
finally {
  Pop-Location
}
