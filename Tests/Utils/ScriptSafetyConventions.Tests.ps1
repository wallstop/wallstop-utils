Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:migratedScripts = @(
        "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1",
        "Scripts/Utils/BackupDxMessaging.ps1",
        "Scripts/Utils/FormatPowershellScripts.ps1",
        "Scripts/Utils/PandocConvertDirectory.ps1",
        "Scripts/Utils/Increment-Version.ps1"
    )
    $script:workflowPath = Join-Path -Path $script:repoRoot -ChildPath ".github/workflows/github-pr-summarizer-quality.yml"
}

Describe "Shared helper migration" {
    It "loads StrictModeHelpers in each migrated script" {
        foreach ($scriptPath in $script:migratedScripts) {
            $fullPath = Join-Path -Path $script:repoRoot -ChildPath $scriptPath
            $content = Get-Content -Path $fullPath -Raw
            $content | Should -Match "StrictModeHelpers\.ps1"
        }
    }

    It "avoids Measure-Object count pattern in migrated scripts" {
        foreach ($scriptPath in $script:migratedScripts) {
            $fullPath = Join-Path -Path $script:repoRoot -ChildPath $scriptPath
            $content = Get-Content -Path $fullPath -Raw
            $content | Should -Not -Match "\|\s*Measure-Object\)\.Count"
        }
    }

    It "avoids case-insensitive headers variable collision in retry function" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Not -Match '\$headers\s*=\s*Get-ResponseHeaders'
        $content | Should -Match '\$responseHeaders\s*=\s*Get-ResponseHeaders'
    }
}

Describe "CI scope expansion" {
    It "triggers workflow on all script and test changes" {
        $workflow = Get-Content -Path $script:workflowPath -Raw

        $workflow | Should -Match "'Scripts/\*\*'"
        $workflow | Should -Match "'Tests/\*\*'"
    }

    It "runs ScriptAnalyzer against all scripts" {
        $workflow = Get-Content -Path $script:workflowPath -Raw
        $workflow | Should -Match 'Invoke-ScriptAnalyzer\s+-Path\s+"Scripts"'
    }
}

Describe "GitHub API resilience conventions" {
    It "keeps 403 in retryable status conditions" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match '\$statusCode\s+-eq\s+429\s+-or\s+\$statusCode\s+-eq\s+403\s+-or\s+\$statusCode\s+-ge\s+500'
    }

    It "supports Retry-After fallback for rate-limit waits" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match 'Get-HeaderValue\s+-Headers\s+\$responseHeaders\s+-Key\s+"Retry-After"'
    }

    It "uses fail-fast auth rate-limit classification" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match 'E_AUTH_RATE_LIMITED'
    }
}
