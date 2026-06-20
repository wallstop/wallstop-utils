param(
    [Parameter(Mandatory = $false)]
    [string]$ProfileName,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rootDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$rootDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $rootDirectory -ChildPath "..") -ErrorAction Stop).Path
$profileHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "KomorebiProfileHelpers.ps1"
if (-not (Test-Path -LiteralPath $profileHelpersPath -PathType Leaf)) {
    throw "E_KOMOREBI_PROFILE_HELPER_MISSING: Komorebi profile helper script not found at '$profileHelpersPath'."
}

. $profileHelpersPath

Push-Location -LiteralPath $rootDirectory
try {
    $result = Initialize-KomorebiProfileFromLegacyRoot -RepositoryRoot $rootDirectory -ProfileName $ProfileName -Force:$Force
    Write-Host (
        "Initialized Komorebi profile '{0}' ({1}) from legacy root snapshot at {2}" -f
        $result.ProfileName,
        $result.ProfileSource,
        $result.ProfileDirectory
    ) -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    Pop-Location
}
