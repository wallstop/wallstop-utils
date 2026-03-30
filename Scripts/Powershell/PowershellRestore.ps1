Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
Push-Location -Path $baseDirectory

try {
    $settingsPath = Join-Path -Path $baseDirectory -ChildPath 'Config'
    $settingsPath = Join-Path -Path $settingsPath -ChildPath 'Powershell'
    $settingsPath = Join-Path -Path $settingsPath -ChildPath 'Microsoft.Powershell_profile.ps1'
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
        New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
    }

    $powershellBackupFile = Join-Path -Path $backupFolder -ChildPath "powershell_settings_backup_$timestamp.ps1"
    if (Test-Path -Path $powershellSettings) {
        Copy-Item -Path $powershellSettings -Destination $powershellBackupFile -Force
        Write-Host "Current PowerShell settings backed up to $powershellBackupFile"
    }
    else {
        Write-Warning "E_PS_RESTORE_NO_POWERSHELL_PROFILE: No existing PowerShell profile found at '$powershellSettings'; skipping safety backup."
    }

    $windowsPowershellBackupFile = Join-Path -Path $backupFolder -ChildPath "windows_powershell_settings_backup_$timestamp.ps1"
    if (Test-Path -Path $windowsPowershellSettings) {
        Copy-Item -Path $windowsPowershellSettings -Destination $windowsPowershellBackupFile -Force
        Write-Host "Current Windows PowerShell settings backed up to $windowsPowershellBackupFile"
    }
    else {
        Write-Warning "E_PS_RESTORE_NO_WINDOWS_POWERSHELL_PROFILE: No existing Windows PowerShell profile found at '$windowsPowershellSettings'; skipping safety backup."
    }

    Copy-Item -Path $settingsPath -Destination $powershellSettings -Force
    Copy-Item -Path $settingsPath -Destination $windowsPowershellSettings -Force

    Write-Host "PowerShell settings restored from $settingsPath."
}
finally {
    Pop-Location
}
