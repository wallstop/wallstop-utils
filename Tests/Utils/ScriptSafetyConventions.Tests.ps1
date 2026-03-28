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

Describe "Scope safety conventions" {
    It "does not reference function parameters from script scope" {
        $scriptsRoot = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        $scripts = Get-ChildItem -Path $scriptsRoot -Filter "*.ps1" -File -Recurse -ErrorAction Stop
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($scriptFile in $scripts) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($null -eq $ast) {
                continue
            }

            $functions = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                    }, $true))
            if ($functions.Count -eq 0) {
                continue
            }

            $topLevelParamNames = @()
            if ($null -ne $ast.ParamBlock) {
                foreach ($topParam in $ast.ParamBlock.Parameters) {
                    $topLevelParamNames += $topParam.Name.VariablePath.UserPath
                }
            }

            $scriptAssignedNames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
            $scriptAssignments = @($ast.FindAll({
                        param($node)
                        if (-not ($node -is [System.Management.Automation.Language.AssignmentStatementAst])) {
                            return $false
                        }

                        if (-not ($node.Left -is [System.Management.Automation.Language.VariableExpressionAst])) {
                            return $false
                        }

                        $isInsideFunction = @($functions | Where-Object {
                                $node.Extent.StartOffset -ge $_.Extent.StartOffset -and $node.Extent.EndOffset -le $_.Extent.EndOffset
                            }).Count -gt 0

                        return -not $isInsideFunction
                    }, $true))
            foreach ($assignment in $scriptAssignments) {
                $name = $assignment.Left.VariablePath.UserPath
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    [void]$scriptAssignedNames.Add($name)
                }
            }

            $scriptScopeVariables = @($ast.FindAll({
                        param($node)
                        if (-not ($node -is [System.Management.Automation.Language.VariableExpressionAst])) {
                            return $false
                        }

                        if (-not $node.VariablePath.IsUnscopedVariable) {
                            return $false
                        }

                        $isInsideFunction = @($functions | Where-Object {
                                $node.Extent.StartOffset -ge $_.Extent.StartOffset -and $node.Extent.EndOffset -le $_.Extent.EndOffset
                            }).Count -gt 0

                        return -not $isInsideFunction
                    }, $true))

            if ($scriptScopeVariables.Count -eq 0) {
                continue
            }

            foreach ($function in $functions) {
                $paramNames = @()
                if ($null -ne $function.Body -and $null -ne $function.Body.ParamBlock) {
                    foreach ($param in $function.Body.ParamBlock.Parameters) {
                        $paramName = $param.Name.VariablePath.UserPath
                        if ($topLevelParamNames -contains $paramName) {
                            continue
                        }

                        if ($scriptAssignedNames.Contains($paramName)) {
                            continue
                        }

                        $paramNames += $paramName
                    }
                }

                if ($paramNames.Count -eq 0) {
                    continue
                }

                foreach ($scriptVariable in $scriptScopeVariables) {
                    $variableName = $scriptVariable.VariablePath.UserPath
                    if ($paramNames -contains $variableName) {
                        $relative = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                        $violations.Add("${relative}:$($scriptVariable.Extent.StartLineNumber) variable '$variableName' from function '$($function.Name)' referenced at script scope") | Out-Null
                    }
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Function parameters must not leak into script scope. Violations: {0}" -f ($violations -join ", ")
        )
    }

    It "uses centralized GitHub owner/repo and host validation helpers across entry points" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match 'function\s+Assert-GitHubHostFormat'
        $content | Should -Match 'function\s+Assert-GitHubOwnerRepoFormat'
        $content | Should -Match 'function\s+Assert-GitHubRequestUri'
        $content | Should -Match 'function\s+Assert-GitHubHostInAllowlist'

        $content | Should -Match 'function\s+Parse-GitHubPullRequestUrl[\s\S]*Assert-GitHubHostFormat'
        $content | Should -Match 'function\s+Parse-GitHubPullRequestUrl[\s\S]*Assert-GitHubOwnerRepoFormat'
        $content | Should -Match 'function\s+Select-PullRequestInteractively[\s\S]*Assert-GitHubOwnerRepoFormat'
        $content | Should -Match 'function\s+Resolve-PullRequestTarget[\s\S]*Assert-GitHubHostFormat'
        $content | Should -Match 'function\s+Resolve-PullRequestTarget[\s\S]*Assert-GitHubOwnerRepoFormat'
        $content | Should -Match 'function\s+Resolve-PullRequestTarget[\s\S]*GitHubHostProvided'
        $content | Should -Match 'function\s+Resolve-PullRequestTarget[\s\S]*Assert-GitHubHostInAllowlist'
        $content | Should -Match 'function\s+Invoke-GitHubRequestWithRetry[\s\S]*Assert-GitHubRequestUri'
        $content | Should -Match 'function\s+Validate-GitHubTokenForRepoAccess[\s\S]*Assert-GitHubRequestUri'

        $content | Should -Not -Match '\^\[A-Za-z0-9\]\[A-Za-z0-9_-\]\{0,37\}\$'
    }

    It "keeps comprehensive non-global IP host blocking for GitHub targets" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match 'Test-GitHubIPAddressAllowed'
        $content | Should -Match '\$octet0\s*-eq\s*10'
        $content | Should -Match '\$octet0\s*-eq\s*169\s*-and\s*\$octet1\s*-eq\s*254'
        $content | Should -Match '\$octet0\s*-ge\s*224'
        $content | Should -Match 'IsIPv6LinkLocal'
        $content | Should -Match 'IsIPv6Multicast'
        $content | Should -Match '\(\$bytes\[0\]\s*-band\s*0xFE\)\s*-eq\s*0xFC'
    }

    It "keeps outbound HTTP calls behind URI safety assertions" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$parseErrors)

        $functions = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true))

        $violations = New-Object System.Collections.Generic.List[string]
        $allowedDirectHttpFunctions = @("Invoke-GitHubRequestWithRetry", "Validate-GitHubTokenForRepoAccess")

        foreach ($function in $functions) {
            $commandNames = @($function.Body.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $containsDirectHttpCall = ($commandNames -contains "Invoke-RestMethod") -or ($commandNames -contains "Invoke-WebRequest")
            if ($containsDirectHttpCall -and -not ($allowedDirectHttpFunctions -contains $function.Name)) {
                $violations.Add("$($function.Name) uses direct HTTP call") | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because ("Direct HTTP calls must stay in approved wrappers. Violations: {0}" -f ($violations -join ", "))

        $content = Get-Content -Path $fullPath -Raw
        $content | Should -Match 'function\s+Invoke-GitHubRequestWithRetry[\s\S]*Assert-GitHubRequestUri[\s\S]*Invoke-RestMethod'
        $content | Should -Match 'function\s+Validate-GitHubTokenForRepoAccess[\s\S]*Assert-GitHubRequestUri[\s\S]*Invoke-WebRequest'
    }

    It "threads allowlist enforcement through Invoke-Main auth retry branch" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match 'function\s+Invoke-Main[\s\S]*\$allowedGitHubHostsNormalized\s*=\s*Get-NormalizedGitHubHostAllowlist'
        $content | Should -Match 'function\s+Invoke-Main[\s\S]*Validate-GitHubTokenForRepoAccess[^\n]*-AllowedGitHubHostsNormalized\s+\$allowedGitHubHostsNormalized'
        $content | Should -Match 'function\s+Invoke-Main[\s\S]*Get-UnresolvedReviewThreads[^\n]*-AllowedGitHubHostsNormalized\s+\$allowedGitHubHostsNormalized'
    }

    It "keeps security regression tests for host mismatch and non-global host cases" {
        $testsPath = Join-Path -Path $script:repoRoot -ChildPath "Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1"
        $testsContent = Get-Content -Path $testsPath -Raw

        $testsContent | Should -Match '169\.254\.169\.254'
        $testsContent | Should -Match 'fe80::1'
        $testsContent | Should -Match 'does not match explicitly provided -GitHubHost'
        $testsContent | Should -Match 'allowed GitHub host list'
    }

    It "keeps Increment-Version direct-run invocation guard" {
        $incrementPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Increment-Version.ps1"
        $incrementContent = Get-Content -Path $incrementPath -Raw

        $incrementContent | Should -Match 'if\s*\(\$MyInvocation\.InvocationName\s*-ne\s*"\."\)\s*\{\s*Increment-Version\s+@args\s*\}'
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

        $content | Should -Match 'Get-SingleHeaderValueOrThrow\s+-Headers\s+\$responseHeaders\s+-Key\s+"Retry-After"'
    }

    It "uses strict single-value extraction for X-RateLimit-Reset in wait path" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match 'Get-SingleHeaderValueOrThrow\s+-Headers\s+\$responseHeaders\s+-Key\s+"X-RateLimit-Reset"'
    }

    It "uses a shared helper for 403 rate-limit header classification" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match 'function\s+Test-HasRateLimitHeaders'
        $content | Should -Match 'Invoke-GitHubRequestWithRetry[\s\S]*\$hasRateLimitHeaders\s*=\s*Test-HasRateLimitHeaders\s+-Headers\s+\$responseHeaders'
        $content | Should -Match 'Validate-GitHubTokenForRepoAccess[\s\S]*\$hasRateLimitHeaders\s*=\s*Test-HasRateLimitHeaders\s+-Headers\s+\$responseHeaders'
    }

    It "does not use X-RateLimit-Remaining as a standalone 403 rate-limit signal" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Not -Match 'Test-HasRateLimitHeaders[\s\S]*X-RateLimit-Remaining'
        $content | Should -Not -Match '\$hasRateLimitHeaders\s*=\s*\([^\n]*X-RateLimit-Remaining'
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
        $testsContent | Should -Match 'throws for null input and includes context'
        $testsContent | Should -Match 'throws for empty string input'
        $testsContent | Should -Match 'throws for whitespace input'
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

Describe "Utility configuration safety conventions" {
    It "guards Invoke-Pester usage in Run-PreCommitValidation" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $content = Get-Content -Path $preCommitPath -Raw

        $content | Should -Match 'Get-Command\s+-Name\s+Invoke-Pester'
        $content | Should -Match 'E_CONFIG_ERROR:\s+Invoke-Pester is not available'
    }

    It "avoids hardcoded user-home Import-Module paths in utility scripts" {
        $utilsRoot = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils"
        $utilsScripts = Get-ChildItem -Path $utilsRoot -Filter "*.ps1" -File -Recurse -ErrorAction Stop
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($scriptFile in $utilsScripts) {
            $content = Get-Content -Path $scriptFile.FullName -Raw
            if ($content -match '(?im)^\s*Import-Module\s+~[/\\]' -or $content -match '(?im)^\s*Import-Module\s+\$env:USERPROFILE[/\\]') {
                $relative = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                $violations.Add($relative) | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because ("Hardcoded user-home module imports break portability. Violations: {0}" -f ($violations -join ', '))
    }

    It "uses rich E_CONFIG_ERROR diagnostics for strict mode helper bootstrapping" {
        foreach ($scriptPath in $script:migratedScripts) {
            $fullPath = Join-Path -Path $script:repoRoot -ChildPath $scriptPath
            $content = Get-Content -Path $fullPath -Raw

            $content | Should -Match 'E_CONFIG_ERROR: Strict mode helper file not found at'
            $content | Should -Match '\$strictModeHelpersPath'
        }
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

Describe "PowerShell formatting conventions" {
    It "avoids standalone comma lines inside param blocks" {
        $searchRoots = @(
            (Join-Path -Path $script:repoRoot -ChildPath "Scripts"),
            (Join-Path -Path $script:repoRoot -ChildPath "Tests")
        )

        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($root in $searchRoots) {
            if (-not (Test-Path -Path $root -PathType Container)) {
                continue
            }

            $files = Get-ChildItem -Path $root -Filter "*.ps1" -File -Recurse -ErrorAction Stop
            foreach ($file in $files) {
                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
                if ($null -eq $ast) {
                    continue
                }

                $paramBlocks = @($ast.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.ParamBlockAst]
                        }, $true))
                if ($paramBlocks.Count -eq 0) {
                    continue
                }

                $lineContent = Get-Content -Path $file.FullName
                foreach ($token in @($tokens)) {
                    if ($token.Kind -ne [System.Management.Automation.Language.TokenKind]::Comma) {
                        continue
                    }

                    $lineNumber = $token.Extent.StartLineNumber
                    if ($lineNumber -lt 1 -or $lineNumber -gt $lineContent.Count) {
                        continue
                    }

                    if ($lineContent[$lineNumber - 1].Trim() -ne ",") {
                        continue
                    }

                    $nextNonEmptyLine = ""
                    for ($index = $lineNumber; $index -lt $lineContent.Count; $index++) {
                        $candidate = $lineContent[$index].Trim()
                        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                            $nextNonEmptyLine = $candidate
                            break
                        }
                    }

                    if (-not ($nextNonEmptyLine.StartsWith("[") -or $nextNonEmptyLine.StartsWith("$"))) {
                        continue
                    }

                    $isInsideParamBlock = $false
                    foreach ($paramBlock in $paramBlocks) {
                        if ($lineNumber -ge $paramBlock.Extent.StartLineNumber -and $lineNumber -le $paramBlock.Extent.EndLineNumber) {
                            $isInsideParamBlock = $true
                            break
                        }
                    }

                    if ($isInsideParamBlock) {
                        $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName)
                        $violations.Add("${relativePath}:$lineNumber") | Out-Null
                    }
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Standalone comma lines inside param blocks reduce readability and are easy to miss in review. Violations: {0}" -f ($violations -join ", ")
        )
    }
}

Describe "Retry test determinism conventions" {
    It "ensures Invoke-GitHubRequestWithRetry describe blocks define a default Start-Sleep mock" {
        $testRoot = Join-Path -Path $script:repoRoot -ChildPath "Tests"
        $testFiles = Get-ChildItem -Path $testRoot -Filter "*.Tests.ps1" -File -Recurse -ErrorAction Stop
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($file in $testFiles) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($null -eq $ast) {
                continue
            }

            $describeCommands = @($ast.FindAll({
                        param($node)
                        if (-not ($node -is [System.Management.Automation.Language.CommandAst])) {
                            return $false
                        }

                        if ($node.GetCommandName() -ne "Describe") {
                            return $false
                        }

                        $describeNameElement = $node.CommandElements | Select-Object -Skip 1 -First 1
                        if ($null -eq $describeNameElement) {
                            return $false
                        }

                        try {
                            return $describeNameElement.SafeGetValue() -eq "Invoke-GitHubRequestWithRetry"
                        } catch {
                            return $false
                        }
                    }, $true))

            foreach ($describe in $describeCommands) {
                $describeScriptBlockExpression = $describe.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
                } | Select-Object -First 1

                if ($null -eq $describeScriptBlockExpression) {
                    $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName)
                    $violations.Add("${relativePath}:$($describe.Extent.StartLineNumber):missing describe script block") | Out-Null
                    continue
                }

                $describeScriptBlock = $describeScriptBlockExpression.ScriptBlock
                $hasDefaultSleepMock = @($describeScriptBlock.FindAll({
                            param($innerNode)
                            if (-not ($innerNode -is [System.Management.Automation.Language.CommandAst])) {
                                return $false
                            }

                            if ($innerNode.GetCommandName() -ne "BeforeEach" -and $innerNode.GetCommandName() -ne "BeforeAll") {
                                return $false
                            }

                            $beforeEachScriptBlockExpression = $innerNode.CommandElements | Where-Object {
                                $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
                            } | Select-Object -First 1

                            if ($null -eq $beforeEachScriptBlockExpression) {
                                return $false
                            }

                            $beforeEachScriptBlock = $beforeEachScriptBlockExpression.ScriptBlock
                            return @($beforeEachScriptBlock.FindAll({
                                        param($mockNode)
                                        if (-not ($mockNode -is [System.Management.Automation.Language.CommandAst])) {
                                            return $false
                                        }

                                        if ($mockNode.GetCommandName() -ne "Mock") {
                                            return $false
                                        }

                                        if ($mockNode.CommandElements.Count -lt 2) {
                                            return $false
                                        }

                                        $targetElement = $mockNode.CommandElements[1]
                                        try {
                                            if ([string]$targetElement.SafeGetValue() -ne "Start-Sleep") {
                                                return $false
                                            }

                                            $mockScriptBlockExpression = $mockNode.CommandElements | Where-Object {
                                                $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
                                            } | Select-Object -First 1

                                            return $null -ne $mockScriptBlockExpression
                                        } catch {
                                            return $false
                                        }
                                    }, $true)).Count -gt 0
                        }, $true)).Count -gt 0

                if (-not $hasDefaultSleepMock) {
                    $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName)
                    $violations.Add("${relativePath}:$($describe.Extent.StartLineNumber)") | Out-Null
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Retry test suites must default-mock Start-Sleep in BeforeEach or BeforeAll to avoid real wall-clock delays. Violations: {0}" -f ($violations -join ", ")
        )
    }
}
