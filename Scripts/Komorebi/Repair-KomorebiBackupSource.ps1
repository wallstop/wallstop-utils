[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileName,

    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$UserProfileRoot,

    [Parameter(Mandatory = $false)]
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$operatorRunbookUrl = "https://github.com/wallstop/wallstop-utils/blob/main/docs/operator-runbooks/backup-host-state.md"
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$profileHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "KomorebiProfileHelpers.ps1"
if (-not (Test-Path -LiteralPath $profileHelpersPath -PathType Leaf)) {
    throw "E_KOMOREBI_REPAIR_HELPER_MISSING: Komorebi profile helper not found at '$profileHelpersPath'. See $operatorRunbookUrl"
}

. $profileHelpersPath

$resolvedRepositoryRoot = Resolve-KomorebiRepositoryRoot -RepositoryRoot $repositoryRoot
$resolvedUserProfileRoot = Resolve-KomorebiUserProfileRoot -UserProfileRoot $UserProfileRoot
$selection = Resolve-KomorebiProfileSelection -ProfileName $ProfileName -EnvironmentProfileName $null
$source = Resolve-KomorebiRestoreSourceDirectory -RepositoryRoot $resolvedRepositoryRoot -Selection $selection
Assert-KomorebiSnapshotJsonValid -Directory $source.Directory -ErrorCode "E_KOMOREBI_REPAIR_SOURCE_INVALID" -Context "repair source"

Write-Host "Komorebi backup-source repair preview" -ForegroundColor Cyan
Write-Host ("  Profile:     {0}" -f $selection.Name)
Write-Host ("  Source:      {0}" -f $source.Directory)
Write-Host ("  Destination: {0}" -f $resolvedUserProfileRoot)
Write-Host ("  Apply:       {0}" -f $Apply.IsPresent)

if (-not $Apply.IsPresent) {
    Write-Host "No files changed. Re-run with -Apply after reviewing the selected profile." -ForegroundColor Yellow
    exit 0
}

if (-not $PSCmdlet.ShouldProcess($resolvedUserProfileRoot, "restore selected Komorebi profile '$($selection.Name)' transactionally")) {
    exit 0
}

try {
    $result = Invoke-KomorebiProfileRestore `
        -RepositoryRoot $resolvedRepositoryRoot `
        -UserProfileRoot $resolvedUserProfileRoot `
        -ProfileName $selection.Name `
        -EnvironmentProfileName $null

    Write-Host ("Komorebi backup source repaired successfully for profile '{0}' at '{1}'." -f $result.ProfileName, $result.UserProfileRoot) -ForegroundColor Green
}
catch {
    if ($_.Exception.Message -match '^E_KOMOREBI_') {
        throw
    }

    throw "E_KOMOREBI_REPAIR_FAILED: Could not restore Komorebi profile '$($selection.Name)' to '$resolvedUserProfileRoot'. error=$($_.Exception.Message). See $operatorRunbookUrl"
}
