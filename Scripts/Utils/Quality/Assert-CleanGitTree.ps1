[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Context = "quality checks",

    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$diagnosticsHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Common/DiagnosticsHelpers.ps1"
if (-not (Test-Path -Path $diagnosticsHelpersPath -PathType Leaf)) {
    throw "E_ASSERT_CLEAN_GIT_TREE_DIAGNOSTICS_HELPER_MISSING: diagnostics helper file not found at '$diagnosticsHelpersPath'."
}

.$diagnosticsHelpersPath

function Get-LastExitCodeOrDefault {
    $lecValue = Get-Variable -Name 'LASTEXITCODE' -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $lecValue) {
        return [int]$lecValue
    }

    return -1
}

$gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) {
    throw "E_ASSERT_CLEAN_GIT_TREE_GIT_NOT_AVAILABLE: git is not available on PATH."
}

Write-Verbose ("Assert-CleanGitTree git diagnostics: gitPath='{0}'" -f $gitCommand.Source)

$gitExecutable = $gitCommand.Source
$workingDirectory = (Get-Location).Path
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $repoProbeRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "../../..") -ErrorAction Stop).Path
    $repositoryRootArgs = @("-C", $repoProbeRoot, "rev-parse", "--show-toplevel")
    $repositoryRootOutput = @(& $gitExecutable @repositoryRootArgs 2>$null)
    $repositoryRootExitCode = Get-LastExitCodeOrDefault
    if ($repositoryRootExitCode -ne 0 -or $repositoryRootOutput.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$repositoryRootOutput[0])) {
        $repositoryRootDiagnostics = @(& $gitExecutable @repositoryRootArgs 2>&1)
        $repositoryRootPreview = Get-OutputPreview -OutputLines $repositoryRootDiagnostics
        throw (
            "E_ASSERT_CLEAN_GIT_TREE_NOT_REPOSITORY: unable to determine repository root for context '{0}' (exitCode={1}; workingDirectory='{2}'; outputPreview={3})." -f
            $Context,
            $repositoryRootExitCode,
            $workingDirectory,
            $repositoryRootPreview
        )
    }

    $RepositoryRoot = (Resolve-Path -LiteralPath ([string]$repositoryRootOutput[0]).Trim() -ErrorAction Stop).Path
}

$statusArgs = @("-C", $RepositoryRoot, "status", "--porcelain=v1", "--untracked-files=all")
$status = @(& $gitExecutable @statusArgs 2>$null)
$statusExitCode = Get-LastExitCodeOrDefault
if ($statusExitCode -ne 0) {
    $statusDiagnostics = @(& $gitExecutable @statusArgs 2>&1)
    $statusPreview = Get-OutputPreview -OutputLines $statusDiagnostics
    throw "E_GIT_STATUS_FAILED: Unable to inspect repository status after $Context (exitCode=$statusExitCode; repositoryRoot='$RepositoryRoot'; workingDirectory='$workingDirectory'; outputPreview=$statusPreview)."
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

    throw "E_FORMAT_DRIFT: Repository has changes after $Context (repositoryRoot='$RepositoryRoot'; workingDirectory='$workingDirectory'). Run local auto-fix and commit updates before pushing.`nSummary: $summary`nDetails:`n$details$hint"
}

Write-Host "Git tree is clean after $Context."
