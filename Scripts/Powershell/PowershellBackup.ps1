$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$baseDirectory = "$baseDirectory\.."
$backupFolder = "$baseDirectory\Config\Powershell"
Push-Location "$baseDirectory"

if (-not (Test-Path -Path $backupFolder)) {
  New-Item -Path $backupFolder -ItemType Directory
}

$sourcePath = $HOME
$sourcePath = "$sourcePath\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
if (Test-Path -Path $sourcePath) {
  $backupFile = Split-Path $sourcePath -Leaf
  $backupFile = "$backupFolder\$backupFile"
  Copy-Item -Path $sourcePath -Destination $backupFile
  Write-Host "Powershell settings exported successfully."
} else {
  Write-Warning "Powershell settings file not found at $sourcePath!"
}

$powershell7SourcePath = $HOME
$powershell7SourcePath = "$powershell7SourcePath\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
if (Test-Path -Path $powershell7SourcePath) {
  $backupFile = Split-Path $powershell7SourcePath -Leaf
  $backupFile = "$backupFolder\$backupFile"
  Copy-Item -Path $powershell7SourcePath -Destination $backupFile
  Write-Host "Powershell 7 settings exported successfully."
} else {
  Write-Warning "Powershell 7 settings file not found at $powershell7SourcePath!"
}

Pop-Location
