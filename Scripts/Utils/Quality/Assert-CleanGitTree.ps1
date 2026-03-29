[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Context = "quality checks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$status = @(& git status --porcelain=v1 --untracked-files=all)
$lecValue = Get-Variable -Name 'LASTEXITCODE' -ValueOnly -ErrorAction SilentlyContinue
$statusExitCode = if ($null -ne $lecValue) { [int]$lecValue } else { -1 }
if ($statusExitCode -ne 0) {
    throw "E_GIT_STATUS_FAILED: Unable to inspect repository status after $Context."
}

if (@($status).Count -gt 0) {
    $trackedChanges = @($status | Where-Object { $_ -notmatch '^\?\?' })
    $untrackedChanges = @($status | Where-Object { $_ -match '^\?\?' })

    $summary = "tracked=$($trackedChanges.Count), untracked=$($untrackedChanges.Count), total=$(@($status).Count)"
    $details = $status -join [Environment]::NewLine

    $hint = ""
    if ($untrackedChanges.Count -gt 0) {
        $ciToolCandidates = @($untrackedChanges | Where-Object { $_ -match '(?i)\?\?\s+\.?tools[/\\]|autohotkey-portable' })
        if ($ciToolCandidates.Count -gt 0) {
            $hint = "`nHint: untracked CI tool artifacts were detected. Ensure workflow caches/install roots use runner-temp paths (for example, `$env:RUNNER_TEMP) instead of repository-relative directories."
        }
    }

    throw "E_FORMAT_DRIFT: Repository has changes after $Context. Run local auto-fix and commit updates before pushing.`nSummary: $summary`nDetails:`n$details$hint"
}

Write-Host "Git tree is clean after $Context."
