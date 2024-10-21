$rootDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location $rootDirectory
try {
  $komorebiConfig = "$env:USERPROFILE\komorebi.json"
  $komorebiBarConfig = "$env:USERPROFILE\komorebi.bar.json"
  Copy-Item -Path $komorebiConfig -Destination "$rootDirectory\Config\Komorebi\komorebi.json" -Force
  Copy-Item -Path $komorebiBarConfig -Destination "$rootDirectory\Config\Komorebi\komorebi.bar.json" -Force
  Write-Host "Successfully backed up Komorebi" -ForegroundColor Green
}
finally {
  Pop-Location
}
