$rootDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location $rootDirectory
try {
  $komorebiConfig = "$env:USERPROFILE\komorebi.json"
  $komorebiBarConfig = "$env:USERPROFILE\komorebi.bar.json"
  Copy-Item -Path "$rootDirectory\Config\Komorebi\komorebi.json" -Destination $komorebiConfig -Force
  Copy-Item -Path "$rootDirectory\Config\Komorebi\komorebi.bar.json" -Destination $komorebiBarConfig -Force
  Write-Host "Successfully restored Komorebi" -ForegroundColor Green
}
finally {
  Pop-Location
}
