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
        $stagedFileQuery = 'git diff --cached --name-only --diff-filter=ACMR'
        $stagedFileOutput = @(& git diff --cached --name-only --diff-filter=ACMR 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $gitErrorText = if ($stagedFileOutput.Count -gt 0) { $stagedFileOutput -join ' ' } else { '(no output)' }
            throw "E_CONFIG_ERROR: Failed to read staged files using '$stagedFileQuery' (exitCode=$LASTEXITCODE). Git output: $gitErrorText"
        }

        $stagedFiles = $stagedFileOutput
    }

    $utilsTestPattern = '^(Scripts/Utils|Tests/Utils)/.+\.ps1$'
    $githubTestPattern = '^(Scripts/Utils/GitHub|Tests/GitHub)/.+\.ps1$'
    $scriptPattern = '^Scripts/Utils/.+\.ps1$'

    $utilsTestFiles = @($stagedFiles | Where-Object { $_ -match $utilsTestPattern })
    $githubTestFiles = @($stagedFiles | Where-Object { $_ -match $githubTestPattern })
    $scriptFiles = @($stagedFiles | Where-Object { $_ -match $scriptPattern })

    $runUtilsTests = $All -or $utilsTestFiles.Count -gt 0
    $runGitHubTests = $All -or $githubTestFiles.Count -gt 0
    $runAnalyzer = $All -or $scriptFiles.Count -gt 0

    if (-not $runUtilsTests -and -not $runGitHubTests -and -not $runAnalyzer) {
        Write-Host "No staged files requiring utility validation; skipping validation."
        return
    }

    if ($runUtilsTests -or $runGitHubTests) {
        $pesterCommand = Get-Command -Name Invoke-Pester -ErrorAction SilentlyContinue
        if ($null -eq $pesterCommand) {
            throw "E_CONFIG_ERROR: Invoke-Pester is not available. Install Pester (for example: Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0)."
        }
    }

    if ($runUtilsTests) {
        Write-Host "Running Tests/Utils Pester suite..."
        $testResult = Invoke-Pester -Path "Tests/Utils" -PassThru -ErrorAction Stop
        if ($testResult.FailedCount -gt 0) {
            throw "E_TEST_FAILURE: Tests/Utils failed ($($testResult.FailedCount) failing tests)."
        }
    }

    if ($runGitHubTests) {
        Write-Host "Running Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1 Pester suite..."
        $githubTestResult = Invoke-Pester -Path "Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1" -PassThru -ErrorAction Stop
        if ($githubTestResult.FailedCount -gt 0) {
            throw "E_TEST_FAILURE: Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1 failed ($($githubTestResult.FailedCount) failing tests)."
        }
    }

    if (-not $SkipAnalyzer -and $runAnalyzer) {
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
