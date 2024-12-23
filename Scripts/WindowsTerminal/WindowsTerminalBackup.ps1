$sourcePath = "$HOME\scoop\apps\windows-terminal\current\settings\settings.json"
$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$baseDirectory = "$baseDirectory\.."
$backupFolder = "$baseDirectory\Config\WindowsTerminal"
Push-Location "$baseDirectory"

if (-not (Test-Path -Path $backupFolder)) {
  New-Item -Path $backupFolder -ItemType Directory
}

if (Test-Path -Path $sourcePath) {
  $backupFile = "$backupFolder\settings.json"
  Copy-Item -Path $sourcePath -Destination $backupFile
  Write-Host "Windows Terminal settings exported successfully."
} else {
  Write-Host "Windows Terminal settings file not found!"
}

$computerName = $env:COMPUTERNAME
Get-Content -Path (Get-PSReadLineOption).HistorySavePath | Out-File -FilePath "$backupFolder\$computerName-PowerShellHistory.txt"
Write-Host "Backed up PowerShellHistory for $computerName"
Pop-Location
