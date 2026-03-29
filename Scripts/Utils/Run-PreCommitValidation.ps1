[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$All,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-ModulePathCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -Path $Path -PathType Container)) {
        return
    }

    $separator = [System.IO.Path]::PathSeparator
    $currentEntries = @($env:PSModulePath -split [regex]::Escape([string]$separator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($currentEntries -contains $Path) {
        return
    }

    $env:PSModulePath = if ([string]::IsNullOrWhiteSpace($env:PSModulePath)) {
        $Path
    }
    else {
        "$Path$separator$env:PSModulePath"
    }
}

function Ensure-PortableUserModulePaths {
    $userHome = [Environment]::GetFolderPath("UserProfile")
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        return
    }

    Add-ModulePathCandidate -Path (Join-Path -Path $userHome -ChildPath ".local/share/powershell/Modules")

    $snapCodeRoot = Join-Path -Path $userHome -ChildPath "snap/code"
    if (Test-Path -Path $snapCodeRoot -PathType Container) {
        $snapCodeProfiles = Get-ChildItem -Path $snapCodeRoot -Directory -ErrorAction SilentlyContinue
        foreach ($profile in @($snapCodeProfiles)) {
            Add-ModulePathCandidate -Path (Join-Path -Path $profile.FullName -ChildPath ".local/share/powershell/Modules")
        }
    }
}

function Get-CommandWithOptionalModuleImport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$ModuleName,

        [Parameter(Mandatory = $true)]
        [version]$MinimumVersion
    )

    Ensure-PortableUserModulePaths
    $command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command
    }

    try {
        Import-Module -Name $ModuleName -MinimumVersion $MinimumVersion -ErrorAction Stop | Out-Null
    }
    catch {
        return $null
    }

    return (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)
}

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
    $llmHarnessPattern = '^(\.llm/.+\.md|AGENTS\.md|\.github/copilot-instructions\.md|CLAUDE\.md|GEMINI\.md|CURSOR\.md|OPENAI\.md|CODEX\.md|Scripts/Utils/Quality/(Update-LlmSkillsIndex|Test-LlmHarness)\.ps1|Tests/Utils/LlmHarness\.Tests\.ps1)$'

    $utilsTestFiles = @($stagedFiles | Where-Object { $_ -match $utilsTestPattern })
    $githubTestFiles = @($stagedFiles | Where-Object { $_ -match $githubTestPattern })
    $scriptFiles = @($stagedFiles | Where-Object { $_ -match $scriptPattern })
    $llmHarnessFiles = @($stagedFiles | Where-Object { $_ -match $llmHarnessPattern })

    $runUtilsTests = $All -or $utilsTestFiles.Count -gt 0
    $runGitHubTests = $All -or $githubTestFiles.Count -gt 0
    $runAnalyzer = $All -or $scriptFiles.Count -gt 0
    $runLlmHarnessValidation = $All -or $llmHarnessFiles.Count -gt 0

    if (-not $runUtilsTests -and -not $runGitHubTests -and -not $runAnalyzer -and -not $runLlmHarnessValidation) {
        Write-Host "No staged files requiring utility validation; skipping validation."
        return
    }

    if ($runUtilsTests -or $runGitHubTests) {
        $pesterCommand = Get-CommandWithOptionalModuleImport -CommandName "Invoke-Pester" -ModuleName "Pester" -MinimumVersion ([version]"5.5.0")
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
        $scriptAnalyzerCommand = Get-CommandWithOptionalModuleImport -CommandName "Invoke-ScriptAnalyzer" -ModuleName "PSScriptAnalyzer" -MinimumVersion ([version]"1.21.0")
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

    if ($runLlmHarnessValidation) {
        $llmValidatorPath = Join-Path -Path $repoRoot -ChildPath "Scripts/Utils/Quality/Test-LlmHarness.ps1"
        if (-not (Test-Path -Path $llmValidatorPath -PathType Leaf)) {
            throw "E_CONFIG_ERROR: LLM harness validator is missing at '$llmValidatorPath'."
        }

        Write-Host "Running LLM harness validation..."
        & $llmValidatorPath -RootPath $repoRoot
    }

    Write-Host "Pre-commit validation passed."
}
finally {
    Pop-Location
}
