Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$baseDirectory = "$baseDirectory\.."
$backupFolder = "$baseDirectory\Config\Powershell"
Push-Location -Path $baseDirectory

try {
    if (-not (Test-Path -Path $backupFolder)) {
        New-Item -Path $backupFolder -ItemType Directory | Out-Null
    }

    $profilesBackedUp = 0

    $sourcePath = $HOME
    $sourcePath = "$sourcePath\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
    if (Test-Path -Path $sourcePath -PathType Leaf) {
        $backupFile = Split-Path $sourcePath -Leaf
        $backupFile = "$backupFolder\$backupFile"
        Copy-Item -Path $sourcePath -Destination $backupFile
        $profilesBackedUp++
        Write-Host "Windows PowerShell settings exported successfully." -ForegroundColor Green
    }
    else {
        Write-Warning "W_POWERSHELL_BACKUP_PROFILE_MISSING: Windows PowerShell settings file not found at '$sourcePath'."
    }

    $powershell7SourcePath = $HOME
    $powershell7SourcePath = "$powershell7SourcePath\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
    if (Test-Path -Path $powershell7SourcePath -PathType Leaf) {
        $backupFile = Split-Path $powershell7SourcePath -Leaf
        $backupFile = "$backupFolder\$backupFile"
        Copy-Item -Path $powershell7SourcePath -Destination $backupFile
        $profilesBackedUp++
        Write-Host "PowerShell 7 settings exported successfully." -ForegroundColor Green
    }
    else {
        Write-Warning "W_POWERSHELL7_BACKUP_PROFILE_MISSING: PowerShell 7 settings file not found at '$powershell7SourcePath'."
    }

    if ($profilesBackedUp -eq 0) {
        Write-Error "E_POWERSHELL_BACKUP_NO_PROFILES_FOUND: No PowerShell profile files were found to back up."
        exit 1
    }
}
finally {
    Pop-Location
}
