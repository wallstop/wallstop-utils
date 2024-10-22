$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location $baseDirectory
try {
  $copyFrom = "$baseDirectory\..\Config\PowerToys"

  if (-not (Test-Path -Path $copyFrom)) {
    Write-Warning "Failed to find PowerToys settings at $copyFrom."
    exit 1
  }

  $targetPath = "$env:LOCALAPPDATA\Microsoft\PowerToys"
  if (-not (Test-Path -Path $targetPath)) {
    Write-Warning "Failed to detect PowerToys config directory at '$targetPath'."
    exit 1
  }

  Robocopy.exe $copyFrom $targetPath *.json /S
  Write-Host "PowerToys configuration settings restored from $targetFolder."
}
finally {
  Pop-Location
}
