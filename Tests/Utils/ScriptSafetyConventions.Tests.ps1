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

    It "uses generic API fallback instead of GraphQL fallback in REST retry path" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Not -Match 'throw\s+"E_GRAPHQL_ERROR:\s+\$errorText"'
        $content | Should -Match 'E_GITHUB_API_ERROR\(\$statusCode\): GitHub request failed'
    }

    It "threads RequestTimeoutSeconds through interactive pull request selection" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match 'function\s+Get-OpenPullRequests[\s\S]*?\[int\]\$RequestTimeoutSeconds'
        $content | Should -Match 'function\s+Select-PullRequestInteractively[\s\S]*?\[int\]\$RequestTimeoutSeconds'
        $content | Should -Match 'Get-OpenPullRequests[^\n]*-RequestTimeoutSeconds\s+\$RequestTimeoutSeconds'
        $content | Should -Match 'Select-PullRequestInteractively[^\n]*-RequestTimeoutSeconds\s+\$RequestTimeoutSeconds'
        $content | Should -Match 'Resolve-PullRequestTarget[^\n]*-RequestTimeoutSeconds\s+\$RequestTimeoutSeconds'
    }
}

Describe "Workflow security conventions" {
    It "uses precise token patterns to avoid redaction false positives" {
        $workflow = Get-Content -Path $script:workflowPath -Raw

        $workflow | Should -Match 'ghp_\[A-Za-z0-9\]\{36\}'
        $workflow | Should -Match 'github_pat_\[A-Za-z0-9_\]\{80,\}'
        $workflow | Should -Not -Match '\(ghp_\|github_pat_\|Authorization'
    }

    It "keeps redaction token patterns aligned with workflow scanner precision" {
        $workflow = Get-Content -Path $script:workflowPath -Raw
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $scriptContent = Get-Content -Path $scriptPath -Raw

        $workflow | Should -Match 'ghp_\[A-Za-z0-9\]\{36\}'
        $scriptContent | Should -Match 'ghp_\[A-Za-z0-9\]\{36\}'

        $workflow | Should -Match 'github_pat_\[A-Za-z0-9_\]\{80,\}'
        $scriptContent | Should -Match 'github_pat_\[A-Za-z0-9_\]\{80,\}'
    }

    It "scans both bearer and token authorization header schemes" {
        $workflow = Get-Content -Path $script:workflowPath -Raw

        $workflow | Should -Match '\(Bearer\|token\)'
    }

    It "keeps scanner and script authorization redaction schemes aligned" {
        $workflow = Get-Content -Path $script:workflowPath -Raw
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $scriptContent = Get-Content -Path $scriptPath -Raw
        $redactionPatternLiteral = '(Bearer|token)\s+[A-Za-z0-9_\-\.]{20,}'

        $workflow | Should -Match '\(Bearer\|token\)'
        $scriptContent | Should -Match ([regex]::Escape($redactionPatternLiteral))
    }

    It "prints scanner diagnostics and validates behavior corpus" {
        $workflow = Get-Content -Path $script:workflowPath -Raw

        $workflow | Should -Match 'scanner_engine='
        $workflow | Should -Match 'active_pattern='
        $workflow | Should -Match 'match_count='
        $workflow | Should -Match 'should_detect='
        $workflow | Should -Match 'should_ignore='
        $workflow | Should -Match 'Scanner corpus failure'
    }

    It "uses equivalent iex boundary patterns in rg and grep paths" {
        $workflow = Get-Content -Path $script:workflowPath -Raw

        $workflow | Should -Match "dangerous_pattern_rg='Invoke-Expression\|\(\^\|\[\^\[:alnum:\]_\]\)iex\(\[\^\[:alnum:\]_\]\|\$\)'"
        $workflow | Should -Match "dangerous_pattern_grep='Invoke-Expression\|\(\^\|\[\^\[:alnum:\]_\]\)iex\(\[\^\[:alnum:\]_\]\|\$\)'"
    }

    It "guards against tracking generated coverage artifacts" {
        $workflow = Get-Content -Path $script:workflowPath -Raw

        $workflow | Should -Match 'Generated artifact tracking checks'
        $workflow | Should -Match 'git ls-files coverage.xml out.txt'
    }
}

Describe "JSON parsing conventions" {
    It "keeps strict ConvertFrom-JsonSingleObject edge-case coverage" {
        $testsPath = Join-Path -Path $script:repoRoot -ChildPath "Tests/Utils/StrictModeHelpers.Tests.ps1"
        $testsContent = Get-Content -Path $testsPath -Raw

        $testsContent | Should -Match 'throws for single-item JSON arrays'
        $testsContent | Should -Match 'throws for string scalar JSON'
        $testsContent | Should -Match 'throws for numeric scalar JSON'
        $testsContent | Should -Match 'throws for null literal'
    }

    It "avoids direct ConvertFrom-Json in utility scripts unless explicitly justified" {
        $utilsRoot = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils"
        $utilsScripts = Get-ChildItem -Path $utilsRoot -Filter "*.ps1" -File -Recurse
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($scriptFile in $utilsScripts) {
            if ($scriptFile.FullName -eq (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/StrictModeHelpers.ps1")) {
                continue
            }

            $content = Get-Content -Path $scriptFile.FullName -Raw
            if ($content -match '(?m)^\s*#\s*direct-json-ok:\s*ConvertFrom-Json\b') {
                continue
            }

            if ($content -match '(?m)^[^#\r\n]*\bConvertFrom-Json\b(?!-)') {
                $relative = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                $violations.Add($relative) | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because ("Use ConvertFrom-JsonSingleObject for utility scripts. Violations: {0}" -f ($violations -join ', '))
    }
}

Describe "GitHub fixture hygiene" {
    It "does not keep orphan JSON fixtures in Tests/GitHub/Fixtures" {
        $fixturesPath = Join-Path -Path $script:repoRoot -ChildPath "Tests/GitHub/Fixtures"
        if (-not (Test-Path -Path $fixturesPath -PathType Container)) {
            return
        }

        $fixtures = Get-ChildItem -Path $fixturesPath -Filter "*.json" -File -ErrorAction SilentlyContinue
        @($fixtures).Count | Should -Be 0
    }
}
