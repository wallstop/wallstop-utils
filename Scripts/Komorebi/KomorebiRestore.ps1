$rootDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$rootDirectory = "$rootDirectory\.."
Push-Location $rootDirectory
try {
    $applicationYaml = "$env:USERPROFILE\applications.yaml"
    $komorebiConfig = "$env:USERPROFILE\komorebi.json"
    $komorebiBarConfig = "$env:USERPROFILE\komorebi.bar.json"

    $komorebiSourceConfig = "$rootDirectory\Config\Komorebi\komorebi.json"
    $komorebiSourceBarConfig = "$rootDirectory\Config\Komorebi\komorebi.bar.json"
    $komorebiSourceApplications = "$rootDirectory\Config\Komorebi\applications.yaml"

    $missingSources = @()
    foreach ($sourcePath in @($komorebiSourceConfig, $komorebiSourceBarConfig, $komorebiSourceApplications)) {
        if (-not (Test-Path -Path $sourcePath)) {
            $missingSources += $sourcePath
        }
    }

    if ($missingSources.Count -gt 0) {
        Write-Error ("E_KOMOREBI_RESTORE_SOURCE_MISSING: Missing required Komorebi backup file(s): {0}" -f ($missingSources -join ', '))
        exit 1
    }

    Copy-Item -Path $komorebiSourceConfig -Destination $komorebiConfig -Force
    Copy-Item -Path $komorebiSourceBarConfig -Destination $komorebiBarConfig -Force
    Copy-Item -Path $komorebiSourceApplications -Destination $applicationYaml -Force
    Write-Host "Successfully restored Komorebi" -ForegroundColor Green
}
finally {
    Pop-Location
}
