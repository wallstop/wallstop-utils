Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rootDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$rootDirectory = "$rootDirectory\.."

Push-Location -Path $rootDirectory
try {
  $applicationYaml = "$env:USERPROFILE\applications.yaml"
  $komorebiConfig = "$env:USERPROFILE\komorebi.json"
  $komorebiBarConfig = "$env:USERPROFILE\komorebi.bar.json"

  $missingSources = @()
  foreach ($sourcePath in @($komorebiConfig, $komorebiBarConfig, $applicationYaml)) {
    if (-not (Test-Path -Path $sourcePath -PathType Leaf)) {
      $missingSources += $sourcePath
    }
  }

  if ($missingSources.Count -gt 0) {
    Write-Error ("E_KOMOREBI_BACKUP_SOURCE_MISSING: Missing required Komorebi file(s): {0}" -f ($missingSources -join ', '))
    exit 1
  }

  try {
    Copy-Item -Path $komorebiConfig -Destination "$rootDirectory\Config\Komorebi\komorebi.json" -Force
    Copy-Item -Path $komorebiBarConfig -Destination "$rootDirectory\Config\Komorebi\komorebi.bar.json" -Force
    Copy-Item -Path $applicationYaml -Destination "$rootDirectory\Config\Komorebi\applications.yaml" -Force
    Write-Host "Successfully backed up Komorebi" -ForegroundColor Green
  }
  catch {
    Write-Error ("E_KOMOREBI_BACKUP_COPY_FAILED: Failed to copy Komorebi backup files: {0}" -f $_.Exception.Message)
    exit 1
  }
}
finally {
  Pop-Location
}
