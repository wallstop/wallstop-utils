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
    It "exists and parses without PowerShell syntax errors" {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:validationScriptPath, [ref]$tokens, [ref]$parseErrors)

        $ast | Should -Not -BeNullOrEmpty
        @($parseErrors).Count | Should -Be 0
    }

    It "runs both pre-commit and pre-push stages across all files" {
        $script:validationScript | Should -Match 'pre-commit\s+run\s+--hook-stage\s+pre-commit\s+--all-files'
        $script:validationScript | Should -Match 'pre-commit\s+run\s+--hook-stage\s+pre-push\s+--all-files'
    }

    It "runs explicit LLM index and harness checks" {
        $script:validationScript | Should -Match 'Update-LlmSkillsIndex\.ps1'
        $script:validationScript | Should -Match '-Check'
        $script:validationScript | Should -Match 'Test-LlmHarness\.ps1'
    }

    It "checks workspace drift using before and after git status snapshots" {
        $script:validationScript | Should -Match 'Get-StatusSnapshot'
        $script:validationScript | Should -Match 'Compare-Object\s+-ReferenceObject\s+\$statusBeforeValidation\s+-DifferenceObject\s+\$statusAfterValidation'
        $script:validationScript | Should -Match 'E_VALIDATION_TREE_DRIFT'
    }

    It "supports CI watch mode and checks GitHub PR status" {
        $script:validationScript | Should -Match '\[switch\]\$WatchCi'
        $script:validationScript | Should -Match 'gh\s+pr\s+view'
        $script:validationScript | Should -Match 'gh\s+pr\s+checks\s+\$prNumber\s+--watch'
    }

    It "defines explicit failure code families for deterministic triage" {
        $script:validationScript | Should -Match 'E_VALIDATION_PRECOMMIT_FAILED'
        $script:validationScript | Should -Match 'E_VALIDATION_PREPUSH_FAILED'
        $script:validationScript | Should -Match 'E_VALIDATION_CI_FAILED'
        $script:validationScript | Should -Match 'E_VALIDATION_PR_MISSING'
        $script:validationScript | Should -Match 'E_VALIDATION_PREREQ_MISSING'
    }
}

Describe "Pre-push enforcement integration" {
    It "uses Invoke-FullValidation.ps1 from pre-push when pwsh is available" {
        $script:prePushHook | Should -Match 'Invoke-FullValidation\.ps1'
    }
}
