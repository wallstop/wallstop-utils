[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$All,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
Push-Location -Path $repoRoot

try {
    $stagedFiles = @()
    if (-not $All) {
        $stagedFiles = @(git diff --cached --name-only --diff-filter=ACMR)
        if ($LASTEXITCODE -ne 0) {
            throw "E_CONFIG_ERROR: Failed to read staged files."
        }
    }

    $relevantPattern = '^(Scripts/Utils|Tests/Utils)/.+\.ps1$'
    $relevantFiles = @($stagedFiles | Where-Object { $_ -match $relevantPattern })

    if (-not $All -and $relevantFiles.Count -eq 0) {
        Write-Host "No staged files in Scripts/Utils or Tests/Utils; skipping validation."
        return
    }

    Write-Host "Running Tests/Utils Pester suite..."
    $testResult = Invoke-Pester -Path "Tests/Utils" -PassThru -ErrorAction Stop
    if ($testResult.FailedCount -gt 0) {
        throw "E_TEST_FAILURE: Tests/Utils failed ($($testResult.FailedCount) failing tests)."
    }

    if (-not $SkipAnalyzer) {
        $scriptAnalyzerCommand = Get-Command -Name Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue
        if ($null -eq $scriptAnalyzerCommand) {
            throw "E_CONFIG_ERROR: Invoke-ScriptAnalyzer is not available. Install PSScriptAnalyzer or re-run with -SkipAnalyzer."
        }

        Write-Host "Running ScriptAnalyzer for Scripts/Utils..."
        $analysisRaw = Invoke-ScriptAnalyzer -Path "Scripts/Utils" -Settings ".psscriptanalyzer.psd1" -Recurse -ErrorAction Stop
        $analysisResult = if ($null -eq $analysisRaw) { @() } else { @($analysisRaw) }
        $analysisCount = @($analysisResult).Count
        if ($analysisCount -gt 0) {
            $firstIssue = @($analysisResult)[0]
            throw "E_LINT_FAILURE: ScriptAnalyzer reported $analysisCount issue(s). First issue: $($firstIssue.RuleName) at $($firstIssue.ScriptName):$($firstIssue.Line)"
        }
    }

    Write-Host "Pre-commit validation passed."
} finally {
    Pop-Location
}
