Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Stop-Process -Name "komorebi" -ErrorAction SilentlyContinue
Stop-Process -Name "whkd" -ErrorAction SilentlyContinue

$profileHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "KomorebiProfileHelpers.ps1"
if (-not (Test-Path -LiteralPath $profileHelpersPath -PathType Leaf)) {
    throw "E_KOMOREBI_PROFILE_HELPER_MISSING: Komorebi profile helper script not found at '$profileHelpersPath'."
}

. $profileHelpersPath

$userProfileRoot = Resolve-KomorebiUserProfileRoot
$configPath = Join-Path -Path $userProfileRoot -ChildPath "komorebi.json"
komorebic start --config $configPath --whkd --clean-state

# `komorebic monitor-information` needs a running Komorebi, so the gate runs after start.
# It fails loudly when a display would silently fall back to the Komorebi defaults instead
# of the layout this config asks for.
$assignments = @(Assert-KomorebiLiveConfiguration -ConfigPath $configPath)
Write-KomorebiMonitorAssignmentSummary -Assignments $assignments
