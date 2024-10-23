$sourcePath = $PROFILE
$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$baseDirectory = "$baseDirectory\.."
$backupFolder = "$baseDirectory\Config\Powershell"
Push-Location "$baseDirectory"

if (-not (Test-Path -Path $backupFolder)) {
  New-Item -Path $backupFolder -ItemType Directory
}

if (Test-Path -Path $sourcePath) {
  $backupFile = Split-Path $sourcePath -Leaf
  $backupFile = "$backupFolder\$backupFile"
  Copy-Item -Path $sourcePath -Destination $backupFile
  Write-Host "Powershell settings exported successfully."
} else {
  Write-Warning "Powershell settings file not found!"
}

$powershell7SourcePath = $HOME
$powershell7SourcePath = "$powershell7SourcePath\PowerShell\profile.ps1"
if (Test-Path -Path $powershell7SourcePath) {
  $backupFile = Split-Path $powershell7SourcePath -Leaf
  $backupFile = "$backupFolder\$backupFile"
  Copy-Item -Path $powershell7SourcePath -Destination $backupFile
  Write-Host "Powershell 7 settings exported successfully."
} else {
  Write-Warning "Powershell 7 settings file not found!"
}

$computerName = $env:COMPUTERNAME
Get-Content -Path (Get-PSReadLineOption).HistorySavePath | Out-File -FilePath "$backupFolder\$computerName-PowerShellHistory.txt"
Write-Host "Backed up PowerShellHistory for $computerName"
Pop-Location
