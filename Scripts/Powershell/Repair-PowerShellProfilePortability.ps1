[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$ProfilePath,

    [Parameter(Mandatory = $false)]
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$operatorRunbookUrl = "https://github.com/wallstop/wallstop-utils/blob/main/docs/operator-runbooks/backup-host-state.md"
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$profileHelperPath = Join-Path -Path $repositoryRoot -ChildPath "Scripts/Utils/Common/PSReadLineProfilePortabilityHelpers.ps1"
$repositoryProfilePath = Join-Path -Path $repositoryRoot -ChildPath "Config/Powershell/CurrentUserCurrentHost_Microsoft.PowerShell_profile.ps1"

if (-not (Test-Path -LiteralPath $profileHelperPath -PathType Leaf)) {
    throw "E_PROFILE_REPAIR_HELPER_MISSING: PSReadLine portability helper not found at '$profileHelperPath'. See $operatorRunbookUrl"
}
if (-not (Test-Path -LiteralPath $repositoryProfilePath -PathType Leaf)) {
    throw "E_PROFILE_REPAIR_SOURCE_MISSING: Repository PowerShell profile not found at '$repositoryProfilePath'. See $operatorRunbookUrl"
}

. $profileHelperPath

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = $PROFILE.CurrentUserCurrentHost
}

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    throw "E_PROFILE_REPAIR_DESTINATION_UNAVAILABLE: No PowerShell current-user profile path was available. Pass -ProfilePath explicitly. See $operatorRunbookUrl"
}

$resolvedRepositoryProfilePath = (Resolve-Path -LiteralPath $repositoryProfilePath -ErrorAction Stop).Path
$repositoryViolations = @(Get-PSReadLineProfilePortabilityViolation -Path $resolvedRepositoryProfilePath)
if ($repositoryViolations.Count -gt 0) {
    throw (
        "E_PROFILE_REPAIR_SOURCE_NOT_PORTABLE: Repository profile '{0}' is not portable. violations={1}. Repair the repository profile before changing a user profile. See {2}" -f
        $resolvedRepositoryProfilePath,
        ($repositoryViolations -join ','),
        $operatorRunbookUrl
    )
}

$destinationPath = [System.IO.Path]::GetFullPath($ProfilePath)

Write-Host "PowerShell profile repair preview" -ForegroundColor Cyan
Write-Host ("  Source:      {0}" -f $resolvedRepositoryProfilePath)
Write-Host ("  Destination: {0}" -f $destinationPath)
Write-Host ("  Apply:       {0}" -f $Apply.IsPresent)

if (-not $Apply.IsPresent) {
    Write-Host "No files changed. Re-run with -Apply after reviewing the destination." -ForegroundColor Yellow
    exit 0
}

if (-not $PSCmdlet.ShouldProcess($destinationPath, "replace with the validated repository PowerShell profile")) {
    exit 0
}

try {
    $repairResult = Restore-PowerShellProfileFromValidatedSource -ProfilePath $destinationPath -RepositoryProfilePath $resolvedRepositoryProfilePath
    if (-not $repairResult.Repaired) {
        throw "E_PROFILE_REPAIR_SAME_FILE: Destination profile '$destinationPath' is the repository profile source; repairing it from itself cannot resolve drift."
    }

    Write-Host ("PowerShell profile repaired successfully: {0}" -f $destinationPath) -ForegroundColor Green
    if (-not [string]::IsNullOrWhiteSpace($repairResult.BackupPath)) {
        Write-Host ("Previous profile backed up to: {0}" -f $repairResult.BackupPath) -ForegroundColor DarkGray
    }
}
catch {
    if ($_.Exception.Message -match '^(E_PROFILE_REPAIR_|E_PSREADLINE_PROFILE_REPAIR_)') {
        throw
    }

    throw "E_PROFILE_REPAIR_FAILED: Could not repair PowerShell profile '$destinationPath'. error=$($_.Exception.Message). See $operatorRunbookUrl"
}
