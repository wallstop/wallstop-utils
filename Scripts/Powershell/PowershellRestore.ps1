Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
Push-Location -LiteralPath $baseDirectory

try {
    $settingsPath = Join-Path -Path $baseDirectory -ChildPath 'Config'
    $settingsPath = Join-Path -Path $settingsPath -ChildPath 'Powershell'
    $settingsPath = Join-Path -Path $settingsPath -ChildPath 'Microsoft.PowerShell_profile.ps1'
    if (-not (Test-Path -Path $settingsPath -PathType Leaf)) {
        Write-Error "E_POWERSHELL_RESTORE_SOURCE_MISSING: PowerShell settings backup not found at '$settingsPath'."
        exit 1
    }

    $documentsPath = Join-Path -Path $HOME -ChildPath 'Documents'
    $powershellConfigPath = Join-Path -Path $documentsPath -ChildPath 'PowerShell'
    if (-not (Test-Path -Path $powershellConfigPath -PathType Container)) {
        Write-Host "Powershell settings directory not found at $powershellConfigPath, creating..."
        New-Item -ItemType Directory -Path $powershellConfigPath -Force
    }

    $windowsPowershellConfigPath = Join-Path -Path $documentsPath -ChildPath 'WindowsPowerShell'
    if (-not (Test-Path -Path $windowsPowershellConfigPath -PathType Container)) {
        Write-Host "Windows Powershell settings directory not found at $windowsPowershellConfigPath, creating..."
        New-Item -ItemType Directory -Path $windowsPowershellConfigPath -Force
    }

    $powershellSettings = Join-Path -Path $powershellConfigPath -ChildPath 'Microsoft.PowerShell_profile.ps1'
    $windowsPowershellSettings = Join-Path -Path $windowsPowershellConfigPath -ChildPath 'Microsoft.PowerShell_profile.ps1'

    # Make a backup of the current settings before overwriting
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupFolder = Join-Path -Path $documentsPath -ChildPath 'PowerShell_Settings_Backup'
    if (-not (Test-Path -Path $backupFolder -PathType Container)) {
        New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
    }

    $powershellBackupFile = Join-Path -Path $backupFolder -ChildPath "powershell_settings_backup_$timestamp.ps1"
    if (Test-Path -Path $powershellSettings -PathType Leaf) {
        Copy-Item -Path $powershellSettings -Destination $powershellBackupFile -Force
        Write-Host "Current PowerShell settings backed up to $powershellBackupFile"
    }
    else {
        Write-Warning "W_POWERSHELL_RESTORE_NO_POWERSHELL_PROFILE: No existing PowerShell profile found at '$powershellSettings'; skipping safety backup."
    }

    $windowsPowershellBackupFile = Join-Path -Path $backupFolder -ChildPath "windows_powershell_settings_backup_$timestamp.ps1"
    if (Test-Path -Path $windowsPowershellSettings -PathType Leaf) {
        Copy-Item -Path $windowsPowershellSettings -Destination $windowsPowershellBackupFile -Force
        Write-Host "Current Windows PowerShell settings backed up to $windowsPowershellBackupFile"
    }
    else {
        Write-Warning "W_POWERSHELL_RESTORE_NO_WINDOWS_POWERSHELL_PROFILE: No existing Windows PowerShell profile found at '$windowsPowershellSettings'; skipping safety backup."
    }

    Copy-Item -Path $settingsPath -Destination $powershellSettings -Force
    Copy-Item -Path $settingsPath -Destination $windowsPowershellSettings -Force

    Write-Host "PowerShell settings restored from $settingsPath."
}
finally {
    Pop-Location
}
