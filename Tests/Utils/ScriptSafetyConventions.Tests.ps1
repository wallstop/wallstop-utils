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
    $script:crossLanguageWorkflowPath = Join-Path -Path $script:repoRoot -ChildPath ".github/workflows/script-quality.yml"
    $script:preCommitConfigPath = Join-Path -Path $script:repoRoot -ChildPath ".pre-commit-config.yaml"
    $script:preCommitHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-commit"
    $script:prePushHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-push"
    $script:qualityPowerShellScripts = @(
        "Scripts/Utils/Quality/Assert-CleanGitTree.ps1",
        "Scripts/Utils/Quality/Format-PowerShellFiles.ps1",
        "Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1"
    )
    $script:qualityConfigFiles = @(
        ".pre-commit-config.yaml",
        ".editorconfig",
        ".shellcheckrc",
        ".stylua.toml"
    )
    $script:shellConventionScripts = @(
        "Scripts/Mac/Backup.sh",
        "Scripts/Mac/backup_brew.sh",
        "Scripts/Mac/restore_brew.sh",
        "Scripts/PaperWM/PaperWMRestore.sh",
        "Scripts/Utils/increment-version.sh",
        "Scripts/Utils/Quality/Invoke-MacOSLanguageChecks.sh"
    )
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

        $workflow | Should -Match 'Scripts/\*\*'
        $workflow | Should -Match 'Tests/\*\*'
    }

    It "runs ScriptAnalyzer against all scripts" {
        $workflow = Get-Content -Path $script:workflowPath -Raw
        $workflow | Should -Match 'Invoke-ScriptAnalyzer\s+-Path\s+"Scripts"'
    }
}

Describe "Cross-language quality platform conventions" {
    It "defines a pinned pre-commit configuration with required hook coverage" {
        $preCommitConfig = Get-Content -Path $script:preCommitConfigPath -Raw

        $preCommitConfig | Should -Match 'repo:\s+https://github\.com/pre-commit/pre-commit-hooks'
        $preCommitConfig | Should -Match 'repo:\s+https://github\.com/scop/pre-commit-shfmt'
        $preCommitConfig | Should -Match 'repo:\s+https://github\.com/shellcheck-py/shellcheck-py'
        $preCommitConfig | Should -Match 'repo:\s+https://github\.com/JohnnyMorganz/StyLua'
        $preCommitConfig | Should -Match 'repo:\s+https://github\.com/rhysd/actionlint'
        $preCommitConfig | Should -Match 'rev:\s+v\d+\.\d+\.\d+'

        $preCommitConfig | Should -Match 'id:\s+check-json'
        $preCommitConfig | Should -Match 'id:\s+check-yaml'
        $preCommitConfig | Should -Match 'id:\s+pretty-format-json'
        $preCommitConfig | Should -Match 'id:\s+powershell-format'
        $preCommitConfig | Should -Match 'id:\s+shellcheck'
        $preCommitConfig | Should -Match 'id:\s+shfmt'
        $preCommitConfig | Should -Match 'id:\s+stylua'
        $preCommitConfig | Should -Match 'id:\s+actionlint'

        $preCommitConfig | Should -Match 'id:\s+powershell-format[\s\S]*stages:\s+\[pre-commit\]'
        $preCommitConfig | Should -Match 'id:\s+powershell-precommit-validation'
        $preCommitConfig | Should -Match 'id:\s+powershell-prepush-validation'
        $preCommitConfig | Should -Match 'stages:\s+\[pre-push\]'
    }

    It "scopes deterministic JSON formatting away from snapshot dumps" {
        $preCommitConfig = Get-Content -Path $script:preCommitConfigPath -Raw

        $preCommitConfig | Should -Match 'pretty-format-json[\s\S]*files:\s+''\^\(Config/Komorebi/'
        $preCommitConfig | Should -Not -Match 'pretty-format-json[\s\S]*files:\s+''\^Config/PowerToys/'
        $preCommitConfig | Should -Match 'exclude:\s+''\^Config/\(PowerToys/\|\\\.config/\)'''
    }

    It "keeps mixed-line-ending hook aligned with Windows command-script policy" {
        $preCommitConfig = Get-Content -Path $script:preCommitConfigPath -Raw

        $preCommitConfig | Should -Match 'id:\s+mixed-line-ending'
        $preCommitConfig | Should -Match 'id:\s+mixed-line-ending[\s\S]*args:\s+\[--fix=lf\]'
        $preCommitConfig | Should -Match 'id:\s+mixed-line-ending[\s\S]*exclude:\s+''[^'']*\(bat\|cmd\)[^'']*'''
    }

    It "keeps LLM skills index sorting culture-invariant" {
        $indexUpdaterPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1'
        $indexUpdater = Get-Content -Path $indexUpdaterPath -Raw

        $indexUpdater | Should -Match '\$script:InvariantCulture\s*=\s*\[System\.Globalization\.CultureInfo\]::InvariantCulture'
        $indexUpdater | Should -Match 'Sort-Object\s+-Unique\s+-Culture\s+\$script:InvariantCulture'
        $indexUpdater | Should -Match 'Sort-Object\s+Name,\s*RelativePath\s+-Culture\s+\$script:InvariantCulture'
        $indexUpdater | Should -Match 'Sort-Object\s+FullName\s+-Culture\s+\$script:InvariantCulture'
    }

    It "excludes encrypted snapshot directories from check-json validation" {
        $preCommitConfig = Get-Content -Path $script:preCommitConfigPath -Raw

        $preCommitConfig | Should -Match 'id:\s+check-json[\s\S]*exclude:\s+''\^Config/\(PowerToys/\|\\\.config/\)'''
    }

    It "keeps git hooks pre-commit-first with fallback guidance" {
        $preCommitHook = Get-Content -Path $script:preCommitHookPath -Raw
        $prePushHook = Get-Content -Path $script:prePushHookPath -Raw

        $preCommitHook | Should -Match 'pre-commit run --hook-stage pre-commit'
        $preCommitHook | Should -Match 'Run-PreCommitValidation\.ps1'
        $preCommitHook | Should -Match 'python3 -m pip install --user pre-commit'

        $prePushHook | Should -Match 'pre-commit run --hook-stage pre-push --all-files'
        $prePushHook | Should -Match 'Run-PreCommitValidation\.ps1" -All'
        $prePushHook | Should -Match 'python3 -m pip install --user pre-commit'
    }

    It "explicitly propagates pwsh fallback exit status in git hooks" {
        $preCommitHook = Get-Content -Path $script:preCommitHookPath -Raw
        $prePushHook = Get-Content -Path $script:prePushHookPath -Raw

        $preCommitHook | Should -Match 'pwsh -NoLogo -NoProfile -File "Scripts/Utils/Run-PreCommitValidation\.ps1"\s*\r?\n\s*return\s+\$\?'
        $prePushHook | Should -Match 'pwsh -NoLogo -NoProfile -File "Scripts/Utils/Run-PreCommitValidation\.ps1" -All\s*\r?\n\s*return\s+\$\?'
        $preCommitHook | Should -Match 'run_legacy_validation\s*\r?\n\s*exit\s+\$\?'
        $prePushHook | Should -Match 'run_legacy_validation\s*\r?\n\s*exit\s+\$\?'
    }

    It "tracks pre-push hook executable mode in git" {
        $git = Get-Command -Name git -ErrorAction SilentlyContinue
        if ($null -eq $git) {
            Set-ItResult -Skipped -Because "git is unavailable on this runner"
            return
        }

        $lsFilesOutput = @(& $git.Source -C $script:repoRoot ls-files --stage -- .githooks/pre-push 2>$null)
        if ($lsFilesOutput.Count -eq 0) {
            Set-ItResult -Skipped -Because ".githooks/pre-push is not tracked in git in this working tree; add/stage it before validating tracked mode"
            return
        }

        $mode = ($lsFilesOutput[0] -split '\s+')[0]
        $mode | Should -Be '100755'
    }

    It "defines a multi-OS CI workflow with full-repo checks and dirty-tree assertions" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw

        $workflow | Should -Match 'runs-on:\s+ubuntu-latest'
        $workflow | Should -Match 'runs-on:\s+windows-latest'
        $workflow | Should -Match 'runs-on:\s+macos-latest'

        $workflow | Should -Match 'SKIP=shellcheck,shfmt pre-commit run --all-files'
        $workflow | Should -Match 'Run shell hooks on changed files'
        $workflow | Should -Match 'Invoke-WindowsLanguageChecks\.ps1'
        $workflow | Should -Match 'Invoke-MacOSLanguageChecks\.sh'
        $workflow | Should -Match 'Assert-CleanGitTree\.ps1'

        $workflow | Should -Match 'uses:\s+actions/checkout@v\d+\.\d+\.\d+'
        $workflow | Should -Match 'uses:\s+actions/setup-python@v\d+\.\d+\.\d+'
        $workflow | Should -Match 'uses:\s+actions/cache@v\d+\.\d+\.\d+'
        $workflow | Should -Match 'shell-debt-audit'
        $workflow | Should -Match 'run_shell_debt_audit'
    }

    It "keeps fast and deep Windows CI lanes with runtime guardrails" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw

        $workflow | Should -Match 'windows-language:\s*\r?\n\s+name:\s+Windows language validation \(PR fast lane\)'
        $workflow | Should -Match 'windows-language:[\s\S]*timeout-minutes:\s+6'
        $workflow | Should -Match 'windows-language:[\s\S]*Detect changed Windows language targets'
        $workflow | Should -Match 'windows-language:[\s\S]*E_CI_TIME_BUDGET'
        $workflow | Should -Not -Match 'windows-language:[\s\S]*choco\s+install'

        $workflow | Should -Match 'windows-language-nightly:'
        $workflow | Should -Match 'windows-language-nightly:[\s\S]*timeout-minutes:\s+15'
        $workflow | Should -Match 'run_windows_deep_audit'
        $workflow | Should -Match 'schedule:\s*\r?\n\s+-\s+cron:'
    }

    It "keeps AutoHotkey CI runtime cache outside repository tree" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw

        $workflow | Should -Match 'path:\s+\$\{\{\s*runner\.temp\s*\}\}/autohotkey-portable-\$\{\{\s*env\.AHK_RUNTIME_VERSION\s*\}\}'
        $workflow | Should -Match 'Join-Path\s+-Path\s+\$env:RUNNER_TEMP\s+-ChildPath\s+"autohotkey-portable-\$version"'
        $workflow | Should -Not -Match 'path:\s+\.tools/autohotkey'
        $workflow | Should -Not -Match 'Join-Path\s+-Path\s+\$PWD\s+-ChildPath\s+"\.tools/autohotkey"'
    }

    It "keeps Node24-ready pinned action versions in quality workflows" {
        $crossLanguageWorkflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw
        $powerShellWorkflow = Get-Content -Path $script:workflowPath -Raw

        $crossLanguageWorkflow | Should -Match 'uses:\s+actions/checkout@v6\.\d+\.\d+'
        $crossLanguageWorkflow | Should -Match 'uses:\s+actions/setup-python@v6\.\d+\.\d+'
        $crossLanguageWorkflow | Should -Match 'uses:\s+actions/cache@v5\.\d+\.\d+'
        $powerShellWorkflow | Should -Match 'uses:\s+actions/checkout@v6\.\d+\.\d+'
    }

    It "keeps targeted Windows helper script contract for changed-file validation" {
        $windowsChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1'
        $windowsChecks = Get-Content -Path $windowsChecksPath -Raw

        $windowsChecks | Should -Match '\[string\]\$TargetFiles'
        $windowsChecks | Should -Match '\[switch\]\$RequireAutoHotkey'
        $windowsChecks | Should -Match 'Resolve-RequestedTargetFilePaths'
        $windowsChecks | Should -Match 'Invoke-AutoHotkeyValidationCommand'
        $windowsChecks | Should -Match '/iLib'
        $windowsChecks | Should -Match 'running in targeted mode'
        $windowsChecks | Should -Match 'E_AHK_UNAVAILABLE'
        $windowsChecks | Should -Match 'E_AHK_VALIDATE_UNAVAILABLE'
        $windowsChecks | Should -Match '\[switch\]\$NoInvokeMain'
        $windowsChecks | Should -Match 'if\s*\(-not\s+\$NoInvokeMain\)\s*\{\s*Invoke-Main'
    }

    It "keeps AHK v1 syntax detection and empty-output ambiguity handling in validator" {
        $windowsChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1'
        $windowsChecks = Get-Content -Path $windowsChecksPath -Raw

        # v1 syntax detection function must exist
        $windowsChecks | Should -Match 'function\s+Test-IsAutoHotkeyV1Script'
        $windowsChecks | Should -Match 'E_AHK_V1_SYNTAX_DETECTED'
        # Validator must guard against treating empty-output ambiguous exit codes as definitive failures
        $windowsChecks | Should -Match '\$hasActualOutput'
        # Detection must be wired into the per-file loop
        $windowsChecks | Should -Match 'Test-IsAutoHotkeyV1Script\s+-Content'
    }

    It "keeps data-driven unit coverage for AutoHotkey capability probing" {
        $windowsChecksTestsPath = Join-Path -Path $script:repoRoot -ChildPath 'Tests/Utils/Invoke-WindowsLanguageChecks.Tests.ps1'
        $windowsChecksTests = Get-Content -Path $windowsChecksTestsPath -Raw

        $windowsChecksTests | Should -Match 'Invoke-AutoHotkeyValidationCommand'
        $windowsChecksTests | Should -Match '-TestCases'
        $windowsChecksTests | Should -Match 'validate unsupported then iLib succeeds'
        $windowsChecksTests | Should -Match 'Test-BatchScriptsStaticSmoke'
        $windowsChecksTests | Should -Match 'single-line batch files correctly'
        # Anti-regression: exit=-1 with no output must be covered specifically
        $windowsChecksTests | Should -Match 'exit=-1.*no output|no output.*exit=-1'
        # v1 detection tests must be present
        $windowsChecksTests | Should -Match 'Test-IsAutoHotkeyV1Script'
        $windowsChecksTests | Should -Match '#NoEnv directive'
        # Policy test for all repo AHK scripts requiring v2 must be present
        $windowsChecksTests | Should -Match '#Requires AutoHotkey v2'
    }

    It "keeps cross-platform Invoke-AutoHotkeyCommand tests deterministic" {
        $windowsChecksTestsPath = Join-Path -Path $script:repoRoot -ChildPath 'Tests/Utils/Invoke-WindowsLanguageChecks.Tests.ps1'
        $windowsChecksTests = Get-Content -Path $windowsChecksTestsPath -Raw

        $windowsChecksTests | Should -Match 'captures exit code and output deterministically'
        $windowsChecksTests | Should -Match 'LinuxExecutable\s*='
        $windowsChecksTests | Should -Match 'WindowsExecutable\s*='
    }

    It "uses Start-Process output redirection in Invoke-AutoHotkeyCommand and avoids LASTEXITCODE dependency" {
        $windowsChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1'
        $windowsChecks = Get-Content -Path $windowsChecksPath -Raw

        $windowsChecks | Should -Match 'Start-Process\s+@startParams|Start-Process\s+-FilePath'
        $windowsChecks | Should -Match 'RedirectStandardOutput'
        $windowsChecks | Should -Match 'RedirectStandardError'
        $windowsChecks | Should -Match 'E_AHK_PROCESS_EXECUTION_FAILED'

        # Prevent regression: do not rely on raw LASTEXITCODE assignment in this helper.
        $windowsChecks | Should -Not -Match '(?m)^\s*\$exitCode\s*=\s*\$LASTEXITCODE\b'
    }

    It "all repository AHK scripts declare #Requires AutoHotkey v2" {
        $ahkFiles = @(
            Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/AutoHotKey') -Filter '*.ahk' -File -Recurse -ErrorAction SilentlyContinue
        )
        $ahkFiles.Count | Should -BeGreaterThan 0 -Because 'at least one .ahk file must exist under Scripts/AutoHotKey'

        foreach ($file in $ahkFiles) {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
            $content | Should -Match '(?m)^\s*#Requires\s+AutoHotkey\s+v2' -Because "$($file.Name) must declare #Requires AutoHotkey v2.0 at the top"
        }
    }

    It "keeps AppleScript migration-safe validation behavior" {
        $macChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-MacOSLanguageChecks.sh'
        $macChecks = Get-Content -Path $macChecksPath -Raw

        $macChecks | Should -Match 'no text sources found; validating existing \.scpt artifacts as migration fallback'
        $macChecks | Should -Match '\*\.applescript'
        $macChecks | Should -Match '\*\.scpt'
        $macChecks | Should -Match 'osadecompile'
        $macChecks | Should -Match 'osacompile'
    }

    It "documents batch validation limitations in Windows checks" {
        $windowsChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1'
        $windowsChecks = Get-Content -Path $windowsChecksPath -Raw

        $windowsChecks | Should -Match 'Batch checks limitation'
        $windowsChecks | Should -Match 'best-effort static smoke checks'
        $windowsChecks | Should -Match 'unbalanced parentheses at end-of-file'
    }
}

Describe "Quality script executable guardrails" {
    It "parses quality PowerShell scripts without parser errors" {
        foreach ($relativePath in $script:qualityPowerShellScripts) {
            $fullPath = Join-Path -Path $script:repoRoot -ChildPath $relativePath
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$parseErrors)

            $ast | Should -Not -BeNullOrEmpty -Because ("Expected AST for {0}" -f $relativePath)
            @($parseErrors).Count | Should -Be 0 -Because (
                "Parser errors in {0}: {1}" -f $relativePath, ((@($parseErrors) | ForEach-Object { $_.Message }) -join '; ')
            )
        }
    }

    It "keeps Windows quality script parser-clean" {
        $windowsChecksPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1"
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($windowsChecksPath, [ref]$tokens, [ref]$parseErrors)

        @($parseErrors).Count | Should -Be 0 -Because (
            "Windows quality script must parse cleanly: {0}" -f ((@($parseErrors) | ForEach-Object { $_.Message }) -join '; ')
        )
    }

    It "keeps shell syntax-check invocation path and avoids bash nameref in macOS helper" {
        $preCommitConfig = Get-Content -Path $script:preCommitConfigPath -Raw
        $macChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-MacOSLanguageChecks.sh'
        $macChecks = Get-Content -Path $macChecksPath -Raw

        $preCommitConfig | Should -Match 'id:\s+shellcheck'
        $preCommitConfig | Should -Match 'id:\s+shfmt'
        $preCommitConfig | Should -Match 'files:\s+''\^\(Scripts/\.\*\\\.sh\|\\\.githooks/\(pre-commit\|pre-push\)\)\$'''
        $macChecks | Should -Not -Match '(?m)^\s*local\s+-n\b'
    }

    It "propagates compiled-source validation exit code in macOS helper fallback path" {
        $macChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-MacOSLanguageChecks.sh'
        $macChecks = Get-Content -Path $macChecksPath -Raw

        $macChecks | Should -Match 'validate_compiled_sources\s+"\$\{compiled_sources\[@\]\}"\s*\r?\n\s*exit\s+\$\?'
    }

    It "passes bash -n syntax check for macOS helper when bash is available" {
        $bash = Get-Command -Name bash -ErrorAction SilentlyContinue
        if ($null -eq $bash) {
            Set-ItResult -Skipped -Because "bash is unavailable on this runner"
            return
        }

        $macChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-MacOSLanguageChecks.sh'
        $output = @(& $bash.Source -n $macChecksPath 2>&1)

        $global:LASTEXITCODE | Should -Be 0 -Because (
            "bash -n failed for macOS helper: {0}" -f ($output -join '; ')
        )
    }
}

Describe "Quality config file conventions" {
    It "keeps .gitattributes enforcing LF line endings to prevent cross-platform regex failures" {
        $gitattributesPath = Join-Path -Path $script:repoRoot -ChildPath '.gitattributes'
        Test-Path -Path $gitattributesPath -PathType Leaf | Should -BeTrue -Because ".gitattributes must exist to enforce consistent line endings"

        # Normalize to LF so multiline regex anchors work on all platforms.
        $gitattributes = (Get-Content -Path $gitattributesPath -Raw) -replace "`r", ''
        $gitattributes | Should -Match '(?m)^\*\s+text=auto\s+eol=lf\s*$' -Because ".gitattributes must default all text files to LF"
        $gitattributes | Should -Match '(?m)^\*\.bat\s+text\s+eol=crlf\s*$' -Because ".gitattributes must keep .bat files as CRLF for cmd.exe"
        $gitattributes | Should -Match '(?m)^\*\.cmd\s+text\s+eol=crlf\s*$' -Because ".gitattributes must keep .cmd files as CRLF for cmd.exe"
    }

    It "keeps .tools ignored as an ephemeral cache safety net" {
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $gitignore = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath '.gitignore') -Raw) -replace "`r", ''
        $gitignore | Should -Match '(?m)^\.tools/$'
    }

    It "keeps quality config files ending with a trailing newline" {
        foreach ($relativePath in $script:qualityConfigFiles) {
            $fullPath = Join-Path -Path $script:repoRoot -ChildPath $relativePath
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)

            $bytes.Length | Should -BeGreaterThan 0 -Because ("{0} should not be empty" -f $relativePath)
            $bytes[$bytes.Length - 1] | Should -Be 10 -Because ("{0} must end with a newline (LF)" -f $relativePath)
        }
    }

    It "keeps git hook wrapper scripts ending with a trailing newline" {
        $hookPaths = @($script:preCommitHookPath, $script:prePushHookPath)

        foreach ($hookPath in $hookPaths) {
            $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $hookPath)
            $bytes = [System.IO.File]::ReadAllBytes($hookPath)

            $bytes.Length | Should -BeGreaterThan 0 -Because ("{0} should not be empty" -f $relativePath)
            $bytes[$bytes.Length - 1] | Should -Be 10 -Because ("{0} must end with a newline (LF)" -f $relativePath)
        }
    }
}

Describe "Shell quality conventions" {
    It "keeps strict shell error handling in critical shell scripts" {
        foreach ($relativePath in $script:shellConventionScripts) {
            $fullPath = Join-Path -Path $script:repoRoot -ChildPath $relativePath
            # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
            $content = (Get-Content -Path $fullPath -Raw) -replace "`r", ''

            $content | Should -Match '(?m)^\s*set\s+-euo\s+pipefail\s*$'
        }
    }

    It "keeps Home-directory glob loops quoted in Backup.sh" {
        $backupPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Mac/Backup.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $backupContent = (Get-Content -Path $backupPath -Raw) -replace "`r", ''

        $backupContent | Should -Match '(?m)^\s*for\s+file\s+in\s+"\$HOME"/\.\*;\s+do\s*$'
        $backupContent | Should -Match '(?m)^\s*for\s+file\s+in\s+"\$HOME"/\*\.\{scpt,applescript\};\s+do\s*$'
        $backupContent | Should -Match '(?m)^\s*for\s+file\s+in\s+"\$HOME"/\*\.sh;\s+do\s*$'
    }

    It "avoids parse-ls backup selection pattern in restore_brew" {
        $restorePath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Mac/restore_brew.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $restoreContent = (Get-Content -Path $restorePath -Raw) -replace "`r", ''

        $restoreContent | Should -Not -Match 'ls\s+-1\s+"\$BACKUP_DIR"/brewfile_backup\*\s+2>\s*/dev/null\s*\|\s*sort\s*\|\s*tail'
        $restoreContent | Should -Match "while IFS= read -r -d '' candidate; do"
    }

    It "keeps restore_brew input constrained to the backup directory" {
        $restorePath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Mac/restore_brew.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $restoreContent = (Get-Content -Path $restorePath -Raw) -replace "`r", ''

        $restoreContent | Should -Match 'BACKUP_DIR="\$\(cd "\$BACKUP_DIR" && pwd\)"'
        $restoreContent | Should -Match '(?m)^\s*case\s+"\$candidate_path_abs"\s+in\s*$'
        $restoreContent | Should -Match '"\$BACKUP_DIR"/\*\)'
        $restoreContent | Should -Match 'Backup file must be inside'
        $restoreContent | Should -Match '\[\[\s+-L\s+"\$candidate_path_abs"\s+\]\]'
        $restoreContent | Should -Match 'does not match expected pattern ''brewfile_backup\*'''
    }

    It "does not execute remote installers in restore_brew" {
        $restorePath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Mac/restore_brew.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $restoreContent = (Get-Content -Path $restorePath -Raw) -replace "`r", ''

        $restoreContent | Should -Not -Match 'curl\s+-fsSL\s+https://raw\.githubusercontent\.com/Homebrew/install/.+\|\s*(/bin/)?bash'
        $restoreContent | Should -Match 'Install Homebrew first, then rerun this script\.'
    }

    It "keeps lockfile add flow explicit in increment-version" {
        $incrementPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/increment-version.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $incrementContent = (Get-Content -Path $incrementPath -Raw) -replace "`r", ''

        $incrementContent | Should -Not -Match '\[\[\s+-f\s+"\$lock_path"\s+\]\]\s+&&\s+git\s+add\s+--\s+"\$lock_path"\s+\|\|\s+true'
        $incrementContent | Should -Match '(?m)^\s*if\s+\[\[\s+-f\s+"\$lock_path"\s+\]\];\s+then\s*$'
    }

    It "uses a lock directory in increment-version to avoid concurrent writes" {
        $incrementPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/increment-version.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $incrementContent = (Get-Content -Path $incrementPath -Raw) -replace "`r", ''

        $incrementContent | Should -Match 'function\s+acquire_lock_dir|acquire_lock_dir\s*\(\)'
        $incrementContent | Should -Match 'mkdir\s+"\$lock_dir"'
        $incrementContent | Should -Match 'trap\s+''release_lock_dir\s+"\$lock_dir"''\s+EXIT'
    }

    It "surfaces dconf backup warnings in PaperWM restore" {
        $paperwmPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/PaperWM/PaperWMRestore.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $paperwmContent = (Get-Content -Path $paperwmPath -Raw) -replace "`r", ''

        $paperwmContent | Should -Match 'Warning: Could not backup existing dconf settings:'
        $paperwmContent | Should -Match '(?m)^\s*if\s+CURRENT_SETTINGS=\$\(dconf dump "\$DCONF_PATH"'
    }

    It "documents shell suppression governance and avoids broad disable directives" {
        $shellcheckPath = Join-Path -Path $script:repoRoot -ChildPath '.shellcheckrc'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $shellcheckConfig = (Get-Content -Path $shellcheckPath -Raw) -replace "`r", ''

        $shellcheckConfig | Should -Match 'severity=style'
        $shellcheckConfig | Should -Match 'Suppression governance'
        $shellcheckConfig | Should -Not -Match '(?m)^\s*disable\s*=\s*all\s*$'
    }

    It "keeps shell governance and LLM remediation guidance documented" {
        $mainReadme = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'README.md') -Raw
        $qualityReadme = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/README.md') -Raw
        $contractPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/skill-details/shell-governance/llm-remediation-contract.md'
        $contractContent = Get-Content -Path $contractPath -Raw

        $mainReadme | Should -Match 'Shell suppression governance'
        $mainReadme | Should -Match '\.llm/skill-details/shell-governance/llm-remediation-contract\.md'
        $qualityReadme | Should -Match 'Shell suppression governance'
        $qualityReadme | Should -Match 'AI remediation workflow'
        $qualityReadme | Should -Match '\.llm/skill-details/shell-governance/llm-remediation-contract\.md'
        $contractContent | Should -Match 'Fix first'
        $contractContent | Should -Match 'Final verification checklist'
    }

    It "requires justification text when shellcheck disable directives are present" {
        $shellScriptsRoot = Join-Path -Path $script:repoRoot -ChildPath 'Scripts'
        $shellScripts = Get-ChildItem -Path $shellScriptsRoot -Filter '*.sh' -File -Recurse -ErrorAction Stop
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($scriptFile in $shellScripts) {
            $lines = Get-Content -Path $scriptFile.FullName
            for ($index = 0; $index -lt $lines.Count; $index++) {
                $line = $lines[$index]
                if ($line -notmatch '#\s*shellcheck\s+disable=') {
                    continue
                }

                $hasInlineReason = $line -match '#\s*shellcheck\s+disable=[^\r\n]*\s+#\s+Reason:'
                $hasNeighborReason = $false
                if ($index + 1 -lt $lines.Count -and $lines[$index + 1] -match '#\s*Reason:') {
                    $hasNeighborReason = $true
                }

                if (-not $hasInlineReason -and -not $hasNeighborReason) {
                    $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                    $violations.Add("${relativePath}:$($index + 1)") | Out-Null
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Shellcheck disable directives must include reason comments. Violations: {0}" -f ($violations -join ', ')
        )
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

    It "documents SC2016 suppressions for literal regex and PowerShell corpus samples" {
        $workflow = Get-Content -Path $script:workflowPath -Raw

        $workflow | Should -Match '# shellcheck disable=SC2016 # Reason: regex intentionally includes a literal end-of-line anchor'
        $workflow | Should -Match '# shellcheck disable=SC2016 # Reason: corpus samples are literal PowerShell snippets'
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

        $content | Should -Match 'Get-CommandWithOptionalModuleImport\s+-CommandName\s+"Invoke-Pester"'
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

Describe "GitHub output and clipboard conventions" {
    It "keeps Copy and Truncate parameters in the PR unresolved comments script" {
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $scriptPath -Raw

        $content | Should -Match '\[switch\]\$Truncate'
        $content | Should -Match '\[switch\]\$Copy'
        $content | Should -Match '\.PARAMETER\s+Truncate'
        $content | Should -Match '\.PARAMETER\s+Copy'
    }

    It "keeps truncation conditional instead of unconditional in record conversion" {
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $scriptPath -Raw

        $content | Should -Match 'function\s+Convert-ReviewThreadToOutputRecord[\s\S]*\[switch\]\$Truncate'
        $content | Should -Match 'function\s+Convert-ReviewThreadToOutputRecord[\s\S]*if\s*\(\$Truncate\.IsPresent\)'
        $content | Should -Match 'function\s+Convert-ReviewThreadToOutputRecord[\s\S]*Normalize-CommentText\s+-Text\s+\$top\.body\s+-MaxLength\s+500'
        $content | Should -Match 'function\s+Convert-ReviewThreadToOutputRecord[\s\S]*Normalize-CommentText\s+-Text\s+\$top\.body\s+-DisableTruncation'
    }

    It "keeps clipboard copy non-fatal and output additive" {
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $scriptPath -Raw

        $content | Should -Match 'function\s+Copy-ToClipboard[\s\S]*Write-Warning\s+"W_CLIPBOARD_UNAVAILABLE'
        $content | Should -Match 'function\s+Copy-ToClipboard[\s\S]*Write-Warning\s+"W_CLIPBOARD_COPY_FAILED'
        $content | Should -Match 'function\s+Invoke-Main[\s\S]*if\s*\(\$Copy\.IsPresent\)'
        $content | Should -Match 'function\s+Invoke-Main[\s\S]*Write-Output\s+\$output'
    }

    It "keeps regression coverage for stdout on copy failure" {
        $testsPath = Join-Path -Path $script:repoRoot -ChildPath "Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1"
        $testsContent = Get-Content -Path $testsPath -Raw

        $testsContent | Should -Match 'writes stdout output even when copy fails'
    }
}
