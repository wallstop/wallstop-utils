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
    $script:dependabotConfigPath = Join-Path -Path $script:repoRoot -ChildPath ".github/dependabot.yml"
    $script:llmContextPath = Join-Path -Path $script:repoRoot -ChildPath ".llm/context.md"
    $script:preCommitConfigPath = Join-Path -Path $script:repoRoot -ChildPath ".pre-commit-config.yaml"
    $script:preCommitHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-commit"
    $script:prePushHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-push"
    $script:qualityPowerShellScripts = @(
        "Scripts/Utils/Quality/Assert-CleanGitTree.ps1",
        "Scripts/Utils/Quality/Format-PowerShellFiles.ps1",
        "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1",
        "Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1"
    )
    $script:qualityConfigFiles = @(
        ".pre-commit-config.yaml",
        ".editorconfig",
        ".psscriptanalyzer.format.psd1",
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

    $wrapperHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/LlmWrapperContractHelpers.ps1"
    if (-not (Test-Path -Path $wrapperHelperPath -PathType Leaf)) {
        throw "E_CONFIG_ERROR: LLM wrapper helper file not found at '$wrapperHelperPath'."
    }

    . $wrapperHelperPath

    $script:wrapperContractFiles = @(
        Get-WrapperContractEntries -ContextFilePath $script:llmContextPath -DefaultFallback @()
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

    It "declares Set-StrictMode -Version Latest and ErrorActionPreference Stop in each migrated script" {
        foreach ($scriptPath in $script:migratedScripts) {
            $fullPath = Join-Path -Path $script:repoRoot -ChildPath $scriptPath
            $content = (Get-Content -Path $fullPath -Raw) -replace "`r", ''
            $content | Should -Match 'Set-StrictMode\s+-Version\s+Latest' -Because (
                "$scriptPath is a migrated utility script and must declare strict mode at script entry."
            )
            $content | Should -Match '\$ErrorActionPreference\s*=\s*"Stop"' -Because (
                "$scriptPath is a migrated utility script and must set ErrorActionPreference to Stop at script entry."
            )
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

    It "keeps clipboard strict-mode and output-file contracts for unresolved PR comments" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match '\[switch\]\$CopyStrict'
        $content | Should -Match '\[Alias\("OutFile"\)\]\s*\r?\n\s*\[string\]\$OutputPath'
        $content | Should -Match 'if\s*\(\$CopyStrict\.IsPresent\s*-and\s*-not\s*\$Copy\.IsPresent\)\s*\{\s*throw\s+"E_CONFIG_ERROR: -CopyStrict requires -Copy\."'
        $content | Should -Match 'if\s*\(\$Copy\.IsPresent\)\s*\{[\s\S]*E_CLIPBOARD_COPY_FAILED'
        $content | Should -Match 'function\s+Write-RenderedOutputToFile'
        $content | Should -Match 'Write-RenderedOutputToFile\s+-Text\s+\$output\s+-OutputPath\s+\$OutputPath'
        $content | Should -Match '\[System\.IO\.File\]::WriteAllText\(\$resolvedPath,\s*\$content,\s*\[System\.Text\.UTF8Encoding\]::new\(\$false\)\)'
    }

    It "checks LASTEXITCODE after native clipboard commands in Copy-ToClipboard" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        foreach ($tool in @("pbcopy", "xclip", "xsel", "wl-copy")) {
            $escapedTool = [regex]::Escape($tool)
            $content | Should -Match (
                "function\s+Copy-ToClipboard[\s\S]*""$escapedTool""\s*\{[\s\S]*?LASTEXITCODE\s+-ne\s+0[\s\S]*?continue[\s\S]*?return\s+\`$true"
            ) -Because "Copy-ToClipboard must check LASTEXITCODE after '$tool' to detect silent native command failures"
        }
    }

    It "keeps OSC52-first ordering in clipboard command priority" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $functionMatch = [regex]::Match($content, 'function\s+Get-ClipboardCommandPriority\s*\{(?<body>[\s\S]*?)^\}', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $functionMatch.Success | Should -BeTrue -Because "Get-ClipboardCommandPriority should exist so clipboard ordering contracts can be validated"
        $functionBody = $functionMatch.Groups["body"].Value

        $functionBody | Should -Match 'if\s*\(\$supportsOsc52\s*-and\s*\(Test-ShouldUseClipboardOsc52\)\)' -Because "OSC52 strategy must remain explicitly gated by capability and terminal-context checks"

        $osc52AddIndex = $functionBody.IndexOf('$commands.Add("Set-Clipboard-AsOSC52")', [System.StringComparison]::Ordinal)
        $setClipboardAddIndex = $functionBody.IndexOf('$commands.Add("Set-Clipboard")', [System.StringComparison]::Ordinal)
        $osc52AddIndex | Should -BeGreaterThan -1 -Because "Get-ClipboardCommandPriority must include Set-Clipboard-AsOSC52"
        $setClipboardAddIndex | Should -BeGreaterThan -1 -Because "Get-ClipboardCommandPriority must include Set-Clipboard"
        $osc52AddIndex | Should -BeLessThan $setClipboardAddIndex -Because "clipboard strategy order is a behavior contract: OSC52 attempt must run before plain Set-Clipboard"
    }

    It "uses PSBoundParameters for OutputPath gating in Invoke-Main" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match 'function\s+Invoke-Main[\s\S]*TopLevelBoundParameters\.ContainsKey\("OutputPath"\)'
        $content | Should -Not -Match 'function\s+Invoke-Main[\s\S]*IsNullOrWhiteSpace\(\$OutputPath\)[\s\S]*Write-RenderedOutputToFile'
    }

    It "keeps PowerShell argument-completion metadata for unresolved PR comments" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        $content | Should -Match '\[ArgumentCompletions\("github\.com"\)\]'
        $content | Should -Match '\[ArgumentCompletions\("text",\s*"json"\)\]'
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

    It "keeps robust Pester CI workflow wiring: <Name>" -TestCases @(
        @{
            Name    = "coverage step invokes shared gate script"
            Pattern = 'Run Pester with coverage[\s\S]*Invoke-PesterQualityGate\.ps1'
        }
        @{
            Name    = "coverage step passes coverage gate arguments"
            Pattern = 'Run Pester with coverage[\s\S]*-EnableCoverage[\s\S]*-CoveragePath\s+\$coveragePath[\s\S]*-MinimumCoveragePercent\s+75'
        }
        @{
            Name    = "coverage step uses explicit timeout"
            Pattern = 'Run Pester with coverage[\s\S]*timeout-minutes:\s+10'
        }
        @{
            Name    = "coverage step fails clearly when gate script is missing"
            Pattern = 'Run Pester with coverage[\s\S]*if\s*\(\s*-not\s*\(Test-Path\s+-Path\s+\$pesterGateScript\s+-PathType\s+Leaf\)\s*\)[\s\S]*E_CI_PESTER_GATE_SCRIPT_MISSING'
        }
        @{
            Name    = "utils step invokes shared gate script"
            Pattern = 'Run Utils Pester tests[\s\S]*Invoke-PesterQualityGate\.ps1'
        }
        @{
            Name    = "utils step passes diagnostics prefix"
            Pattern = 'Run Utils Pester tests[\s\S]*-DiagnosticsPrefix\s+"Utils Pester"'
        }
        @{
            Name    = "utils step uses explicit timeout"
            Pattern = 'Run Utils Pester tests[\s\S]*timeout-minutes:\s+10'
        }
        @{
            Name    = "utils step fails clearly when gate script is missing"
            Pattern = 'Run Utils Pester tests[\s\S]*if\s*\(\s*-not\s*\(Test-Path\s+-Path\s+\$pesterGateScript\s+-PathType\s+Leaf\)\s*\)[\s\S]*E_CI_PESTER_GATE_SCRIPT_MISSING'
        }
    ) {
        param($Name, $Pattern)

        $workflow = Get-Content -Path $script:workflowPath -Raw
        $workflow | Should -Match $Pattern -Because $Name
    }

    It "keeps shared Pester quality gate script contract: <Name>" -TestCases @(
        @{
            Name    = "imports Pester with minimum supported version"
            Pattern = 'Import-Module\s+Pester\s+-MinimumVersion\s+\$minimumPesterVersion'
        }
        @{
            Name    = "uses New-PesterConfiguration command-based setup"
            Pattern = 'New-PesterConfiguration'
        }
        @{
            Name    = "emits New-PesterConfiguration availability diagnostics"
            Pattern = 'hasNewPesterConfiguration=\$\(\$null\s+-ne\s+\$newPesterConfigurationCommand\)'
        }
        @{
            Name    = "fails with explicit version parse diagnostic"
            Pattern = 'E_CI_PESTER_VERSION_PARSE_FAILED'
        }
        @{
            Name    = "fails with explicit minimum version diagnostic"
            Pattern = 'E_CI_PESTER_VERSION_TOO_OLD'
        }
        @{
            Name    = "fails when coverage properties are empty"
            Pattern = 'E_CI_PESTER_COVERAGE_PROPS_EMPTY'
        }
        @{
            Name    = "fails with explicit coverage parse diagnostic"
            Pattern = 'E_CI_PESTER_COVERAGE_PARSE_FAILED'
        }
        @{
            Name    = "fails coverage gate with explicit error code"
            Pattern = 'E_CI_PESTER_COVERAGE_GATE_FAILED'
        }
    ) {
        param($Name, $Pattern)

        $pesterGateScriptPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1'
        $pesterGateScript = Get-Content -Path $pesterGateScriptPath -Raw
        $pesterGateScript | Should -Match $Pattern -Because $Name
    }

    It "forbids fragile Pester type literals across all GitHub workflows" {
        $workflowFiles = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath '.github/workflows') -Filter '*.yml' -File -Recurse -ErrorAction Stop)
        $workflowFiles.Count | Should -BeGreaterThan 0 -Because 'Expected at least one GitHub workflow file in .github/workflows.'

        foreach ($workflowFile in $workflowFiles) {
            $workflow = Get-Content -Path $workflowFile.FullName -Raw
            $workflow | Should -Not -Match '\[PesterConfiguration\]::Default' -Because "$($workflowFile.Name) must use New-PesterConfiguration to avoid module type-loading fragility."
        }
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

    It "routes LLM harness validation through the precommit orchestrator" {
        $preCommitConfig = Get-Content -Path $script:preCommitConfigPath -Raw
        $preCommitConfig | Should -Match 'id:\s+powershell-precommit-validation'
        $preCommitConfig | Should -Match 'entry:\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+Scripts/Utils/Run-PreCommitValidation\.ps1'
        $preCommitConfig | Should -Not -Match 'id:\s+llm-harness-validation' -Because 'LLM harness checks should run once via the orchestrator to avoid duplicate execution'
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

        $indexUpdater | Should -Match '\$script:InvariantCultureName\s*=\s*\[System\.Globalization\.CultureInfo\]::InvariantCulture\.Name'
        $indexUpdater | Should -Match 'Sort-Object\s+-Unique\s+-Culture\s+\$script:InvariantCultureName'
        $indexUpdater | Should -Match 'Sort-Object\s+Name,\s*RelativePath\s+-Culture\s+\$script:InvariantCultureName'
        $indexUpdater | Should -Match 'Sort-Object\s+FullName\s+-Culture\s+\$script:InvariantCultureName'
        $indexUpdater | Should -Not -Match 'Sort-Object\s+[^\r\n]*-Culture\s+\(\[System\.Globalization\.CultureInfo\]::InvariantCulture\)'
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
        $preCommitHook | Should -Match 'pipx install pre-commit'
        $preCommitHook | Should -Match 'python3 -m venv ~/.local/venvs/pre-commit'
        $preCommitHook | Should -Not -Match 'python3 -m pip install --user pre-commit'

        $prePushHook | Should -Match 'pre-commit run --hook-stage pre-push --all-files'
        $prePushHook | Should -Match 'Run-PreCommitValidation\.ps1" -All'
        $prePushHook | Should -Match 'pipx install pre-commit'
        $prePushHook | Should -Match 'python3 -m venv ~/.local/venvs/pre-commit'
        $prePushHook | Should -Not -Match 'python3 -m pip install --user pre-commit'
    }

    It "keeps pre-commit bootstrap guidance aligned with PEP 668-safe flows" {
        $readme = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'README.md') -Raw
        $fullValidation = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-FullValidation.ps1') -Raw
        $preCommitHook = Get-Content -Path $script:preCommitHookPath -Raw
        $prePushHook = Get-Content -Path $script:prePushHookPath -Raw

        $readme | Should -Match 'pipx install pre-commit'
        $readme | Should -Match 'python3 -m venv ~/.local/venvs/pre-commit'
        $readme | Should -Match '~/.bashrc'
        $readme | Should -Not -Match 'python3 -m pip install --user pre-commit'

        $fullValidation | Should -Match 'E_VALIDATION_PREREQ_MISSING'
        $fullValidation | Should -Match 'pipx install pre-commit'
        $fullValidation | Should -Match 'python3 -m venv ~/.local/venvs/pre-commit'
        $fullValidation | Should -Match '~/.bashrc or ~/.zshrc'
        $fullValidation | Should -Not -Match 'python3 -m pip install --user pre-commit'

        $preCommitHook | Should -Match '~/.bashrc or ~/.zshrc'
        $prePushHook | Should -Match '~/.bashrc or ~/.zshrc'
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
        $workflow | Should -Match 'E_CI_PRECOMMIT_AUTOFIX_REQUIRED'
        $workflow | Should -Match 'E_CI_PRECOMMIT_HOOK_FAILURE'
        $workflow | Should -Match 'files were modified by this hook'
        $workflow | Should -Match 'Auto-formatted files'
        $workflow | Should -Not -Match 'hook id:[\s\S]*\{\s*print\s+\$NF\s*\}'
        # failed_hook_ids must use awk block-tracking (exit code) not a plain sed to avoid capturing passing hooks
        $workflow | Should -Not -Match 'failed_hook_ids.*sed\s+-n\s+''s.*hook\s+id'
        $workflow | Should -Match 'failed_hook_ids[\s\S]*exit code[\s\S]*[1-9]'
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
        $windowsChecksTests | Should -Match 'Executable\s*='
        $windowsChecksTests | Should -Match 'Arguments\s*='
    }

    It "uses System.Diagnostics.Process with ArgumentList in Invoke-AutoHotkeyCommand and avoids LASTEXITCODE dependency" {
        $windowsChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1'
        $windowsChecks = Get-Content -Path $windowsChecksPath -Raw

        $windowsChecks | Should -Match 'System\.Diagnostics\.ProcessStartInfo'
        $windowsChecks | Should -Match 'ArgumentList\.Add'
        $windowsChecks | Should -Match 'RedirectStandardOutput'
        $windowsChecks | Should -Match 'RedirectStandardError'
        $windowsChecks | Should -Match 'E_AHK_PROCESS_EXECUTION_FAILED'

        # Prevent regression: do not rely on Start-Process which mangles special characters
        # (curly braces, double quotes) in arguments on Windows.
        $windowsChecks | Should -Not -Match 'Start-Process\s+@startParams|Start-Process\s+-FilePath'
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

    It "keeps .editorconfig aligned with Windows command-script line endings" {
        $editorconfigPath = Join-Path -Path $script:repoRoot -ChildPath '.editorconfig'
        Test-Path -Path $editorconfigPath -PathType Leaf | Should -BeTrue -Because ".editorconfig must exist"

        $editorconfig = (Get-Content -Path $editorconfigPath -Raw) -replace "`r", ''
        $editorconfig | Should -Match '(?m)^\[\*\.\{bat,cmd\}\]\s*$' -Because ".editorconfig must include a dedicated .bat/.cmd section"
        $editorconfig | Should -Match '(?ms)\[\*\.\{bat,cmd\}\]\s*\n\s*end_of_line\s*=\s*crlf' -Because ".editorconfig must keep .bat/.cmd as CRLF to match .gitattributes"
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

    It "keeps prerelease IFS changes scoped in increment-version" {
        $incrementPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/increment-version.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $incrementContent = (Get-Content -Path $incrementPath -Raw) -replace "`r", ''

        $incrementContent | Should -Match 'increment_prerelease_rollover\(\)[\s\S]*local IFS=''\.'''
        $incrementContent | Should -Match 'increment_prerelease_default\(\)[\s\S]*local IFS=''\.'''
        $incrementContent | Should -Not -Match 'increment_prerelease_default\(\)[\s\S]*\n\s*IFS=''\.''\s*\n\s*echo\s+"\$\{parts\[\*\]\}"\s*\n\s*\}'
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

Describe "Directory restoration safety conventions" {
    It "requires try/finally restoration for Push-Location in PowerShell scripts" {
        $scriptsRoot = Join-Path -Path $script:repoRoot -ChildPath 'Scripts'
        $powerShellScripts = @(Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -File -Recurse -ErrorAction Stop)

        foreach ($scriptFile in $powerShellScripts) {
            # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
            $content = (Get-Content -LiteralPath $scriptFile.FullName -Raw) -replace "`r", ''
            if ($content -notmatch '(?m)^\s*Push-Location\b') {
                continue
            }

            $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)

            # Per-occurrence check: split content on each Push-Location invocation.
            # Each part after index 0 is the content that follows one Push-Location call.
            # Every such segment must contain a try/finally block with Pop-Location,
            # ensuring every Push-Location is independently guarded — a single-regex check
            # over the whole file would pass even when only one of multiple Push-Locations
            # is protected.
            $parts = [regex]::Split($content, '\bPush-Location\b[^\n]*')
            for ($i = 1; $i -lt $parts.Count; $i++) {
                $segment = $parts[$i]
                $segment | Should -Match 'try\s*\{[\s\S]*?finally\s*\{[\s\S]*?Pop-Location' -Because (
                    "{0}: Push-Location occurrence #{1} must be followed by a try/finally block that calls Pop-Location. Each Push-Location must be independently guarded." -f $relativePath, $i
                )
            }
        }
    }

    It "uses -LiteralPath with Push-Location in all PowerShell scripts under Scripts/" {
        $allScripts = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath "Scripts") -Filter "*.ps1" -Recurse -ErrorAction Stop)

        foreach ($scriptFile in $allScripts) {
            $relativePath = $scriptFile.FullName.Replace($script:repoRoot, '').TrimStart('/\')
            $content = (Get-Content -Path $scriptFile.FullName -Raw) -replace "`r", ''
            $lines = $content -split '\n'
            $pushLocationLines = @($lines | Where-Object { $_ -match 'Push-Location\b' })
            if ($pushLocationLines.Count -eq 0) {
                continue
            }

            # Every Push-Location line must explicitly specify -LiteralPath
            $violations = New-Object System.Collections.Generic.List[string]
            foreach ($line in $pushLocationLines) {
                if ($line -notmatch '-LiteralPath\b') {
                    [void]$violations.Add($line.Trim())
                }
            }

            $violations.Count | Should -Be 0 -Because (
                "$relativePath has Push-Location call(s) without -LiteralPath (catches -Path, positional, and named-param reordering). Violations: {0}" -f ($violations -join '; ')
            )
        }
    }

    It "avoids bare backup-dir cd in Mac brew scripts" {
        foreach ($relativePath in @('Scripts/Mac/backup_brew.sh', 'Scripts/Mac/restore_brew.sh')) {
            # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
            $content = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath $relativePath) -Raw) -replace "`r", ''
            $lines = $content -split "`n"
            $violations = New-Object System.Collections.Generic.List[string]

            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -notmatch '^\s*cd\s+"\$BACKUP_DIR"\s*$') {
                    continue
                }

                $previousIndex = $index - 1
                while ($previousIndex -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$previousIndex])) {
                    $previousIndex--
                }

                if ($previousIndex -lt 0 -or $lines[$previousIndex] -notmatch '^\s*\(\s*$') {
                    $violations.Add(("{0}:{1}" -f $relativePath, ($index + 1))) | Out-Null
                }
            }

            $violations.Count | Should -Be 0 -Because (
                '{0} must only use cd "$BACKUP_DIR" immediately inside a subshell. Violations: {1}' -f $relativePath, ($violations -join ', ')
            )
            $content | Should -Match '(?s)\(\s*\n\s*cd\s+"\$BACKUP_DIR"' -Because (
                "{0} should scope BACKUP_DIR cd to a subshell to keep location changes local." -f $relativePath
            )
        }
    }
}

Describe "File stream safety conventions" {
    It "requires protected disposal for OpenRead usage in Scripts PowerShell files" {
        $scriptsRoot = Join-Path -Path $script:repoRoot -ChildPath 'Scripts'
        $powerShellScripts = @(Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -File -Recurse -ErrorAction Stop)

        foreach ($scriptFile in $powerShellScripts) {
            $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
            $content = (Get-Content -LiteralPath $scriptFile.FullName -Raw) -replace "`r", ''
            $openReadMatches = [regex]::Matches($content, '\[System\.IO\.File\]::OpenRead\s*\(')

            if ($openReadMatches.Count -eq 0) {
                continue
            }

            foreach ($match in $openReadMatches) {
                $startIndex = [Math]::Max(0, $match.Index - 400)
                $endIndex = [Math]::Min($content.Length, $match.Index + 1600)
                $snippet = $content.Substring($startIndex, $endIndex - $startIndex)
                $lineNumber = ([regex]::Matches($content.Substring(0, $match.Index), "`n")).Count + 1

                $isUsingOpenRead = $snippet -match 'using\s*\(\s*\$[A-Za-z0-9_]+\s*=\s*\[System\.IO\.File\]::OpenRead\s*\('
                $isTryFinallyProtected = $snippet -match 'try\s*\{[\s\S]*?\[System\.IO\.File\]::OpenRead\s*\([\s\S]*?finally\s*\{[\s\S]*?(?:\.Dispose\(\)|\.Close\(\))'

                ($isUsingOpenRead -or $isTryFinallyProtected) | Should -BeTrue -Because (
                    "{0}:{1} OpenRead must be protected by using(...) or try/finally with Dispose()/Close() to guarantee file-handle cleanup." -f $relativePath, $lineNumber
                )
            }
        }
    }

    It "centralizes Remove-BOM prefix reads in a disposal-safe helper" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $content = (Get-Content -LiteralPath $removeBomPath -Raw) -replace "`r", ''

        $content | Should -Match 'function\s+Read-FilePrefixBytes\s*\{[\s\S]*?try\s*\{[\s\S]*?\[System\.IO\.File\]::OpenRead\s*\([\s\S]*?finally\s*\{[\s\S]*?\.Dispose\(\)'

        $openReadCount = ([regex]::Matches($content, '\[System\.IO\.File\]::OpenRead\s*\(')).Count
        $openReadCount | Should -Be 1 -Because 'Remove-BOM should keep OpenRead centralized in Read-FilePrefixBytes to avoid duplicated disposal logic.'

        $closeCount = ([regex]::Matches($content, '\.Close\s*\(\)')).Count
        $closeCount | Should -Be 0 -Because 'Remove-BOM should avoid manual Close() calls and rely on centralized disposal logic.'
    }

    It "uses git-native ignore semantics in Remove-BOM file discovery" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $content = (Get-Content -LiteralPath $removeBomPath -Raw) -replace "`r", ''

        $content | Should -Match '\$gitListArguments\s*=\s*@\("ls-files",\s*"--cached",\s*"--others",\s*"--exclude-standard"\)'
        $content | Should -Match '\-C\s+\$scanPlan\.GitRoot\s+@\(\$scanPlan\.GitListArguments\)'
        $content | Should -Match 'function\s+Resolve-ScannableFileDiscovery'
        $content | Should -Match 'function\s+Get-ScannableFileStream'
        $content | Should -Match 'function\s+Get-ScannableFiles'
        $content | Should -Not -Match '\$scanFiles\s*=\s*@\(\$scanPlan\.Files\)'
        $content | Should -Match 'Get-ScannableFileStream\s+-scanPlan\s+\$scanPlan\s*\|'
        $content | Should -Match 'listedPaths=deferred'
        $content | Should -Not -Match 'listedPaths=\$\(\$listedPathCount\)'
        $content | Should -Not -Match 'Get-GitCommandDetails\s+-gitExecutable\s+\$gitCommand\.Source\s+-workingDirectory\s+\$gitRoot\s+-arguments\s+\$gitListArguments\s*\r?\n\s*if\s*\(\$gitListResult\.ExitCode\s*-eq\s*0\)'
        $content | Should -Not -Match 'function\s+Get-GitIgnorePatterns'
        $content | Should -Not -Match 'function\s+Test-PathAgainstGitIgnore'
    }

    It "keeps explicit prefix-read diagnostics in Remove-BOM" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $content = (Get-Content -LiteralPath $removeBomPath -Raw) -replace "`r", ''

        $content | Should -Match 'W_REMOVE_BOM_READ_PREFIX_FAILED'
        $content | Should -Match 'W_REMOVE_BOM_PREFIX_READ_FAILURES'
        $content | Should -Match '\$script:prefixReadFailures\s*=\s*0'
    }

    It "keeps Remove-BOM discovery fallback diagnostics and direct-run guard" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $content = (Get-Content -LiteralPath $removeBomPath -Raw) -replace "`r", ''

        $content | Should -Match 'W_REMOVE_BOM_GIT_DISCOVERY_FALLBACK'
        $content | Should -Match 'E_REMOVE_BOM_GIT_DISCOVERY_REQUIRED'
        $content | Should -Match 'filesystem-fallback'
        $content | Should -Match 'if\s*\(\$MyInvocation\.InvocationName\s*-ne\s*"\."\)\s*\{\s*Invoke-Main'
    }
}

Describe "Restore script safety conventions" {
    It "enforces strict mode and isolated child execution in Restore orchestrator" {
        $restoreScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Restore.ps1') -Raw) -replace "`r", ''

        $restoreScript | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
        $restoreScript | Should -Match '\$ErrorActionPreference\s*=\s*"Stop"'
        $restoreScript | Should -Match 'Get-Command\s+-Name\s+"pwsh"'
        $restoreScript | Should -Match '&\s+\$pwshCommand\s+-NoLogo\s+-NoProfile\s+-File'
        $restoreScript | Should -Match 'E_RESTORE_PARTIAL_FAILURE'
    }

    It "anchors restore step script resolution to PSScriptRoot with pre-flight diagnostics" {
        $restoreScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Restore.ps1') -Raw) -replace "`r", ''

        $restoreScript | Should -Match '\$scriptsDirectory\s*=\s*\(Resolve-Path\s+-LiteralPath\s+\$PSScriptRoot'
        $restoreScript | Should -Not -Match 'Join-Path\s+-Path\s+\$baseDirectory\s+-ChildPath\s+"Scripts"'
        $restoreScript | Should -Match 'Assert-RestoreStepScriptsExist\s+-Steps\s+\$applicableSteps'
        $restoreScript | Should -Match 'E_RESTORE_PRE_FLIGHT_STEP_SCRIPT_MISSING'
        $restoreScript | Should -Match 'E_RESTORE_PRE_FLIGHT_FAILED'
    }

    It "uses platform-aware restore step metadata and skip diagnostics" {
        $restoreScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Restore.ps1') -Raw) -replace "`r", ''

        $restoreScript | Should -Match 'function\s+Get-ApplicableRestoreSteps'
        $restoreScript | Should -Match 'SupportedPlatforms\s*=\s*@\("All"\)'
        $restoreScript | Should -Match 'SupportedPlatforms\s*=\s*@\("Windows"\)'
        $restoreScript | Should -Match 'W_RESTORE_STEP_SKIPPED_PLATFORM'
        $restoreScript | Should -Match 'E_RESTORE_STEP_SELECTION_INVALID'
        $restoreScript | Should -Match 'Restore platform diagnostics:'
        $restoreScript | Should -Match 'Assert-ApplicableRestoreStepsFlat\s+-ApplicableSteps\s+\$applicableSteps'
        $restoreScript | Should -Match 'Assert-RestoreStepScriptsExist\s+-Steps\s+\$applicableSteps'
        $restoreScript | Should -Not -Match 'return\s*,\s*\$applicableSteps\.ToArray\(\)'
        $restoreScript | Should -Match 'foreach\s*\(\$step\s+in\s+\$applicableSteps\)'
    }

    It "uses defined destination variables in PowerToys restore messages" {
        $powerToysRestore = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/PowerToys/PowerToysRestore.ps1') -Raw) -replace "`r", ''

        $powerToysRestore | Should -Match '\$targetPath'
        $powerToysRestore | Should -Not -Match '\$targetFolder'
        $powerToysRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$copyFrom\s+-PathType\s+Container'
        $powerToysRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$targetPath\s+-PathType\s+Container'
        $powerToysRestore | Should -Match 'Robocopy\.exe'
        $powerToysRestore | Should -Match 'robocopyExitCode\s*-ge\s*8'
        $powerToysRestore | Should -Match 'E_POWERTOYS_RESTORE_ROBOCOPY_FAILED'
        $powerToysRestore | Should -Match 'E_POWERTOYS_RESTORE_SOURCE_MISSING'
        $powerToysRestore | Should -Match 'E_POWERTOYS_RESTORE_TARGET_MISSING'
    }

    It "backs up live Windows Terminal settings and guards missing live files" {
        $windowsTerminalRestore = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/WindowsTerminal/WindowsTerminalRestore.ps1') -Raw) -replace "`r", ''

        $windowsTerminalRestore | Should -Not -Match 'Copy-Item\s+-Path\s+\$settingsPath\s+-Destination\s+\$currentBackupFile'
        $windowsTerminalRestore | Should -Match 'if\s*\(\s*Test-Path\s+-LiteralPath\s+\$windowsTerminalSettings\s+-PathType\s+Leaf\s*\)\s*\{[\s\S]*?Copy-Item\s+-Path\s+\$windowsTerminalSettings\s+-Destination\s+\$currentBackupFile'
        $windowsTerminalRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$settingsPath\s+-PathType\s+Leaf'
        $windowsTerminalRestore | Should -Match 'E_WT_RESTORE_SOURCE_MISSING'
        $windowsTerminalRestore | Should -Match 'W_WT_RESTORE_NO_LIVE_SETTINGS'
    }

    It "guards PowerShell profile backups on first-time machines" {
        $powershellRestore = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Powershell/PowershellRestore.ps1') -Raw) -replace "`r", ''

        $powershellRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$settingsPath\s+-PathType\s+Leaf'
        $powershellRestore | Should -Match 'Write-Error\s+"E_POWERSHELL_RESTORE_SOURCE_MISSING:'
        $powershellRestore | Should -Not -Match 'Write-Host\s+"Powershell settings backup not found at'
        $powershellRestore | Should -Match '(?-i)Microsoft\.PowerShell_profile\.ps1'
        $powershellRestore | Should -Not -Match '(?-i)Microsoft\.Powershell_profile\.ps1'
        $powershellRestore | Should -Match 'Join-Path\s+-Path\s+\$HOME\s+-ChildPath\s+''Documents'''
        $powershellRestore | Should -Match 'Join-Path\s+-Path\s+\$documentsPath\s+-ChildPath\s+''PowerShell'''
        $powershellRestore | Should -Match 'Join-Path\s+-Path\s+\$documentsPath\s+-ChildPath\s+''WindowsPowerShell'''
        $powershellRestore | Should -Not -Match '\$HOME\\Documents\\PowerShell'
        $powershellRestore | Should -Not -Match '\$HOME\\Documents\\Powershell'
        $powershellRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$powershellConfigPath\s+-PathType\s+Container'
        $powershellRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$windowsPowershellConfigPath\s+-PathType\s+Container'
        $powershellRestore | Should -Match 'if\s*\(\s*Test-Path\s+-LiteralPath\s+\$powershellSettings\s+-PathType\s+Leaf\s*\)\s*\{[\s\S]*?Copy-Item\s+-Path\s+\$powershellSettings\s+-Destination\s+\$powershellBackupFile'
        $powershellRestore | Should -Match 'if\s*\(\s*Test-Path\s+-LiteralPath\s+\$windowsPowershellSettings\s+-PathType\s+Leaf\s*\)\s*\{[\s\S]*?Copy-Item\s+-Path\s+\$windowsPowershellSettings\s+-Destination\s+\$windowsPowershellBackupFile'
        $powershellRestore | Should -Match 'W_POWERSHELL_RESTORE_NO_POWERSHELL_PROFILE'
        $powershellRestore | Should -Match 'W_POWERSHELL_RESTORE_NO_WINDOWS_POWERSHELL_PROFILE'
    }

    It "validates required Komorebi source files before restore copy" {
        $komorebiRestore = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Komorebi/KomorebiRestore.ps1') -Raw) -replace "`r", ''

        $komorebiRestore | Should -Match '\$missingSources\s*=\s*@\('
        $komorebiRestore | Should -Match 'E_KOMOREBI_RESTORE_SOURCE_MISSING'
        $komorebiRestore | Should -Match 'foreach\s*\(\$sourcePath\s+in\s+@\(\$komorebiSourceConfig,\s*\$komorebiSourceBarConfig,\s*\$komorebiSourceApplications\)\)'
        $komorebiRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$sourcePath\s+-PathType\s+Leaf'
    }

    It "fails fast when Config restore backup directory is empty" {
        $configRestore = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Config/ConfigRestore.ps1') -Raw) -replace "`r", ''

        $configRestore | Should -Match 'Get-ChildItem\s+-LiteralPath\s+\$backupDir\s+-Force\s+-ErrorAction\s+Stop'
        $configRestore | Should -Match 'foreach\s*\(\$backupItem\s+in\s+\$backupItems\)\s*\{[\s\S]*Copy-Item\s+-LiteralPath\s+\$backupItem\.FullName\s+-Destination\s+\$configDir'
        $configRestore | Should -Match 'E_CONFIG_RESTORE_EMPTY_BACKUP'
        $configRestore | Should -Match 'E_CONFIG_RESTORE_BACKUP_MISSING'
        $configRestore | Should -Match 'E_CONFIG_RESTORE_COPY_FAILED'
    }

    It "validates Scoop restore source and import exit codes" {
        $scoopRestore = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Scoop/ScoopRestore.ps1') -Raw) -replace "`r", ''

        $scoopRestore | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
        $scoopRestore | Should -Match 'E_SCOOP_RESTORE_SOURCE_MISSING'
        $scoopRestore | Should -Match 'E_SCOOP_RESTORE_IMPORT_FAILED'
        $scoopRestore | Should -Match 'scoop\s+import\s+\$scoopFilePath'
    }
}

Describe "Backup script safety conventions" {
    It "tracks per-step results and emits best-effort summary in Backup orchestrator" {
        $backupScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Backup.ps1') -Raw) -replace "`r", ''

        $backupScript | Should -Match '\$stepResults\s*=\s*New-Object\s+System\.Collections\.Generic\.List\[object\]'
        $backupScript | Should -Match 'Proceeding with git operations \(best-effort mode\)'
        $backupScript | Should -Match 'if\s*\(\s*\$hasBackupStepFailures\s*\)\s*\{[\s\S]*partial success:'
        $backupScript | Should -Match 'else\s*\{[\s\S]*\$commitMessage\s*=\s*"Backup for \$dateString \(\$succeededCount/\$totalCount\)"'
        $backupScript | Should -Match 'Get-Command\s+-Name\s+"pwsh"'
        $backupScript | Should -Match '&\s+\$pwshCommand\s+-NoLogo\s+-NoProfile\s+-File'
        $backupScript | Should -Match 'git\s+rev-parse\s+--is-inside-work-tree'
        $backupScript | Should -Match 'E_BACKUP_GIT_NOT_REPOSITORY'
        $backupScript | Should -Match 'E_BACKUP_GIT_ADD_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_DIFF_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_COMMIT_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_PULL_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_PUSH_FAILED'
        $backupScript | Should -Match 'Backup git preflight diagnostics:'
        $backupScript | Should -Match 'Backup git staging diagnostics:'
        $backupScript | Should -Match 'if\s*\(\s*-not\s+\$hasGitFailure\s*\)\s*\{[\s\S]*?git\s+pull\s+--ff-only\s+origin\s+main'
        $backupScript | Should -Match 'if\s*\(\s*-not\s+\$hasGitFailure\s*\)\s*\{[\s\S]*?git\s+push\s+origin\s+main'
        $backupScript | Should -Match 'W_BACKUP_GIT_PULL_SKIPPED_PRIOR_GIT_FAILURE'
        $backupScript | Should -Match 'W_BACKUP_GIT_ADD_SKIPPED_PRIOR_GIT_FAILURE'
        $backupScript | Should -Match 'W_BACKUP_GIT_COMMIT_SKIPPED_PRIOR_GIT_FAILURE'
        $backupScript | Should -Match 'W_BACKUP_GIT_PUSH_SKIPPED_PRIOR_GIT_FAILURE'
        $backupScript | Should -Match 'E_BACKUP_STEP_SELECTION_INVALID'
        $backupScript | Should -Match 'Assert-ApplicableBackupStepsFlat\s+-ApplicableSteps\s+\$applicableSteps'
        $backupScript | Should -Not -Match 'return\s*,\s*\$applicableSteps\.ToArray\(\)'
        # git pull --ff-only must appear BEFORE git add --all: staging before pull causes pull to fail
        # with "local changes would be overwritten" when staged changes overlap with remote changes
        $backupScript | Should -Match 'git\s+pull\s+--ff-only\s+origin\s+main[\s\S]*?git\s+add\s+--all' -Because "git pull --ff-only must execute before git add --all; staging before pull causes pull to fail if remote changed the same files"
        # git pull --ff-only must also appear BEFORE git commit
        $backupScript | Should -Match 'git\s+pull\s+--ff-only\s+origin\s+main[\s\S]*?git\s+commit' -Because "git pull --ff-only must execute before git commit; committing first causes --ff-only to fail when origin/main has advanced"
    }

    It "uses platform-aware backup step metadata and skip diagnostics" {
        $backupScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Backup.ps1') -Raw) -replace "`r", ''

        $backupScript | Should -Match 'function\s+Get-ApplicableBackupSteps'
        $backupScript | Should -Match 'SupportedPlatforms\s*=\s*@\("All"\)'
        $backupScript | Should -Match 'SupportedPlatforms\s*=\s*@\("Windows"\)'
        $backupScript | Should -Match 'W_BACKUP_STEP_SKIPPED_PLATFORM'
        $backupScript | Should -Match 'Backup platform diagnostics:'
        $backupScript | Should -Match 'Assert-BackupStepScriptsExist\s+-Steps\s+\$applicableSteps'
        $backupScript | Should -Match 'foreach\s*\(\$step\s+in\s+\$applicableSteps\)'
    }

    It "requires strict mode in utility backup and restore scripts" {
        $targetDirectories = @('Config', 'Komorebi', 'PowerToys', 'Powershell', 'Scoop', 'WindowsTerminal')

        foreach ($targetDirectory in $targetDirectories) {
            $directoryPath = Join-Path -Path $script:repoRoot -ChildPath (Join-Path -Path 'Scripts' -ChildPath $targetDirectory)
            $candidateScripts = @(Get-ChildItem -Path $directoryPath -Filter '*.ps1' -File -ErrorAction Stop)
            $backupRestoreScripts = @($candidateScripts | Where-Object { $_.Name -match '(Backup|Restore)\.ps1$' })

            foreach ($scriptFile in $backupRestoreScripts) {
                $content = (Get-Content -Path $scriptFile.FullName -Raw) -replace "`r", ''
                $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                $content | Should -Match 'Set-StrictMode\s+-Version\s+Latest' -Because (
                    '{0} is part of backup/restore flow and must declare strict mode.' -f $relativePath
                )
            }
        }
    }

    It "anchors backup step script resolution to PSScriptRoot with pre-flight diagnostics" {
        $backupScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Backup.ps1') -Raw) -replace "`r", ''

        $backupScript | Should -Match '\$scriptsDirectory\s*=\s*\(Resolve-Path\s+-LiteralPath\s+\$PSScriptRoot'
        $backupScript | Should -Not -Match 'Join-Path\s+-Path\s+\$baseDirectory\s+-ChildPath\s+"Scripts"'
        $backupScript | Should -Match 'Assert-BackupStepScriptsExist\s+-Steps\s+\$applicableSteps'
        $backupScript | Should -Match 'E_BACKUP_PRE_FLIGHT_STEP_SCRIPT_MISSING'
        $backupScript | Should -Match 'E_BACKUP_PRE_FLIGHT_FAILED'
    }

    It "keeps Update orchestrator rooted at script directory without nested Scripts suffix" {
        $updateScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Update.ps1') -Raw) -replace "`r", ''

        $updateScript | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
        $updateScript | Should -Match '\$scriptsDirectory\s*=\s*\(Resolve-Path\s+-LiteralPath\s+\$PSScriptRoot'
        $updateScript | Should -Match 'Push-Location\s+-LiteralPath\s+\$scriptsDirectory'
        $updateScript | Should -Match 'function\s+Get-ApplicableUpdateSteps'
        $updateScript | Should -Match 'SupportedPlatforms\s*=\s*@\("All"\)'
        $updateScript | Should -Match 'SupportedPlatforms\s*=\s*@\("Windows"\)'
        $updateScript | Should -Match 'W_UPDATE_STEP_SKIPPED_PLATFORM'
        $updateScript | Should -Match 'E_UPDATE_STEP_SELECTION_INVALID'
        $updateScript | Should -Match 'Assert-ApplicableUpdateStepsFlat\s+-ApplicableSteps\s+\$applicableSteps'
        $updateScript | Should -Match 'Update platform diagnostics:'
        $updateScript | Should -Not -Match 'return\s*,\s*\$applicableSteps\.ToArray\(\)'
        $updateScript | Should -Not -Match 'Push-Location\s+"\$baseDirectory/Scripts/"'
    }

    It "validates Config backup source before destructive clear" {
        $configBackup = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Config/ConfigBackup.ps1') -Raw) -replace "`r", ''

        $configBackup | Should -Match 'E_CONFIG_BACKUP_SOURCE_MISSING'
        $configBackup | Should -Match 'Get-ChildItem\s+-LiteralPath\s+\$backupFolder\s+-Force\s+-ErrorAction\s+Stop'
        $configBackup | Should -Match 'foreach\s*\(\$backupEntry\s+in\s+\$backupEntries\)\s*\{[\s\S]*Remove-Item\s+-LiteralPath\s+\$backupEntry\.FullName'
        $configBackup | Should -Match 'Backup successful! \.config folder saved to \$backupFolder'
        $configBackup | Should -Not -Match 'Remove-Item[^\r\n]*-ErrorAction\s+SilentlyContinue'
    }

    It "fails when Windows Terminal backup source is missing" {
        $windowsTerminalBackup = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/WindowsTerminal/WindowsTerminalBackup.ps1') -Raw) -replace "`r", ''

        $windowsTerminalBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$sourcePath\s+-PathType\s+Leaf'
        $windowsTerminalBackup | Should -Match 'E_WT_BACKUP_SOURCE_MISSING'
        $windowsTerminalBackup | Should -Match 'E_WT_BACKUP_SOURCE_MISSING[\s\S]*exit\s+1'
        $windowsTerminalBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$backupFolder\s+-PathType\s+Container'
    }

    It "uses profile-driven path-safe backup and fails when no PowerShell profiles are available" {
        $powershellBackup = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Powershell/PowershellBackup.ps1') -Raw) -replace "`r", ''

        $powershellBackup | Should -Match 'Join-Path\s+-Path\s+\(Join-Path\s+-Path\s+\$baseDirectory\s+-ChildPath\s+"Config"\)\s+-ChildPath\s+"Powershell"'
        $powershellBackup | Should -Match '\$PROFILE\.CurrentUserCurrentHost'
        $powershellBackup | Should -Match '\$PROFILE\.CurrentUserAllHosts'
        $powershellBackup | Should -Match 'HashSet\[string\]\(\[System\.StringComparer\]::OrdinalIgnoreCase\)'
        $powershellBackup | Should -Match 'W_POWERSHELL_BACKUP_PROFILE_MISSING\('
        $powershellBackup | Should -Match 'PowerShell backup profile discovery diagnostics:'
        $powershellBackup | Should -Not -Match '\$backupFolder\s*=\s*"\$baseDirectory\\Config\\Powershell"'
        $powershellBackup | Should -Not -Match '\$HOME\\Documents\\PowerShell'
        $powershellBackup | Should -Not -Match '\$HOME\\Documents\\WindowsPowerShell'
        $powershellBackup | Should -Match '\$profilesBackedUp\s*=\s*0'
        $powershellBackup | Should -Match 'if\s*\(\s*\$profilesBackedUp\s*-eq\s*0\s*\)'
        $powershellBackup | Should -Match 'E_POWERSHELL_BACKUP_NO_PROFILES_FOUND'
        $powershellBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$backupFolder\s+-PathType\s+Container'
        $powershellBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$candidate\.Path\s+-PathType\s+Leaf'
    }

    It "uses UTF-8 no-BOM writes for Scoop backup output" {
        $scoopBackup = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Scoop/ScoopBackup.ps1') -Raw) -replace "`r", ''

        $scoopBackup | Should -Not -Match 'Out-File\s+-FilePath\s+"scoopfile\.json"\s+-Encoding\s+utf8'
        $scoopBackup | Should -Match '\[System\.Text\.UTF8Encoding\]::new\(\$false\)'
        $scoopBackup | Should -Match '\[System\.IO\.File\]::WriteAllText'
        $scoopBackup | Should -Match 'E_SCOOP_BACKUP_EXPORT_FAILED'
    }

    It "checks robocopy exit semantics in PowerToys backup" {
        $powerToysBackup = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/PowerToys/PowerToysBackup.ps1') -Raw) -replace "`r", ''

        $powerToysBackup | Should -Match 'Robocopy\.exe'
        $powerToysBackup | Should -Match 'robocopyExitCode\s*-ge\s*8'
        $powerToysBackup | Should -Match 'E_POWERTOYS_BACKUP_ROBOCOPY_FAILED'
        $powerToysBackup | Should -Match 'E_POWERTOYS_BACKUP_SOURCE_MISSING'
        $powerToysBackup | Should -Match 'Get-ChildItem\s+-LiteralPath\s+\$backupFolder\s+-Force\s+-ErrorAction\s+Stop'
        $powerToysBackup | Should -Match 'Remove-Item\s+-LiteralPath\s+\$backupEntry\.FullName'
        $powerToysBackup | Should -Not -Match 'Remove-Item[^\r\n]*-ErrorAction\s+SilentlyContinue'
    }

    It "validates Komorebi backup sources before copy operations" {
        $komorebiBackup = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Komorebi/KomorebiBackup.ps1') -Raw) -replace "`r", ''

        $komorebiBackup | Should -Match '\$missingSources\s*=\s*@\('
        $komorebiBackup | Should -Match 'E_KOMOREBI_BACKUP_SOURCE_MISSING'
        $komorebiBackup | Should -Match 'foreach\s*\(\$sourcePath\s+in\s+@\(\$komorebiConfig,\s*\$komorebiBarConfig,\s*\$applicationYaml\)\)'
        $komorebiBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$sourcePath\s+-PathType\s+Leaf'
    }

    It "documents backup safety contract in LLM context" {
        $llmContext = (Get-Content -Path $script:llmContextPath -Raw) -replace "`r", ''

        $llmContext | Should -Match '## Backup/Restore Safety Contract'
        $llmContext | Should -Match 'Source Validation'
        $llmContext | Should -Match 'Robocopy Exit Codes'
        $llmContext | Should -Match 'Best-Effort Orchestrators'
    }

    It "keeps utility backup jobs fail-fast with explicit unexpected-error signaling" {
        $dxMessagingBackup = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/BackupDxMessaging.ps1') -Raw) -replace "`r", ''

        $dxMessagingBackup | Should -Match 'E_DXMSG_BACKUP_UNEXPECTED'
        $dxMessagingBackup | Should -Match 'Test-Path\s+-Path\s+\$sourcePath\s+-PathType\s+Container'
        $dxMessagingBackup | Should -Match 'Test-Path\s+-Path\s+\$backupDir\s+-PathType\s+Container'
        $dxMessagingBackup | Should -Match 'catch\s*\{[\s\S]*E_DXMSG_BACKUP_UNEXPECTED[\s\S]*exit\s+1'
        # Cleanup finally block must use -LiteralPath and -PathType to be path-safe
        $dxMessagingBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$tempStagePath\s+-PathType\s+Container'
        $dxMessagingBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$zipFilePath\s+-PathType\s+Leaf'
        $dxMessagingBackup | Should -Match 'Remove-Item\s+-LiteralPath\s+\$tempStagePath'
        $dxMessagingBackup | Should -Match 'Remove-Item\s+-LiteralPath\s+\$zipFilePath'
        # Old-backup rotation loop must use -LiteralPath for both enumeration and deletion
        $dxMessagingBackup | Should -Match 'Get-ChildItem\s+-LiteralPath\s+\$backupDir'
        $dxMessagingBackup | Should -Match 'Remove-Item\s+-LiteralPath\s+\$file\.FullName'
    }

    It "enforces portable environment-variable usage in script scopes: <Name>" -TestCases @(
        @{
            Name             = "cross-platform scripts avoid env:USERPROFILE"
            RootRelativePath = "Scripts"
            ExcludePattern   = '[/\\](Komorebi|WindowsTerminal|WinGet|PowerToys)([/\\]|$)'
            ForbiddenPattern = '\$env:USERPROFILE\b'
        }
        @{
            Name             = "Scripts/Utils scripts avoid env:TEMP"
            RootRelativePath = "Scripts/Utils"
            ExcludePattern   = ""
            ForbiddenPattern = '\$env:TEMP\b'
        }
    ) {
        param($Name, $RootRelativePath, $ExcludePattern, $ForbiddenPattern)

        $scriptRoot = Join-Path -Path $script:repoRoot -ChildPath $RootRelativePath
        $scriptFiles = @(
            Get-ChildItem -LiteralPath $scriptRoot -Filter "*.ps1" -Recurse -ErrorAction Stop |
                Where-Object {
                    [string]::IsNullOrWhiteSpace($ExcludePattern) -or $_.FullName -notmatch $ExcludePattern
                }
        )

        $scriptFiles.Count | Should -BeGreaterThan 0 -Because (
            "Expected at least one script under {0} for policy case '{1}'." -f $RootRelativePath, $Name
        )

        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($scriptFile in $scriptFiles) {
            $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
            $content = (Get-Content -Path $scriptFile.FullName -Raw) -replace "`r", ''

            if ($content -match $ForbiddenPattern) {
                $violations.Add($relativePath) | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Policy case '{0}' forbids '{1}' under '{2}'. Offending files: {3}" -f $Name, $ForbiddenPattern, $RootRelativePath, ($violations -join ', ')
        )
    }

    It "uses 24-hour time format (HH) not 12-hour (hh) in backup git commit message timestamp" {
        $backupScript = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Backup.ps1") -Raw
        $backupScript | Should -Match 'HH:mm:ss' -Because (
            "Backup.ps1 commit message timestamp must use 24-hour format (HH) for unambiguous diagnostics."
        )
        $backupScript | Should -Not -Match '"\{0:yyyy/MM/dd hh:mm:ss\}"' -Because (
            "Backup.ps1 commit message must not use ambiguous 12-hour format (hh) without AM/PM."
        )
    }

    It "calls WaitForExit after Start-Process -Wait -PassThru to avoid exit code race condition" {
        $scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath "Scripts") -Filter "*.ps1" -Recurse -ErrorAction Stop)

        foreach ($scriptFile in $scriptFiles) {
            $relativePath = $scriptFile.FullName.Replace($script:repoRoot, '').TrimStart('/\')
            $content = Get-Content -Path $scriptFile.FullName -Raw
            if ($content -notmatch '(?i)Start-Process.*-Wait.*-PassThru|(?i)Start-Process.*-PassThru.*-Wait') {
                continue
            }
            $content | Should -Match '\.WaitForExit\(' -Because (
                "$relativePath uses Start-Process -Wait -PassThru and must call .WaitForExit() to avoid the exit code race condition."
            )
        }
    }
}

Describe "Path derivation safety conventions" {
    It "avoids string-concatenated parent directory derivation in Scripts PowerShell files" {
        $scriptsRoot = Join-Path -Path $script:repoRoot -ChildPath 'Scripts'
        $powerShellScripts = @(Get-ChildItem -Path $scriptsRoot -Filter '*.ps1' -File -Recurse -ErrorAction Stop)

        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($scriptFile in $powerShellScripts) {
            $lines = @(Get-Content -Path $scriptFile.FullName)
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match '\$[A-Za-z0-9_]+\s*=\s*"\$[A-Za-z0-9_]+[\\/]\.\.') {
                    $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                    $violations.Add("${relativePath}:$($index + 1)") | Out-Null
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Parent-directory derivation must use Resolve-Path/Join-Path instead of string '..' concatenation. Violations: {0}" -f ($violations -join ', ')
        )
    }

    It "derives repository root with two parent traversals in nested backup/restore utility scripts" {
        $nestedUtilityScripts = @(
            'Scripts/Config/ConfigBackup.ps1',
            'Scripts/Config/ConfigRestore.ps1',
            'Scripts/Scoop/ScoopBackup.ps1',
            'Scripts/Scoop/ScoopRestore.ps1',
            'Scripts/Komorebi/KomorebiBackup.ps1',
            'Scripts/Komorebi/KomorebiRestore.ps1',
            'Scripts/Powershell/PowershellBackup.ps1',
            'Scripts/Powershell/PowershellRestore.ps1',
            'Scripts/WindowsTerminal/WindowsTerminalBackup.ps1',
            'Scripts/WindowsTerminal/WindowsTerminalRestore.ps1',
            'Scripts/PowerToys/PowerToysBackup.ps1',
            'Scripts/PowerToys/PowerToysRestore.ps1'
        )

        foreach ($relativePath in $nestedUtilityScripts) {
            $content = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath $relativePath) -Raw) -replace "`r", ''
            $parentTraversalMatches = [regex]::Matches($content, 'Join-Path\s+-Path\s+\$[A-Za-z0-9_]+\s+-ChildPath\s+["'']\.\.["'']')
            $parentTraversalMatches.Count | Should -BeGreaterOrEqual 2 -Because (
                '{0} must traverse two parents from nested Scripts subdirectories to reach repository root before targeting Config paths.' -f $relativePath
            )
        }
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

Describe "Dependabot update automation conventions" {
    It "defines Dependabot configuration in .github/dependabot.yml" {
        Test-Path -Path $script:dependabotConfigPath -PathType Leaf | Should -BeTrue -Because (
            "Repository dependency automation policy requires a Dependabot configuration file"
        )
    }

    It "pins Dependabot schema to version 2 with updates blocks" {
        $content = (Get-Content -Path $script:dependabotConfigPath -Raw) -replace "`r", ''

        $content | Should -Match '(?m)^version:\s*2\s*$'
        $content | Should -Match '(?m)^updates:\s*$'
    }

    It "keeps exactly the required ecosystems for current tooling areas" {
        $content = (Get-Content -Path $script:dependabotConfigPath -Raw) -replace "`r", ''

        $ecosystemMatches = [System.Text.RegularExpressions.Regex]::Matches(
            $content,
            '(?m)^\s*-\s*package-ecosystem:\s*"?(?<name>[A-Za-z0-9-]+)"?\s*$'
        )
        $ecosystems = @($ecosystemMatches | ForEach-Object { $_.Groups['name'].Value })

        $ecosystems.Count | Should -Be 3
        @($ecosystems | Sort-Object -Unique) | Should -Be @('devcontainers', 'github-actions', 'pre-commit') -Because (
            "Dependabot coverage must remain aligned to the agreed tooling areas"
        )
    }

    It "uses Monday 03:00 UTC weekly schedule for each configured ecosystem" {
        $content = (Get-Content -Path $script:dependabotConfigPath -Raw) -replace "`r", ''

        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*interval:\s*(?:"weekly"|weekly)\s*$')).Count | Should -Be 3
        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*day:\s*(?:"monday"|monday)\s*$')).Count | Should -Be 3
        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*time:\s*(?:"03:00"|03:00)\s*$')).Count | Should -Be 3
        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*timezone:\s*(?:"UTC"|UTC)\s*$')).Count | Should -Be 3
    }

    It "groups both version and security updates into one PR per ecosystem area per update type" {
        $content = (Get-Content -Path $script:dependabotConfigPath -Raw) -replace "`r", ''

        # Parse line-by-line rather than with a single block regex so valid YAML
        # whitespace/reordering changes do not make this policy test brittle.
        $ecosystemBlocks = @{}
        $currentEcosystem = $null
        $currentLines = New-Object System.Collections.Generic.List[string]
        $contentLines = @($content -split "`n")

        foreach ($line in $contentLines) {
            $match = [System.Text.RegularExpressions.Regex]::Match(
                $line,
                '^\s*-\s*package-ecosystem:\s*"?(?<name>[A-Za-z0-9-]+)"?\s*$'
            )

            if ($match.Success) {
                if (-not [string]::IsNullOrWhiteSpace($currentEcosystem)) {
                    $ecosystemBlocks[$currentEcosystem] = ($currentLines -join "`n")
                }

                $currentEcosystem = $match.Groups['name'].Value
                $currentLines = New-Object System.Collections.Generic.List[string]
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($currentEcosystem)) {
                $currentLines.Add($line) | Out-Null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($currentEcosystem)) {
            $ecosystemBlocks[$currentEcosystem] = ($currentLines -join "`n")
        }

        foreach ($ecosystem in @('github-actions', 'pre-commit', 'devcontainers')) {
            $ecosystemBlocks.ContainsKey($ecosystem) | Should -BeTrue -Because "Missing ecosystem block for '$ecosystem'"
            $body = $ecosystemBlocks[$ecosystem]

            $body | Should -Match ('(?m)^\s*' + [System.Text.RegularExpressions.Regex]::Escape("$ecosystem-all") + ':\s*$')
            $body | Should -Match ('(?m)^\s*' + [System.Text.RegularExpressions.Regex]::Escape("$ecosystem-security") + ':\s*$')

            $allGroupPattern = '(?ms)^\s*' +
            [System.Text.RegularExpressions.Regex]::Escape("$ecosystem-all") +
            ':\s*(?<block>.*?)(?=^\s*' +
            [System.Text.RegularExpressions.Regex]::Escape("$ecosystem-security") +
            ':\s*|\z)'
            $allGroupMatch = [System.Text.RegularExpressions.Regex]::Match($body, $allGroupPattern)
            $allGroupMatch.Success | Should -BeTrue -Because "Version-updates group block must be parseable for '$ecosystem'"
            $allGroupBody = $allGroupMatch.Groups['block'].Value

            # Accept quoted and unquoted YAML scalar styles for forward compatibility.
            $allGroupBody | Should -Match '(?m)^\s*applies-to:\s*(?:"version-updates"|version-updates)\s*$'
            $allGroupBody | Should -Match '(?m)^\s*patterns:\s*$'
            $allGroupBody | Should -Match '(?m)^\s*-\s*"\*"\s*$'

            $securityGroupPattern = '(?ms)^\s*' +
            [System.Text.RegularExpressions.Regex]::Escape("$ecosystem-security") +
            ':\s*(?<block>.*)$'
            $securityGroupMatch = [System.Text.RegularExpressions.Regex]::Match($body, $securityGroupPattern)
            $securityGroupMatch.Success | Should -BeTrue -Because "Security-updates group block must be parseable for '$ecosystem'"
            $securityGroupBody = $securityGroupMatch.Groups['block'].Value

            $securityGroupBody | Should -Match '(?m)^\s*applies-to:\s*(?:"security-updates"|security-updates)\s*$'
            $securityGroupBody | Should -Match '(?m)^\s*patterns:\s*$'
            $securityGroupBody | Should -Match '(?m)^\s*-\s*"\*"\s*$'
        }
    }

    It "targets repository root directory for all configured ecosystems" {
        $content = (Get-Content -Path $script:dependabotConfigPath -Raw) -replace "`r", ''

        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*directory:\s*(?:"/"|/)\s*$')).Count | Should -Be 3
    }

    It "caps open version-update PR volume per ecosystem and keeps default branch behavior" {
        $content = (Get-Content -Path $script:dependabotConfigPath -Raw) -replace "`r", ''

        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*open-pull-requests-limit:\s*10\s*$')).Count | Should -Be 3
        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*separator:\s*"?/"?\s*$')).Count | Should -Be 3
        # Policy assumption: updates target the repository default branch.
        # If multi-branch release flows are introduced, this policy test should be updated.
        $content | Should -Not -Match '(?m)^\s*target-branch:\s*'
    }
}

Describe "Dependabot manifest coverage drift conventions" {
    It "requires explicit ecosystem coverage when common dependency manifests are introduced" {
        $content = (Get-Content -Path $script:dependabotConfigPath -Raw) -replace "`r", ''
        $ignoredDirectoryNames = @('.git', '.venv', '.cache', '.tox', '.pytest_cache', '.egg-info', '.bundle', '.dart_tool', '.flutter-plugins', 'node_modules', 'dist', 'build', 'venv', 'vendor', 'target', '__pycache__')
        $ignoredPathAlternation = (
            $ignoredDirectoryNames |
                ForEach-Object { [System.Text.RegularExpressions.Regex]::Escape($_) }
        ) -join '|'
        $ignoredPathPattern = "(?:^|[\\/])($ignoredPathAlternation)(?:[\\/]|$)"

        $manifestMappings = @(
            @{ Filter = 'package.json'; Ecosystem = 'npm' },
            @{ Filter = 'requirements*.txt'; Ecosystem = 'pip' },
            @{ Filter = 'pyproject.toml'; Ecosystem = 'pip' },
            @{ Filter = 'Pipfile'; Ecosystem = 'pip' },
            @{ Filter = 'poetry.lock'; Ecosystem = 'pip' },
            @{ Filter = 'Dockerfile'; Ecosystem = 'docker' },
            @{ Filter = 'docker-compose*.yml'; Ecosystem = 'docker-compose' },
            @{ Filter = 'docker-compose*.yaml'; Ecosystem = 'docker-compose' },
            @{ Filter = 'compose.yml'; Ecosystem = 'docker-compose' },
            @{ Filter = 'compose.yaml'; Ecosystem = 'docker-compose' },
            @{ Filter = 'go.mod'; Ecosystem = 'gomod' },
            @{ Filter = 'Cargo.toml'; Ecosystem = 'cargo' },
            @{ Filter = 'Gemfile'; Ecosystem = 'bundler' },
            @{ Filter = 'pom.xml'; Ecosystem = 'maven' },
            @{ Filter = 'build.gradle'; Ecosystem = 'gradle' },
            @{ Filter = 'build.gradle.kts'; Ecosystem = 'gradle' },
            @{ Filter = '*.csproj'; Ecosystem = 'nuget' }
        )

        $violations = New-Object System.Collections.Generic.List[string]
        $scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $scanMode = 'git-ls-files'
        $fallbackReason = ''

        try {
            $relativePaths = @(
                git -C $script:repoRoot ls-files --cached --others --exclude-standard 2>$null |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            )

            if ($LASTEXITCODE -ne 0) {
                throw "git ls-files exited with code $LASTEXITCODE"
            }

            $allRepoFiles = @(
                $relativePaths |
                    Where-Object { $_ -notmatch $ignoredPathPattern } |
                    ForEach-Object {
                        $absolutePath = Join-Path -Path $script:repoRoot -ChildPath $_
                        if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
                            Get-Item -LiteralPath $absolutePath -ErrorAction SilentlyContinue
                        }
                    } |
                    Where-Object { $null -ne $_ }
            )
        }
        catch {
            # Fallback keeps this guardrail operational even outside a git worktree while pruning ignored directories up-front.
            $scanMode = 'fallback-pruned-recursion'
            $fallbackReason = $_.Exception.Message
            $pendingDirectories = New-Object 'System.Collections.Generic.Queue[string]'
            $pendingDirectories.Enqueue($script:repoRoot)
            $collectedFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'

            while ($pendingDirectories.Count -gt 0) {
                $currentDirectory = $pendingDirectories.Dequeue()
                $entries = @(Get-ChildItem -Path $currentDirectory -Force -ErrorAction SilentlyContinue)

                foreach ($entry in $entries) {
                    if ($entry.PSIsContainer) {
                        if ($ignoredDirectoryNames -contains $entry.Name) {
                            continue
                        }

                        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                            continue
                        }

                        $pendingDirectories.Enqueue($entry.FullName)
                        continue
                    }

                    if ($entry -is [System.IO.FileInfo]) {
                        $collectedFiles.Add($entry) | Out-Null
                    }
                }
            }

            $allRepoFiles = @(
                $collectedFiles |
                    Sort-Object FullName
            )
        }

        $scanStopwatch.Stop()
        $scanDiagnostics = "scanMode={0}; repoFilesScanned={1}; manifestMappings={2}; scanElapsedMs={3}" -f $scanMode, $allRepoFiles.Count, $manifestMappings.Count, $scanStopwatch.ElapsedMilliseconds
        if (-not [string]::IsNullOrWhiteSpace($fallbackReason)) {
            $scanDiagnostics = "$scanDiagnostics; fallbackReason=$fallbackReason"
        }

        foreach ($mapping in $manifestMappings) {
            $foundFiles = @(
                $allRepoFiles |
                    Where-Object { $_.Name -like $mapping.Filter }
            )

            if ($foundFiles.Count -eq 0) {
                continue
            }

            $ecosystemPattern = '(?m)^\s*-\s*package-ecosystem:\s*"?' + [System.Text.RegularExpressions.Regex]::Escape($mapping.Ecosystem) + '"?\s*$'
            if ($content -match $ecosystemPattern) {
                continue
            }

            $sampleFiles = @(
                $foundFiles |
                    Select-Object -First 3 |
                    ForEach-Object { [System.IO.Path]::GetRelativePath($script:repoRoot, $_.FullName) }
            )

            $violations.Add(("{0} requires ecosystem '{1}' (matches={2}; example files: {3}; diagnostics: {4})" -f $mapping.Filter, $mapping.Ecosystem, $foundFiles.Count, ($sampleFiles -join '; '), $scanDiagnostics)) | Out-Null
        }

        $violations.Count | Should -Be 0 -Because (
            "When new dependency manifests are added, Dependabot must be extended deliberately. Diagnostics: {0}. Violations: {1}" -f $scanDiagnostics, ($violations -join ' | ')
        )
    }

    It "keeps configured ecosystems anchored to real manifests in this repository" {
        $githubWorkflowsPath = Join-Path -Path $script:repoRoot -ChildPath '.github/workflows'
        $githubWorkflowFiles = @(
            Get-ChildItem -Path $githubWorkflowsPath -Filter '*.yml' -File -ErrorAction SilentlyContinue
            Get-ChildItem -Path $githubWorkflowsPath -Filter '*.yaml' -File -ErrorAction SilentlyContinue
        )
        $githubWorkflowFiles.Count | Should -BeGreaterThan 0 -Because (
            "Dependabot ecosystem 'github-actions' requires workflow manifest files under .github/workflows"
        )

        Test-Path -Path (Join-Path -Path $script:repoRoot -ChildPath '.pre-commit-config.yaml') -PathType Leaf | Should -BeTrue -Because (
            "Dependabot ecosystem 'pre-commit' requires .pre-commit-config.yaml"
        )

        Test-Path -Path (Join-Path -Path $script:repoRoot -ChildPath '.devcontainer/devcontainer.json') -PathType Leaf | Should -BeTrue -Because (
            "Dependabot ecosystem 'devcontainers' requires .devcontainer/devcontainer.json"
        )
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
    It "keeps formatter settings and tab-normalization fail-fast diagnostics in Format-PowerShellFiles" {
        $formatterPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Format-PowerShellFiles.ps1"
        $formatterContent = Get-Content -Path $formatterPath -Raw

        $formatterContent | Should -Match '\.psscriptanalyzer\.format\.psd1'
        $formatterContent | Should -Match 'Get-LeadingTabIndentedLineNumbers'
        $formatterContent | Should -Match 'return\s*,\s*\$lineNumbers\.ToArray\(\)'
        $formatterContent | Should -Match "-split '\\r\?\\n'"
        $formatterContent | Should -Not -Match "-split '\\r\?\\n',\s*-1"
        $formatterContent | Should -Match 'E_FORMATTER_OUTPUT_INVALID'
        $formatterContent | Should -Match 'E_FORMATTER_TAB_INDENTATION_REMAINING'
        $formatterContent | Should -Match 'Formatter tab-normalization diagnostics:'
        $formatterContent | Should -Match 'Get-LineNumberPreview'

        $formatSettingsPath = Join-Path -Path $script:repoRoot -ChildPath '.psscriptanalyzer.format.psd1'
        $formatSettings = Get-Content -Path $formatSettingsPath -Raw
        $formatSettings | Should -Match 'PSUseConsistentIndentation'
        $formatSettings | Should -Match 'Kind\s*=\s*''space'''
        $formatSettings | Should -Match 'IndentationSize\s*=\s*4'
    }

    It "guards Invoke-Pester usage in Run-PreCommitValidation" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $content = Get-Content -Path $preCommitPath -Raw

        $content | Should -Match 'Get-CommandWithOptionalModuleImport\s+-CommandName\s+"Invoke-Pester"'
        $content | Should -Match 'E_CONFIG_ERROR:\s+Invoke-Pester is not available'
    }

    It "keeps Run-PreCommitValidation LLM harness telemetry low-noise" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $content = Get-Content -Path $preCommitPath -Raw

        $content | Should -Match 'Write-Host\s*\("Running LLM harness validation\.\.\. allMode='
        $content | Should -Match 'Write-Verbose\s*\(\s*"LLM harness trigger diagnostics:'
        $content | Should -Match 'Write-Verbose\s*\(\s*"Validation trigger summary:'
        $content | Should -Match 'Write-Verbose\s*\(\s*"LLM harness staged-file diagnostics:'
        $content | Should -Match 'Write-Verbose\s*"No staged files requiring utility validation; skipping validation\."'
        $content | Should -Not -Match 'Write-Host\s*\(\s*"LLM harness staged-file diagnostics:'
    }

    It "keeps Invoke-PesterQualityGate diagnostics low-noise" {
        $pesterGatePath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1"
        $content = Get-Content -Path $pesterGatePath -Raw

        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: version='
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: modulePath='
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: hasNewPesterConfiguration='
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: passed='
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: coverageProperties='
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: coveragePercent='
        $content | Should -Not -Match 'Write-Host\s*"\$DiagnosticsPrefix diagnostics:'
    }

    It "keeps cross-platform CIM and WMI guidance precise" {
        $crossPlatformDetailsPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/skill-details/cross-platform-powershell.md'
        $content = (Get-Content -Path $crossPlatformDetailsPath -Raw) -replace "`r", ''
        $windowsOnlySectionMatch = [regex]::Match(
            $content,
            '(?ms)^##\s+Avoiding\s+Windows-Only\s+APIs\s+And\s+Commands\s*$\n(?<section>.*?)(?=^##\s|\z)'
        )
        $windowsOnlySection = if ($windowsOnlySectionMatch.Success) { $windowsOnlySectionMatch.Groups['section'].Value } else { '' }

        $windowsOnlySectionMatch.Success | Should -BeTrue
        $windowsOnlySection | Should -Not -Match '(?im)^Commands and APIs that do not exist on Linux/macOS:\s*$'
        $windowsOnlySection | Should -Match '(?i)Get-WmiObject'
        $windowsOnlySection | Should -Match '(?i)Windows-only'
        $windowsOnlySection | Should -Match '(?i)Get-CimInstance'
        $windowsOnlySection | Should -Match '(?i)(provider-dependent|providers?\s+are\s+often\s+limited|often\s+limited)'
        $windowsOnlySection | Should -Not -Match '(?im)^\|\s*`Get-WmiObject`\s*/\s*`Get-CimInstance`\s*\|'
        $windowsOnlySection | Should -Match '(?im)^\|\s*`Get-WmiObject`[^|]*Windows-only'
        $windowsOnlySection | Should -Match '(?im)^\|\s*`Get-CimInstance`[^|]*(provider-dependent|limited)'
        $windowsOnlySection | Should -Match '(?i)\[System\.Windows\.Forms\]'
        $windowsOnlySection | Should -Match '(?i)Windows\s+UI\s+only'
        $windowsOnlySection | Should -Not -Match '(?i)\[System\.Windows\.Forms\][^\r\n|]*Not\s+available'
    }

    It "derives LLM harness trigger pattern from Wrapper Contract instead of hardcoded wrapper names" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $content = Get-Content -Path $preCommitPath -Raw

        $content | Should -Match 'LlmWrapperContractHelpers\.ps1'
        $content | Should -Not -Match 'function\s+Get-WrapperContractEntries\s*\{'
        $content | Should -Match 'function\s+New-LlmHarnessPattern\s*\{'
        $content | Should -Match '(?m)^\s*\$contextPath\s*=\s*Join-Path\s+-Path\s+\$repoRoot\s+-ChildPath\s+''\.llm/context\.md'''
        $content | Should -Match '\$llmHarnessWrapperFiles\s*=\s*@\(Get-WrapperContractEntries\s+-ContextFilePath\s+\$contextPath\)'
        $content | Should -Match 'LLM harness trigger diagnostics:'

        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Test-LlmHarness.ps1"
        $validatorContent = Get-Content -Path $validatorPath -Raw
        $validatorContent | Should -Match 'LlmWrapperContractHelpers\.ps1'
        $validatorContent | Should -Not -Match 'function\s+Get-WrapperContractEntries\s*\{'

        foreach ($wrapperFile in $script:wrapperContractFiles) {
            $content | Should -Match ([regex]::Escape($wrapperFile)) -Because "Fallback wrapper set should stay aligned with Wrapper Contract entries"
        }

        foreach ($phantomWrapper in @('GEMINI.md', 'CURSOR.md', 'OPENAI.md', 'CODEX.md')) {
            $content | Should -Not -Match ([regex]::Escape($phantomWrapper)) -Because "$phantomWrapper should never be hardcoded into LLM harness trigger logic"
        }
    }

    It "derives LLM harness fixture wrapper entries via shared helper in tests" {
        $llmHarnessTestsPath = Join-Path -Path $script:repoRoot -ChildPath "Tests/Utils/LlmHarness.Tests.ps1"
        $content = Get-Content -Path $llmHarnessTestsPath -Raw

        $content | Should -Match 'LlmWrapperContractHelpers\.ps1'
        $content | Should -Match '\$script:wrapperFiles\s*=\s*@\(Get-WrapperContractEntries\s+-ContextFilePath\s+\$script:contextPath\s+-DefaultFallback\s+@\(\)\)'
        $content | Should -Not -Match '\[System\.IO\.File\]::ReadLines\(\$script:contextPath,\s*\[System\.Text\.Encoding\]::UTF8\)'
        $content | Should -Match 'wrapperCount='
    }

    It "keeps docs-to-config consistency diagnostics in Test-LlmHarness" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Test-LlmHarness.ps1"
        $content = Get-Content -Path $validatorPath -Raw

        $content | Should -Match 'Dependabot/context diagnostics'
        $content | Should -Match 'Cross-platform command availability diagnostics'
        $content | Should -Match 'hasWindowsOnlySection'
        $content | Should -Match 'legacyNoExistHeader'
        $content | Should -Match 'hasGetWmiWindowsOnly'
        $content | Should -Match 'hasGetCimProviderLanguage'
        $content | Should -Match 'hasCimProviderCaveat'
        $content | Should -Match 'hasCombinedWmiCimTableRow'
        $content | Should -Match 'must not combine Get-WmiObject and Get-CimInstance'
        $content | Should -Match 'foreach\s*\(\$diagnostic\s+in\s+\$diagnostics\)\s*\{\s*Write-Verbose\s+\$diagnostic'
        $content | Should -Not -Match 'Write-Warning\s+\$warning'
        $content | Should -Match 'per\\s\+update\\s\+type'
        $content | Should -Match 'monday\\D\+03:00\\D\+utc'
        $content | Should -Match 'default\\s\+HFS\\\+'
        $content | Should -Match 'Case\\s\+Sensitivity\\s\+And\\s\+File\\s\+System\\s\+Differences'
        $content | Should -Match '\(\?<section>\.\*\?\)'
        $content | Should -Match '\\bAPFS\\b'
        $content | Should -Match 'Windows,\s*macOS,\s*and\s+Linux'
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

    It "uses literal path validation for Pandoc input directory" {
        $pandocPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/PandocConvertDirectory.ps1'
        $pandocContent = (Get-Content -Path $pandocPath -Raw) -replace "`r", ''

        $pandocContent | Should -Match 'ValidateScript\(\{\s*Test-Path\s+-LiteralPath\s+\$_\s+-PathType\s+''Container''\s*\}\)'
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
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                continue
            }

            $files = Get-ChildItem -LiteralPath $root -Filter "*.ps1" -File -Recurse -ErrorAction Stop
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

    It "enforces space indentation in PowerShell files" {
        $searchRoots = @(
            (Join-Path -Path $script:repoRoot -ChildPath "Scripts"),
            (Join-Path -Path $script:repoRoot -ChildPath "Tests")
        )

        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($root in $searchRoots) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                continue
            }

            $files = @(
                Get-ChildItem -LiteralPath $root -Filter "*.ps1" -File -Recurse -ErrorAction Stop
                Get-ChildItem -LiteralPath $root -Filter "*.psm1" -File -Recurse -ErrorAction Stop
                Get-ChildItem -LiteralPath $root -Filter "*.psd1" -File -Recurse -ErrorAction Stop
            )

            foreach ($file in $files) {
                $lines = @(Get-Content -Path $file.FullName)
                for ($index = 0; $index -lt $lines.Count; $index++) {
                    if ($lines[$index] -match '^(?: )*\t+') {
                        $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName)
                        $violations.Add("${relativePath}:$($index + 1)") | Out-Null
                    }
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "PowerShell files must use space indentation per .editorconfig. Violations: {0}" -f ($violations -join ', ')
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
                        }
                        catch {
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
                                        }
                                        catch {
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

Describe "UTF-8 encoding conventions" {
    It "uses no-BOM UTF-8 for all WriteAllText calls in production scripts" {
        $scriptsRoot = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        $scripts = Get-ChildItem -Path $scriptsRoot -Filter "*.ps1" -File -Recurse -ErrorAction Stop
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($scriptFile in $scripts) {
            $lines = @(Get-Content -Path $scriptFile.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'WriteAllText\(' -and $lines[$i] -match '\[System\.Text\.Encoding\]::UTF8') {
                    $relative = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                    $violations.Add("${relative}:$($i + 1)") | Out-Null
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "WriteAllText must use [System.Text.UTF8Encoding]::new(`$false) (no BOM) instead of [System.Text.Encoding]::UTF8 (emits BOM). Violations: {0}" -f ($violations -join ', ')
        )
    }
}

Describe "Skills index generation conventions" {
    It "includes a known-casing dictionary in ConvertTo-SkillTitle" {
        $indexGeneratorPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Update-LlmSkillsIndex.ps1"
        $content = Get-Content -Path $indexGeneratorPath -Raw

        $content | Should -Match 'function\s+ConvertTo-SkillTitle[\s\S]*\$knownCasing'
        $content | Should -Match '\$knownCasing\.ContainsKey\('
        foreach ($term in @("github", "powershell", "pr", "api", "ci", "llm")) {
            $content | Should -Match "`"$term`"\s*=" -Because "knownCasing dictionary must include '$term' to prevent incorrect title casing"
        }
    }
}

Describe "PowerShell return safety conventions" {
    It "does not use unsuppressed 'return @()' in production scripts" {
        $scriptsRoot = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        $scripts = Get-ChildItem -Path $scriptsRoot -Filter "*.ps1" -File -Recurse -ErrorAction Stop
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($scriptFile in $scripts) {
            $lines = @(Get-Content -Path $scriptFile.FullName)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '\breturn\s+@\(\)' -and $lines[$i] -notmatch '#\s*array-unwrap-safe') {
                    $relative = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                    $violations.Add("${relative}:$($i + 1)") | Out-Null
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "'return @()' silently returns `$null` instead of an empty array. Use 'return , @()' (comma operator) to preserve the array wrapper, or add '# array-unwrap-safe' if callers always wrap with @(). Violations: {0}" -f ($violations -join ', ')
        )

        $fullValidationPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-FullValidation.ps1"
        $fullValidation = Get-Content -Path $fullValidationPath -Raw
        $fullValidation | Should -Match 'function\s+Get-StatusSnapshot\b[\s\S]*?Sort-Object' -Because "Get-StatusSnapshot should keep deterministic sorting for stable drift comparisons."
        $fullValidation | Should -Match '\$invariantCultureName\s*=\s*\[System\.Globalization\.CultureInfo\]::InvariantCulture\.Name' -Because "Sort-Object -Culture should use an explicit culture name string to avoid binder ambiguity."
        $fullValidation | Should -Match 'function\s+Get-StatusSnapshot\b[\s\S]*?Sort-Object\s+-Culture\s+\$invariantCultureName' -Because "Get-StatusSnapshot should use an explicit invariant culture name string for deterministic sorting."
        $fullValidation | Should -Not -Match 'Sort-Object\s+-Culture\s+\(\[System\.Globalization\.CultureInfo\]::InvariantCulture\)' -Because "Sort-Object -Culture must not pass CultureInfo objects directly."
        $fullValidation | Should -Match 'function\s+Get-StatusSnapshot\b[\s\S]*?Write-Output\s+-NoEnumerate\s+\(' -Because "Get-StatusSnapshot must use Write-Output -NoEnumerate to preserve empty git-status snapshots as a typed string[] without extra array wrapping."
        $fullValidation | Should -Match 'if\s*\(\s*\$null\s*-eq\s*\$statusBeforeValidation\s*\)\s*\{\s*throw\s+"E_VALIDATION_STATUS_BEFORE_NULL' -Because "workspace drift comparison must guard null before-snapshot values with an explicit E_ code."
        $fullValidation | Should -Match 'if\s*\(\s*\$null\s*-eq\s*\$statusAfterValidation\s*\)\s*\{\s*throw\s+"E_VALIDATION_STATUS_AFTER_NULL' -Because "workspace drift comparison must guard null after-snapshot values with an explicit E_ code."
    }
}
