[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Context = "quality checks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$status = @(& git status --porcelain)
if ($LASTEXITCODE -ne 0) {
    throw "E_GIT_STATUS_FAILED: Unable to inspect repository status after $Context."
}

if (@($status).Count -gt 0) {
    $details = $status -join [Environment]::NewLine
    throw "E_FORMAT_DRIFT: Repository has changes after $Context. Run local auto-fix and commit updates before pushing.`n$details"
}

Write-Host "Git tree is clean after $Context."
