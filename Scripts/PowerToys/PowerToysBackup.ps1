$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location $baseDirectory
try {
  $backupFolder = "$baseDirectory\..\Config\PowerToys"

  if (-not (Test-Path -Path $backupFolder)) {
    New-Item -Path $backupFolder -ItemType Directory
  }
  else {
    Remove-Item -Path "$backupFolder\*" -Recurse -Force
  }

  $sourcePath = "$env:LOCALAPPDATA\Microsoft\PowerToys"
  if (-not (Test-Path -Path $sourcePath)) {
    Write-Warning "Failed to detect PowerToys config directory at '$sourcePath'."
    exit 1
  }

  Robocopy.exe $sourcePath $backupFolder *.json /S
  Write-Host "PowerToys configuration settings have been backed up to $backupFolder."
}
finally {
  Pop-Location
}
