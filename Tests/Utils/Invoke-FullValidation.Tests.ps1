Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:validationScriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-FullValidation.ps1"
    $script:prePushHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-push"

    $script:validationScript = Get-Content -Path $script:validationScriptPath -Raw
    $script:prePushHook = Get-Content -Path $script:prePushHookPath -Raw
}

Describe "Invoke-FullValidation workflow contract" {
    $requiredValidationCommands = @(
        @{ Name = "pre-commit stage all files"; Pattern = 'pre-commit\s+run\s+--hook-stage\s+pre-commit\s+--all-files' }
        @{ Name = "pre-push stage all files"; Pattern = 'pre-commit\s+run\s+--hook-stage\s+pre-push\s+--all-files' }
    )

    $requiredFailureCodes = @(
        "E_VALIDATION_PRECOMMIT_FAILED"
        "E_VALIDATION_PREPUSH_FAILED"
        "E_VALIDATION_CI_FAILED"
        "E_VALIDATION_PR_MISSING"
        "E_VALIDATION_PREREQ_MISSING"
        "E_VALIDATION_STATUS_BEFORE_NULL"
        "E_VALIDATION_STATUS_AFTER_NULL"
    )

    $workspaceDriftSafetyMarkers = @(
        @{ Name = "snapshot helper"; Pattern = 'Get-StatusSnapshot' }
        @{ Name = "snapshot sorting"; Pattern = 'function\s+Get-StatusSnapshot\b[\s\S]*?Sort-Object' }
        @{ Name = "non-enumerating snapshot return"; Pattern = 'function\s+Get-StatusSnapshot\b[\s\S]*?Write-Output\s+-NoEnumerate\s+\(\s*\[string\[\]\]\s*\$sortedStatusLines\s*\)' }
        @{ Name = "before snapshot null guard"; Pattern = 'if\s*\(\s*\$null\s*-eq\s*\$statusBeforeValidation\s*\)\s*\{\s*throw\s+"E_VALIDATION_STATUS_BEFORE_NULL' }
        @{ Name = "after snapshot null guard"; Pattern = 'if\s*\(\s*\$null\s*-eq\s*\$statusAfterValidation\s*\)\s*\{\s*throw\s+"E_VALIDATION_STATUS_AFTER_NULL' }
        @{ Name = "verbose snapshot diagnostics"; Pattern = 'Write-Verbose\s+".*before=\$beforeCount.*after=\$afterCount' }
        @{ Name = "tree drift failure code"; Pattern = 'E_VALIDATION_TREE_DRIFT' }
        @{ Name = "compare object assertion"; Pattern = 'Compare-Object[\s\S]*\$statusBeforeValidation[\s\S]*\$statusAfterValidation' }
    )

    It "exists and parses without PowerShell syntax errors" {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:validationScriptPath, [ref]$tokens, [ref]$parseErrors)

        $ast | Should -Not -BeNullOrEmpty
        @($parseErrors).Count | Should -Be 0
    }

    It "runs required validation command: <Name>" -ForEach $requiredValidationCommands {
        $script:validationScript | Should -Match $Pattern
    }

    It "runs explicit LLM index and harness checks" {
        $script:validationScript | Should -Match 'Update-LlmSkillsIndex\.ps1'
        $script:validationScript | Should -Match '-Check'
        $script:validationScript | Should -Match 'Test-LlmHarness\.ps1'
    }

    It "enforces workspace drift safeguard: <Name>" -ForEach $workspaceDriftSafetyMarkers {
        $script:validationScript | Should -Match $Pattern
    }

    It "supports CI watch mode and checks GitHub PR status" {
        $script:validationScript | Should -Match '\[switch\]\$WatchCi'
        $script:validationScript | Should -Match 'gh\s+pr\s+view'
        $script:validationScript | Should -Match 'gh\s+pr\s+checks\s+\$prNumber\s+--watch'
    }

    It "defines failure code for deterministic triage: <_>" -ForEach $requiredFailureCodes {
        $escapedCode = [Regex]::Escape($PSItem)
        $script:validationScript | Should -Match $escapedCode
    }
}

Describe "Pre-push enforcement integration" {
    It "uses Invoke-FullValidation.ps1 from pre-push when pwsh is available" {
        $script:prePushHook | Should -Match 'Invoke-FullValidation\.ps1'
    }
}
