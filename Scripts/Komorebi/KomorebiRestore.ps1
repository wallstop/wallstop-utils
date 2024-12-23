$rootDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$rootDirectory = "$rootDirectory\.."
Push-Location $rootDirectory
try {
  $applicationYaml = "$env:USERPROFILE\applications.yaml"
  $komorebiConfig = "$env:USERPROFILE\komorebi.json"
  $komorebiBarConfig = "$env:USERPROFILE\komorebi.bar.json"
  Copy-Item -Path "$rootDirectory\Config\Komorebi\komorebi.json" -Destination $komorebiConfig -Force
  Copy-Item -Path "$rootDirectory\Config\Komorebi\komorebi.bar.json" -Destination $komorebiBarConfig -Force
  Copy-Item -Path "$rootDirectory\Config\Komorebi\applications.yaml" -Destination $applicationYaml -Force
  Write-Host "Successfully restored Komorebi" -ForegroundColor Green
}
finally {
  Pop-Location
}
