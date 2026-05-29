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
        @{ Name = "pre-commit stage all files"; Pattern = 'Invoke-PreCommitWithRecovery\.ps1[\s\S]*-HookStage\s+pre-commit\s+-AllFiles' }
        @{ Name = "pre-push stage all files"; Pattern = 'Invoke-PreCommitWithRecovery\.ps1[\s\S]*-HookStage\s+pre-push\s+-AllFiles' }
    )

    $requiredFailureCodes = @(
        "E_VALIDATION_PRECOMMIT_FAILED"
        "E_VALIDATION_PREPUSH_FAILED"
        "E_VALIDATION_CI_FAILED"
        "E_VALIDATION_PR_MISSING"
        "E_VALIDATION_PREREQ_MISSING"
        "E_VALIDATION_ARG_CONFLICT"
        "E_VALIDATION_POWERSHELL_MODULES_MISSING"
        "E_VALIDATION_MODULE_HELPER_MISSING"
        "E_VALIDATION_DIAGNOSTICS_HELPER_MISSING"
        "E_VALIDATION_NATIVE_TOOL_SCRIPT_MISSING"
        "E_VALIDATION_PRECOMMIT_RECOVERY_SCRIPT_MISSING"
        "E_VALIDATION_PRECOMMIT_ENV_PREFLIGHT_FAILED"
        "E_VALIDATION_STATUS_BEFORE_NULL"
        "E_VALIDATION_STATUS_AFTER_NULL"
    )

    $workspaceDriftSafetyMarkers = @(
        @{ Name = "snapshot helper"; Pattern = 'Get-StatusSnapshot' }
        @{ Name = "snapshot sorting"; Pattern = 'function\s+Get-StatusSnapshot\b[\s\S]*?Sort-Object' }
        @{ Name = "non-enumerating snapshot return"; Pattern = 'function\s+Get-StatusSnapshot\b[\s\S]*?Write-Output\s+-NoEnumerate\s+\(\s*\[string\[\]\]\s*\$sortedStatusLines\s*\)' }
        @{ Name = "status args contract"; Pattern = 'statusArgs\s*=\s*@\("-C",\s*\$RepositoryRoot,\s*"status",\s*"--porcelain=v1",\s*"--untracked-files=all"\)' }
        @{ Name = "status snapshot call passes repository root (before)"; Pattern = 'Get-StatusSnapshot\s+-gitExecutable\s+\$gitExecutable\s+-RepositoryRoot\s+\$repoRoot' }
        @{ Name = "status snapshot call passes repository root (after)"; Pattern = 'Get-StatusSnapshot\s+-gitExecutable\s+\$gitExecutable\s+-RepositoryRoot\s+\$repoRoot' }
        @{ Name = "status root fallback failure code"; Pattern = 'E_VALIDATION_GIT_NOT_REPOSITORY' }
        @{ Name = "status failure repository diagnostics"; Pattern = 'E_VALIDATION_GIT_STATUS_FAILED:[^\n]*repositoryRoot=' }
        @{ Name = "status failure working-directory diagnostics"; Pattern = 'E_VALIDATION_GIT_STATUS_FAILED:[^\n]*workingDirectory=' }
        @{ Name = "status failure output preview"; Pattern = 'E_VALIDATION_GIT_STATUS_FAILED:[^\n]*outputPreview=' }
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

    It "runs PowerShell quality module preflight before pre-commit execution" {
        $script:validationScript | Should -Match 'Common/ModuleHelpers\.ps1'
        $script:validationScript | Should -Match 'Assert-PowerShellQualityModuleAvailability'
        $script:validationScript | Should -Match 'PowerShell module prerequisite check'
        $script:validationScript | Should -Match 'Assert-ModuleCommandRequirements\s+-Requirements\s+\$moduleRequirements\s+-ErrorCode\s+"E_VALIDATION_POWERSHELL_MODULES_MISSING"'
        $script:validationScript | Should -Match 'Invoke-ScriptAnalyzer'
        $script:validationScript | Should -Match 'Invoke-Formatter'
        $script:validationScript | Should -Match 'Invoke-Pester'
    }

    It "preflights pinned native tools and pre-commit hook environments before validation" {
        $script:validationScript | Should -Match 'Assert-NativeQualityToolAvailability'
        $script:validationScript | Should -Match 'Invoke-NativeQualityChecks\.ps1'
        $script:validationScript | Should -Match 'native quality tool prerequisite check'
        $script:validationScript | Should -Match 'Assert-PreCommitHookEnvironmentAvailability'
        $script:validationScript | Should -Match 'Invoke-PreCommitWithRecovery\.ps1'
        $script:validationScript | Should -Match 'pre-commit hook environment preflight'
    }

    It "reuses shared diagnostics helper for output previews" {
        $script:validationScript | Should -Match 'Common/DiagnosticsHelpers\.ps1'
        $script:validationScript | Should -Not -Match 'function\s+Get-OutputPreview'
    }

    It "supports lightweight preflight-only mode" {
        $script:validationScript | Should -Match '\[switch\]\$PreflightOnly'
        $script:validationScript | Should -Match 'E_VALIDATION_ARG_CONFLICT'
        $script:validationScript | Should -Match 'Validation preflight passed\.'
        $script:validationScript | Should -Match 'if\s*\(\$PreflightOnly\s*-and\s*\$WatchCi\)'
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

    It "keeps pre-push wrapper execution bounded by timeout guardrails" {
        $script:prePushHook | Should -Match 'run_with_timeout'
        $script:prePushHook | Should -Match 'WALLSTOP_PREPUSH_TIMEOUT_SECONDS'
        $script:prePushHook | Should -Match 'E_HOOK_TIMEOUT'
    }
}
