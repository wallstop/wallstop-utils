Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rootDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$rootDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $rootDirectory -ChildPath "..") -ErrorAction Stop).Path

Push-Location -LiteralPath $rootDirectory
try {
    $applicationYaml = "$env:USERPROFILE\applications.yaml"
    $komorebiConfig = "$env:USERPROFILE\komorebi.json"
    $komorebiBarConfig = "$env:USERPROFILE\komorebi.bar.json"

    $missingSources = @()
    foreach ($sourcePath in @($komorebiConfig, $komorebiBarConfig, $applicationYaml)) {
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            $missingSources += $sourcePath
        }
    }

    if ($missingSources.Count -gt 0) {
        Write-Error ("E_KOMOREBI_BACKUP_SOURCE_MISSING: Missing required Komorebi file(s): {0}" -f ($missingSources -join ', '))
        exit 1
    }

    try {
        Copy-Item -LiteralPath $komorebiConfig -Destination "$rootDirectory\Config\Komorebi\komorebi.json" -Force
        Copy-Item -LiteralPath $komorebiBarConfig -Destination "$rootDirectory\Config\Komorebi\komorebi.bar.json" -Force
        Copy-Item -LiteralPath $applicationYaml -Destination "$rootDirectory\Config\Komorebi\applications.yaml" -Force
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
