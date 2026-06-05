Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    function Resolve-CanonicalTempRoot {
        param([string]$Path)

        $resolvedItem = Get-Item -LiteralPath $Path -ErrorAction Stop
        return $resolvedItem.FullName
    }

    function Get-RequiredFunctionDefinitionAst {
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.Language.Ast]$Ast,

            [Parameter(Mandatory = $true)]
            [string]$Name,

            [Parameter(Mandatory = $true)]
            [string]$Context
        )

        $matches = @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
                }, $true))

        if ($matches.Count -ne 1) {
            throw "E_CONFIG_ERROR: Expected exactly one function '$Name' for $Context; found $($matches.Count)."
        }

        return $matches[0]
    }

    function Test-IsSelectObjectFirstOneCommandAst {
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.Language.CommandAst]$CommandAst
        )

        $commandName = $CommandAst.GetCommandName()
        if ($commandName -notin @("Select-Object", "Select")) {
            return $false
        }

        $sawFirstParameter = $false
        foreach ($element in @($CommandAst.CommandElements | Select-Object -Skip 1)) {
            if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) {
                return $true
            }

            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $parameterName = $element.ParameterName
                if (-not [string]::IsNullOrWhiteSpace($parameterName) -and "First".StartsWith($parameterName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ($null -ne $element.Argument) {
                        return ($element.Argument.Extent.Text -eq "1")
                    }

                    $sawFirstParameter = $true
                    continue
                }

                $sawFirstParameter = $false
                continue
            }

            if ($sawFirstParameter) {
                return ($element.Extent.Text -eq "1")
            }
        }

        return $false
    }

    function Test-HasFunctionDefinitionAstTypeReference {
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.Language.Ast]$Ast
        )

        return @($Ast.FindAll({
                    param($node)
                    if (-not ($node -is [System.Management.Automation.Language.TypeExpressionAst])) {
                        return $false
                    }

                    return ($node.TypeName.FullName -eq "System.Management.Automation.Language.FunctionDefinitionAst" -or
                        $node.TypeName.Name -eq "FunctionDefinitionAst")
                }, $true)).Count -gt 0
    }

    function Get-GitHubWorkflowStepBlocks {
        param(
            [Parameter(Mandatory = $true)]
            [string]$WorkflowContent,

            [Parameter(Mandatory = $true)]
            [string]$StepName
        )

        $normalized = $WorkflowContent -replace "`r", ''
        $escapedName = [regex]::Escape($StepName)
        $stepBlocks = [regex]::Split($normalized, '(?m)^(?=\s*-\s+name:\s)')
        return @($stepBlocks | Where-Object { $_ -match "(?m)^[^\S\r\n]*-[^\S\r\n]+name:[^\S\r\n]+$escapedName[^\S\r\n]*$" }) # array-unwrap-safe
    }

    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    . (Join-Path -Path $PSScriptRoot -ChildPath "../../Scripts/Utils/Common/CompatibilityHelpers.ps1")
    $script:migratedScripts = @(
        "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1",
        "Scripts/Utils/BackupDxMessaging.ps1",
        "Scripts/Utils/FormatPowershellScripts.ps1",
        "Scripts/Utils/PandocConvertDirectory.ps1",
        "Scripts/Utils/Increment-Version.ps1"
    )
    $script:workflowPath = Join-Path -Path $script:repoRoot -ChildPath ".github/workflows/github-pr-summarizer-quality.yml"
    $script:crossLanguageWorkflowPath = Join-Path -Path $script:repoRoot -ChildPath ".github/workflows/script-quality.yml"
    $script:devcontainerWorkflowPath = Join-Path -Path $script:repoRoot -ChildPath ".github/workflows/devcontainer-validate.yml"
    $script:dependabotConfigPath = Join-Path -Path $script:repoRoot -ChildPath ".github/dependabot.yml"
    $script:llmContextPath = Join-Path -Path $script:repoRoot -ChildPath ".llm/context.md"
    $script:preCommitConfigPath = Join-Path -Path $script:repoRoot -ChildPath ".pre-commit-config.yaml"
    $script:preCommitHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-commit"
    $script:prePushHookPath = Join-Path -Path $script:repoRoot -ChildPath ".githooks/pre-push"
    $script:qualityPowerShellScripts = @(
        "Scripts/Utils/Common/GitHookRegistrationHelpers.ps1",
        "Scripts/Utils/Common/PreCommitCliHelpers.ps1",
        "Scripts/Utils/Common/QualityToolingHelpers.ps1",
        "Scripts/Utils/Quality/Assert-CleanGitTree.ps1",
        "Scripts/Utils/Quality/Format-PowerShellFiles.ps1",
        "Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1",
        "Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1",
        "Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1",
        "Scripts/Utils/Quality/Invoke-GitPushWithUpstream.ps1",
        "Scripts/Utils/Quality/Invoke-PrePushPreCommitValidation.ps1",
        "Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1",
        "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1",
        "Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1"
    )
    $script:qualityConfigFiles = @(
        ".pre-commit-config.yaml",
        ".editorconfig",
        ".psscriptanalyzer.format.psd1",
        ".psscriptanalyzer.psd1",
        ".shellcheckrc",
        ".stylua.toml",
        "requirements.txt",
        "Scripts/Utils/Quality/native-quality-tools.json"
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

Describe "PowerShell test harness conventions" {
    It "does not truncate FunctionDefinitionAst matches before exact-cardinality assertions" {
        $testsRoot = Join-Path -Path $script:repoRoot -ChildPath "Tests"
        $testFiles = @(Get-ChildItem -Path $testsRoot -Filter "*.ps1" -File -Recurse -ErrorAction Stop)
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($testFile in $testFiles) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($testFile.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count -gt 0) {
                continue
            }

            $functionAstMatchVariables = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $functionAstAssignments = @($ast.FindAll({
                        param($node)
                        if (-not ($node -is [System.Management.Automation.Language.AssignmentStatementAst])) {
                            return $false
                        }

                        if (-not ($node.Left -is [System.Management.Automation.Language.VariableExpressionAst])) {
                            return $false
                        }

                        return (Test-HasFunctionDefinitionAstTypeReference -Ast $node.Right)
                    }, $true))

            foreach ($assignment in $functionAstAssignments) {
                $variableName = $assignment.Left.VariablePath.UserPath
                if (-not [string]::IsNullOrWhiteSpace($variableName)) {
                    [void]$functionAstMatchVariables.Add($variableName)
                }
            }

            $violatingPipelines = @($ast.FindAll({
                        param($node)
                        if (-not ($node -is [System.Management.Automation.Language.PipelineAst])) {
                            return $false
                        }

                        $hasSelectFirstOne = $false
                        foreach ($pipelineElement in $node.PipelineElements) {
                            if ($pipelineElement -is [System.Management.Automation.Language.CommandAst] -and
                                (Test-IsSelectObjectFirstOneCommandAst -CommandAst $pipelineElement)) {
                                $hasSelectFirstOne = $true
                                break
                            }
                        }

                        if ($hasSelectFirstOne) {
                            foreach ($pipelineElement in $node.PipelineElements) {
                                $variableReferences = @($pipelineElement.FindAll({
                                            param($innerNode)
                                            if (-not ($innerNode -is [System.Management.Automation.Language.VariableExpressionAst])) {
                                                return $false
                                            }

                                            return $functionAstMatchVariables.Contains($innerNode.VariablePath.UserPath)
                                        }, $true))

                                if ($variableReferences.Count -gt 0) {
                                    return $true
                                }
                            }
                        }

                        if (-not $hasSelectFirstOne) {
                            return $false
                        }

                        return (Test-HasFunctionDefinitionAstTypeReference -Ast $node)
                    }, $true))

            foreach ($pipeline in $violatingPipelines) {
                $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $testFile.FullName
                $portableRelativePath = $relativePath -replace '\\', '/'
                $violations.Add("${portableRelativePath}:$($pipeline.Extent.StartLineNumber)") | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "FunctionDefinitionAst extraction tests must collect all matches and assert Count -eq 1 before dot-sourcing or inspecting a function. Violations: {0}" -f ($violations -join ", ")
        )
    }
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
                        $relative = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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

    It "keeps unresolved-thread JSON output schema lower-camel and array-stable" {
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $scriptContent = Get-Content -Path $scriptPath -Raw
        $testsPath = Join-Path -Path $script:repoRoot -ChildPath "Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1"
        $testsContent = Get-Content -Path $testsPath -Raw

        $convertRecordFunctionMatch = [regex]::Match($scriptContent, 'function\s+Convert-ReviewThreadToOutputRecord\s*\{(?<body>[\s\S]*?)^\}', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $convertRecordFunctionMatch.Success | Should -BeTrue -Because "Convert-ReviewThreadToOutputRecord must exist so output key casing can be validated"
        $convertRecordFunctionBody = $convertRecordFunctionMatch.Groups["body"].Value

        $lowerPathMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*path\s*=\s*\$outputLocation\.Path\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $lowerLocationSourceMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*locationSource\s*=\s*\$outputLocation\.Source\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $lowerGitHubPathMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*githubPath\s*=\s*\$safePath\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $lowerGitHubLineStartMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*githubLineStart\s*=\s*\$githubAnchor\.Start\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $lowerGitHubLineEndMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*githubLineEnd\s*=\s*\$githubAnchor\.End\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $lowerEmbeddedLocationsMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*embeddedLocations\s*=\s*@\(\$embeddedLocations\)\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $lowerOwnerMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*owner\s*=\s*\$Owner\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $lowerRepoMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*repo\s*=\s*\$Repo\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        # Lowercase checks enforce exact contract values; uppercase checks intentionally
        # match any uppercase assignment so any PascalCase regression is caught.
        $upperPathMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*Path\s*=', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $upperOwnerMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*Owner\s*=', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $upperRepoMatches = [regex]::Matches($convertRecordFunctionBody, '^\s*Repo\s*=', [System.Text.RegularExpressions.RegexOptions]::Multiline)

        $lowerPathMatches.Count | Should -Be 1
        $lowerLocationSourceMatches.Count | Should -Be 1
        $lowerGitHubPathMatches.Count | Should -Be 1
        $lowerGitHubLineStartMatches.Count | Should -Be 1
        $lowerGitHubLineEndMatches.Count | Should -Be 1
        $lowerEmbeddedLocationsMatches.Count | Should -Be 1
        $lowerOwnerMatches.Count | Should -Be 1
        $lowerRepoMatches.Count | Should -Be 1
        $upperPathMatches.Count | Should -Be 0
        $upperOwnerMatches.Count | Should -Be 0
        $upperRepoMatches.Count | Should -Be 0

        # Array-stable singleton output is preserved via ConvertTo-JsonArrayCompat, the
        # cross-version replacement for `ConvertTo-Json -AsArray` (absent on Windows
        # PowerShell 5.1).
        $scriptContent | Should -Match 'function\s+Format-UnresolvedThreadsAsJson[\s\S]*ConvertTo-JsonArrayCompat\s+-InputObject\s+\$Records\s+-Depth\s+8'

        $testsContent | Should -Match 'Format-UnresolvedThreadsAsJson'
        $testsContent | Should -Match '\(\$propertyNames\s+-ccontains\s+"path"\)\s+\|\s+Should\s+-BeTrue'
        $testsContent | Should -Match '\(\$propertyNames\s+-ccontains\s+"Path"\)\s+\|\s+Should\s+-BeFalse'
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

    It "keeps PowerShell argument metadata cross-version safe for unresolved PR comments" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $fullPath -Raw

        # OutputFormat must use [ValidateSet] (validation + completion, works on both
        # Windows PowerShell 5.1 and PowerShell 7+) rather than the 7+-only
        # [ArgumentCompletions] attribute.
        $content | Should -Match '\[ValidateSet\("text",\s*"json"\)\]'
        # [ArgumentCompletions] is a PowerShell 7+ attribute that fails to parse on
        # Windows PowerShell 5.1 and must not be reintroduced.
        $content | Should -Not -Match '\[ArgumentCompletions\('
    }

    It "keeps Increment-Version direct-run invocation guard" {
        $incrementPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Increment-Version.ps1"
        $incrementContent = Get-Content -Path $incrementPath -Raw

        $incrementContent | Should -Match 'if\s*\(\$MyInvocation\.InvocationName\s*-ne\s*"\."\)\s*\{\s*Increment-Version\s+@args\s*\}'
    }
}

Describe "CI scope expansion" {
    It "keeps the GitHub utility workflow narrowed to GitHub utility coverage" {
        $workflow = Get-Content -Path $script:workflowPath -Raw

        $workflow | Should -Match 'Scripts/Utils/GitHub/\*\*'
        $workflow | Should -Match 'Tests/GitHub/\*\*'
        $workflow | Should -Match 'Scripts/Utils/Common/StrictModeHelpers\.ps1'
        $workflow | Should -Match 'Invoke-PesterQualityGate\.ps1'
        $workflow | Should -Match 'runs-on:\s+ubuntu-latest'
        $workflow | Should -Not -Match 'matrix:'
        $workflow | Should -Not -Match 'windows-latest|macos-latest'
        $workflow | Should -Not -Match '(?m)^\s*-\s+"Scripts/\*\*"'
        $workflow | Should -Not -Match '(?m)^\s*-\s+"Tests/\*\*"'
        $workflow | Should -Not -Match '\.githooks/pre-commit|\.githooks/pre-push|\.shellcheckrc|\.stylua\.toml'
        $workflow | Should -Not -Match 'Invoke-ScriptAnalyzer|PSScriptAnalyzer|Run Utils Pester tests|Tests/Utils'
        $workflow | Should -Not -Match 'Security pattern checks|Generated artifact tracking checks|scanner_engine='
    }

    It "triggers GitHub utility coverage when dot-sourced common helpers change" {
        $workflow = Get-Content -Path $script:workflowPath -Raw
        $githubUtilityPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $githubUtility = Get-Content -Path $githubUtilityPath -Raw

        $githubUtility | Should -Match 'Common/StrictModeHelpers\.ps1'
        $githubUtility | Should -Match 'Common/CompatibilityHelpers\.ps1'
        $workflow | Should -Match 'Scripts/Utils/Common/StrictModeHelpers\.ps1'
        $workflow | Should -Match 'Scripts/Utils/Common/CompatibilityHelpers\.ps1'
    }

    It "keeps robust Pester CI workflow wiring: <Name>" -TestCases @(
        @{
            Name    = "coverage step invokes shared gate script"
            Pattern = 'Run GitHub utility Pester with coverage[\s\S]*Invoke-PesterQualityGate\.ps1'
        }
        @{
            Name    = "coverage step passes coverage gate arguments"
            Pattern = 'Run GitHub utility Pester with coverage[\s\S]*-EnableCoverage[\s\S]*-CoveragePath\s+\$coveragePath[\s\S]*-MinimumCoveragePercent\s+75'
        }
        @{
            Name    = "coverage step writes XML result artifact"
            Pattern = 'Run GitHub utility Pester with coverage[\s\S]*testresults-github\.xml[\s\S]*-TestResultOutputPath\s+\$testResultPath'
        }
        @{
            Name    = "coverage step uses explicit timeout"
            Pattern = 'Run GitHub utility Pester with coverage[\s\S]*timeout-minutes:\s+10'
        }
        @{
            Name    = "coverage step fails clearly when gate script is missing"
            Pattern = 'Run GitHub utility Pester with coverage[\s\S]*if\s*\(\s*-not\s*\(Test-Path\s+-Path\s+\$pesterGateScript\s+-PathType\s+Leaf\)\s*\)[\s\S]*E_CI_PESTER_GATE_SCRIPT_MISSING'
        }
        @{
            Name    = "coverage step passes scoped diagnostics prefix"
            Pattern = 'Run GitHub utility Pester with coverage[\s\S]*-DiagnosticsPrefix\s+"GitHub Utility Pester"'
        }
        @{
            Name    = "workflow uploads only GitHub XML result artifact"
            Pattern = 'Upload Pester test results[\s\S]*if:\s+always\(\)[\s\S]*actions/upload-artifact@v4\.6\.2[\s\S]*testresults-github\.xml'
        }
    ) {
        param($Name, $Pattern)

        $workflow = Get-Content -Path $script:workflowPath -Raw
        $workflow | Should -Match $Pattern -Because $Name
    }

    It "keeps shared Pester quality gate script contract: <Name>" -TestCases @(
        @{
            Name    = "sources shared module helper"
            Pattern = 'Common/ModuleHelpers\.ps1'
        }
        @{
            Name    = "resolves Invoke-Pester via shared helper with minimum supported version"
            Pattern = 'Get-CommandWithOptionalModuleImport\s+-CommandName\s+"Invoke-Pester"\s+-ModuleName\s+"Pester"\s+-MinimumVersion\s+\$minimumPesterVersion'
        }
        @{
            Name    = "reports installed Pester versions in diagnostics"
            Pattern = 'Get-AvailableModuleVersionsText\s+-ModuleName\s+"Pester"'
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
            Name    = "fails with explicit discovery container diagnostic"
            Pattern = 'E_CI_PESTER_DISCOVERY_FAILED'
        }
        @{
            Name    = "fails with explicit zero-discovery diagnostic"
            Pattern = 'E_CI_PESTER_NO_TESTS_DISCOVERED'
        }
        @{
            Name    = "emits discovery count diagnostics"
            Pattern = 'diagnostics: total=\$totalCount failedContainers=\$failedContainersCount result=\$resultState'
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
        @{
            Name    = "supports XML test result artifact output"
            Pattern = '\$TestResultOutputPath[\s\S]*TestResult\.Enabled\s*=\s*\$true[\s\S]*TestResult\.OutputPath\s*=\s*\$TestResultOutputPath'
        }
    ) {
        param($Name, $Pattern)

        $pesterGateScriptPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1'
        $pesterGateScript = Get-Content -Path $pesterGateScriptPath -Raw
        $pesterGateScript | Should -Match $Pattern -Because $Name
    }

    It "routes cross-version PowerShell workflow tests through the shared Pester gate" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw

        $workflow | Should -Match 'Run Pester suite under Windows PowerShell 5\.1[\s\S]*timeout-minutes:\s+10'
        $workflow | Should -Match 'Run Pester suite under Windows PowerShell 5\.1[\s\S]*Invoke-PesterQualityGate\.ps1[\s\S]*-OutputVerbosity\s+None[\s\S]*-TestResultOutputPath\s+"testresults-winps51\.xml"'
        $workflow | Should -Match 'Run Pester suite under PowerShell 7\+[\s\S]*timeout-minutes:\s+10'
        $workflow | Should -Match 'Run Pester suite under PowerShell 7\+[\s\S]*Invoke-PesterQualityGate\.ps1[\s\S]*-OutputVerbosity\s+None[\s\S]*-TestResultOutputPath\s+"testresults-pwsh7\.xml"'
        $workflow | Should -Match 'Windows PowerShell 5\.1 Pester duration: \$elapsedSeconds seconds'
        $workflow | Should -Match 'PowerShell 7\+ Pester duration: \$elapsedSeconds seconds'
    }

    It "keeps each Pester XML artifact upload bound to its own always-run step" {
        $crossLanguageWorkflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw
        $prSummarizerWorkflow = Get-Content -Path $script:workflowPath -Raw

        $crossLanguageUploadBlocks = @(Get-GitHubWorkflowStepBlocks -WorkflowContent $crossLanguageWorkflow -StepName 'Upload test results')
        $winPsUploadBlocks = @($crossLanguageUploadBlocks | Where-Object { $_ -match '(?m)^[^\S\r\n]*name:[^\S\r\n]+pester-winps51[^\S\r\n]*$' })
        $pwshUploadBlocks = @($crossLanguageUploadBlocks | Where-Object { $_ -match '(?m)^[^\S\r\n]*name:[^\S\r\n]+pester-pwsh7[^\S\r\n]*$' })

        $winPsUploadBlocks.Count | Should -Be 1 -Because 'The Windows PowerShell 5.1 Pester artifact upload step should be uniquely identifiable.'
        $pwshUploadBlocks.Count | Should -Be 1 -Because 'The PowerShell 7+ Pester artifact upload step should be uniquely identifiable.'
        $winPsUploadBlocks[0] | Should -Match '(?m)^[^\S\r\n]*if:[^\S\r\n]+always\(\)[^\S\r\n]*$'
        $winPsUploadBlocks[0] | Should -Match '(?m)^[^\S\r\n]*path:[^\S\r\n]+testresults-winps51\.xml[^\S\r\n]*$'
        $pwshUploadBlocks[0] | Should -Match '(?m)^[^\S\r\n]*if:[^\S\r\n]+always\(\)[^\S\r\n]*$'
        $pwshUploadBlocks[0] | Should -Match '(?m)^[^\S\r\n]*path:[^\S\r\n]+testresults-pwsh7\.xml[^\S\r\n]*$'

        $prUploadBlocks = @(Get-GitHubWorkflowStepBlocks -WorkflowContent $prSummarizerWorkflow -StepName 'Upload Pester test results')
        $prUploadBlocks.Count | Should -Be 1 -Because 'The PR summarizer Pester artifact upload step should be uniquely identifiable.'
        $prUploadBlocks[0] | Should -Match '(?m)^[^\S\r\n]*if:[^\S\r\n]+always\(\)[^\S\r\n]*$'
        $prUploadBlocks[0] | Should -Match '(?m)^[^\S\r\n]*(path:[^\S\r\n]+)?testresults-github\.xml[^\S\r\n]*$'
        $prUploadBlocks[0] | Should -Not -Match 'testresults-utils\.xml'
    }

    It "forbids fragile Pester type literals across all GitHub workflows" {
        $workflowFiles = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath '.github/workflows') -Filter '*.yml' -File -Recurse -ErrorAction Stop)
        $workflowFiles.Count | Should -BeGreaterThan 0 -Because 'Expected at least one GitHub workflow file in .github/workflows.'

        foreach ($workflowFile in $workflowFiles) {
            $workflow = Get-Content -Path $workflowFile.FullName -Raw
            $workflow | Should -Not -Match '\[PesterConfiguration\]::Default' -Because "$($workflowFile.Name) must use New-PesterConfiguration to avoid module type-loading fragility."
        }
    }

    It "forbids direct Invoke-Pester workflow calls outside the shared quality gate" {
        $workflowFiles = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath '.github/workflows') -Filter '*.yml' -File -Recurse -ErrorAction Stop)
        $workflowFiles.Count | Should -BeGreaterThan 0 -Because 'Expected at least one GitHub workflow file in .github/workflows.'

        foreach ($workflowFile in $workflowFiles) {
            $workflow = Get-Content -Path $workflowFile.FullName -Raw
            $workflow | Should -Not -Match '(?<![\w.-])(?:[A-Za-z0-9_.-]+\\)?Invoke-Pester(?!QualityGate)(?![\w.-])' -Because "$($workflowFile.Name) must route Pester through Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1."
        }
    }
}

Describe "Workflow PowerShell module bootstrap routing" {
    It "forbids inline gallery/module bootstrap in workflow YAML: <Label>" -TestCases @(
        @{ Label = 'Set-PSRepository'; Pattern = '(?m)^\s*Set-PSRepository\b' }
        @{ Label = 'Register-PSRepository'; Pattern = '(?m)^\s*Register-PSRepository\b' }
        @{ Label = 'Get-PackageProvider'; Pattern = '(?m)^\s*Get-PackageProvider\b' }
        @{ Label = 'Install-Module Pester'; Pattern = '(?m)^\s*Install-Module\b[^\r\n]*\bPester\b' }
        @{ Label = 'Install-Module PSScriptAnalyzer'; Pattern = '(?m)^\s*Install-Module\b[^\r\n]*\bPSScriptAnalyzer\b' }
    ) {
        param($Label, $Pattern)

        # Scope strictly to .github/workflows/*.yml. The shared bootstrap helper
        # (Install-PowerShellQualityModules.ps1) and ModuleHelpers.ps1 legitimately
        # contain Set-PSRepository / Register-PSRepository / Install-Module and must
        # never be flagged; directory-scoping is the clean allowlist.
        $workflowFiles = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath '.github/workflows') -Filter '*.yml' -File -Recurse -ErrorAction Stop)
        $workflowFiles.Count | Should -BeGreaterThan 0 -Because 'Expected at least one GitHub workflow file in .github/workflows.'

        foreach ($workflowFile in $workflowFiles) {
            $normalized = (Get-Content -Path $workflowFile.FullName -Raw) -replace "`r", ''
            $normalized | Should -Not -Match $Pattern -Because "$($workflowFile.Name) must route module installation through Install-PowerShellQualityModules.ps1 instead of inline $Label."
        }
    }

    It "requires module-consuming workflow lanes to route through the shared bootstrap script: <Name>" -TestCases @(
        @{ Name = 'cross-language quality workflow'; Path = '.github/workflows/script-quality.yml' }
        @{ Name = 'pr summarizer quality workflow'; Path = '.github/workflows/github-pr-summarizer-quality.yml' }
    ) {
        param($Name, $Path)

        $workflowFullPath = Join-Path -Path $script:repoRoot -ChildPath $Path
        $raw = (Get-Content -Path $workflowFullPath -Raw) -replace "`r", ''
        $raw | Should -Match 'Install-PowerShellQualityModules\.ps1' -Because "$Name must invoke the shared module bootstrap script."
    }

    It "writes GITHUB_OUTPUT UTF-8 no-BOM in Windows PowerShell 5.1 steps (shell: powershell)" {
        # Windows PowerShell 5.1 (shell: powershell, NOT pwsh) routes the '>' / '>>' redirection
        # operators and Out-File through UTF-16LE, and 'Out-File -Encoding utf8' prepends a UTF-8
        # BOM. GitHub Actions reads $GITHUB_OUTPUT as UTF-8, so either form corrupts the key=value
        # line and silently breaks the step output (here: the actions/cache module path -> a broken
        # or failing cache step). WinPS 5.1 steps must write GITHUB_OUTPUT via the no-BOM idiom:
        #   [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "...`n", [System.Text.UTF8Encoding]::new($false))
        # PowerShell 7+ (shell: pwsh) defaults to UTF-8 no-BOM, so '>>' under shell: pwsh stays allowed.
        $workflowFiles = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath '.github/workflows') -Filter '*.yml' -File -Recurse -ErrorAction Stop)
        $workflowFiles.Count | Should -BeGreaterThan 0 -Because 'Expected at least one GitHub workflow file in .github/workflows.'

        foreach ($workflowFile in $workflowFiles) {
            $normalized = (Get-Content -Path $workflowFile.FullName -Raw) -replace "`r", ''

            # Split into per-step blocks at YAML list-item boundaries so each step's shell is
            # evaluated in isolation (a step's shell directive does not leak to sibling steps).
            $stepBlocks = [regex]::Split($normalized, '(?m)^(?=\s*-\s+name:\s)')
            foreach ($stepBlock in $stepBlocks) {
                if ($stepBlock -notmatch '(?m)^\s*shell:\s*powershell\s*$') { continue }

                $offendingLines = @(
                    ($stepBlock -split "`n") | Where-Object {
                        $_ -match '>\s*\$env:GITHUB_OUTPUT' -or ($_ -match '\bOut-File\b' -and $_ -match 'GITHUB_OUTPUT')
                    }
                )

                $offendingLines.Count | Should -Be 0 -Because "$($workflowFile.Name): a Windows PowerShell 5.1 step (shell: powershell) writes GITHUB_OUTPUT via redirection/Out-File (UTF-16LE/BOM corruption). Use [System.IO.File]::AppendAllText(`$env:GITHUB_OUTPUT, ..., [System.Text.UTF8Encoding]::new(`$false)). Offending: $($offendingLines.ForEach({ $_.Trim() }) -join ' | ')"
            }
        }
    }

    It "resolves module-cache paths with the UTF-8 no-BOM GITHUB_OUTPUT idiom: <Name>" -TestCases @(
        @{ Name = 'winps51 lane'; StepName = 'Resolve Windows PowerShell 5.1 user module path' }
        @{ Name = 'pwsh7 lane'; StepName = 'Resolve PowerShell 7+ user module path' }
    ) {
        param($Name, $StepName)

        $raw = (Get-Content -Path $script:crossLanguageWorkflowPath -Raw) -replace "`r", ''
        $escapedName = [regex]::Escape($StepName)
        $raw | Should -Match $escapedName -Because "Expected the '$StepName' step to exist."

        # Isolate the named step block (up to the next list item or end of file).
        $stepBlock = [regex]::Match($raw, "(?ms)-\s+name:\s*$escapedName\b.*?(?=^\s*-\s+name:\s|\z)").Value
        $stepBlock | Should -Match '\[System\.IO\.File\]::AppendAllText\(\s*\$env:GITHUB_OUTPUT' -Because "$Name must write GITHUB_OUTPUT via [System.IO.File]::AppendAllText for UTF-8 no-BOM safety."
        $stepBlock | Should -Match '\[System\.Text\.UTF8Encoding\]::new\(\s*\$false\s*\)' -Because "$Name must use a BOM-free UTF-8 encoding."
        $stepBlock | Should -Not -Match '>\s*\$env:GITHUB_OUTPUT' -Because "$Name must not use '>'/'>>' redirection to GITHUB_OUTPUT."
    }
}

Describe "Cross-language quality platform conventions" {
    It "defines a pinned pre-commit configuration with required hook coverage" {
        $preCommitConfig = Get-Content -Path $script:preCommitConfigPath -Raw

        $preCommitConfig | Should -Match 'repo:\s+https://github\.com/pre-commit/pre-commit-hooks'
        $preCommitConfig | Should -Not -Match 'repo:\s+https://github\.com/scop/pre-commit-shfmt'
        $preCommitConfig | Should -Not -Match 'repo:\s+https://github\.com/shellcheck-py/shellcheck-py'
        $preCommitConfig | Should -Not -Match 'shfmt[-_]py|shfmt-binary'
        $preCommitConfig | Should -Not -Match 'repo:\s+https://github\.com/JohnnyMorganz/StyLua'
        $preCommitConfig | Should -Not -Match 'repo:\s+https://github\.com/rhysd/actionlint'
        $preCommitConfig | Should -Not -Match 'mirrors-prettier|prettier-yaml'
        $preCommitConfig | Should -Match 'rev:\s+v\d+\.\d+\.\d+'

        $preCommitConfig | Should -Match 'id:\s+check-json'
        $preCommitConfig | Should -Match 'id:\s+check-yaml'
        $preCommitConfig | Should -Match 'id:\s+pretty-format-json'
        $preCommitConfig | Should -Match 'id:\s+powershell-format'
        $preCommitConfig | Should -Match 'id:\s+shellcheck'
        $preCommitConfig | Should -Match 'id:\s+shfmt'
        $preCommitConfig | Should -Match 'id:\s+stylua'
        $preCommitConfig | Should -Match 'id:\s+actionlint'

        $preCommitConfig | Should -Match 'id:\s+shfmt[\s\S]*entry:\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+Scripts/Utils/Quality/Invoke-ShellQualityChecks\.ps1\s+-Tool\s+shfmt\s+-Fix'
        $preCommitConfig | Should -Match 'id:\s+shellcheck[\s\S]*entry:\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+Scripts/Utils/Quality/Invoke-ShellQualityChecks\.ps1\s+-Tool\s+shellcheck'
        $preCommitConfig | Should -Match 'id:\s+stylua[\s\S]*entry:\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+Scripts/Utils/Quality/Invoke-NativeQualityChecks\.ps1\s+-Tool\s+stylua\s+-Fix'
        $preCommitConfig | Should -Match 'id:\s+actionlint[\s\S]*entry:\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+Scripts/Utils/Quality/Invoke-NativeQualityChecks\.ps1\s+-Tool\s+actionlint'
        $preCommitConfig | Should -Match 'id:\s+shfmt[\s\S]*language:\s+system'
        $preCommitConfig | Should -Match 'id:\s+shellcheck[\s\S]*language:\s+system'
        $preCommitConfig | Should -Match 'id:\s+stylua[\s\S]*language:\s+system'
        $preCommitConfig | Should -Match 'id:\s+actionlint[\s\S]*language:\s+system'
        $preCommitConfig | Should -Not -Match '(?m)^\s*entry:\s+(shfmt|shellcheck|stylua|actionlint)\b' -Because 'native hooks must resolve repo-managed pinned tools instead of relying on PATH.'

        $preCommitConfig | Should -Match 'id:\s+powershell-format[\s\S]*stages:\s+\[pre-commit\]'
        $preCommitConfig | Should -Match 'id:\s+powershell-precommit-validation'
        $preCommitConfig | Should -Match 'id:\s+powershell-prepush-validation'
        $preCommitConfig | Should -Match 'id:\s+powershell-prepush-validation[\s\S]*entry:\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+Scripts/Utils/Quality/Invoke-PrePushPreCommitValidation\.ps1'
        $preCommitConfig | Should -Match 'id:\s+powershell-prepush-validation[\s\S]*pass_filenames:\s+true'
        $preCommitConfig | Should -Not -Match 'id:\s+powershell-prepush-validation[\s\S]*Run-PreCommitValidation\.ps1\s+-All'
        $preCommitConfig | Should -Not -Match 'id:\s+powershell-prepush-validation[\s\S]*entry:\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+Scripts/Utils/Run-PreCommitValidation\.ps1\s+-TargetFiles' -Because (
            "pwsh -File only binds the first pre-commit filename to a named array parameter; the wrapper must capture filenames positionally and splat them as one array."
        )
        $preCommitConfig | Should -Match 'stages:\s+\[pre-push\]'
    }

    It "routes pre-push pre-commit filenames through an array-splat wrapper" {
        $wrapperPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-PrePushPreCommitValidation.ps1'
        $wrapperContent = Get-Content -Path $wrapperPath -Raw

        $wrapperContent | Should -Match 'ValueFromRemainingArguments\s*=\s*\$true'
        $wrapperContent | Should -Match '\[string\[\]\]\$TargetFiles\s*=\s*@\(\)'
        $wrapperContent | Should -Match 'Run-PreCommitValidation\.ps1'
        $wrapperContent | Should -Match 'TargetFiles\s*=\s*@\(\$TargetFiles\)'
        $wrapperContent | Should -Match '&\s+\$validationScriptPath\s+@validationArguments'
    }

    It "routes LLM harness validation through the precommit orchestrator" {
        $preCommitConfig = Get-Content -Path $script:preCommitConfigPath -Raw
        $preCommitConfig | Should -Match 'id:\s+powershell-precommit-validation'
        $preCommitConfig | Should -Match 'entry:\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+Scripts/Utils/Run-PreCommitValidation\.ps1'
        $preCommitConfig | Should -Not -Match 'id:\s+llm-harness-validation' -Because 'LLM harness checks should run once via the orchestrator to avoid duplicate execution'
    }

    It "pins and verifies the pre-commit CLI itself" {
        $requirementsPath = Join-Path -Path $script:repoRoot -ChildPath 'requirements.txt'
        $requirements = (Get-Content -Path $requirementsPath -Raw) -replace "`r", ''
        $fullValidation = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-FullValidation.ps1') -Raw
        $recoveryScript = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1') -Raw
        $cliHelper = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/PreCommitCliHelpers.ps1') -Raw

        $requirements | Should -Match '(?m)^pre-commit==\d+(?:\.\d+){1,3}$'
        $cliHelper | Should -Match 'Get-RequiredPreCommitVersion'
        $cliHelper | Should -Match 'E_VALIDATION_PRECOMMIT_VERSION_MISMATCH'
        $fullValidation | Should -Match 'Assert-PreCommitCliVersion'
        $recoveryScript | Should -Match 'Assert-PreCommitCliVersion'
    }

    It "routes shell safety conventions through the precommit orchestrator" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Run-PreCommitValidation.ps1'
        $validatorContent = Get-Content -Path $validatorPath -Raw

        $validatorContent | Should -Match '\$shellSafetyTriggerPattern\s*='
        $validatorContent | Should -Match '\$shellQualityPattern\s*='
        $validatorContent | Should -Match 'Scripts/.+\.sh'
        $validatorContent | Should -Match '\.devcontainer/.+\.sh'
        $validatorContent | Should -Match '\.githooks/\(pre-commit\|pre-push\)'
        $validatorContent | Should -Match 'Invoke-ShellQualityChecks\.ps1'
        $validatorContent | Should -Match 'E_PRECOMMIT_SHELL_QUALITY_RESTAGE_REQUIRED'
        $validatorContent | Should -Match 'Compare-Object\s+-ReferenceObject\s+\$preShellQualityDiffOutput\s+-DifferenceObject\s+\$formattedShellQualityFiles'
        $validatorContent | Should -Match '\$_\.SideIndicator\s+-eq\s+''=>'''
        $validatorContent | Should -Match '\$preShellQualityDirtyFileHashes\s*='
        $validatorContent | Should -Match 'Get-FileContentHashOrMissing\s+-Path\s+\$targetPath'
        $validatorContent | Should -Match 'Get-FileHash\s+-LiteralPath\s+\$Path\s+-Algorithm\s+SHA256'
        $validatorContent | Should -Match '\$allModeFormatterModifiedDirtyFiles'
        $validatorContent | Should -Match 'ScriptSafetyConventions\.Tests\.ps1'
        $validatorContent | Should -Match '\$runShellSafetySuite\s*=\s*\$All\s+-and\s+-not\s+\$runUtilsTests'
        $validatorContent | Should -Match 'Running Tests/Utils/ScriptSafetyConventions\.Tests\.ps1 Pester suite in isolated process'
        $validatorContent | Should -Match 'PreCommitScriptSafety'
    }

    It "keeps precommit git path-list probes trace-safe" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Run-PreCommitValidation.ps1'
        $validatorContent = (Get-Content -Path $validatorPath -Raw) -replace "`r", ''

        $validatorContent | Should -Match 'function\s+Invoke-GitCommandWithSplitOutput'
        $validatorContent | Should -Match '\$stdout\s*=\s*@\(&\s+\$GitExecutable\s+@Arguments\s+2>\s+\$gitStderrPath\)'
        $validatorContent | Should -Match 'function\s+Join-GitCommandDiagnosticOutput'
        $validatorContent | Should -Match 'function\s+Invoke-GitStdoutOrThrow'
        $validatorContent | Should -Match 'Invoke-GitCommandWithSplitOutput\s+-GitExecutable\s+\$GitExecutable\s+-Arguments\s+\$stagedFileArgs'
        $validatorContent | Should -Match 'Invoke-GitStdoutOrThrow\s+-GitExecutable\s+\$gitExecutable\s+-Arguments\s+@\("-C",\s*\$repoRoot,\s*"ls-files"\)'
        $validatorContent | Should -Match 'Invoke-GitStdoutOrThrow\s+-GitExecutable\s+\$gitExecutable\s+-Arguments\s+\$windowsLanguageDiffArgs'
        $validatorContent | Should -Match 'Invoke-GitStdoutOrThrow\s+-GitExecutable\s+\$gitExecutable\s+-Arguments\s+\$shellQualityDiffArgs'
        $validatorContent | Should -Match 'Invoke-GitStdoutOrThrow\s+-GitExecutable\s+\$gitExecutable\s+-Arguments\s+\$nativeQualityDiffArgs'
        $validatorContent | Should -Not -Match '@stagedFileArgs\s+2>&1'
        $validatorContent | Should -Not -Match 'ls-files\s+2>&1'
        $validatorContent | Should -Not -Match '@(?:windowsLanguage|shellQuality|nativeQuality)DiffArgs\s+2>&1'
    }

    It "keeps parsed Git command helpers split-output and trace-safe" {
        $hookRegistration = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/GitHookRegistrationHelpers.ps1') -Raw) -replace "`r", ''
        $gitPush = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-GitPushWithUpstream.ps1') -Raw) -replace "`r", ''
        $removeBom = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1') -Raw) -replace "`r", ''

        $hookRegistration | Should -Match '\$output\s*=\s*@\(&\s+\$GitExecutable\s+-C\s+\$RepositoryRoot\s+@Arguments\s+2>\s+\$stderrPath\)'
        $hookRegistration | Should -Match 'DiagnosticOutput\s*=\s*@\(\$diagnosticOutput\)'
        $hookRegistration | Should -Match 'Get-GitHookRegistrationDiagnosticOutput\s+-Result\s+\$rootResult'
        $hookRegistration | Should -Not -Match '@Arguments\s+2>&1'

        $gitPush | Should -Match '\$output\s*=\s*@\(&\s+\$GitExecutable\s+-C\s+\$RepositoryRoot\s+@Arguments\s+2>\s+\$stderrPath\)'
        $gitPush | Should -Match 'DiagnosticOutput\s*=\s*@\(\$diagnosticOutput\)'
        $gitPush | Should -Match 'function\s+Get-GitPushCommandDiagnosticOutput'
        $gitPush | Should -Match 'Get-GitPushCommandDiagnosticOutput\s+-Result\s+\$Result'
        $gitPush | Should -Not -Match '@Arguments\s+2>&1'

        $removeBom | Should -Match '\$commandOutput\s*=\s*@\(&\s+\$gitExecutable\s+-C\s+\$workingDirectory\s+@arguments\s+2>\s+\$commandStderrPath\)'
        $removeBom | Should -Match 'DiagnosticOutput\s*=\s*@\(\$diagnosticOutput\)'
        $removeBom | Should -Match 'function\s+Get-GitCommandFirstDiagnosticLine'
        $removeBom | Should -Not -Match '@arguments\s+2>&1'
    }

    It "keeps devcontainer shell linting on repo-managed shell quality tooling" {
        $workflow = Get-Content -Path $script:devcontainerWorkflowPath -Raw

        $workflow | Should -Match 'Invoke-ShellQualityChecks\.ps1\s+-Tool\s+All\s+-EnsureOnly'
        $workflow | Should -Match 'Invoke-ShellQualityChecks\.ps1\s+-Tool\s+All\s+\.devcontainer/post-create\.sh\s+\.githooks/pre-commit\s+\.githooks/pre-push'
        $workflow | Should -Not -Match 'apt-get\s+install[\s\S]*shellcheck'
        $workflow | Should -Not -Match 'shellcheck\s+--severity'
    }

    It "routes staged Windows language checks through the precommit orchestrator" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Run-PreCommitValidation.ps1'
        $validatorContent = Get-Content -Path $validatorPath -Raw

        $validatorContent | Should -Match '\$windowsLanguagePattern\s*='
        $validatorContent | Should -Match 'Scripts/AutoHotKey/.+\\\.ahk'
        $validatorContent | Should -Match 'Config/\\\.config/.+\\\.ahk'
        $validatorContent | Should -Match 'Invoke-WindowsLanguageChecks\.ps1'
        $validatorContent | Should -Match '-TargetFiles\s+\$windowsLanguageFiles'
        $validatorContent | Should -Match '-TargetFiles\s+\$windowsLanguageFiles\s+-StaticOnly'
        $validatorContent | Should -Not -Match '-TargetFiles\s+\$windowsLanguageFiles\s+-Fix'
        $validatorContent | Should -Match 'E_PRECOMMIT_WINDOWS_LANGUAGE_RESTAGE_REQUIRED'
        $validatorContent | Should -Match 'git diff[\s\S]*--name-only'
        $validatorContent | Should -Match 'Running Windows language static validation'
    }

    It "runs cross-version compatibility checks only through the deep precommit orchestrator mode" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Run-PreCommitValidation.ps1'
        $validatorContent = Get-Content -Path $validatorPath -Raw

        $validatorContent | Should -Match '\$compatibilityTargetPattern\s*='
        $validatorContent | Should -Match '\$runCompatibilityGate\s*=\s*\$All\s+-and\s+\$compatibilityTargetFiles\.Count\s+-gt\s+0'
        $validatorContent | Should -Not -Match '\$runCompatibilityGate\s*=\s*-not\s+\$All'
        $validatorContent | Should -Match 'Invoke-CompatibilityChecks\.ps1'
        $validatorContent | Should -Match 'Running cross-version compatibility gate for'
        $validatorContent | Should -Match 'E_PRECOMMIT_COMPATIBILITY_FAILED'
    }

    It "keeps pre-commit utils Pester execution fast-lane scoped to staged utils test files" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Run-PreCommitValidation.ps1'
        $validatorContent = Get-Content -Path $validatorPath -Raw

        $validatorContent | Should -Match '\$utilsPesterPattern\s*=\s*''\^Tests/Utils/.+\\.Tests\\.ps1\$'''
        $validatorContent | Should -Match '\$utilsScriptPattern\s*=\s*''\^Scripts/Utils/.+\\.ps1\$'''
        $validatorContent | Should -Match 'Skipping Tests/Utils Pester suite for script-only staged changes in fast local mode'
        $validatorContent | Should -Match 'full suite remains enforced in -All/full validation'
    }

    It "routes native Lua and workflow checks through the precommit orchestrator" {
        $validatorPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Run-PreCommitValidation.ps1'
        $validatorContent = Get-Content -Path $validatorPath -Raw

        $validatorContent | Should -Match '\$nativeQualityPattern\s*='
        $validatorContent | Should -Match 'Config/Wezterm/wezterm\\\.lua'
        $validatorContent | Should -Match '\\.github/workflows/.+\\\.\(yml\|yaml\)'
        $validatorContent | Should -Match 'Invoke-NativeQualityChecks\.ps1'
        $validatorContent | Should -Match '-Tool\s+All\s+-Fix\s+@nativeQualityFiles'
        $validatorContent | Should -Match 'E_PRECOMMIT_NATIVE_QUALITY_RESTAGE_REQUIRED'
        $validatorContent | Should -Match 'Running Lua and GitHub workflow native quality validation'
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

    It "keeps git hooks last-resort with fallback guidance" {
        $preCommitHook = Get-Content -Path $script:preCommitHookPath -Raw
        $prePushHook = Get-Content -Path $script:prePushHookPath -Raw

        $preCommitHook | Should -Match 'pre-commit run --hook-stage pre-commit'
        $preCommitHook | Should -Match 'command -v git'
        $preCommitHook | Should -Match 'E_PRECOMMIT_HOOK_GIT_NOT_AVAILABLE'
        $preCommitHook | Should -Not -Match 'repo_root="\$\(git rev-parse --show-toplevel 2>&1\)"'
        $preCommitHook | Should -Match 'repo_root_stderr_path="\$\(mktemp 2> /dev/null\)"'
        $preCommitHook | Should -Match 'repo_root="\$\(git rev-parse --show-toplevel 2>\s*"\$repo_root_stderr_path"\)"'
        $preCommitHook | Should -Match 'repo_root_exit=\$\?'
        $preCommitHook | Should -Match 'repo_root_stderr="\$\(< "\$repo_root_stderr_path"\)"'
        $preCommitHook | Should -Match 'repo_root_output="\$repo_root"'
        $preCommitHook | Should -Match 'E_PRECOMMIT_REPO_ROOT_UNAVAILABLE'
        $preCommitHook | Should -Match 'workingDirectory=\$\{working_directory\}; gitCommand=\$\{git_command\}'
        $preCommitHook | Should -Match 'run_safe_autorepair'
        $preCommitHook | Should -Match 'has_staged_windows_language_targets'
        $preCommitHook | Should -Match 'git -C "\$repo_root" diff --cached --name-only --diff-filter=ACMR --'
        $preCommitHook | Should -Match 'W_PRECOMMIT_AUTOREPAIR_PREFILTER_FAILED'
        $preCommitHook | Should -Match 'Invoke-PreCommitAutoRepair\.ps1'
        $preCommitHook | Should -Match 'Invoke-PreCommitWithRecovery\.ps1" -HookStage pre-commit'
        $preCommitHook | Should -Match 'precommit_recovery_inner_timeout_seconds=30'
        $preCommitHook | Should -Match 'precommit_recovery_shutdown_buffer_seconds=15'
        $preCommitHook | Should -Match 'precommit_recovery_setup_slack_seconds=15'
        $preCommitHook | Should -Match 'minimum_precommit_timeout_seconds=\$\(\(precommit_recovery_inner_timeout_seconds \+ precommit_recovery_shutdown_buffer_seconds \+ precommit_recovery_setup_slack_seconds\)\)'
        $preCommitHook | Should -Match '\$\{precommit_recovery_inner_timeout_seconds\}s inner recovery timeout plus \$\{precommit_recovery_shutdown_buffer_seconds\}s shutdown buffer plus \$\{precommit_recovery_setup_slack_seconds\}s setup slack'
        $preCommitHook | Should -Match 'emit_recovery_budget_diagnostic'
        $preCommitHook | Should -Match 'configuredTimeoutSeconds=\$\{precommit_timeout_seconds\}'
        $preCommitHook | Should -Match 'elapsedSetupSeconds=\$\{elapsed_seconds\}'
        $preCommitHook | Should -Match 'remainingSeconds=\$\{remaining_seconds\}'
        $preCommitHook | Should -Match 'requiredRemainingSeconds=\$\{required_remaining_seconds\}'
        $preCommitHook | Should -Match 'timeoutProvider=\$\{timeout_provider\}'
        $preCommitHook | Should -Match 'inner_timeout_seconds=\$\(\(remaining_seconds - precommit_recovery_shutdown_buffer_seconds\)\)'
        $preCommitHook | Should -Match 'Invoke-PreCommitWithRecovery\.ps1" -HookStage pre-commit -TimeoutSeconds "\$inner_timeout_seconds"'
        $preCommitHook | Should -Match '\[\[ "\$inner_timeout_seconds" -lt "\$precommit_recovery_inner_timeout_seconds" \]\]'
        $preCommitHook | Should -Match 'below required recovery budget'
        $preCommitHook | Should -Match 'Run-PreCommitValidation\.ps1'
        $preCommitHook | Should -Match 'pipx install pre-commit'
        $preCommitHook | Should -Match 'python3 -m venv ~/.local/venvs/pre-commit'
        $preCommitHook | Should -Not -Match 'python3 -m pip install --user pre-commit'
        $preCommitHook | Should -Match 'run_with_timeout'
        $preCommitHook | Should -Match 'hook_start_seconds='
        $preCommitHook | Should -Match 'remaining_timeout_seconds'
        $preCommitHook | Should -Match 'minimumInnerTimeoutSeconds=\$\{precommit_recovery_inner_timeout_seconds\}'
        $preCommitHook | Should -Match 'shutdownBufferSeconds=\$\{precommit_recovery_shutdown_buffer_seconds\}'
        $preCommitHook | Should -Match 'setupSlackSeconds=\$\{precommit_recovery_setup_slack_seconds\}'
        $preCommitHook | Should -Match 'WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS'
        $preCommitHook | Should -Match 'E_HOOK_TIMEOUT_CONFIG'
        $preCommitHook | Should -Match 'W_HOOK_RUNTIME_BUDGET'
        $preCommitHook | Should -Match 'HookTimeout\.sh'
        $preCommitHook | Should -Match 'wallstop_resolve_timeout_command'
        $preCommitHook | Should -Match 'wallstop_start_timeout_command'
        $preCommitHook | Should -Match '\[\[ ! "\$timeout_value" =~ \^\[0-9\]\+\$ \]\] \|\| \[\[ "\$timeout_value" -lt "\$minimum_precommit_timeout_seconds" \]\]'
        $preCommitHook | Should -Match 'grep -Ei'

        $prePushHook | Should -Not -Match 'pre-commit run --hook-stage pre-push --all-files'
        $prePushHook | Should -Not -Match '--all-files'
        $prePushHook | Should -Match 'command -v git'
        $prePushHook | Should -Match 'E_PREPUSH_HOOK_GIT_NOT_AVAILABLE'
        $prePushHook | Should -Not -Match 'repo_root="\$\(git rev-parse --show-toplevel 2>&1\)"'
        $prePushHook | Should -Match 'repo_root_stderr_path="\$\(mktemp 2> /dev/null\)"'
        $prePushHook | Should -Match 'repo_root="\$\(git rev-parse --show-toplevel 2>\s*"\$repo_root_stderr_path"\)"'
        $prePushHook | Should -Match 'repo_root_exit=\$\?'
        $prePushHook | Should -Match 'repo_root_stderr="\$\(< "\$repo_root_stderr_path"\)"'
        $prePushHook | Should -Match 'repo_root_output="\$repo_root"'
        $prePushHook | Should -Match 'E_PREPUSH_REPO_ROOT_UNAVAILABLE'
        $prePushHook | Should -Match 'workingDirectory=\$\{working_directory\}; gitCommand=\$\{git_command\}'
        $prePushHook | Should -Not -Match 'Invoke-FullValidation\.ps1'
        $prePushHook | Should -Not -Match 'Run-PreCommitValidation\.ps1"\s+-All'
        $prePushHook | Should -Match 'Invoke-PreCommitWithRecovery\.ps1" -HookStage pre-push'
        $prePushHook | Should -Match 'prepush_recovery_inner_timeout_seconds=30'
        $prePushHook | Should -Match 'prepush_recovery_shutdown_buffer_seconds=15'
        $prePushHook | Should -Match 'prepush_recovery_setup_slack_seconds=15'
        $prePushHook | Should -Match 'minimum_prepush_timeout_seconds=\$\(\(prepush_recovery_inner_timeout_seconds \+ prepush_recovery_shutdown_buffer_seconds \+ prepush_recovery_setup_slack_seconds\)\)'
        $prePushHook | Should -Match '\$\{prepush_recovery_inner_timeout_seconds\}s inner recovery timeout plus \$\{prepush_recovery_shutdown_buffer_seconds\}s shutdown buffer plus \$\{prepush_recovery_setup_slack_seconds\}s setup slack'
        $prePushHook | Should -Match 'emit_recovery_budget_diagnostic'
        $prePushHook | Should -Match 'configuredTimeoutSeconds=\$\{prepush_timeout_seconds\}'
        $prePushHook | Should -Match 'elapsedSetupSeconds=\$\{elapsed_seconds\}'
        $prePushHook | Should -Match 'remainingSeconds=\$\{remaining_seconds\}'
        $prePushHook | Should -Match 'requiredRemainingSeconds=\$\{required_remaining_seconds\}'
        $prePushHook | Should -Match 'minimumInnerTimeoutSeconds=\$\{prepush_recovery_inner_timeout_seconds\}'
        $prePushHook | Should -Match 'shutdownBufferSeconds=\$\{prepush_recovery_shutdown_buffer_seconds\}'
        $prePushHook | Should -Match 'setupSlackSeconds=\$\{prepush_recovery_setup_slack_seconds\}'
        $prePushHook | Should -Match 'timeoutProvider=\$\{timeout_provider\}'
        $prePushHook | Should -Match 'changedFileCount=\$\{#resolved_changed_files\[@\]\}'
        $prePushHook | Should -Match 'inner_timeout_seconds=\$\(\(remaining_seconds - prepush_recovery_shutdown_buffer_seconds\)\)'
        $prePushHook | Should -Match 'Invoke-PreCommitWithRecovery\.ps1" -HookStage pre-push -TimeoutSeconds "\$inner_timeout_seconds" -FileListPath "\$target_file_list_path"'
        $prePushHook | Should -Match 'write_changed_file_list'
        $prePushHook | Should -Not -Match 'target_file_list_path="\$\(write_changed_file_list\)"'
        $prePushHook | Should -Match 'write_changed_file_list\s*\r?\n\s*target_file_list_path="\$changed_file_list_path"\s*\r?\n\s*if remaining_seconds="\$\(remaining_timeout_seconds "pre-push changed-file pre-commit validation"\)"'
        $prePushHook | Should -Match 'Run-PreCommitValidation\.ps1" -IncludePreCommitOwnedChecks -TargetFileListPath "\$target_file_list_path"'
        $prePushHook | Should -Match 'pipx install pre-commit'
        $prePushHook | Should -Match 'python3 -m venv ~/.local/venvs/pre-commit'
        $prePushHook | Should -Not -Match 'python3 -m pip install --user pre-commit'
        $prePushHook | Should -Match 'run_with_timeout'
        $prePushHook | Should -Match 'WALLSTOP_PREPUSH_TIMEOUT_SECONDS'
        $prePushHook | Should -Match 'W_HOOK_RUNTIME_BUDGET'
        $prePushHook | Should -Match 'HookTimeout\.sh'
        $prePushHook | Should -Match 'wallstop_resolve_timeout_command'
        $prePushHook | Should -Match 'wallstop_start_timeout_command'
    }

    It "provides a hook-preflighted push helper for branches without upstreams" {
        $pushHelperPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-GitPushWithUpstream.ps1'
        $pushHelper = Get-Content -Path $pushHelperPath -Raw

        $pushHelper | Should -Match 'Assert-GitHookRegistration\s+-RepositoryRoot\s+\$resolvedRepositoryRoot\s+-Repair'
        $pushHelper | Should -Match 'push",\s*"-u",\s*\$SelectedRemote,\s*"HEAD"'
        $pushHelper | Should -Match 'push",\s*\$SelectedRemote,\s*"HEAD"'
        $pushHelper | Should -Match 'E_GIT_PUSH_DETACHED_HEAD'
        $pushHelper | Should -Match 'E_GIT_PUSH_REMOTE_MISSING'
        $pushHelper | Should -Match 'E_GIT_PUSH_REMOTE_MISMATCH'
        $pushHelper | Should -Match 'E_GIT_PUSH_REMOTE_BRANCH_DIVERGED'
        $pushHelper | Should -Match 'merge-base",\s*"--is-ancestor"'
        $pushHelper | Should -Not -Match 'push",\s*"-f"|--force' -Because (
            "Automated push helpers must never force-push."
        )
    }

    It "keeps pre-hook Windows language auto-repair safe and static-only" {
        $autoRepairPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-PreCommitAutoRepair.ps1'
        $autoRepair = (Get-Content -Path $autoRepairPath -Raw) -replace "`r", ''

        $autoRepair | Should -Match 'diff",\s*"--cached",\s*"--name-only",\s*"--diff-filter=ACMR"'
        $autoRepair | Should -Match 'Scripts/AutoHotKey/.+\\\.ahk'
        $autoRepair | Should -Match 'Config/\\\.config/.+\\\.ahk'
        $autoRepair | Should -Match 'Scripts/.+\\\.bat'
        $autoRepair | Should -Match 'W_PRECOMMIT_AUTOREPAIR_WINDOWS_LANGUAGE_SKIPPED_UNSTAGED'
        $autoRepair | Should -Match 'W_PRECOMMIT_AUTOREPAIR_WINDOWS_LANGUAGE_SOURCE_UNSTAGED'
        $autoRepair | Should -Match 'function\s+Invoke-WindowsLanguageCheckerForAutoRepair'
        $autoRepair | Should -Match 'Invoke-WindowsLanguageChecks\.ps1'
        $autoRepair | Should -Match '-TargetFiles\s+\$repairTargets\s+-Fix\s+-StaticOnly'
        $autoRepair | Should -Match 'add",\s*"--"'
        $autoRepair | Should -Match 'E_PRECOMMIT_AUTOREPAIR_GIT_ADD_FAILED'
        $autoRepair | Should -Match 'Invoke-SafeGitIndexLockRecovery'
        $autoRepair | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_DETECTED'
        $autoRepair | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_RETRYING'
        $autoRepair | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_SKIPPED'
        $autoRepair | Should -Match 'E_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_FAILED'
        $autoRepair | Should -Match 'E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED'
    }

    It "keeps pre-commit bootstrap guidance aligned with PEP 668-safe flows" {
        $readme = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'README.md') -Raw
        $fullValidation = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-FullValidation.ps1') -Raw
        $preCommitHook = Get-Content -Path $script:preCommitHookPath -Raw
        $prePushHook = Get-Content -Path $script:prePushHookPath -Raw

        $readme | Should -Match 'pipx install pre-commit'
        $readme | Should -Match 'python3 -m venv ~/.local/venvs/pre-commit'
        $readme | Should -Match '~/.bashrc'
        $readme | Should -Match 'Install-PowerShellQualityModules\.ps1'
        $readme | Should -Match 'Invoke-FullValidation\.ps1 -PreflightOnly'
        $readme | Should -Not -Match 'python3 -m pip install --user pre-commit'

        $fullValidation | Should -Match 'E_VALIDATION_PREREQ_MISSING'
        $fullValidation | Should -Match 'pipx install pre-commit'
        $fullValidation | Should -Match 'python3 -m venv ~/.local/venvs/pre-commit'
        $fullValidation | Should -Match '~/.bashrc or ~/.zshrc'
        $fullValidation | Should -Match 'Get-PreCommitBootstrapVersionGuidance'
        $fullValidation | Should -Not -Match '\$\(Get-RequiredPreCommitVersion'
        $fullValidation | Should -Not -Match 'python3 -m pip install --user pre-commit'

        $preCommitHook | Should -Match '~/.bashrc or ~/.zshrc'
        $prePushHook | Should -Match '~/.bashrc or ~/.zshrc'
    }

    It "bootstraps pinned shell tools during validation preflight" {
        $fullValidation = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-FullValidation.ps1') -Raw
        $shellQualityScriptPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1'
        $shellQualityScript = Get-Content -Path $shellQualityScriptPath -Raw
        $shellToolManifestPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/shell-quality-tools.json'
        $shellToolManifest = Get-Content -Path $shellToolManifestPath -Raw | ConvertFrom-Json

        $sharedHelper = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/QualityToolingHelpers.ps1') -Raw

        $fullValidation | Should -Match 'Assert-ShellQualityToolAvailability'
        $fullValidation | Should -Match 'Invoke-ShellQualityChecks\.ps1'
        $fullValidation | Should -Match '-Tool\s+All\s+-EnsureOnly'

        # Shared tooling infrastructure is single-sourced in QualityToolingHelpers.ps1; the
        # consumer script dot-sources it and emits stable diagnostics through context prefixes.
        $shellQualityScript | Should -Match '\.tools/shell-quality'
        $shellQualityScript | Should -Match 'QualityToolingHelpers\.ps1'
        $shellQualityScript | Should -Match '"SHELL_TOOL"'
        $shellQualityScript | Should -Match '"SHELL_QUALITY"'
        $shellQualityScript | Should -Not -Match 'Invoke-WebRequest'
        $shellQualityScript | Should -Not -Match 'Start-Process\s+@|Start-Process\s+-FilePath'
        $shellQualityScript | Should -Match 'Test-ShellQualityTargetMatchesSuite'
        $shellQualityScript | Should -Match 'Select-ShellQualityTargetFiles'
        $shellQualityScript | Should -Match '\.githooks/\(pre-commit\|pre-push\)'

        $sharedHelper | Should -Match 'Invoke-WebRequest'
        $sharedHelper | Should -Match 'Get-FileHash'
        $sharedHelper | Should -Match 'System\.Diagnostics\.ProcessStartInfo'
        # Argument passing must go through the portable shim (native ArgumentList on 7+,
        # escaped .Arguments string on Windows PowerShell 5.1) rather than touching the
        # .NET Core-only ArgumentList collection directly, which throws on 5.1.
        $sharedHelper | Should -Match 'Set-PortableProcessArguments'
        $sharedHelper | Should -Not -Match '\$\w+\.ArgumentList\.Add'
        $sharedHelper | Should -Match 'W_\$\(\$Context\.DiagnosticPrefix\)_PLATFORM_FALLBACK'
        $sharedHelper | Should -Match 'E_\$\(\$Context\.DiagnosticPrefix\)_HASH_MISMATCH'
        $sharedHelper | Should -Match 'E_\$\(\$Context\.DiagnosticPrefix\)_PLATFORM_UNSUPPORTED'
        $sharedHelper | Should -Match 'E_\$\(\$Context\.TargetDiagnosticPrefix\)_TARGET_OUTSIDE_REPOSITORY'
        $sharedHelper | Should -Not -Match 'Start-Process\s+@|Start-Process\s+-FilePath'

        $shellToolManifest.tools.shfmt.version | Should -Be '3.13.0'
        $shellToolManifest.tools.shellcheck.version | Should -Be '0.11.0'
        foreach ($toolName in @('shfmt', 'shellcheck')) {
            $tool = $shellToolManifest.tools.$toolName
            $tool.repository | Should -Not -BeNullOrEmpty
            $tool.releaseTag | Should -Match '^v\d+\.\d+\.\d+'

            $actualAssetKeys = @($tool.assets.PSObject.Properties.Name | Sort-Object)
            $expectedAssetKeys = @('darwin-arm64', 'darwin-x64', 'linux-arm64', 'linux-x64', 'windows-x64')
            $actualAssetKeys | Should -Be $expectedAssetKeys

            foreach ($assetProperty in @($tool.assets.PSObject.Properties)) {
                $asset = $assetProperty.Value
                $asset.assetName | Should -Not -BeNullOrEmpty
                $asset.kind | Should -Match '^(executable|zip|tar\.gz)$'
                $asset.sha256 | Should -Match '^[a-f0-9]{64}$'
            }
        }
    }

    It "bootstraps pinned native tools during validation preflight" {
        $fullValidation = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-FullValidation.ps1') -Raw
        $nativeQualityScriptPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1'
        $nativeQualityScript = Get-Content -Path $nativeQualityScriptPath -Raw
        $nativeToolManifestPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/native-quality-tools.json'
        $nativeToolManifest = Get-Content -Path $nativeToolManifestPath -Raw | ConvertFrom-Json

        $sharedHelper = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/QualityToolingHelpers.ps1') -Raw

        $fullValidation | Should -Match 'Assert-NativeQualityToolAvailability'
        $fullValidation | Should -Match 'Invoke-NativeQualityChecks\.ps1'
        $fullValidation | Should -Match '-Tool\s+All\s+-EnsureOnly'

        # Shared tooling infrastructure is single-sourced in QualityToolingHelpers.ps1; the
        # consumer script dot-sources it and emits stable diagnostics through context prefixes.
        $nativeQualityScript | Should -Match '\.tools/native-quality'
        $nativeQualityScript | Should -Match 'QualityToolingHelpers\.ps1'
        $nativeQualityScript | Should -Match '"NATIVE_TOOL"'
        $nativeQualityScript | Should -Match '"NATIVE_QUALITY"'
        $nativeQualityScript | Should -Match 'WALLSTOP_NATIVE_TOOL_DOWNLOAD_TIMEOUT_SECONDS'
        $nativeQualityScript | Should -Match 'E_NATIVE_TOOL_TIMEOUT_CONFIG'
        $nativeQualityScript | Should -Not -Match 'Invoke-WebRequest'
        $nativeQualityScript | Should -Not -Match 'Start-Process\s+@|Start-Process\s+-FilePath'
        $nativeQualityScript | Should -Match 'Test-NativeQualityTargetMatchesTool'
        $nativeQualityScript | Should -Match 'Select-NativeQualityToolTargetFiles'
        $nativeQualityScript | Should -Not -Match '\$filterForTool\s*=\s*\(\$SelectedTool\s+-eq\s+"All"\)'
        $nativeQualityScript | Should -Not -Match '-FilterForTool'

        $sharedHelper | Should -Match 'Invoke-WebRequest'
        $sharedHelper | Should -Match 'Get-FileHash'
        $sharedHelper | Should -Match 'System\.Diagnostics\.ProcessStartInfo'
        # Argument passing must go through the portable shim (native ArgumentList on 7+,
        # escaped .Arguments string on Windows PowerShell 5.1) rather than touching the
        # .NET Core-only ArgumentList collection directly, which throws on 5.1.
        $sharedHelper | Should -Match 'Set-PortableProcessArguments'
        $sharedHelper | Should -Not -Match '\$\w+\.ArgumentList\.Add'
        $sharedHelper | Should -Match 'W_\$\(\$Context\.DiagnosticPrefix\)_PLATFORM_FALLBACK'
        $sharedHelper | Should -Match 'E_\$\(\$Context\.DiagnosticPrefix\)_HASH_MISMATCH'
        $sharedHelper | Should -Match 'E_\$\(\$Context\.DiagnosticPrefix\)_PLATFORM_UNSUPPORTED'
        $sharedHelper | Should -Match 'E_\$\(\$Context\.TargetDiagnosticPrefix\)_TARGET_OUTSIDE_REPOSITORY'

        $nativeToolManifest.tools.stylua.version | Should -Be '2.5.2'
        $nativeToolManifest.tools.actionlint.version | Should -Be '1.7.12'
    }

    It "auto-recovers pre-commit hook environment corruption before falling back to manual triage" {
        $recoveryScriptPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1'
        $recoveryScript = Get-Content -Path $recoveryScriptPath -Raw
        $autoRepairScript = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-PreCommitAutoRepair.ps1') -Raw
        $fullValidation = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-FullValidation.ps1') -Raw

        $recoveryScript | Should -Match 'Test-PreCommitEnvironmentFailure'
        $recoveryScript | Should -Match 'pre-commit"\s+-ErrorAction\s+SilentlyContinue'
        $recoveryScript | Should -Match 'pre-commit clean|@\("clean"\)'
        $recoveryScript | Should -Match 'install-hooks'
        $recoveryScript | Should -Match 'W_PRECOMMIT_ENV_AUTO_REPAIR'
        $recoveryScript | Should -Match 'E_PRECOMMIT_ENV_AUTO_REPAIR_FAILED'
        $recoveryScript | Should -Match 'Resolve-PreCommitRecoveryRepositoryRootOrThrow'
        $recoveryScript | Should -Not -Match 'rev-parse --show-toplevel 2>&1'
        $recoveryScript | Should -Match 'repositoryRootStderrPath'
        $recoveryScript | Should -Match 'rev-parse --show-toplevel 2> \$repositoryRootStderrPath'
        $autoRepairScript | Should -Not -Match 'rev-parse --show-toplevel 2>&1'
        $autoRepairScript | Should -Match 'repoRootStderrPath'
        $autoRepairScript | Should -Match 'rev-parse --show-toplevel 2> \$repoRootStderrPath'
        $autoRepairScript | Should -Match 'function\s+Invoke-GitCommandWithSplitOutput'
        $autoRepairScript | Should -Match '\$stdout\s*=\s*@\(&\s+\$GitExecutable\s+@Arguments\s+2>\s+\$gitStderrPath\)'
        $autoRepairScript | Should -Match 'Join-GitCommandDiagnosticOutput\s+-Stdout\s+\$gitOutput\s+-Stderr\s+\$gitResult\.Stderr'
        $autoRepairScript | Should -Not -Match '@\(&\s+\$GitExecutable\s+@gitArgs\s+2>&1\)'
        $recoveryScript | Should -Match 'Get-PreCommitRecoveryRemainingTimeoutSeconds'
        $recoveryScript | Should -Match 'Receive-PreCommitCommandStreamText'
        $recoveryScript | Should -Match 'StreamDrainTimeoutMilliseconds'
        $recoveryScript | Should -Match 'E_PRECOMMIT_RECOVERY_CAPTURE_TIMEOUT'
        $recoveryScript | Should -Match 'New-PreCommitEnvironmentRepairResult'
        $recoveryScript | Should -Match 'Succeeded'
        $recoveryScript | Should -Match '\$deadlineUtc\s*=\s*\[datetime\]::UtcNow\.AddSeconds\(\$CommandTimeoutSeconds\)[\s\S]*Get-PreCommitRecoveryGitExecutableOrThrow[\s\S]*Resolve-PreCommitRecoveryRepositoryRootOrThrow[\s\S]*Get-PreCommitExecutableOrThrow[\s\S]*-DeadlineUtc\s+\$deadlineUtc'
        $recoveryScript | Should -Match 'Assert-PreCommitCliVersion[\s\S]*-TimeoutSeconds\s+\$versionProbeTimeoutSeconds'
        $recoveryScript | Should -Match 'OverallTimeoutSeconds'
        $recoveryScript | Should -Match 'WorkingDirectory = \$RepositoryRoot'
        $recoveryScript | Should -Match 'Invoke-PreCommitIndexLockRecovery'
        $recoveryScript | Should -Match 'Invoke-SafeGitIndexLockRecovery'
        $recoveryScript | Should -Match 'workingDirectory='
        $recoveryScript | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_DETECTED'
        $recoveryScript | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_RETRYING'
        $recoveryScript | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_SKIPPED'
        $recoveryScript | Should -Match 'E_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_FAILED'
        $recoveryScript | Should -Match 'E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED'
        $recoveryScript | Should -Not -Match 'Start-Process\s+@|Start-Process\s+-FilePath'

        $fullValidation | Should -Match 'Assert-PreCommitHookEnvironmentAvailability'
        $fullValidation | Should -Match 'Invoke-PreCommitWithRecovery\.ps1'
        $fullValidation | Should -Match '-InstallHooksOnly'
        $fullValidation | Should -Match 'E_VALIDATION_PRECOMMIT_ENV_PREFLIGHT_FAILED'
        $fullValidation | Should -Match '-HookStage\s+pre-commit\s+-AllFiles'
        $fullValidation | Should -Match 'Run-PreCommitValidation\.ps1'
        $fullValidation | Should -Match 'E_VALIDATION_DEEP_POWERSHELL_FAILED'
        $fullValidation | Should -Not -Match '-HookStage\s+pre-push\s+-AllFiles'

        $validationWorkflow = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath '.llm/validation-workflow.md') -Raw
        $validationWorkflow | Should -Match 'E_VALIDATION_DEEP_POWERSHELL_FAILED'
        $validationWorkflow | Should -Not -Match 'E_VALIDATION_PREPUSH_FAILED'
    }

    It "explicitly propagates pwsh fallback exit status in git hooks" {
        $preCommitHook = Get-Content -Path $script:preCommitHookPath -Raw
        $prePushHook = Get-Content -Path $script:prePushHookPath -Raw

        $preCommitHook | Should -Match 'remaining_timeout_seconds\s+"legacy pre-commit PowerShell validation"'
        $preCommitHook | Should -Match 'run_with_timeout\s+"\$remaining_seconds"\s+"legacy pre-commit PowerShell validation"\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+"Scripts/Utils/Run-PreCommitValidation\.ps1"\s+-IncludePreCommitOwnedChecks\s+-AllowPreCommitOwnedFixes\s*\r?\n\s*return\s+\$\?'
        $prePushHook | Should -Match 'run_with_timeout\s+"\$remaining_seconds"\s+"legacy pre-push PowerShell validation"\s+pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+"Scripts/Utils/Run-PreCommitValidation\.ps1"\s+-IncludePreCommitOwnedChecks\s+-TargetFileListPath\s+"\$target_file_list_path"\s*\r?\n\s*return\s+\$\?'
        $preCommitHook | Should -Match 'run_legacy_validation\s*\r?\n\s*exit\s+\$\?'
        $prePushHook | Should -Match 'run_legacy_validation\s*\r?\n\s*exit\s+\$\?'
    }

    It "enforces timeout guardrails for hooks and devcontainer preflight" {
        $preCommitHook = Get-Content -Path $script:preCommitHookPath -Raw
        $prePushHook = Get-Content -Path $script:prePushHookPath -Raw
        $readme = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'README.md') -Raw
        $postCreatePath = Join-Path -Path $script:repoRoot -ChildPath '.devcontainer/post-create.sh'
        $postCreate = Get-Content -Path $postCreatePath -Raw
        $hookTimeoutHelperPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/HookTimeout.sh'
        $hookTimeoutHelper = Get-Content -Path $hookTimeoutHelperPath -Raw
        $recoveryScript = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-PreCommitWithRecovery.ps1') -Raw

        $preCommitHook | Should -Match 'resolve_timeout_command'
        $preCommitHook | Should -Match 'E_HOOK_TIMEOUT'
        $preCommitHook | Should -Match 'using shell watchdog timeout'
        $preCommitHook | Should -Match 'sleep "\$timeout_seconds"'
        $preCommitHook | Should -Match 'wallstop_start_timeout_command'
        $preCommitHook | Should -Match 'wallstop_terminate_timeout_command'
        $preCommitHook | Should -Match 'wallstop_cleanup_timeout_command_processes'
        $preCommitHook | Should -Match '\$timeout_command"\s+-k\s+2s\s+"\$\{timeout_seconds\}s"'
        $preCommitHook | Should -Not -Match 'timeout_command"\s+--foreground'
        $preCommitHook | Should -Not -Match 'kill\s+-TERM\s+"\$command_pid"'
        $preCommitHook | Should -Not -Match 'kill\s+-KILL\s+"\$command_pid"'
        $prePushHook | Should -Match 'resolve_timeout_command'
        $prePushHook | Should -Match 'E_HOOK_TIMEOUT'
        $prePushHook | Should -Match 'using shell watchdog timeout'
        $prePushHook | Should -Match 'sleep "\$timeout_seconds"'
        $prePushHook | Should -Match 'wallstop_start_timeout_command'
        $prePushHook | Should -Match 'wallstop_terminate_timeout_command'
        $prePushHook | Should -Match 'wallstop_cleanup_timeout_command_processes'
        $prePushHook | Should -Match '\$timeout_command"\s+-k\s+2s\s+"\$\{timeout_seconds\}s"'
        $prePushHook | Should -Not -Match 'timeout_command"\s+--foreground'
        $prePushHook | Should -Not -Match 'kill\s+-TERM\s+"\$command_pid"'
        $prePushHook | Should -Not -Match 'kill\s+-KILL\s+"\$command_pid"'
        $prePushHook | Should -Match 'pre-push changed-file pre-commit validation'
        $prePushHook | Should -Match '\[\[ ! "\$timeout_value" =~ \^\[0-9\]\+\$ \]\] \|\| \[\[ "\$timeout_value" -lt "\$minimum_prepush_timeout_seconds" \]\]'

        $readme | Should -Match 'WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS[\s\S]*at least 60 seconds' -Because (
            "README must document the same pre-commit minimum enforced by .githooks/pre-commit."
        )
        $readme | Should -Match '30s inner recovery timeout plus a 15s shutdown buffer plus 15s setup slack' -Because (
            "README must explain why pre-commit accepts no values below 60 seconds."
        )
        $readme | Should -Match 'WALLSTOP_PREPUSH_TIMEOUT_SECONDS[\s\S]*at least 60 seconds' -Because (
            "README must document the same pre-push recovery-buffer minimum enforced by .githooks/pre-push."
        )

        $postCreate | Should -Match '_run_with_timeout'
        $postCreate | Should -Match '_validate_timeout_seconds'
        $postCreate | Should -Match 'WALLSTOP_DEVCONTAINER_PREFLIGHT_TIMEOUT_SECONDS'
        $postCreate | Should -Match 'WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS'
        $postCreate | Should -Match 'Invoke-PreCommitWithRecovery\.ps1 -InstallHooksOnly -TimeoutSeconds "\$\{precommit_prewarm_inner_timeout_seconds\}"'
        $postCreate | Should -Match 'Invoke-FullValidation\.ps1 -PreflightOnly'
        $postCreate | Should -Match 'using shell watchdog timeout'
        $postCreate | Should -Match 'E_HOOK_TIMEOUT'
        $postCreate | Should -Match 'HookTimeout\.sh'
        $postCreate | Should -Match 'wallstop_start_timeout_command'
        $postCreate | Should -Match 'wallstop_terminate_timeout_command'
        $postCreate | Should -Match 'wallstop_cleanup_timeout_command_processes'
        $postCreate | Should -Match '\$timeout_command"\s+-k\s+2s\s+"\$\{timeout_seconds\}s"'
        $postCreate | Should -Not -Match 'timeout_command"\s+--foreground'
        $postCreate | Should -Not -Match 'kill\s+-TERM\s+"\$\{command_pid\}"'
        $postCreate | Should -Not -Match 'kill\s+-KILL\s+"\$\{command_pid\}"'
        $postCreate | Should -Match '_resolve_codex_npm_global_bin'
        $postCreate | Should -Match '_resolve_codex_npm_package_bin'
        $postCreate | Should -Match '_test_codex_local_bin_is_npm_managed'
        $postCreate | Should -Match '_resolve_codex_path_without_local_bin'
        $postCreate | Should -Match 'E_DEVCONTAINER_CODEX_LINK_FAILED'
        $postCreate | Should -Match 'E_DEVCONTAINER_CODEX_BINARY_UNRESOLVED'
        $postCreate | Should -Match 'npm root --global'
        $postCreate | Should -Match '@openai/codex'
        $postCreate | Should -Match 'pwd -P'
        $postCreate | Should -Match 'readlink -f "\$\{codex_path\}"'
        $postCreate | Should -Match 'refusing to use \${codex_link_path} as its own link source'
        $postCreate | Should -Match 'ln -sfn "\$\{codex_source_path\}" "\$\{codex_link_path\}"'
        $postCreate | Should -Not -Match 'codex_path="\$\(command -v codex'

        $hookTimeoutHelper | Should -Match 'function\s+wallstop_start_timeout_command|wallstop_start_timeout_command\(\)'
        $hookTimeoutHelper | Should -Match '\bsetsid\b'
        $hookTimeoutHelper | Should -Match 'os\.setsid\(\)'
        $hookTimeoutHelper | Should -Match 'wallstop_can_start_session_with_setsid'
        $hookTimeoutHelper | Should -Match 'kill -0 -- "-\$\$"'
        $hookTimeoutHelper | Should -Match 'os\.kill\(-os\.getpid\(\), 0\)'
        $hookTimeoutHelper | Should -Match 'kill 0, -\$\$'
        $hookTimeoutHelper | Should -Match 'wallstop_terminate_timeout_command'
        $hookTimeoutHelper | Should -Match 'kill "\-\$\{signal_name\}" -- "-\$\{command_pid\}"'
        $hookTimeoutHelper | Should -Match 'wallstop_cleanup_timeout_command_processes'
        $hookTimeoutHelper | Should -Match 'W_HOOK_PROCESS_GROUP_UNAVAILABLE'
        $hookTimeoutHelper | Should -Match 'W_HOOK_PROCESS_GROUP_CLEANUP'
        $hookTimeoutWarningFunctionMatch = [regex]::Match(
            $hookTimeoutHelper,
            '(?ms)wallstop_timeout_emit_warning\(\)\s*\{(?<body>.*?)^\}'
        )
        $hookTimeoutWarningFunctionMatch.Success | Should -BeTrue
        $hookTimeoutWarningFunctionBody = $hookTimeoutWarningFunctionMatch.Groups["body"].Value
        $hookTimeoutWarningFunctionBody | Should -Match '\$\{WALLSTOP_TIMEOUT_WARNING_PREFIX\}\$\{message\}[\s\S]*?1?>\s*&2'
        $hookTimeoutWarningFunctionBody | Should -Match '\$message[\s\S]*?1?>\s*&2'
        $hookTimeoutWarningFunctionBody | Should -Not -Match '(?m)^\s*(?:echo|printf\b)(?![^\r\n]*(?:1?>\s*&2|\|[&]?\s*(?:cat|tee)\s*>\s*/dev/stderr))[^\r\n]*\$message'

        $streamDrainMatch = [regex]::Match($recoveryScript, '\[int\]\$StreamDrainTimeoutMilliseconds\s*=\s*(?<milliseconds>\d+)')
        $preCommitBufferMatch = [regex]::Match($preCommitHook, 'precommit_recovery_shutdown_buffer_seconds=(?<seconds>\d+)')
        $prewarmBufferMatch = [regex]::Match($postCreate, 'precommit_prewarm_shutdown_buffer_seconds=(?<seconds>\d+)')
        $streamDrainMatch.Success | Should -BeTrue -Because 'the recovery wrapper must declare a bounded per-stream drain timeout'
        $preCommitBufferMatch.Success | Should -BeTrue -Because 'pre-commit hook must reserve shutdown/capture time outside the inner recovery timeout'
        $prewarmBufferMatch.Success | Should -BeTrue -Because 'devcontainer prewarm must reserve shutdown/capture time outside the inner recovery timeout'

        $minimumBufferMilliseconds = ([int]$streamDrainMatch.Groups['milliseconds'].Value * 2) + 1000
        ([int]$preCommitBufferMatch.Groups['seconds'].Value * 1000) | Should -BeGreaterOrEqual $minimumBufferMilliseconds
        ([int]$prewarmBufferMatch.Groups['seconds'].Value * 1000) | Should -BeGreaterOrEqual $minimumBufferMilliseconds
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
        $workflow | Should -Match '\.devcontainer/\.\*\\\.sh'
        $workflow | Should -Match 'Invoke-WindowsLanguageChecks\.ps1'
        $workflow | Should -Match 'Invoke-MacOSLanguageChecks\.sh'
        $workflow | Should -Match 'Assert-CleanGitTree\.ps1'

        $workflow | Should -Match 'uses:\s+actions/checkout@v\d+\.\d+\.\d+'
        $workflow | Should -Match 'uses:\s+actions/setup-python@v\d+\.\d+\.\d+'
        $workflow | Should -Match 'uses:\s+actions/cache@v\d+\.\d+\.\d+'
        $workflow | Should -Match "hashFiles\('\.pre-commit-config\.yaml', 'requirements\.txt'\)"
        $workflow | Should -Match 'python -m pip install --requirement requirements\.txt'
        $workflow | Should -Not -Match 'python -m pip install --upgrade pip pre-commit'
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

        $windowsChecks | Should -Match '\[string\[\]\]\$TargetFiles'
        $windowsChecks | Should -Match '\[switch\]\$RequireAutoHotkey'
        $windowsChecks | Should -Match '\[switch\]\$Fix'
        $windowsChecks | Should -Match 'Resolve-RequestedTargetFilePaths'
        $windowsChecks | Should -Match 'Test-AutoHotkeyRequiresV2Directive'
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
        $windowsChecks | Should -Match 'E_AHK_REQUIRES_V2_MISSING'
        $windowsChecks | Should -Match 'E_AHK_REQUIRES_V2_NOT_TOP_LEVEL'
        $windowsChecks | Should -Match 'E_AHK_STATIC_VALIDATION_FAILED'
        # Validator must guard against treating empty-output ambiguous exit codes as definitive failures
        $windowsChecks | Should -Match '\$hasActualOutput'
        # Detection must be wired into the per-file loop
        $windowsChecks | Should -Match 'Test-IsAutoHotkeyV1Script\s+-Content'
        $windowsChecks | Should -Match 'E_AHK_STATIC_VALIDATION_FAILED[\s\S]*\$ahkExecutable\s*=\s*Get-AutoHotkeyExecutablePath' -Because 'Runtime probing should happen only after dependency-free static validation has completed.'
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
        # Static #Requires tests and fix tests must be present
        $windowsChecksTests | Should -Match 'Test-AutoHotkeyRequiresV2Directive'
        $windowsChecksTests | Should -Match 'E_AHK_REQUIRES_V2_NOT_TOP_LEVEL'
        $windowsChecksTests | Should -Match 'auto-fixes missing #Requires'
        $windowsChecksTests | Should -Match 'snapshot drift'
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

    It "uses System.Diagnostics.Process with portable argument passing in Invoke-AutoHotkeyCommand and avoids LASTEXITCODE dependency" {
        $windowsChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1'
        $windowsChecks = Get-Content -Path $windowsChecksPath -Raw

        $windowsChecks | Should -Match 'System\.Diagnostics\.ProcessStartInfo'
        # Portable argument passing (native ArgumentList on 7+, escaped .Arguments string on
        # Windows PowerShell 5.1) instead of the .NET Core-only ArgumentList collection.
        $windowsChecks | Should -Match 'Set-PortableProcessArguments'
        $windowsChecks | Should -Not -Match '\$\w+\.ArgumentList\.Add'
        $windowsChecks | Should -Match 'RedirectStandardOutput'
        $windowsChecks | Should -Match 'RedirectStandardError'
        $windowsChecks | Should -Match 'E_AHK_PROCESS_EXECUTION_FAILED'
        $windowsChecks | Should -Match '\$streamDrainTimeoutMilliseconds\s*=\s*\[Math\]::Min\(\[Math\]::Max\(\[int\]\(\$processTimeoutMilliseconds / 10\),\s*1500\),\s*10000\)'

        # Prevent regression: do not rely on Start-Process which mangles special characters
        # (curly braces, double quotes) in arguments on Windows.
        $windowsChecks | Should -Not -Match 'Start-Process\s+@startParams|Start-Process\s+-FilePath'
        # Prevent regression: do not rely on raw LASTEXITCODE assignment in this helper.
        $windowsChecks | Should -Not -Match '(?m)^\s*\$exitCode\s*=\s*\$LASTEXITCODE\b'
    }

    It "all repository AHK scripts in validated roots declare #Requires AutoHotkey v2" {
        $ahkRoots = @('Scripts/AutoHotKey', 'Config/.config')
        $ahkFiles = @()

        foreach ($relativeRoot in $ahkRoots) {
            $rootFiles = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath $relativeRoot) -Filter '*.ahk' -File -Recurse -ErrorAction SilentlyContinue)
            $rootFiles.Count | Should -BeGreaterThan 0 -Because "at least one .ahk file must exist under $relativeRoot"
            $ahkFiles += $rootFiles
        }

        foreach ($file in $ahkFiles) {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
            $relativePath = (Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $file.FullName).Replace([System.IO.Path]::DirectorySeparatorChar, '/').Replace([System.IO.Path]::AltDirectorySeparatorChar, '/')
            $content | Should -Match '(?ms)\A(?:\xEF\xBB\xBF)?(?:[ \t]*;[^\r\n]*\r?\n|[ \t]*\r?\n)*[ \t]*#Requires\s+AutoHotkey\s+v2(?:\.\d+)?\b' -Because "$relativePath must declare #Requires AutoHotkey v2 (or v2.x) at the top with only optional leading blank/comment lines"
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

    It "keeps bounded follow-up static validation pass for fixable AHK dependency chains" {
        $windowsChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1'
        $windowsChecks = Get-Content -Path $windowsChecksPath -Raw

        $windowsChecks | Should -Match '\$maxStaticPasses\s*=\s*if\s*\(\$Fix\)\s*\{\s*2\s*\}\s*else\s*\{\s*1\s*\}'
        $windowsChecks | Should -Match 'repairsAppliedThisPass'
        $windowsChecks | Should -Match 'running follow-up static validation pass after auto-repair updates'
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
        $preCommitConfig | Should -Match 'Invoke-ShellQualityChecks\.ps1'
        $preCommitConfig | Should -Match 'files:\s+''\^\(Scripts/\.\*\\\.sh\|\\\.devcontainer/\.\*\\\.sh\|\\\.githooks/\(pre-commit\|pre-push\)\)\$'''
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
        $bashPathArgument = $macChecksPath
        if (Test-IsWindowsPlatform) {
            $cygpath = Get-Command -Name cygpath -ErrorAction SilentlyContinue
            if ($null -ne $cygpath) {
                $convertedPath = @(& $cygpath.Source -u $macChecksPath 2>$null | Select-Object -First 1)
                if ($global:LASTEXITCODE -eq 0 -and $convertedPath.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($convertedPath[0])) {
                    $bashPathArgument = [string]$convertedPath[0]
                }
            }
            elseif (Get-Command -Name wsl.exe -ErrorAction SilentlyContinue) {
                $convertedPath = @(& wsl.exe wslpath -a $macChecksPath 2>$null | Select-Object -First 1)
                if ($global:LASTEXITCODE -eq 0 -and $convertedPath.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($convertedPath[0])) {
                    $bashPathArgument = [string]$convertedPath[0]
                }
            }

            if ($bashPathArgument -eq $macChecksPath) {
                Set-ItResult -Skipped -Because "bash is available, but no Windows-to-bash path converter is available"
                return
            }
        }

        $output = @(& $bash.Source -n $bashPathArgument 2>&1)

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
            $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $hookPath
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

    It "avoids negation-based exit-code capture antipatterns in shell scripts" {
        $shellFiles = @(
            Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts') -Filter '*.sh' -File -Recurse -ErrorAction Stop
            Get-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath '.devcontainer/post-create.sh') -ErrorAction Stop
            Get-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath '.githooks/pre-commit') -ErrorAction Stop
            Get-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath '.githooks/pre-push') -ErrorAction Stop
        )

        $violations = New-Object System.Collections.Generic.List[string]
        $negatedCommandSubstitutionCapturePattern = '(?m)^\s*if\s+!\s+[A-Za-z_][A-Za-z0-9_]*="\$\([^\n]*\)";\s+then\s*$\n^\s*[A-Za-z_][A-Za-z0-9_]*=\$\?\s*$'
        $negatedExitPropagationPattern = '(?m)^\s*if\s+!\s+[^\n;]+;\s+then\s*$\n^\s*(?:return|exit)\s+\$\?\s*$'

        foreach ($shellFile in $shellFiles) {
            $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $shellFile.FullName
            $content = (Get-Content -Path $shellFile.FullName -Raw) -replace "`r", ''
            if ($content -match $negatedCommandSubstitutionCapturePattern -or $content -match $negatedExitPropagationPattern) {
                $violations.Add($relativePath) | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Shell scripts must not propagate `$? from negated conditions. Violations: {0}" -f ($violations -join ', ')
        )
    }

    It "routes shell warning and error diagnostics to stderr" {
        $shellFiles = @(
            Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts') -Filter '*.sh' -File -Recurse -ErrorAction Stop
            Get-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath '.devcontainer/post-create.sh') -ErrorAction Stop
            Get-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath '.githooks/pre-commit') -ErrorAction Stop
            Get-Item -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath '.githooks/pre-push') -ErrorAction Stop
        )
        $diagnosticEmitPattern = '^\s*(?:echo(?:\s+-e)?|printf\b).*?(?:(?<![A-Za-z0-9_])(?:E_[A-Z0-9_]+|W_[A-Z0-9_]+)\b|Error:|Warning:|Unknown option:|Use -h or --help|Install Homebrew first)'
        $diagnosticTextPattern = '(?:(?<![A-Za-z0-9_])(?:E_[A-Z0-9_]+|W_[A-Z0-9_]+)\b|Error:|Warning:|Unknown option:|Use -h or --help|Install Homebrew first)'
        $diagnosticHelperNames = @("emit_diagnostic", "_warn", "wallstop_timeout_emit_warning")
        $diagnosticHelperCallPattern = '^\s*(?<helper>{0})\s+' -f (($diagnosticHelperNames | ForEach-Object { [regex]::Escape($_) }) -join '|')
        $diagnosticHelperFunctionPattern = '(?m)^\s*(?<helper>{0})\(\)\s*\{{' -f (($diagnosticHelperNames | ForEach-Object { [regex]::Escape($_) }) -join '|')
        $stderrRedirectPattern = '(?:1?>\s*&2|\|[&]?\s*(?:cat|tee)\s*>\s*/dev/stderr)'
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($shellFile in $shellFiles) {
            $relativePath = (Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $shellFile.FullName) -replace '\\', '/'
            $content = (Get-Content -Path $shellFile.FullName -Raw) -replace "`r", ''
            $lines = $content -split "`n"
            $stderrGroupedLines = [System.Collections.Generic.HashSet[int]]::new()
            $groupStartStack = New-Object System.Collections.Generic.Stack[int]
            $stderrDiagnosticHelpers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

            foreach ($helperMatch in [regex]::Matches($content, $diagnosticHelperFunctionPattern)) {
                $helperName = $helperMatch.Groups["helper"].Value
                $lineStart = $helperMatch.Index
                $lineEnd = $content.IndexOf("`n", $lineStart)
                if ($lineEnd -lt 0) {
                    $lineEnd = $content.Length
                }

                $definitionLine = $content.Substring($lineStart, $lineEnd - $lineStart)
                $helperBody = ''
                if ($definitionLine -match '^\s*[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{\s*(?<body>.*?)\s*\}\s*$') {
                    $helperBody = $Matches["body"]
                }
                else {
                    $bodyStart = $content.IndexOf("`n", $lineStart)
                    if ($bodyStart -lt 0) {
                        continue
                    }

                    $bodyEndMatch = [regex]::Match($content.Substring($bodyStart + 1), '(?m)^\s*\}')
                    if (-not $bodyEndMatch.Success) {
                        continue
                    }

                    $helperBody = $content.Substring($bodyStart + 1, $bodyEndMatch.Index)
                }

                $helperBodyLines = $helperBody -split "`n"
                $helperBodyStderrGroupedLines = [System.Collections.Generic.HashSet[int]]::new()
                $helperBodyGroupStartStack = New-Object System.Collections.Generic.Stack[int]
                for ($helperLineIndex = 0; $helperLineIndex -lt $helperBodyLines.Count; $helperLineIndex++) {
                    $helperLineNumber = $helperLineIndex + 1
                    $helperLine = $helperBodyLines[$helperLineIndex]

                    if ($helperLine -match '^\s*\{\s*$') {
                        $helperBodyGroupStartStack.Push($helperLineNumber)
                        continue
                    }

                    if ($helperLine -match '^\s*\}\s*1?>\s*&2\s*$' -and $helperBodyGroupStartStack.Count -gt 0) {
                        $groupStart = $helperBodyGroupStartStack.Pop()
                        for ($groupLineNumber = $groupStart; $groupLineNumber -le $helperLineNumber; $groupLineNumber++) {
                            [void]$helperBodyStderrGroupedLines.Add($groupLineNumber)
                        }
                        continue
                    }

                    if ($helperLine -match '^\s*\}\s*$' -and $helperBodyGroupStartStack.Count -gt 0) {
                        [void]$helperBodyGroupStartStack.Pop()
                    }
                }

                $unsafeHelperEmitLines = @()
                for ($helperLineIndex = 0; $helperLineIndex -lt $helperBodyLines.Count; $helperLineIndex++) {
                    $helperLineNumber = $helperLineIndex + 1
                    $helperLine = $helperBodyLines[$helperLineIndex]

                    if ($helperLine -cnotmatch '^\s*(?:echo(?:\s+-e)?|printf\b)') {
                        continue
                    }

                    if ($helperLine -cmatch $stderrRedirectPattern -or $helperBodyStderrGroupedLines.Contains($helperLineNumber)) {
                        continue
                    }

                    $unsafeHelperEmitLines += $helperLineNumber
                }

                if (@($unsafeHelperEmitLines).Count -eq 0) {
                    [void]$stderrDiagnosticHelpers.Add($helperName)
                    continue
                }

                $helperLineNumber = (($content.Substring(0, $helperMatch.Index) -split "`n").Count)
                $violations.Add("${relativePath}:$helperLineNumber diagnostic helper '$helperName' has stdout emit line(s): $($unsafeHelperEmitLines -join ', ')") | Out-Null
            }

            for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
                $lineNumber = $lineIndex + 1
                $line = $lines[$lineIndex]

                if ($line -match '^\s*\{\s*$') {
                    $groupStartStack.Push($lineNumber)
                    continue
                }

                if ($line -match '^\s*\}\s*1?>\s*&2\s*$' -and $groupStartStack.Count -gt 0) {
                    $groupStart = $groupStartStack.Pop()
                    for ($groupLineNumber = $groupStart; $groupLineNumber -le $lineNumber; $groupLineNumber++) {
                        [void]$stderrGroupedLines.Add($groupLineNumber)
                    }
                    continue
                }

                if ($line -match '^\s*\}\s*$' -and $groupStartStack.Count -gt 0) {
                    [void]$groupStartStack.Pop()
                }
            }

            for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
                $lineNumber = $lineIndex + 1
                $line = $lines[$lineIndex]

                if ($line -cnotmatch $diagnosticEmitPattern) {
                    $helperCallMatch = [regex]::Match($line, $diagnosticHelperCallPattern)
                    if (-not $helperCallMatch.Success -or $line -cnotmatch $diagnosticTextPattern) {
                        continue
                    }

                    $helperName = $helperCallMatch.Groups["helper"].Value
                    if ($stderrDiagnosticHelpers.Contains($helperName)) {
                        continue
                    }

                    $violations.Add("${relativePath}:$lineNumber helper '$helperName' must redirect diagnostics to stderr: $line") | Out-Null
                    continue
                }

                if ($line -cmatch $stderrRedirectPattern -or $stderrGroupedLines.Contains($lineNumber)) {
                    continue
                }

                $violations.Add("${relativePath}:$lineNumber $line") | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Shell diagnostics must go to stderr so stdout remains machine-readable. Violations: {0}" -f ($violations -join ', ')
        )
    }

    It "keeps Home-directory glob loops quoted in Backup.sh" {
        $backupPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Mac/Backup.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $backupContent = (Get-Content -Path $backupPath -Raw) -replace "`r", ''

        $backupContent | Should -Match '(?m)^\s*for\s+file\s+in\s+"\$HOME"/\.\*;\s+do\s*$'
        $backupContent | Should -Match '(?m)^\s*for\s+file\s+in\s+"\$HOME"/\*\.\{scpt,applescript\};\s+do\s*$'
        $backupContent | Should -Match '(?m)^\s*for\s+file\s+in\s+"\$HOME"/\*\.sh;\s+do\s*$'
    }

    It "guards Backup.sh git mutations with explicit branch, scope, and diagnostics checks" {
        $backupPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Mac/Backup.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $backupContent = (Get-Content -Path $backupPath -Raw) -replace "`r", ''

        $backupContent | Should -Match 'command\s+-v\s+git'
        $backupContent | Should -Match 'command\s+-v\s+brew'
        $backupContent | Should -Match 'E_BACKUP_MAC_GIT_NOT_AVAILABLE'
        $backupContent | Should -Match 'E_BACKUP_MAC_BREW_NOT_AVAILABLE'
        $backupContent | Should -Match 'assert_backup_git_branch\(\)'
        $backupContent | Should -Match 'assert_backup_managed_scope_clean\(\)'
        $backupContent | Should -Match 'get_output_preview\(\)'
        $backupContent | Should -Match 'readonly\s+BACKUP_MANAGED_PATH="Config/"'
        $backupContent | Should -Match 'E_BACKUP_GIT_BRANCH_DETECTION_FAILED'
        $backupContent | Should -Match 'E_BACKUP_GIT_DETACHED_HEAD'
        $backupContent | Should -Match 'E_BACKUP_GIT_BRANCH_MISMATCH'
        $backupContent | Should -Match 'E_BACKUP_GIT_STATUS_FAILED'
        $backupContent | Should -Match 'E_BACKUP_GIT_SCOPE_VIOLATION'
        $backupContent | Should -Match 'E_BACKUP_MAC_GIT_PULL_FAILED'
        $backupContent | Should -Match 'E_BACKUP_MAC_GIT_ADD_FAILED'
        $backupContent | Should -Match 'E_BACKUP_MAC_GIT_PUSH_FAILED'
        $backupContent | Should -Match 'outputPreview='
        $backupContent | Should -Match 'E_BACKUP_MAC_GIT_STAGED_DIFF_FAILED'
        $backupContent | Should -Match 'E_BACKUP_MAC_GIT_COMMIT_FAILED'
        $backupContent | Should -Not -Match 'git\s+-C\s+"\$REPO_ROOT"\s+push\s+(?:--force|-f)\b'
        $backupContent | Should -Not -Match 'git\s+-C\s+"\$REPO_ROOT"\s+commit\s+-m\s+"Backup for \$current_date"\s*\|\|'
        $backupContent | Should -Not -Match 'git\s+-C\s+"\$repo_root"\s+rev-parse\s+--abbrev-ref\s+HEAD[^\n]*\|\|\s*true'
        $backupContent | Should -Not -Match 'rev-parse\s+--abbrev-ref\s+HEAD\s+2>&1'
        $backupContent | Should -Not -Match 'status\s+--porcelain=v1[^\n]*2>&1\)";\s*then'
        $backupContent | Should -Match 'branch_stderr_path'
        $backupContent | Should -Match 'outside_status_stderr_path'
        $backupContent | Should -Not -Match '(?m)^\s*git\s+add\s+--all\s*$'
        $backupContent | Should -Not -Match '(?m)^\s*git\s+pull\s+origin\s+main\s*$'
        $backupContent | Should -Not -Match '(?m)^\s*git\s+push\s+origin\s+main\s*$'

        $gitPreflightIndex = $backupContent.IndexOf('command -v git', [System.StringComparison]::Ordinal)
        $brewPreflightIndex = $backupContent.IndexOf('command -v brew', [System.StringComparison]::Ordinal)
        $brewUpdateIndex = $backupContent.IndexOf('brew update', [System.StringComparison]::Ordinal)
        $pullCommandIndex = $backupContent.IndexOf('git -C "$REPO_ROOT" pull --ff-only origin main', [System.StringComparison]::Ordinal)
        $addCommandIndex = $backupContent.IndexOf('git -C "$REPO_ROOT" add -- "$BACKUP_MANAGED_PATH"', [System.StringComparison]::Ordinal)
        $pushCommandIndex = $backupContent.IndexOf('git -C "$REPO_ROOT" push origin main', [System.StringComparison]::Ordinal)
        $backupDirIndex = $backupContent.IndexOf('BACKUP_DIR="$REPO_ROOT/Config/Mac"', [System.StringComparison]::Ordinal)
        $stagedDiffIndex = $backupContent.IndexOf('git -C "$REPO_ROOT" diff --cached --quiet --exit-code', [System.StringComparison]::Ordinal)

        $gitPreflightIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must preflight git before side effects.'
        $brewPreflightIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must preflight brew before side effects.'
        $brewUpdateIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must run brew update in normal flow.'
        $pullCommandIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must run git pull --ff-only in managed git flow.'
        $addCommandIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must stage only managed pathspecs.'
        $pushCommandIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must push on success path.'
        $backupDirIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must derive Config/Mac backup destination before staging.'
        $stagedDiffIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must check staged diff before commit.'
        $gitPreflightIndex | Should -BeLessThan $brewUpdateIndex -Because 'git preflight must happen before brew side effects.'
        $brewPreflightIndex | Should -BeLessThan $brewUpdateIndex -Because 'brew preflight must happen before brew side effects.'

        $scopeGuardBeforePullIndex = $backupContent.LastIndexOf('assert_backup_managed_scope_clean "$REPO_ROOT" "$BACKUP_MANAGED_PATH"', $pullCommandIndex, [System.StringComparison]::Ordinal)
        $branchGuardBeforePullIndex = $backupContent.LastIndexOf('assert_backup_git_branch "$REPO_ROOT" "main"', $pullCommandIndex, [System.StringComparison]::Ordinal)
        $scopeGuardBeforeAddIndex = $backupContent.LastIndexOf('assert_backup_managed_scope_clean "$REPO_ROOT" "$BACKUP_MANAGED_PATH"', $addCommandIndex, [System.StringComparison]::Ordinal)
        $branchGuardBeforePushIndex = $backupContent.LastIndexOf('assert_backup_git_branch "$REPO_ROOT" "main"', $pushCommandIndex, [System.StringComparison]::Ordinal)

        $scopeGuardBeforePullIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must validate managed scope before pulling.'
        $branchGuardBeforePullIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must validate branch before pulling.'
        $scopeGuardBeforeAddIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must validate managed scope before staging.'
        $branchGuardBeforePushIndex | Should -BeGreaterThan -1 -Because 'Backup.sh must validate branch before pushing.'

        $scopeGuardBeforePullIndex | Should -BeLessThan $pullCommandIndex -Because 'scope validation must run before git pull.'
        $branchGuardBeforePullIndex | Should -BeLessThan $pullCommandIndex -Because 'branch validation must run before git pull.'
        $backupDirIndex | Should -BeLessThan $addCommandIndex -Because 'backup directory setup must happen before git add.'
        $scopeGuardBeforeAddIndex | Should -BeLessThan $addCommandIndex -Because 'scope validation must run before git add.'
        $stagedDiffIndex | Should -BeGreaterThan $addCommandIndex -Because 'staged diff inspection must occur after git add.'
        $branchGuardBeforePushIndex | Should -BeLessThan $pushCommandIndex -Because 'branch validation must run before git push.'
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

    It "hardens increment-version git mutation commands with explicit failure handling" {
        $incrementPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/increment-version.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $incrementContent = (Get-Content -Path $incrementPath -Raw) -replace "`r", ''

        $incrementContent | Should -Match 'command\s+-v\s+git'
        $incrementContent | Should -Match 'E_INCREMENT_VERSION_GIT_NOT_AVAILABLE'
        $incrementContent | Should -Match 'E_INCREMENT_VERSION_BRANCH_RESTRICTED'
        $incrementContent | Should -Match 'ALLOW_NON_MAIN'
        $incrementContent | Should -Match 'stage_increment_managed_paths\(\)'
        $incrementContent | Should -Match 'assert_increment_staged_scope\(\)'
        $incrementContent | Should -Match 'E_INCREMENT_VERSION_GIT_BRANCH_DETECTION_FAILED'
        $incrementContent | Should -Match 'E_INCREMENT_VERSION_GIT_SCOPE_VIOLATION'
        $incrementContent | Should -Match 'E_INCREMENT_VERSION_GIT_SCOPE_PATHSPEC_EMPTY'
        $incrementContent | Should -Match 'E_INCREMENT_VERSION_GIT_REPOSITORY_ROOT_FAILED'
        $incrementContent | Should -Match 'outputPreview='
        $incrementContent | Should -Not -Match 'git\s+pull\s+--ff-only\s+\|\|\s+true'
        $incrementContent | Should -Not -Match 'git\s+add\s+-A'
        $incrementContent | Should -Not -Match 'git\s+add\s+--\s+"\$package_json_path"\s+\|\|\s+true'
        $incrementContent | Should -Not -Match 'git\s+commit\s+-m\s+"\$msg"(?:\s+--no-verify)?\s+\|\|\s+true'
        $incrementContent | Should -Not -Match 'git\s+push\s+-u\s+origin\s+"\$branch"\s+\|\|\s+true'
        $incrementContent | Should -Not -Match 'git\s+-C\s+"\$repo_root"\s+push\s+(?:--force|-f)\b'
        $incrementContent | Should -Not -Match '(?m)^\s*if\s+git\s+rev-parse\s+--is-inside-work-tree\b'
        $incrementContent | Should -Not -Match '(?m)^\s*if\s+repo_root_output="\$\(git\s+rev-parse\s+--show-toplevel'
        $incrementContent | Should -Not -Match 'rev-parse\s+--show-toplevel\s+2>&1'
        $incrementContent | Should -Not -Match '(?m)^\s*branch=\$\(git\s+rev-parse\s+--abbrev-ref\s+HEAD\)'
        $incrementContent | Should -Not -Match 'rev-parse\s+--abbrev-ref\s+HEAD\s+2>&1'
        $incrementContent | Should -Not -Match '\$\(\s*git\s+-C\s+"\$repo_root"\s+"\$\{scope_args\[@\]\}"\s+2>&1\)'
        $incrementContent | Should -Match 'repo_root_stderr_path'
        $incrementContent | Should -Match 'branch_stderr_path'
        $incrementContent | Should -Match 'staged_scope_stderr_path'
        $incrementContent | Should -Not -Match '(?m)^\s*if\s+!\s+git\s+fetch\s+--prune;\s+then\s*$'
        $incrementContent | Should -Not -Match '(?m)^\s*if\s+!\s+git\s+-C\s+"\$repo_root"\s+fetch\s+--prune;\s+then\s*$'
        $incrementContent | Should -Not -Match '(?m)^\s*if\s+counts=\$\(git\s+rev-list\s+--left-right\s+--count'
        $incrementContent | Should -Match 'if\s+git_fetch_output="\$\(git\s+-C\s+"\$repo_root"\s+fetch\s+--prune\s+2>&1\)";\s+then'
        $incrementContent | Should -Match 'W_INCREMENT_VERSION_GIT_FETCH_FAILED'
        $incrementContent | Should -Match 'stage_increment_managed_paths\s+"\$repo_root"\s+"\$\{managed_paths\[@\]\}"'
        $incrementContent | Should -Match 'E_INCREMENT_VERSION_GIT_STAGED_DIFF_FAILED'
        $incrementContent | Should -Match 'E_INCREMENT_VERSION_GIT_COMMIT_FAILED'
        $incrementContent | Should -Match 'E_INCREMENT_VERSION_GIT_PUSH_FAILED'

        $repoCheckIndex = $incrementContent.IndexOf('git -C "$package_json_dir" rev-parse --is-inside-work-tree', [System.StringComparison]::Ordinal)
        $repoRootIndex = $incrementContent.IndexOf('git -C "$package_json_dir" rev-parse --show-toplevel', [System.StringComparison]::Ordinal)
        $branchDetectIndex = $incrementContent.IndexOf('git -C "$repo_root" rev-parse --abbrev-ref HEAD', [System.StringComparison]::Ordinal)
        $fetchIndex = $incrementContent.IndexOf('git -C "$repo_root" fetch --prune', [System.StringComparison]::Ordinal)
        $gitDirProbeIndex = $incrementContent.IndexOf('git -C "$repo_root" rev-parse --absolute-git-dir', [System.StringComparison]::Ordinal)
        $revListIndex = $incrementContent.IndexOf('git -C "$repo_root" rev-list --left-right --count', [System.StringComparison]::Ordinal)
        $pullIndex = $incrementContent.IndexOf('git -C "$repo_root" pull --ff-only', [System.StringComparison]::Ordinal)

        $repoCheckIndex | Should -BeGreaterThan -1 -Because 'increment-version must validate git worktree against package.json directory context.'
        $repoRootIndex | Should -BeGreaterThan -1 -Because 'increment-version must resolve repository root before git mutations.'
        $branchDetectIndex | Should -BeGreaterThan -1 -Because 'increment-version must detect branch in resolved repository context.'
        $fetchIndex | Should -BeGreaterThan -1 -Because 'increment-version must fetch in resolved repository context.'
        $gitDirProbeIndex | Should -BeGreaterThan -1 -Because 'increment-version must inspect merge/rebase state in resolved repository context.'
        $revListIndex | Should -BeGreaterThan -1 -Because 'increment-version must compute ahead/behind in resolved repository context.'
        $pullIndex | Should -BeGreaterThan -1 -Because 'increment-version must pull in resolved repository context.'

        $repoCheckIndex | Should -BeLessThan $repoRootIndex -Because 'worktree preflight should run before repository root resolution handling.'
        $repoRootIndex | Should -BeLessThan $branchDetectIndex -Because 'repository root must be resolved before branch detection.'
        $repoRootIndex | Should -BeLessThan $fetchIndex -Because 'repository root must be resolved before fetch.'
        $fetchIndex | Should -BeLessThan $gitDirProbeIndex -Because 'fetch should happen before merge/rebase probe and pull decision.'
        $gitDirProbeIndex | Should -BeLessThan $revListIndex -Because 'git-dir probe must precede upstream divergence calculation.'
        $revListIndex | Should -BeLessThan $pullIndex -Because 'ahead/behind calculation must happen before pull decision.'
    }

    It "uses a lock directory in increment-version to avoid concurrent writes" {
        $incrementPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/increment-version.sh'
        # Normalize to LF so multiline regex anchors work on all platforms (Windows checkout may add CR).
        $incrementContent = (Get-Content -Path $incrementPath -Raw) -replace "`r", ''

        $incrementContent | Should -Match 'function\s+acquire_lock_dir|acquire_lock_dir\s*\(\)'
        $incrementContent | Should -Match 'mkdir\s+"\$lock_dir"'
        $incrementContent | Should -Match 'trap\s+''release_lock_dir\s+"\$lock_dir"''\s+EXIT'

        $lockTrapIndex = $incrementContent.IndexOf('trap ''release_lock_dir "$lock_dir"'' EXIT', [System.StringComparison]::Ordinal)
        $lockAcquireIndex = $incrementContent.IndexOf('if ! lock_dir=$(acquire_lock_dir "$package_json_path"); then', [System.StringComparison]::Ordinal)

        $lockTrapIndex | Should -BeGreaterThan -1 -Because 'increment-version must install lock cleanup trap.'
        $lockAcquireIndex | Should -BeGreaterThan -1 -Because 'increment-version must attempt lock acquisition before mutation.'
        $lockTrapIndex | Should -BeLessThan $lockAcquireIndex -Because 'lock cleanup trap must be registered before lock acquisition to prevent stale locks on interruption.'
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
                    $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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

            $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName

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
            $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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
        $content | Should -Match 'Test-IsPathUnderRoot\s+-path\s+\$candidateItem\.FullName\s+-root\s+\$scanPlan\.ResolvedScanRoot' -Because 'Git-stream scope filtering should use materialized file paths to avoid alias-vs-canonical mismatches.'
        $content | Should -Not -Match '\$scanFiles\s*=\s*@\(\$scanPlan\.Files\)'
        $content | Should -Match 'Get-ScannableFileStream\s+-scanPlan\s+\$scanPlan\s*\|'
        $content | Should -Match 'listedPaths=deferred'
        $content | Should -Not -Match 'listedPaths=\$\(\$listedPathCount\)'
        $content | Should -Not -Match 'Get-GitCommandDetails\s+-gitExecutable\s+\$gitCommand\.Source\s+-workingDirectory\s+\$gitRoot\s+-arguments\s+\$gitListArguments\s*\r?\n\s*if\s*\(\$gitListResult\.ExitCode\s*-eq\s*0\)'
        $content | Should -Not -Match 'function\s+Get-GitIgnorePatterns'
        $content | Should -Not -Match 'function\s+Test-PathAgainstGitIgnore'
    }

    It "preserves caller scan scope when git show-prefix fails in Remove-BOM" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $content = (Get-Content -LiteralPath $removeBomPath -Raw) -replace "`r", ''

        $content | Should -Match 'function\s+Resolve-CanonicalFileSystemPath' -Because 'Remove-BOM must centralize canonical path resolution for symlink-safe comparisons'
        $content | Should -Match '\$resolvedScanRoot\s*=\s*Resolve-CanonicalFileSystemPath\s+-path\s+\$scanRoot' -Because 'The scan root must be canonicalized once at discovery entry'
        $content | Should -Match '\$gitRoot\s*=\s*Resolve-CanonicalFileSystemPath\s+-path\s+\$gitRootCandidate' -Because 'git root must be canonicalized with the same helper as scan roots'

        # When --show-prefix fails, the canonicalScanRoot must NOT be assigned $gitRoot.
        # It must use the caller's original scope to prevent scope leaks.
        $content | Should -Match 'W_REMOVE_BOM_GIT_PREFIX_UNAVAILABLE' -Because 'Remove-BOM must emit a diagnostic when --show-prefix fails'

        # Extract the full canonicalScanRoot if/else assignment block.
        $fullBlock = [regex]::Match(
            $content,
            '(?ms)\$canonicalScanRoot\s*=\s*if\s*\(\$relativeScanRoot\s*-eq\s*"\."\)\s*\{(?<dotBranch>[^}]+)\}\s*else\s*\{(?<elseBranch>[^}]+)\}'
        )
        $fullBlock.Success | Should -BeTrue -Because 'Remove-BOM must have a canonicalScanRoot if/else assignment with both "." and non-"." branches'

        # ---- "." branch: MUST use caller's $resolvedScanRoot with symlink resolution ----
        $dotBranch = $fullBlock.Groups['dotBranch'].Value.Trim()
        $dotBranch | Should -Match '\$resolvedScanRoot' -Because 'The "." branch must use $resolvedScanRoot to preserve caller scope'
        $dotBranch | Should -Not -Match '\$gitRoot' -Because 'The "." branch must NOT use $gitRoot (scope-leak risk)'

        # ---- else branch: MUST canonicalize through helper for symlink-safe normalization ----
        $elseBranch = $fullBlock.Groups['elseBranch'].Value.Trim()
        $elseBranch | Should -Match 'Resolve-CanonicalFileSystemPath' -Because 'The else branch must canonicalize via Resolve-CanonicalFileSystemPath for symlink-safe comparisons'
        $elseBranch | Should -Match '\$gitRoot' -Because 'The else branch must derive the canonical scan root from $gitRoot + relative path'

        # Diagnostics must include resolvedScanRoot for traceability.
        $content | Should -Match 'resolvedScanRoot=\$resolvedScanRoot' -Because 'Discovery diagnostics must include the original resolvedScanRoot for debugging scope issues'
        $content | Should -Match 'scanRootInput=\$scanRootInput' -Because 'Discovery diagnostics must include the caller-provided scan root for alias-vs-canonical troubleshooting'
        $content | Should -Match '\$relativePrefixSegments\s*=\s*@\(\$relativeScanRoot\s+-split\s+''\[\\\\/\]\+''' -Because 'Out-of-root protection should inspect normalized prefix segments for traversal components.'
        $content | Should -Match 'Test-IsPathUnderRoot\s+-path\s+\$relativePrefixCandidateRoot\s+-root\s+\$gitRoot' -Because 'Out-of-root protection should validate canonicalized prefix roots against the git root boundary.'
    }

    It "keeps Remove-BOM canonical path resolution robust and diagnosable" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $content = (Get-Content -LiteralPath $removeBomPath -Raw) -replace "`r", ''

        $content | Should -Match 'E_REMOVE_BOM_CANONICAL_PATH_RESOLUTION_FAILED' -Because 'Canonicalization failures must emit a stable diagnostic for root-cause triage.'
        $content | Should -Match 'function\s+Resolve-UnixPhysicalPath' -Because 'Unix physical-path fallback should remain centralized to cover provider-level alias resolution gaps.'
        $content | Should -Match 'relativeScanRootSource=' -Because 'Discovery diagnostics should identify which show-prefix handling mode was used during git-native scope derivation.'
        $content | Should -Match 'function\s+Resolve-TopLevelPathAlias' -Because 'Top-level alias canonicalization must remain centralized.'
        $content | Should -Match 'PSObject\.Properties\.Name\s+-contains\s+"LinkTarget"' -Because 'Alias resolution should consume provider link metadata when available.'
        $content | Should -Match 'PSObject\.Properties\.Name\s+-contains\s+"Target"' -Because 'Alias resolution should support alternate provider target metadata.'
        $content | Should -Match '\$topLevelItem\.FullName' -Because 'Alias resolution should fall back to item FullName when explicit link metadata is unavailable.'
        $content | Should -Match 'aliasResolutionSource\s*=\s*"pwd-physical"' -Because 'Alias resolution should preserve a physical-path fallback source marker for diagnostics and regression hardening.'
        $content | Should -Match 'Get-Item\s+-LiteralPath\s+\$resolvedPath\s+-ErrorAction\s+Stop' -Because 'Canonicalization should materialize the resolved path directly.'
        $content | Should -Not -Match '\$pathSegments\s*=' -Because 'Segment-by-segment canonicalization is fragile across runner path aliases and should not be reintroduced.'
        $content | Should -Not -Match 'foreach\s*\(\$segment\s+in\s+\$pathSegments\)' -Because 'Canonicalization should avoid intermediate segment traversal.'
    }

    It "keeps explicit prefix-read diagnostics in Remove-BOM" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $content = (Get-Content -LiteralPath $removeBomPath -Raw) -replace "`r", ''

        $content | Should -Match 'W_REMOVE_BOM_READ_PREFIX_FAILED'
        $content | Should -Match 'W_REMOVE_BOM_PREFIX_READ_FAILURES'
        $content | Should -Match '\$script:prefixReadFailures\s*=\s*0'
        $content | Should -Match 'processedCandidates=' -Because 'Git stream failures should include processed candidate counts for actionable diagnostics.'
    }

    It "keeps Remove-BOM discovery fallback diagnostics and direct-run guard" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $content = (Get-Content -LiteralPath $removeBomPath -Raw) -replace "`r", ''

        $content | Should -Match 'function\s+Get-FallbackSafetyAssessment' -Because 'Fallback safety checks should be centralized to avoid duplicated and drifting ancestor-walk logic.'
        $content | Should -Match 'Get-FallbackSafetyAssessment\s+-resolvedScanRoot\s+\$resolvedScanRoot\s+-comparison\s+\$comparison' -Because 'Resolve-ScannableFileDiscovery should consume the centralized fallback safety assessment.'
        $content | Should -Match 'W_REMOVE_BOM_GIT_DISCOVERY_FALLBACK'
        $content | Should -Match 'E_REMOVE_BOM_GIT_DISCOVERY_REQUIRED'
        $content | Should -Match 'fallbackScope=' -Because 'Fallback diagnostics should expose scope mode (scan-root-only vs repository-ancestors).'
        $content | Should -Match 'checkedAncestors=' -Because 'Fallback diagnostics should report how many ancestor levels were safety-checked.'
        $content | Should -Match 'gitBoundary=' -Because 'Fallback diagnostics should include detected repository boundary identity when available.'
        $content | Should -Match 'filesystem-fallback'
        $content | Should -Match 'if\s*\(\$MyInvocation\.InvocationName\s*-ne\s*"\."\)\s*\{\s*Invoke-Main'
    }

    It "prunes excluded directories during Remove-BOM filesystem fallback traversal" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $content = (Get-Content -LiteralPath $removeBomPath -Raw) -replace "`r", ''

        $content | Should -Match 'function\s+Get-FallbackFileStream'
        $content | Should -Match 'Queue\[string\]'
        $content | Should -Match 'Test-DirectoryPathAgainstPatterns'
        $content | Should -Match 'foreach\s*\(\$linkMetadataPropertyName\s+in\s+@\(''LinkTarget'',\s*''Target''\)\)'
        $content | Should -Match 'prunedSymlinkDirectories='
        $content | Should -Match 'fallbackTraversal=directory-pruned'
        $content | Should -Match 'Remove-BOM fallback traversal diagnostics:'
        $content | Should -Not -Match 'Get-ChildItem\s+-LiteralPath\s+\$scanPlan\.ResolvedScanRoot\s+-File\s+-Recurse\s*\|\s*\r?\n\s*Where-Object'
    }
}

Describe "Restore script safety conventions" {
    It "enforces strict mode and isolated child execution in Restore orchestrator" {
        $restoreScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Restore.ps1') -Raw) -replace "`r", ''

        $restoreScript | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
        $restoreScript | Should -Match '\$ErrorActionPreference\s*=\s*"Stop"'
        $restoreScript | Should -Match 'Resolve-PowerShellExecutablePath'
        $restoreScript | Should -Not -Match 'Get-Command\s+-Name\s+"pwsh"'
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
        $windowsTerminalRestore | Should -Match 'if\s*\(\s*Test-Path\s+-LiteralPath\s+\$windowsTerminalSettings\s+-PathType\s+Leaf\s*\)\s*\{[\s\S]*?Copy-Item\s+-LiteralPath\s+\$windowsTerminalSettings\s+-Destination\s+\$currentBackupFile'
        $windowsTerminalRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$settingsPath\s+-PathType\s+Leaf'
        $windowsTerminalRestore | Should -Match 'E_WT_RESTORE_SOURCE_MISSING'
        $windowsTerminalRestore | Should -Match 'W_WT_RESTORE_NO_LIVE_SETTINGS'
    }

    It "discovers PowerShell backup sources and restores profile targets cross-platform" {
        $powershellRestore = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Powershell/PowershellRestore.ps1') -Raw) -replace "`r", ''

        $powershellRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$settingsDir\s+-PathType\s+Container'
        $powershellRestore | Should -Match 'Get-ChildItem\s+-LiteralPath\s+\$settingsDir\s+-Filter\s+"\*\$profileLeafName"\s+-File'
        $powershellRestore | Should -Match 'Sort-Object\s+Name\s+-CaseSensitive'
        $powershellRestore | Should -Match 'Get-PreferredBackupForProfileName'
        $powershellRestore | Should -Match 'Write-Error\s+"E_POWERSHELL_RESTORE_SOURCE_MISSING:'
        $powershellRestore | Should -Match 'E_POWERSHELL_RESTORE_NO_TARGET_PROFILES'
        $powershellRestore | Should -Match 'E_POWERSHELL_RESTORE_FALLBACK_SOURCE_INVALID'
        $powershellRestore | Should -Match 'E_POWERSHELL_RESTORE_SELECTED_SOURCE_MISSING'
        $powershellRestore | Should -Match '(?-i)Microsoft\.PowerShell_profile\.ps1'
        $powershellRestore | Should -Not -Match '(?-i)Microsoft\.Powershell_profile\.ps1'
        $powershellRestore | Should -Match '\$PROFILE\.CurrentUserCurrentHost'
        $powershellRestore | Should -Match '\$PROFILE\.CurrentUserAllHosts'
        $powershellRestore | Should -Match 'if\s*\(Test-IsWindowsPlatform\)\s*\{[\s\S]*Join-Path\s+-Path\s+\$HOME\s+-ChildPath\s+''Documents''[\s\S]*Join-Path\s+-Path\s+\$documentsPath\s+-ChildPath\s+''WindowsPowerShell''' -Because 'Legacy Windows PowerShell paths should only be restored on Windows (via the cross-version Test-IsWindowsPlatform helper).'
        $powershellRestore | Should -Not -Match '\$HOME\\Documents\\PowerShell'
        $powershellRestore | Should -Not -Match '\$HOME\\Documents\\Powershell'
        $powershellRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$sourcePath\s+-PathType\s+Leaf'
        $powershellRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$target\.Path\s+-PathType\s+Leaf'
        $powershellRestore | Should -Match 'Copy-Item\s+-LiteralPath\s+\$sourcePath\s+-Destination\s+\$target\.Path\s+-Force'
        $powershellRestore | Should -Match 'W_POWERSHELL_RESTORE_NO_EXISTING_TARGET_PROFILE'
        $powershellRestore | Should -Match 'PowerShell restore source diagnostics:'
        $powershellRestore | Should -Match 'PowerShell restore fallback diagnostics:'
        $powershellRestore | Should -Match 'PowerShell restore target diagnostics:'
    }

    It "validates required Komorebi source files before restore copy" {
        $komorebiRestore = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Komorebi/KomorebiRestore.ps1') -Raw) -replace "`r", ''

        $komorebiRestore | Should -Match '\$missingSources\s*=\s*@\('
        $komorebiRestore | Should -Match 'E_KOMOREBI_RESTORE_SOURCE_MISSING'
        $komorebiRestore | Should -Match 'foreach\s*\(\$sourcePath\s+in\s+@\(\$komorebiSourceConfig,\s*\$komorebiSourceBarConfig,\s*\$komorebiSourceApplications\)\)'
        $komorebiRestore | Should -Match 'Test-Path\s+-LiteralPath\s+\$sourcePath\s+-PathType\s+Leaf'
        $komorebiRestore | Should -Match 'Copy-Item\s+-LiteralPath\s+\$komorebiSourceConfig'
        $komorebiRestore | Should -Match 'Copy-Item\s+-LiteralPath\s+\$komorebiSourceBarConfig'
        $komorebiRestore | Should -Match 'Copy-Item\s+-LiteralPath\s+\$komorebiSourceApplications'
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
        $backupScript | Should -Match 'param\(\s*\[Parameter\(Mandatory\s*=\s*\$false\)\]\s*\[switch\]\$Unattended\s*\)'
        $backupScript | Should -Match 'WALLSTOP_BACKUP_UNATTENDED'
        $backupScript | Should -Match 'function\s+Test-BackupTruthySettingValue'
        $backupScript | Should -Match 'if\s*\(\s*\$hasBackupStepFailures\s*\)\s*\{[\s\S]*partial success:'
        $backupScript | Should -Match 'else\s*\{[\s\S]*\$commitMessage\s*=\s*"Backup for \$dateString \(\$succeededCount/\$totalCount\)"'
        $backupScript | Should -Match 'Resolve-PowerShellExecutablePath'
        $backupScript | Should -Not -Match 'Get-Command\s+-Name\s+"pwsh"'
        $backupScript | Should -Match '&\s+\$pwshCommand\s+-NoLogo\s+-NoProfile\s+-File'
        $backupScript | Should -Match 'function\s+Get-GitExecutableOrThrow'
        $backupScript | Should -Match 'Get-Command\s+-Name\s+"git"'
        $backupScript | Should -Match 'E_BACKUP_GIT_NOT_AVAILABLE'
        $backupScript | Should -Match 'function\s+Get-GitRepositoryRootOrThrow'
        $backupScript | Should -Match 'function\s+Assert-BackupGitBranchOrThrow'
        $backupScript | Should -Match '\$insideWorkTreeArgs\s*=\s*@\("-C",\s*\$repositoryRoot,\s*"rev-parse",\s*"--is-inside-work-tree"\)'
        $backupScript | Should -Match '&\s+\$gitExecutable\s+@insideWorkTreeArgs'
        $backupScript | Should -Match 'E_BACKUP_GIT_NOT_REPOSITORY'
        $backupScript | Should -Match 'E_BACKUP_GIT_BRANCH_DETECTION_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_DETACHED_HEAD'
        $backupScript | Should -Match 'E_BACKUP_GIT_BRANCH_MISMATCH'
        $backupScript | Should -Match 'E_BACKUP_GIT_TREE_DIRTY_PREFLIGHT'
        $backupScript | Should -Match 'E_BACKUP_GIT_SCOPE_VIOLATION'
        $backupScript | Should -Match 'E_BACKUP_GIT_ADD_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_DIFF_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_COMMIT_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_RESTAGE_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_COMMIT_RETRY_EMPTY_STAGE'
        $backupScript | Should -Match 'if\s*\(\s*\$retryStagedFiles\.Count\s*-eq\s*0\s*\)\s*\{[\s\S]*?E_BACKUP_GIT_COMMIT_RETRY_EMPTY_STAGE' -Because "Backup must emit explicit empty-stage diagnostics when autofix restage removes all managed staged files."
        $backupScript | Should -Match 'E_BACKUP_GIT_COMMIT_RETRY_LIMIT'
        $backupScript | Should -Match 'E_BACKUP_GIT_PULL_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_PUSH_FAILED'
        $backupScript | Should -Match 'E_BACKUP_GIT_PULL_FAILED:[\s\S]*repositoryRoot=' -Because 'Backup pull failures must include repositoryRoot for actionable diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_PULL_FAILED:[\s\S]*outputPreview=' -Because 'Backup pull failures must include outputPreview for actionable diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_ADD_FAILED:[\s\S]*repositoryRoot=' -Because 'Backup add failures must include repositoryRoot for actionable diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_ADD_FAILED:[\s\S]*pathspec=' -Because 'Backup add failures must include managed pathspec diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_ADD_FAILED:[\s\S]*outputPreview=' -Because 'Backup add failures must include outputPreview for actionable diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_RESTAGE_FAILED:[\s\S]*repositoryRoot=' -Because 'Backup restage failures must include repositoryRoot for actionable diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_RESTAGE_FAILED:[\s\S]*pathspec=' -Because 'Backup restage failures must include managed pathspec diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_RESTAGE_FAILED:[\s\S]*outputPreview=' -Because 'Backup restage failures must include outputPreview for actionable diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_PUSH_FAILED:[\s\S]*repositoryRoot=' -Because 'Backup push failures must include repositoryRoot for actionable diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_PUSH_FAILED:[\s\S]*outputPreview=' -Because 'Backup push failures must include outputPreview for actionable diagnostics.'
        $backupScript | Should -Match 'E_BACKUP_GIT_TREE_DIRTY_POSTPUSH'
        $backupScript | Should -Match 'Backup git availability diagnostics:'
        $backupScript | Should -Match 'Backup git preflight diagnostics:'
        $backupScript | Should -Match 'Backup git staging diagnostics:'
        $backupScript | Should -Match '\$diagnosticsHelpersPath\s*=\s*Join-Path\s+-Path\s+\$scriptsDirectory\s+-ChildPath\s+"Utils/Common/DiagnosticsHelpers\.ps1"'
        $backupScript | Should -Match 'E_BACKUP_DIAGNOSTICS_HELPER_MISSING'
        $backupScript | Should -Match '\.\s*\$diagnosticsHelpersPath'
        $backupScript | Should -Not -Match 'function\s+Get-OutputPreview'
        $backupScript | Should -Match 'function\s+Get-PathspecDiagnosticsText'
        $backupScript | Should -Match 'function\s+Get-GitCommandDiagnosticsOutput'
        $backupScript | Should -Match 'E_BACKUP_GIT_STATUS_FAILED:[\s\S]*repositoryRoot='
        $backupScript | Should -Match 'E_BACKUP_GIT_STATUS_FAILED:[\s\S]*pathspec='
        $backupScript | Should -Match 'E_BACKUP_GIT_STATUS_FAILED:[\s\S]*outputPreview='
        $backupScript | Should -Match 'Assert-BackupGitTreeCleanPreflight\s+-GitExecutable\s+\$gitExecutable\s+-RepositoryRoot\s+\$repositoryRoot[\s\S]*?Assert-BackupGitBranchOrThrow\s+-GitExecutable\s+\$gitExecutable\s+-RepositoryRoot\s+\$repositoryRoot\s+-ExpectedBranch\s+"main"[\s\S]*?git\s+pull\s+--ff-only\s+origin\s+main[\s\S]*?foreach\s*\(\$step\s+in\s+\$applicableSteps\)'
        $backupScript | Should -Match 'if\s*\(\s*-not\s+\$hasGitFailure\s*\)\s*\{[\s\S]*?git\s+push\s+origin\s+main'
        $backupScript | Should -Match 'if\s*\(\s*-not\s+\$hasGitFailure\s*\)\s*\{[\s\S]*?Assert-BackupGitBranchOrThrow\s+-GitExecutable\s+\$gitExecutable\s+-RepositoryRoot\s+\$repositoryRoot\s+-ExpectedBranch\s+"main"[\s\S]*?git\s+push\s+origin\s+main'
        $backupScript | Should -Match 'W_BACKUP_GIT_COMMIT_RETRY_AUTOFIX'
        $backupScript | Should -Match 'W_BACKUP_UNATTENDED_MODE_ACTIVE'
        $backupScript | Should -Match 'W_BACKUP_GIT_COMMIT_NO_VERIFY'
        $backupScript | Should -Match 'W_BACKUP_GIT_ADD_SKIPPED_PRIOR_GIT_FAILURE'
        $backupScript | Should -Match 'W_BACKUP_GIT_COMMIT_SKIPPED_PRIOR_GIT_FAILURE'
        $backupScript | Should -Match 'W_BACKUP_GIT_PUSH_SKIPPED_PRIOR_GIT_FAILURE'
        $backupScript | Should -Match 'if\s*\(\s*\$isUnattendedMode\s*\)\s*\{[\s\S]*?\$gitExecutable\s+-C\s+\$repositoryRoot\s+commit\s+--no-verify\s+-m\s+\$commitMessage[\s\S]*?\}\s*else\s*\{' -Because 'Unattended backup commits must bypass hooks with --no-verify, while attended commits use the retry/autofix branch.'
        $backupScript | Should -Not -Match 'while\s*\(\s*-not\s+\$commitSucceeded\s+-and\s+\$commitAttempt\s+-lt\s+\$maxCommitAttempts\s*\)[\s\S]*?--no-verify' -Because '--no-verify must remain scoped to unattended mode and not appear inside attended retry commits.'
        $backupScript | Should -Match 'function\s+Get-BackupManagedChangedFilesOrThrow'
        $backupScript | Should -Match 'function\s+Invoke-BackupKnownSecretSanitization'
        $backupScript | Should -Match 'function\s+Find-BackupUnknownSecretFindings'
        $backupScript | Should -Not -Match 'function\s+Test-BackupLikelyBinaryFile\b'
        $backupSecretHygieneHelpers = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/BackupSecretHygieneHelpers.ps1') -Raw
        $backupSecretHygieneHelpers | Should -Not -Match 'function\s+Test-BackupSecretHygieneLikelyBinaryFile\b'
        $backupScript | Should -Match 'W_BACKUP_SECRET_SANITIZED'
        $backupScript | Should -Match 'E_BACKUP_SECRET_SCAN_FAILED'
        $backupScript | Should -Match 'W_BACKUP_SECRET_SCAN_SKIPPED_PRIOR_GIT_FAILURE'
        $backupScript | Should -Match 'Get-BackupManagedChangedFilesOrThrow\s+-GitExecutable\s+\$gitExecutable\s+-RepositoryRoot\s+\$repositoryRoot\s+-ManagedPathspecs\s+\$managedPathspecs[\s\S]*?Invoke-BackupKnownSecretSanitization\s+-RepositoryRoot\s+\$repositoryRoot\s+-RelativePaths\s+\$managedChangedFiles[\s\S]*?Find-BackupUnknownSecretFindings\s+-RepositoryRoot\s+\$repositoryRoot\s+-RelativePaths\s+\$managedChangedFiles[\s\S]*?\$gitAddArgs\s*=\s*@\("-C",\s*\$repositoryRoot,\s*"add",\s*"--"\)' -Because 'Secret sanitization and unknown-secret scanning must run on managed backup files before staging and commit.'
        $backupScript | Should -Match 'Write-Host\s+"INFO_BACKUP_FORMATTER_BOUNDARY:[^"]*pre-commit run --all-files'
        $backupScript | Should -Match 'E_BACKUP_STEP_SELECTION_INVALID'
        $backupScript | Should -Match 'Assert-ApplicableBackupStepsFlat\s+-ApplicableSteps\s+\$applicableSteps'
        $backupScript | Should -Match 'Get-BackupManagedPathspecs'
        $backupScript | Should -Match 'Assert-BackupManagedPathspecs\s+-ManagedPathspecs\s+\$managedPathspecs'
        $backupScript | Should -Match 'E_BACKUP_GIT_SCOPE_PATHSPEC_EMPTY'
        $backupScript | Should -Match 'E_BACKUP_GIT_SCOPE_PATHSPEC_INVALID'
        $backupScript | Should -Match '\$outsideManagedPathspec\s*=\s*@\("\."\)'
        $backupScript | Should -Match '"\:\(exclude\)\$managedPathspec"'
        $backupScript | Should -Match '\$gitAddArgs\s*=\s*@\("-C",\s*\$repositoryRoot,\s*"add",\s*"--"\)'
        $backupScript | Should -Not -Match 'git\s+add\s+--all'
        $backupScript | Should -Not -Match 'git\s+push\s+(?:--force|-f)\b'
        $backupScript | Should -Not -Match 'RelativeScriptPath\s*=\s*"Utils/FormatPowershellScripts\.ps1"'
        $backupScript | Should -Not -Match 'return\s*,\s*\$applicableSteps\.ToArray\(\)'
        # git pull --ff-only must appear before staging/commit to avoid local-vs-remote divergence.
        $backupScript | Should -Match '\$gitExecutable\s+-C\s+\$repositoryRoot\s+pull\s+--ff-only\s+origin\s+main[\s\S]*?\$gitAddArgs\s*=\s*@\("-C",\s*\$repositoryRoot,\s*"add",\s*"--"\)' -Because "git pull --ff-only must execute before staging managed backup outputs"
        $backupScript | Should -Match '\$gitExecutable\s+-C\s+\$repositoryRoot\s+pull\s+--ff-only\s+origin\s+main[\s\S]*?\$gitExecutable\s+-C\s+\$repositoryRoot\s+commit\s+-m\s+\$commitMessage' -Because "git pull --ff-only must execute before git commit; committing first causes --ff-only to fail when origin/main has advanced"
        $backupScript | Should -Match 'while\s*\(\s*-not\s+\$commitSucceeded\s+-and\s+\$commitAttempt\s+-lt\s+\$maxCommitAttempts\s*\)'
        $backupScript | Should -Match 'files were modified by this hook\|modified by this hook\|hook\.\+modified'
        $backupScript | Should -Match 'if\s*\(\s*\$commitAttempt\s+-ge\s+\$maxCommitAttempts\s*\)\s*\{[\s\S]*?E_BACKUP_GIT_COMMIT_RETRY_LIMIT:[\s\S]*?lastOutputPreview=' -Because "Backup commit retry logic must fail immediately on final autofix attempt without restaging."
        $backupScript | Should -Match 'W_BACKUP_GIT_COMMIT_RETRY_AUTOFIX:[\s\S]*before retry attempt \{0\} of \{1\}' -Because "Retry diagnostics should reference the next attempt, not the attempt that just failed."
        $backupScript | Should -Match 'E_BACKUP_GIT_COMMIT_RETRY_LIMIT:[\s\S]*\$commitAttempt,\s*\$maxCommitAttempts,\s*\$maxAutofixRetries' -Because "Retry-limit diagnostics must report real attempts performed and configured bounds."
        $backupScript | Should -Not -Match 'E_BACKUP_GIT_COMMIT_RETRY_LIMIT:[\s\S]*autofix retry attempt\(s\)' -Because "Retry-limit wording must distinguish total attempts from retry count."
    }

    It "keeps Backup.ps1 free of unused local function definitions" {
        $backupPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Backup.ps1"
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($backupPath, [ref]$tokens, [ref]$parseErrors)

        @($parseErrors).Count | Should -Be 0 -Because "Backup.ps1 must parse before unused helper policy can be validated."

        $functionDefinitions = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true))
        $invokedFunctionNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $commandNodes = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true))

        foreach ($commandNode in $commandNodes) {
            $commandName = $commandNode.GetCommandName()
            if (-not [string]::IsNullOrWhiteSpace($commandName)) {
                [void]$invokedFunctionNames.Add($commandName)
            }
        }

        $unusedFunctions = New-Object System.Collections.Generic.List[string]
        foreach ($functionDefinition in $functionDefinitions) {
            if (-not $invokedFunctionNames.Contains($functionDefinition.Name)) {
                $unusedFunctions.Add("$($functionDefinition.Name):$($functionDefinition.Extent.StartLineNumber)") | Out-Null
            }
        }

        $unusedFunctions.Count | Should -Be 0 -Because (
            "Backup.ps1 local helpers should be directly used by the orchestrator; remove unused thin wrappers instead of keeping dead compatibility surface. Unused definitions: {0}" -f ($unusedFunctions -join ", ")
        )
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
                $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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
        $updateScript | Should -Match 'SupportedPlatforms\s*=\s*@\("Windows"\)'
        $updateScript | Should -Match 'W_UPDATE_STEP_SKIPPED_PLATFORM'
        $updateScript | Should -Match 'E_UPDATE_STEP_SELECTION_INVALID'
        $updateScript | Should -Match 'Assert-ApplicableUpdateStepsFlat\s+-ApplicableSteps\s+\$applicableSteps'
        $updateScript | Should -Match 'Update platform diagnostics:'
        $updateScript | Should -Match 'Write-Host\s+"INFO_UPDATE_FORMATTER_BOUNDARY:[^"]*pre-commit run --all-files'
        $updateScript | Should -Not -Match 'RelativeScriptPath\s*=\s*"Utils/FormatPowershellScripts\.ps1"'
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
        $windowsTerminalBackup | Should -Match 'Copy-Item\s+-LiteralPath\s+\$sourcePath\s+-Destination\s+\$backupFile'
    }

    It "uses profile-driven path-safe backup and fails when no PowerShell profiles are available" {
        $powershellBackup = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Powershell/PowershellBackup.ps1') -Raw) -replace "`r", ''

        $powershellBackup | Should -Match 'Join-Path\s+-Path\s+\(Join-Path\s+-Path\s+\$baseDirectory\s+-ChildPath\s+"Config"\)\s+-ChildPath\s+"Powershell"'
        $powershellBackup | Should -Match '\$PROFILE\.CurrentUserCurrentHost'
        $powershellBackup | Should -Match '\$PROFILE\.CurrentUserAllHosts'
        $powershellBackup | Should -Match '\$pathComparer\s*=\s*if\s*\(Test-IsWindowsPlatform\)'
        $powershellBackup | Should -Match 'HashSet\[string\]\(\$pathComparer\)'
        $powershellBackup | Should -Match 'W_POWERSHELL_BACKUP_PROFILE_MISSING\('
        $powershellBackup | Should -Match 'PowerShell backup profile discovery diagnostics:'
        $powershellBackup | Should -Match 'Join-Path\s+-Path\s+\$backupFolder\s+-ChildPath\s+\$canonicalLeafName'
        $powershellBackup | Should -Match 'Copy-Item\s+-LiteralPath\s+\$candidate\.Path\s+-Destination\s+\$canonicalBackupFile\s+-Force'
        $powershellBackup | Should -Match 'PowerShell canonical backup diagnostics:'
        $powershellBackup | Should -Match 'PowerShell backup output diagnostics:'
        $powershellBackup | Should -Not -Match '\$backupFolder\s*=\s*"\$baseDirectory\\Config\\Powershell"'
        $powershellBackup | Should -Not -Match '\$HOME\\Documents\\PowerShell'
        $powershellBackup | Should -Not -Match '\$HOME\\Documents\\WindowsPowerShell'
        $powershellBackup | Should -Match '\$profilesBackedUp\s*=\s*0'
        $powershellBackup | Should -Match 'if\s*\(\s*\$profilesBackedUp\s*-eq\s*0\s*\)'
        $powershellBackup | Should -Match 'E_POWERSHELL_BACKUP_NO_PROFILES_FOUND'
        $powershellBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$backupFolder\s+-PathType\s+Container'
        $powershellBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$candidate\.Path\s+-PathType\s+Leaf'
        $powershellBackup | Should -Match 'Copy-Item\s+-LiteralPath\s+\$candidate\.Path\s+-Destination\s+\$backupFile'
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
        $powerToysBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$backupFolder\s+-PathType\s+Container'
        $powerToysBackup | Should -Match '\[System\.IO\.Directory\]::CreateDirectory\(\$backupFolder\)'
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
        $komorebiBackup | Should -Match 'Copy-Item\s+-LiteralPath\s+\$komorebiConfig'
        $komorebiBackup | Should -Match 'Copy-Item\s+-LiteralPath\s+\$komorebiBarConfig'
        $komorebiBackup | Should -Match 'Copy-Item\s+-LiteralPath\s+\$applicationYaml'
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

        $dxMessagingBackup | Should -Match 'E_DXMSG_BACKUP_DEST_CREATE_FAILED'
        $dxMessagingBackup | Should -Match 'E_DXMSG_BACKUP_SOURCE_MISSING'
        $dxMessagingBackup | Should -Match 'E_DXMSG_BACKUP_UNEXPECTED'
        $dxMessagingBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$sourcePath\s+-PathType\s+Container'
        $dxMessagingBackup | Should -Match 'Test-Path\s+-LiteralPath\s+\$backupDir\s+-PathType\s+Container'
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
            $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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
                    $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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
    It "canonicalizes temp directory roots in test files that compute relative paths" {
        # On macOS, GetTempPath() returns /var/folders/... (symlink) but FileInfo.FullName
        # returns /private/var/folders/... (canonical). Tests that compute GetRelativePath
        # on temp-created paths must canonicalize the base via Resolve-CanonicalTempRoot
        # to prevent ../../../../../../private/var/... relative path mismatches.
        $testsRoot = Join-Path -Path $script:repoRoot -ChildPath 'Tests'
        $testFiles = @(Get-ChildItem -Path $testsRoot -Filter '*.Tests.ps1' -File -Recurse -ErrorAction Stop)

        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($testFile in $testFiles) {
            $content = (Get-Content -LiteralPath $testFile.FullName -Raw) -replace "`r", ''
            $usesGetTempPath = $content -match '\[System\.IO\.Path\]::GetTempPath\(\)'
            # Cover both the native method and the cross-version Get-RelativePathCompat shim
            # so files that migrated to the portable helper still fall under this policy.
            $usesGetRelativePath = ($content -match '\[System\.IO\.Path\]::GetRelativePath\(') -or ($content -match '\bGet-RelativePathCompat\b')
            if ($usesGetTempPath -and $usesGetRelativePath) {
                $definesHelper = $content -match 'function\s+Resolve-CanonicalTempRoot\s*\{'
                $usesHelper = $content -match 'Resolve-CanonicalTempRoot\s+-Path\b'
                if (-not ($definesHelper -and $usesHelper)) {
                    $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $testFile.FullName
                    $violations.Add($relativePath) | Out-Null
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Test files that create temp directories (GetTempPath) and compute relative paths (GetRelativePath) must canonicalize the temp root via Resolve-CanonicalTempRoot after directory creation to prevent macOS symlink aliasing (/var vs /private/var). See .llm/context.md 'Test Temp Directory Canonicalization'. Violations: {0}" -f ($violations -join ', ')
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

    It "keeps GraphQL variable payload keys aligned with declared casing" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$parseErrors)
        $targetFunction = Get-RequiredFunctionDefinitionAst -Ast $ast -Name "Get-UnresolvedReviewThreads" -Context "GraphQL variable-map contracts"
        $functionBody = $targetFunction.Body.Extent.Text

        $variablesMatch = [regex]::Match($functionBody, '(?ms)\$variables\s*=\s*@\{(?<body>.*?)^\s*\}')
        $variablesMatch.Success | Should -BeTrue -Because "Get-UnresolvedReviewThreads should define a variables hashtable"
        $variablesBody = $variablesMatch.Groups["body"].Value

        $functionBody | Should -Match 'query\s+GetReviewThreads\([\s\S]*\$owner:\s*String![\s\S]*\$repo:\s*String![\s\S]*\$prNumber:\s*Int![\s\S]*\$first:\s*Int![\s\S]*\$after:\s*String'
        $variablesBody | Should -Match '\bowner\s*=\s*\$Owner'
        $variablesBody | Should -Match '\brepo\s*=\s*\$Repo'
        $variablesBody | Should -Match '\bprNumber\s*=\s*\$PrNumber'
        $variablesBody | Should -Match '\bfirst\s*=\s*\$PerPage'
        $variablesBody | Should -Match '\bafter\s*=\s*\$cursor'
        ($variablesBody -cmatch '\bOwner\s*=') | Should -BeFalse
        ($variablesBody -cmatch '\bRepo\s*=') | Should -BeFalse
        $functionBody | Should -Match 'Assert-GraphQLVariableMap\s+-Query\s+\$query\s+-Variables\s+\$variables\s+-Context\s+"Get-UnresolvedReviewThreads"\s+-RejectUnexpectedVariables'
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

    It "keeps source-aware auth token recovery contracts in Invoke-Main" {
        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$parseErrors)

        @($parseErrors).Count | Should -Be 0 -Because "Get-UnresolvedPRComments.ps1 must parse for policy checks to be meaningful"

        $resolveFunction = Get-RequiredFunctionDefinitionAst -Ast $ast -Name "Resolve-AuthTokenWithSource" -Context "source-aware token precedence"
        $invokeMainFunction = Get-RequiredFunctionDefinitionAst -Ast $ast -Name "Invoke-Main" -Context "auth fallback contracts"

        $resolveBodyText = $resolveFunction.Body.Extent.Text
        $ghTokenIndex = $resolveBodyText.IndexOf('-CandidateToken $env:GH_TOKEN', [System.StringComparison]::Ordinal)
        $githubTokenIndex = $resolveBodyText.IndexOf('-CandidateToken $env:GITHUB_TOKEN', [System.StringComparison]::Ordinal)

        $ghTokenIndex | Should -BeGreaterOrEqual 0
        $githubTokenIndex | Should -BeGreaterOrEqual 0
        ($ghTokenIndex -lt $githubTokenIndex) | Should -BeTrue -Because "GH_TOKEN must be evaluated before GITHUB_TOKEN"

        $invokeMainBodyText = $invokeMainFunction.Body.Extent.Text
        $invokeMainBodyText | Should -Match '\$rejectedTokenValues\s*=\s*New-Object\s+System\.Collections\.Generic\.HashSet\[string\]'
        $invokeMainBodyText | Should -Match 'Get-AuthToken[^\n]*-ExplicitToken\s+\$Token[^\n]*-AllowInteractive:\$false[^\n]*-IncludeSourceMetadata'
        $invokeMainBodyText | Should -Match 'Refresh\s+or\s+unset\s+GH_TOKEN'
        $invokeMainBodyText | Should -Match 'GH_TOKEN\s+takes\s+precedence\s+over\s+GITHUB_TOKEN'

        $getAuthTokenCalls = @($invokeMainFunction.Body.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq "Get-AuthToken"
                }, $true))
        $getAuthTokenCalls.Count | Should -BeGreaterOrEqual 2 -Because "Invoke-Main should call Get-AuthToken for initial resolution and prompted retry"

        $hasIncludeSourceMetadata = $false
        $hasBypassEnvironmentRetry = $false
        foreach ($call in $getAuthTokenCalls) {
            $parameterNames = @($call.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst]
                } | ForEach-Object {
                    $_.ParameterName
                })

            if ($parameterNames -contains "IncludeSourceMetadata") {
                $hasIncludeSourceMetadata = $true
            }

            if (($parameterNames -contains "IgnoreEnvironmentTokens") -and ($parameterNames -contains "RejectedTokenValues")) {
                $hasBypassEnvironmentRetry = $true
            }
        }

        $hasIncludeSourceMetadata | Should -BeTrue
        $hasBypassEnvironmentRetry | Should -BeTrue
    }
}

Describe "Workflow security conventions" {
    It "does not reintroduce broad security scanning into the GitHub utility coverage workflow" {
        $workflow = Get-Content -Path $script:workflowPath -Raw

        $workflow | Should -Not -Match 'Security pattern checks'
        $workflow | Should -Not -Match 'scanner_engine=|active_pattern=|match_count='
        $workflow | Should -Not -Match 'should_detect=|should_ignore=|Scanner corpus failure'
        $workflow | Should -Not -Match 'Generated artifact tracking checks|git ls-files coverage\.xml out\.txt'
    }

    It "carries broad security and generated-artifact checks in the canonical script-quality workflow" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw

        $workflow | Should -Match 'Security pattern checks'
        $workflow | Should -Match 'Generated artifact tracking checks'
        $workflow | Should -Match 'git ls-files coverage\.xml out\.txt'
        $workflow | Should -Match 'git ls-files -z --'
        $workflow | Should -Not -Match "':\(exclude\)Tests/\*\*'"
        $workflow | Should -Not -Match "':\(exclude\)\.github/workflows/script-quality\.yml'"
        $workflow | Should -Match 'command_scan_files='
        $workflow | Should -Match 'Tests/\*\*\|\*\.md\|\.llm/\*'
        $workflow | Should -Match 'filter_allowed_security_matches'
        $workflow | Should -Match 'is_allowed_security_match'
        $workflow | Should -Match 'allowed_match_count='
        $workflow | Should -Match 'expected_allowed_match_count=1'
        $workflow | Should -Not -Match '\.github/workflows/script-quality\.yml:\*'
        $workflow | Should -Not -Match '\*\\"token_pattern_rg='
    }

    It "uses broad GitHub token patterns in the canonical workflow scanner and pre-commit redaction" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw
        $preCommitValidationPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $preCommitValidationContent = Get-Content -Path $preCommitValidationPath -Raw
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $scriptContent = Get-Content -Path $scriptPath -Raw

        $workflow | Should -Match 'gh\[pousr\]_\[A-Za-z0-9_\]\{20,\}'
        $workflow | Should -Match 'github_pat_\[A-Za-z0-9_\]\{20,\}'
        $workflow | Should -Not -Match '\(ghp_\|github_pat_\|Authorization'
        $workflow | Should -Not -Match 'gh[pousr]_[A-Za-z0-9_]{20,}'
        $workflow | Should -Not -Match 'github_pat_[A-Za-z0-9_]{20,}'

        $preCommitValidationContent | Should -Match 'gh\[pousr\]_\[A-Za-z0-9_\]\{20,\}'
        $preCommitValidationContent | Should -Match 'github_pat_\[A-Za-z0-9_\]\{20,\}'

        $scriptContent | Should -Match 'gh\[pousr\]_\[A-Za-z0-9_\]\{20,\}'
        $scriptContent | Should -Match 'github_pat_\[A-Za-z0-9_\]\{20,\}'
    }

    It "scans both bearer and token authorization header schemes in the canonical workflow" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $scriptContent = Get-Content -Path $scriptPath -Raw

        $workflow | Should -Match '\(Bearer\|token\)'
        $scriptContent | Should -Match '\(Bearer\|token\)'
    }

    It "keeps scanner and script authorization redaction schemes aligned" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $scriptContent = Get-Content -Path $scriptPath -Raw
        $redactionPatternLiteral = '(Bearer|token)\s+[A-Za-z0-9_\-\.]{20,}'

        $workflow | Should -Match '\(Bearer\|token\)'
        $scriptContent | Should -Match ([regex]::Escape($redactionPatternLiteral))
    }

    It "prints scanner diagnostics and validates behavior corpus in script-quality" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw

        $workflow | Should -Match 'scanner_engine='
        $workflow | Should -Match 'active_pattern='
        $workflow | Should -Match 'match_count='
        $workflow | Should -Match 'tracked_file_count='
        $workflow | Should -Match 'command_file_count='
        $workflow | Should -Match 'allowed_match_count='
        $workflow | Should -Match 'Scanner allowlist drift'
        $workflow | Should -Match 'should_detect='
        $workflow | Should -Match 'should_ignore='
        $workflow | Should -Match 'sample_ghp="gh""p_0123456789abcdef0123456789abcdef0123"'
        $workflow | Should -Match 'sample_ghs="gh""s_0123456789abcdef0123"'
        $workflow | Should -Match 'sample_gho="gh""o_0123456789abcdef0123"'
        $workflow | Should -Match 'sample_ghu="gh""u_0123456789abcdef0123"'
        $workflow | Should -Match 'sample_ghr="gh""r_0123456789abcdef0123"'
        $workflow | Should -Match '"example-token: \$\{sample_ghs\}"'
        $workflow | Should -Match '"example-token: \$\{sample_gho\}"'
        $workflow | Should -Match '"example-token: \$\{sample_ghu\}"'
        $workflow | Should -Match '"example-token: \$\{sample_ghr\}"'
        $workflow | Should -Match 'Scanner corpus failure'
    }

    It "uses equivalent iex boundary patterns in rg and grep scanner paths" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw

        $workflow | Should -Match 'invoke_expression_pattern="Invoke-""Expression"'
        $workflow | Should -Match 'iex_alias_pattern="i""ex"'
        $workflow | Should -Match 'dangerous_pattern_rg="\$\{invoke_expression_pattern\}"'
        $workflow | Should -Match 'dangerous_pattern_grep="\$\{invoke_expression_pattern\}"'
        $workflow | Should -Match '\$\{iex_alias_pattern\}'
        $workflow | Should -Not -Match "dangerous_pattern_rg='Invoke-Expression"
        $workflow | Should -Not -Match "dangerous_pattern_grep='Invoke-Expression"
    }

    It "documents SC2016 suppressions for literal regex and PowerShell corpus samples" {
        $workflow = Get-Content -Path $script:crossLanguageWorkflowPath -Raw

        $workflow | Should -Match '# shellcheck disable=SC2016 # Reason: regex intentionally includes a literal end-of-line anchor'
        $workflow | Should -Match '# shellcheck disable=SC2016 # Reason: corpus samples are literal PowerShell snippets'
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

        $ecosystems.Count | Should -Be 4
        @($ecosystems | Sort-Object -Unique) | Should -Be @('devcontainers', 'github-actions', 'pip', 'pre-commit') -Because (
            "Dependabot coverage must remain aligned to the agreed tooling areas"
        )
    }

    It "uses Monday 03:00 UTC weekly schedule for each configured ecosystem" {
        $content = (Get-Content -Path $script:dependabotConfigPath -Raw) -replace "`r", ''

        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*interval:\s*(?:"weekly"|weekly)\s*$')).Count | Should -Be 4
        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*day:\s*(?:"monday"|monday)\s*$')).Count | Should -Be 4
        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*time:\s*(?:"03:00"|03:00)\s*$')).Count | Should -Be 4
        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*timezone:\s*(?:"UTC"|UTC)\s*$')).Count | Should -Be 4
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

        foreach ($ecosystem in @('github-actions', 'pre-commit', 'pip', 'devcontainers')) {
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

        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*directory:\s*(?:"/"|/)\s*$')).Count | Should -Be 4
    }

    It "caps open version-update PR volume per ecosystem and keeps default branch behavior" {
        $content = (Get-Content -Path $script:dependabotConfigPath -Raw) -replace "`r", ''

        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*open-pull-requests-limit:\s*10\s*$')).Count | Should -Be 4
        @([System.Text.RegularExpressions.Regex]::Matches($content, '(?m)^\s*separator:\s*"?/"?\s*$')).Count | Should -Be 4
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
                    ForEach-Object { Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $_.FullName }
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

        Test-Path -Path (Join-Path -Path $script:repoRoot -ChildPath 'requirements.txt') -PathType Leaf | Should -BeTrue -Because (
            "Dependabot ecosystem 'pip' requires requirements.txt"
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
                $relative = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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

        $formatterContent | Should -Match 'Common/ModuleHelpers\.ps1'
        $formatterContent | Should -Match '\$minimumScriptAnalyzerVersion\s*=\s*\[version\]"1\.21\.0"'
        $formatterContent | Should -Match 'Get-CommandWithOptionalModuleImport\s+-CommandName\s+"Invoke-Formatter"\s+-ModuleName\s+"PSScriptAnalyzer"\s+-MinimumVersion\s+\$minimumScriptAnalyzerVersion'
        $formatterContent | Should -Match 'Get-AvailableModuleVersionsText\s+-ModuleName\s+"PSScriptAnalyzer"'
        $formatterContent | Should -Not -Match 'function\s+Ensure-PortableUserModulePaths\b'
        $formatterContent | Should -Not -Match 'function\s+Get-CommandWithOptionalModuleImport\b'
        $formatterContent | Should -Match '\.psscriptanalyzer\.format\.psd1'
        $formatterContent | Should -Match 'Get-LeadingTabIndentedLineNumbers'
        $formatterContent | Should -Match 'Write-Output\s+-NoEnumerate\s+\(\$lineNumbers\.ToArray\(\)\)'
        $formatterContent | Should -Not -Match 'return\s*,\s*\$lineNumbers\.ToArray\(\)'
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

    It "runs Pester via isolated subprocess in Run-PreCommitValidation" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $content = Get-Content -Path $preCommitPath -Raw

        $content | Should -Match 'Common/ModuleHelpers\.ps1'
        $content | Should -Match 'Assert-PreCommitPowerShellModuleAvailability'
        $content | Should -Match 'E_PRECOMMIT_VALIDATION_MODULES_MISSING'
        $content | Should -Match 'Invoke-PesterQualityGateInIsolatedProcess'
        $content | Should -Match 'Invoke-PesterQualityGate\.ps1'
        $content | Should -Match 'System\.Diagnostics\.ProcessStartInfo'
        $content | Should -Match '\$startInfo\.Environment\["PSModulePath"\]\s*=\s*\$env:PSModulePath'
        $content | Should -Match 'BeginOutputReadLine\(\)'
        $content | Should -Match 'BeginErrorReadLine\(\)'
        $content | Should -Match '\$maxCapturedOutputLinesPerStream\s*=\s*2000'
        $content | Should -Match '\$maxCapturedOutputCharactersPerStream\s*=\s*262144'
        $content | Should -Match 'BoundedProcessCapture'
        $content | Should -Match 'WaitForDrain\(\$remainingStreamWaitMilliseconds\)'
        $content | Should -Match 'output truncated after'
        $content | Should -Match '\$streamDrainTimeoutMilliseconds\s*=\s*\[Math\]::Min\(\[Math\]::Max\(\[int\]\(\$timeoutMilliseconds / 10\),\s*2000\),\s*15000\)'
        $content | Should -Match '\$remainingStreamWaitMilliseconds\s*=\s*\$streamDrainTimeoutMilliseconds'
        $content | Should -Match '\$processBookkeepingTimeoutMilliseconds\s*=\s*5000'
        $content | Should -Match 'WaitForExit\(\$processBookkeepingTimeoutMilliseconds\)'
        $content | Should -Not -Match '\[void\]\$process\.WaitForExit\(\)'
        $content | Should -Match 'process bookkeeping wait exceeded'
        $content | Should -Match 'processBookkeepingTimeoutMs='
        $content | Should -Match 'process resource disposal raised exception'
        $content | Should -Not -Match 'ReadToEndAsync\(\)'
        $content | Should -Match '"-NoLogo"'
        $content | Should -Match '"-NoProfile"'
        $content | Should -Match '"-NonInteractive"'
        $content | Should -Match 'E_TEST_TIMEOUT'
        $content | Should -Match 'E_TEST_CAPTURE_TIMEOUT'
        $content | Should -Match 'E_TEST_CAPTURE_FAILED'
        $content | Should -Not -Match '\.HasExited'
        $content | Should -Not -Match 'function\s+Ensure-PortableUserModulePaths\b'
        $content | Should -Not -Match 'function\s+Get-CommandWithOptionalModuleImport\b'
        $content | Should -Not -Match 'Invoke-Pester\s+-Path\s+"Tests/'
    }

    It "keeps isolated Pester failure exceptions compact and routes previews plus artifacts via warning diagnostics" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $content = Get-Content -Path $preCommitPath -Raw
        $diagnosticsHelpersPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/DiagnosticsHelpers.ps1"
        $diagnosticsHelpers = Get-Content -Path $diagnosticsHelpersPath -Raw

        $content | Should -Match 'Get-FirstRootErrorCode'
        $content | Should -Match 'Write-IsolatedPesterFailureArtifact'
        $content | Should -Match '@\(\s*Convert-ToRedactedOutputLines\s+-OutputLines\s+\$combinedLines\s*\)'
        $content | Should -Match 'authorization\\s\*\[:=\]\\s\*'
        $content | Should -Match 'authorization\\s\*\[:=\]\\s\*\)\.\+\$'
        $content | Should -Match 'access\[_-\]\?token'
        $content | Should -Match 'refresh\[_-\]\?token'
        $content | Should -Match '\\s\*\[:=\]\\s\*'
        $content | Should -Match 'W_TEST_FAILURE_OUTPUT_PREVIEW'
        $content | Should -Match 'W_TEST_FAILURE_ARTIFACT'
        $content | Should -Match 'Get-OutputPreview\s+-OutputLines\s+\$redactedCombinedLines\s+-MaxPreviewLines\s+4'
        $content | Should -Match 'Get-OutputPreview\s+-OutputLines\s+\$redactedCombinedLines\s+-MaxPreviewLines\s+4\s+-FilterBlankLines\s+-HeadTailWhenTruncated\s+-PerLineMaxCharacters\s+240'
        $diagnosticsHelpers | Should -Match 'head: \{0\} \| \.\.\. \(\{1\} omitted line\(s\)\) \.\.\. \| tail: \{2\}'
        $content | Should -Match 'W_TEST_FAILURE_ARTIFACT:\s+suite=\{0\}; exitCode=\{1\}; rootCode=\{2\}; logPath=\{3\}'
        $content | Should -Not -Match 'throw\s+"E_TEST_FAILURE:[^"]*Output preview:'
        $content | Should -Not -Match 'throw\s+"E_TEST_FAILURE:[^"]*\$preview'
        $content | Should -Not -Match 'throw\s+"E_TEST_FAILURE:[^"]*logPath='
        $content | Should -Match 'throw\s+"E_TEST_FAILURE:\s+\$SuiteLabel\s+failed in isolated Pester execution \(exitCode=\$\(\$process\.ExitCode\); rootCode=\$rootCode; details=see W_TEST_FAILURE_ARTIFACT\)\.'
    }

    It "redacts authorization and secret variants in isolated failure output helpers" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($preCommitPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "E_CONFIG_ERROR: Failed to parse Run-PreCommitValidation.ps1 for redaction helper behavior checks."
        }

        $targetFunction = Get-RequiredFunctionDefinitionAst -Ast $ast -Name "Get-RedactedFailureLine" -Context "redaction helper behavior checks"

        . ([scriptblock]::Create($targetFunction.Extent.Text))
        try {
            (Get-RedactedFailureLine -Line 'Authorization: Bearer "secretjwt"') | Should -Be 'Authorization: [REDACTED]'
            (Get-RedactedFailureLine -Line "Authorization: Bearer 'secretjwt'") | Should -Be 'Authorization: [REDACTED]'
            (Get-RedactedFailureLine -Line 'Authorization=Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==') | Should -Be 'Authorization=[REDACTED]'
            (Get-RedactedFailureLine -Line 'Authorization: Digest username="u", response="r"') | Should -Be 'Authorization: [REDACTED]'
            (Get-RedactedFailureLine -Line 'token = "abc def"') | Should -Be 'token = [REDACTED]'
            (Get-RedactedFailureLine -Line 'access_token: abc123') | Should -Be 'access_token: [REDACTED]'
        }
        finally {
            Remove-Item -Path Function:Get-RedactedFailureLine -ErrorAction SilentlyContinue
        }
    }

    It "keeps Convert-ToRedactedOutputLines flat and wrapper-safe for @(... ) call sites" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $content = (Get-Content -Path $preCommitPath -Raw) -replace "`r", ""

        $content | Should -Match 'return\s+@\(\)\s+#\s*array-unwrap-safe:\s*callers always wrap with @\(\)'
        $content | Should -Match 'return\s+@\(\$redactedLines\.ToArray\(\)\)\s+#\s*array-unwrap-safe:\s*callers always wrap with @\(\)'
        $content | Should -Not -Match 'function\s+Convert-ToRedactedOutputLines\s*\{[\s\S]*?return\s*,\s*@\('

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($preCommitPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "E_CONFIG_ERROR: Failed to parse Run-PreCommitValidation.ps1 for array-shape behavior checks."
        }

        $requiredFunctions = @("Get-RedactedFailureLine", "Convert-ToRedactedOutputLines")
        foreach ($requiredFunction in $requiredFunctions) {
            $targetFunction = Get-RequiredFunctionDefinitionAst -Ast $ast -Name $requiredFunction -Context "array-shape behavior checks"

            . ([scriptblock]::Create($targetFunction.Extent.Text))
        }

        try {
            $emptyResult = @(Convert-ToRedactedOutputLines -OutputLines @())
            $emptyResult.Count | Should -Be 0

            $nullResult = @(Convert-ToRedactedOutputLines -OutputLines $null)
            $nullResult.Count | Should -Be 0

            $redactedResult = @(Convert-ToRedactedOutputLines -OutputLines @('Authorization: Bearer "secretjwt"', 'line-two'))
            $redactedResult.Count | Should -Be 2
            $redactedResult[0] | Should -Be 'Authorization: [REDACTED]'
            $redactedResult[1] | Should -Be 'line-two'

            foreach ($line in $redactedResult) {
                $line | Should -BeOfType [string]
            }
        }
        finally {
            Remove-Item -Path Function:Convert-ToRedactedOutputLines -ErrorAction SilentlyContinue
            Remove-Item -Path Function:Get-RedactedFailureLine -ErrorAction SilentlyContinue
        }
    }

    It "keeps Convert-CapturedTextToLines defined only where it is used" {
        $scriptsRoot = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils"
        $scriptFiles = @(Get-ChildItem -Path $scriptsRoot -Filter "*.ps1" -File -Recurse -ErrorAction Stop)
        $definitions = New-Object System.Collections.Generic.List[string]

        foreach ($scriptFile in $scriptFiles) {
            $lineNumber = 0
            foreach ($line in @(Get-Content -Path $scriptFile.FullName)) {
                $lineNumber++
                if ($line -match '^\s*function\s+Convert-CapturedTextToLines\b') {
                    $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
                    $portableRelativePath = $relativePath -replace '\\', '/'
                    $definitions.Add("${portableRelativePath}:$lineNumber") | Out-Null
                }
            }
        }

        $definitions.Count | Should -Be 1 -Because ("Convert-CapturedTextToLines should not drift across scripts. Definitions: {0}" -f ($definitions -join ', '))
        $definitions[0] | Should -Match '^Scripts/Utils/Quality/Invoke-WindowsLanguageChecks\.ps1:\d+$'
    }

    It "keeps isolated Pester failure artifacts temp-root based and redacted" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $content = Get-Content -Path $preCommitPath -Raw

        $outsideRepoGuardIndex = $content.IndexOf('isolated Pester failure artifact path must be outside repository root', [System.StringComparison]::Ordinal)
        $writeIndex = $content.IndexOf('[System.IO.FileStream]::new', [System.StringComparison]::Ordinal)

        $content | Should -Match '\[System\.IO\.Path\]::GetTempPath\(\)'
        $content | Should -Match 'function\s+Resolve-CanonicalPath\s*\{'
        $content | Should -Match 'Resolve-CanonicalPath\s+-Path\s+\$tempRoot'
        $content | Should -Match 'wallstop-precommit-validation'
        $content | Should -Match '@\(\s*Convert-ToRedactedOutputLines\s+-OutputLines\s+\$StdoutLines\s*\)'
        $content | Should -Match '@\(\s*Convert-ToRedactedOutputLines\s+-OutputLines\s+\$StderrLines\s*\)'
        $content | Should -Match 'Get-RedactedFailureLine'
        $content | Should -Match 'function\s+Test-IsLinkOrReparsePoint\s*\{'
        $content | Should -Match 'Test-IsLinkOrReparsePoint\s+-Item\s+\$artifactDirectoryItem'
        $content | Should -Match 'Test-IsLinkOrReparsePoint\s+-Item\s+\$resolvedArtifactDirectoryItem'
        $content | Should -Match '\[System\.IO\.FileAttributes\]::ReparsePoint'
        $content | Should -Match 'LinkType'
        # The canonical-path guard resolves symbolic links to their FINAL target through the
        # portable Get-PortableLinkTarget shim (native ResolveLinkTarget($true) on 7+, the
        # LinkTarget/Target ETS members on Windows PowerShell 5.1) rather than calling the
        # .NET 6-only ResolveLinkTarget method directly, which throws on 5.1.
        $content | Should -Match 'Get-PortableLinkTarget'
        $content | Should -Match 'isolated Pester failure artifact directory must not be a symbolic link or reparse point'
        $content | Should -Match 'Resolve-CanonicalPath\s+-Path\s+\$artifactDirectory'
        $content | Should -Match 'E_CONFIG_ERROR: isolated Pester failure artifact path must be outside repository root'
        $content | Should -Not -Match 'Join-Path\s+-Path\s+\$RepoRoot\s+-ChildPath\s+"wallstop-precommit-validation"'
        $content | Should -Not -Match 'artifactLines\.Add\("repoRoot='
        $content | Should -Match '\[System\.IO\.FileMode\]::CreateNew'
        $content | Should -Not -Match '\[System\.IO\.File\]::WriteAllText\('
        $outsideRepoGuardIndex | Should -BeGreaterThan -1 -Because 'Outside-repository artifact path guard must exist.'
        $writeIndex | Should -BeGreaterThan -1 -Because 'Artifact write operation must exist.'
        $outsideRepoGuardIndex | Should -BeLessThan $writeIndex -Because 'Outside-repository guard must execute before writing the artifact file.'
    }

    It "scopes ScriptAnalyzer targets to staged Scripts/Utils files unless -All is used" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $content = (Get-Content -Path $preCommitPath -Raw) -replace "`r", ''

        $content | Should -Match '\$analyzerTargets\s*=\s*@\(\)'
        $content | Should -Match 'if\s*\(\$All\)\s*\{\s*\$analyzerTargets\s*=\s*@\("Scripts/Utils"\)'
        $content | Should -Match 'elseif\s*\(\$scriptFiles\.Count\s*-gt\s*0\)'
        $content | Should -Match 'Write-Verbose\s*\(\s*"ScriptAnalyzer staged-path diagnostics: skippedMissingCount='
        $content | Should -Match '\$analyzerTargets\s*=\s*@\(\s*\$scriptFiles\s*\|\s*Where-Object\s*\{\s*Test-Path\s*-LiteralPath\s*\$_\s*-PathType\s*Leaf\s*\}\s*\|\s*Sort-Object\s*-Unique\s*\)'
        $content | Should -Match 'foreach\s*\(\$analyzerTarget\s+in\s+\$analyzerTargets\)'
        $content | Should -Match 'Invoke-ScriptAnalyzer\s+-Path\s+\$analyzerTarget\s+-Settings\s+"\.psscriptanalyzer\.psd1"'
        $content | Should -Not -Match 'Invoke-ScriptAnalyzer\s+-Path\s+"Scripts/Utils"\s+-Settings\s+"\.psscriptanalyzer\.psd1"'
    }

    It "centralizes module discovery for formatter and pre-commit validation scripts" {
        $formatterPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Format-PowerShellFiles.ps1"
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $pesterGatePath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1"
        $fullValidationPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-FullValidation.ps1"
        $moduleHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/ModuleHelpers.ps1"

        $formatterContent = Get-Content -Path $formatterPath -Raw
        $preCommitContent = Get-Content -Path $preCommitPath -Raw
        $pesterGateContent = Get-Content -Path $pesterGatePath -Raw
        $fullValidationContent = Get-Content -Path $fullValidationPath -Raw
        $moduleHelperContent = Get-Content -Path $moduleHelperPath -Raw

        $formatterContent | Should -Match 'Common/ModuleHelpers\.ps1'
        $preCommitContent | Should -Match 'Common/ModuleHelpers\.ps1'
        $pesterGateContent | Should -Match 'Common/ModuleHelpers\.ps1'
        $fullValidationContent | Should -Match 'Common/ModuleHelpers\.ps1'
        $fullValidationContent | Should -Match 'Assert-PowerShellQualityModuleAvailability'
        $fullValidationContent | Should -Match 'Assert-ModuleCommandRequirements\s+-Requirements\s+\$moduleRequirements\s+-ErrorCode\s+"E_VALIDATION_POWERSHELL_MODULES_MISSING"'
        $fullValidationContent | Should -Match 'E_VALIDATION_POWERSHELL_MODULES_MISSING'
        $preCommitContent | Should -Match 'Assert-PreCommitPowerShellModuleAvailability'
        $preCommitContent | Should -Match 'E_PRECOMMIT_VALIDATION_MODULES_MISSING'
        $pesterGateContent | Should -Match 'Get-CommandWithOptionalModuleImport\s+-CommandName\s+"Invoke-Pester"\s+-ModuleName\s+"Pester"\s+-MinimumVersion\s+\$minimumPesterVersion'
        $moduleHelperContent | Should -Match 'function\s+Get-CommandWithOptionalModuleImport\b'
        $moduleHelperContent | Should -Match 'function\s+Assert-ModuleCommandRequirements\b'
        $moduleHelperContent | Should -Match 'Import-Module\s+-Name\s+\$ModuleName\s+-MinimumVersion\s+\$MinimumVersion'
        $moduleHelperContent | Should -Match 'Get-AvailableModuleVersionsText'
        $moduleHelperContent | Should -Match 'GetFolderPath\("MyDocuments"\)'
        $moduleHelperContent | Should -Match 'PowerShell/Modules'
        $moduleHelperContent | Should -Match 'WindowsPowerShell/Modules'
        $moduleHelperContent | Should -Match '/usr/local/share/powershell/Modules'
        $moduleHelperContent | Should -Match 'Module path diagnostics:'
        $moduleHelperContent | Should -Not -Match 'return\s+\(Get-Command\s+-Name\s+\$CommandName\s+-ErrorAction\s+SilentlyContinue\)'
    }

    It "uses explicit format argument arrays for module requirement diagnostics" {
        $moduleHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/ModuleHelpers.ps1"
        $moduleHelperContent = (Get-Content -Path $moduleHelperPath -Raw) -replace "`r", ''

        $moduleHelperContent | Should -Match 'installCommand=''\{5\}''\{6\}"\s+-f\s+@\('
        $moduleHelperContent | Should -Match 'command=\{1\}; minimumVersion=\{2\}; issue=command-not-exported; installCommand=''\{3\}''"\s+-f\s+@\('
    }

    It "wires format-operator safety helper into validation entrypoints" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $fullValidationPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-FullValidation.ps1"

        $preCommitContent = (Get-Content -Path $preCommitPath -Raw) -replace "`r", ''
        $fullValidationContent = (Get-Content -Path $fullValidationPath -Raw) -replace "`r", ''

        $preCommitContent | Should -Match 'Common/FormatOperatorSafetyHelpers\.ps1'
        $preCommitContent | Should -Match 'E_PRECOMMIT_FORMAT_OPERATOR_BINDING'
        $preCommitContent | Should -Match 'Assert-NoFormatOperatorContinuationViolations\s+-RootPath\s+\$repoRoot'

        $fullValidationContent | Should -Match 'Common/FormatOperatorSafetyHelpers\.ps1'
        $fullValidationContent | Should -Match 'E_VALIDATION_FORMAT_OPERATOR_BINDING'
        $fullValidationContent | Should -Match 'Assert-NoFormatOperatorContinuationViolations\s+-RootPath\s+\$repoRoot'
    }

    It "keeps Scripts and Tests free of multiline -f continuation binding risks" {
        $helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/FormatOperatorSafetyHelpers.ps1"
        . $helperPath

        $violations = @(Get-FormatOperatorContinuationViolations -RootPath $script:repoRoot -RelativeRoots @("Scripts", "Tests"))
        $violationPreview = @($violations | Select-Object -First 10 | ForEach-Object {
                "{0}:{1} ({2})" -f $_.Path, $_.Line, $_.Snippet
            })

        $violations.Count | Should -Be 0 -Because (
            "Multiline '-f' continuation can under-bind format arguments at runtime. Violations: {0}" -f ($violationPreview -join '; ')
        )
    }

    It "detects multiline -f continuation violations across right-operand expression kinds in fixture scripts" {
        $helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/FormatOperatorSafetyHelpers.ps1"
        . $helperPath

        $fixtureRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("format-operator-violation-{0}" -f ([guid]::NewGuid().ToString("N")))
        [void](New-Item -ItemType Directory -Path $fixtureRoot -Force)
        $fixtureRoot = Resolve-CanonicalTempRoot -Path $fixtureRoot
        $fixtureScriptsPath = Join-Path -Path $fixtureRoot -ChildPath "Scripts"
        $fixtureDefinitions = @(
            [pscustomobject]@{
                FileName        = "VariableViolation.ps1"
                Snippet         = '$first,'
                ExpectedAstType = "VariableExpressionAst"
                Content         = @'
$list = New-Object System.Collections.Generic.List[string]
$list.Add(
    "value {0} {1}" -f
    $first,
    $second
) | Out-Null
'@
            },
            [pscustomobject]@{
                FileName = "LiteralViolation.ps1"
                Snippet  = '1,'
                Content  = @'
$list = New-Object System.Collections.Generic.List[string]
$list.Add(
    "value {0} {1}" -f
    1,
    $second
) | Out-Null
'@
            },
            [pscustomobject]@{
                FileName = "UnaryViolation.ps1"
                Snippet  = '-$first,'
                Content  = @'
$list = New-Object System.Collections.Generic.List[string]
$list.Add(
    "value {0} {1}" -f
    -$first,
    $second
) | Out-Null
'@
            },
            [pscustomobject]@{
                FileName = "ParenthesizedViolation.ps1"
                Snippet  = '($first),'
                Content  = @'
$list = New-Object System.Collections.Generic.List[string]
$list.Add(
    "value {0} {1}" -f
    ($first),
    $second
) | Out-Null
'@
            },
            [pscustomobject]@{
                FileName = "MemberViolation.ps1"
                Snippet  = '$item.Name,'
                Content  = @'
$list = New-Object System.Collections.Generic.List[string]
$list.Add(
    "value {0} {1}" -f
    $item.Name,
    $second
) | Out-Null
'@
            },
            [pscustomobject]@{
                FileName = "IndexViolation.ps1"
                Snippet  = '$items[0],'
                Content  = @'
$list = New-Object System.Collections.Generic.List[string]
$list.Add(
    "value {0} {1}" -f
    $items[0],
    $second
) | Out-Null
'@
            },
            [pscustomobject]@{
                FileName = "SubExpressionViolation.ps1"
                Snippet  = '$(Get-Date),'
                Content  = @'
$list = New-Object System.Collections.Generic.List[string]
$list.Add(
    "value {0} {1}" -f
    $(Get-Date),
    $second
) | Out-Null
'@
            },
            [pscustomobject]@{
                FileName = "MultiLineRightOperandViolation.ps1"
                Snippet  = '),'
                Content  = @'
$list = New-Object System.Collections.Generic.List[string]
$list.Add(
    "value {0} {1}" -f
    (
        $first + "x"
    ),
    $second
) | Out-Null
'@
            }
        )

        try {
            [void](New-Item -ItemType Directory -Path $fixtureScriptsPath -Force)
            foreach ($fixtureDefinition in @($fixtureDefinitions)) {
                $fixtureFilePath = Join-Path -Path $fixtureScriptsPath -ChildPath $fixtureDefinition.FileName
                [System.IO.File]::WriteAllText($fixtureFilePath, $fixtureDefinition.Content, [System.Text.UTF8Encoding]::new($false))
            }

            $violations = @(Get-FormatOperatorContinuationViolations -RootPath $fixtureRoot -RelativeRoots @("Scripts"))
            $violations.Count | Should -Be $fixtureDefinitions.Count

            foreach ($fixtureDefinition in @($fixtureDefinitions)) {
                $expectedPath = "Scripts/{0}" -f $fixtureDefinition.FileName
                $matchedViolations = @($violations | Where-Object { $_.Path -eq $expectedPath })

                $matchedViolations.Count | Should -Be 1
                $matchedViolations[0].Path | Should -Not -Match '\\'
                $matchedViolations[0].Line | Should -Be 4
                $matchedViolations[0].PlaceholderMaxIndex | Should -Be 1
                $matchedViolations[0].RightOperandAstType | Should -Not -BeNullOrEmpty
                if ($fixtureDefinition.PSObject.Properties.Name -contains "ExpectedAstType") {
                    $matchedViolations[0].RightOperandAstType | Should -Be $fixtureDefinition.ExpectedAstType
                }
                $matchedViolations[0].Snippet | Should -Be $fixtureDefinition.Snippet
            }
        }
        finally {
            if (Test-Path -Path $fixtureRoot -PathType Container) {
                Remove-Item -Path $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not flag safe multiline -f formatting patterns in fixture scripts" {
        $helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/FormatOperatorSafetyHelpers.ps1"
        . $helperPath

        $fixtureRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("format-operator-safe-{0}" -f ([guid]::NewGuid().ToString("N")))
        [void](New-Item -ItemType Directory -Path $fixtureRoot -Force)
        $fixtureRoot = Resolve-CanonicalTempRoot -Path $fixtureRoot
        $fixtureScriptsPath = Join-Path -Path $fixtureRoot -ChildPath "Scripts"
        $fixtureDefinitions = @(
            [pscustomobject]@{
                FileName = "SingleLineSafe.ps1"
                Content  = @'
$result = "value {0} {1}" -f $first, $second
'@
            },
            [pscustomobject]@{
                FileName = "ArrayLiteralContinuationSafe.ps1"
                Content  = @'
$result = (
    "value {0} {1}" -f
    $first,
    $second
)
'@
            },
            [pscustomobject]@{
                FileName = "ArraySafe.ps1"
                Content  = @'
$result = "value {0} {1}" -f
    @($first, $second)
'@
            },
            [pscustomobject]@{
                FileName = "SinglePlaceholderSafe.ps1"
                Content  = @'
$result = "value {0}" -f
    $first,
    $second
'@
            },
            [pscustomobject]@{
                FileName = "NoCommaSafe.ps1"
                Content  = @'
$result = "value {0} {1}" -f
    $first
'@
            }
        )

        try {
            [void](New-Item -ItemType Directory -Path $fixtureScriptsPath -Force)
            foreach ($fixtureDefinition in @($fixtureDefinitions)) {
                $fixtureFilePath = Join-Path -Path $fixtureScriptsPath -ChildPath $fixtureDefinition.FileName
                [System.IO.File]::WriteAllText($fixtureFilePath, $fixtureDefinition.Content, [System.Text.UTF8Encoding]::new($false))
            }

            $violations = @(Get-FormatOperatorContinuationViolations -RootPath $fixtureRoot -RelativeRoots @("Scripts"))
            $violationPreview = @($violations | ForEach-Object {
                    "{0}:{1} ({2})" -f $_.Path, $_.Line, $_.Snippet
                })

            $violations.Count | Should -Be 0 -Because (
                "Safe multiline '-f' patterns should not be flagged. Violations: {0}" -f ($violationPreview -join '; ')
            )

            $arrayLiteralFixturePath = Join-Path -Path $fixtureScriptsPath -ChildPath "ArrayLiteralContinuationSafe.ps1"
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($arrayLiteralFixturePath, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0
            $formatExpressions = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                        $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Format
                    }, $true))
            $formatExpressions.Count | Should -Be 1
            $formatExpressions[0].Right.GetType().Name | Should -Be "ArrayLiteralAst"

            $first = "alpha"
            $second = "beta"
            $safeResult = (
                "value {0} {1}" -f
                $first,
                $second
            )
            $safeResult | Should -Be "value alpha beta"
        }
        finally {
            if (Test-Path -Path $fixtureRoot -PathType Container) {
                Remove-Item -Path $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps format-operator helper path outputs normalized for cross-platform determinism" {
        $helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/FormatOperatorSafetyHelpers.ps1"
        $content = (Get-Content -Path $helperPath -Raw) -replace "`r", ''

        $content | Should -Match 'function\s+ConvertTo-PortableFormatOperatorPath\b'
        $content | Should -Match "function\s+ConvertTo-PortableFormatOperatorPath[\s\S]*?-replace\s+'\[\\\\/\]\+'\s*,\s*'/'"
        $content | Should -Match 'relativeParsePath\s*=\s*ConvertTo-PortableFormatOperatorPath\s+-PathValue\s+\(Get-RelativePathCompat\b'
        $content | Should -Match 'relativePath\s*=\s*ConvertTo-PortableFormatOperatorPath\s+-PathValue\s+\(Get-RelativePathCompat\b'
    }

    It "emits verbose diagnostics for module path candidate handling in ModuleHelpers" {
        $moduleHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/ModuleHelpers.ps1"
        $content = Get-Content -Path $moduleHelperPath -Raw

        $content | Should -Match 'Module path candidate skipped: empty-or-whitespace path\.'
        $content | Should -Match 'Module path candidate skipped: directory does not exist; path='''
        $content | Should -Match 'Module path candidate skipped: already present; path='''
        $content | Should -Match 'Module path candidate added: path='''
        $content | Should -Match 'Module path discovery: MyDocuments path unavailable\.'
        $content | Should -Match 'Module path discovery: UserProfile path unavailable\.'
        $content | Should -Match 'Module import diagnostics: module=\{0\}; minimumVersion=\{1\}; importFailure=\{2\}'
        $content | Should -Match 'function\s+Get-ModulePathDiagnosticsText\b'
    }

    It "includes PSModulePath diagnostics in Pester minimum-version failure output" {
        $pesterGatePath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1"
        $content = Get-Content -Path $pesterGatePath -Raw

        $content | Should -Match 'Get-ModulePathDiagnosticsText'
        $content | Should -Match 'Module path diagnostics:'
        $content | Should -Match 'Install-Module Pester -Scope CurrentUser -MinimumVersion \{0\} -Force'
    }

    It "adds module version scope diagnostics to module helper failures" {
        $moduleHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/ModuleHelpers.ps1"
        $content = Get-Content -Path $moduleHelperPath -Raw

        $content | Should -Match 'function\s+Get-AvailableModuleVersionScopeText\b'
        $content | Should -Match 'versionScopes='
        $content | Should -Match 'windows-powershell'
        $content | Should -Match 'pwsh'
    }

    It "provides explicit PowerShell quality module bootstrap automation" {
        $bootstrapPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Install-PowerShellQualityModules.ps1"
        Test-Path -Path $bootstrapPath -PathType Leaf | Should -BeTrue

        $content = (Get-Content -Path $bootstrapPath -Raw) -replace "`r", ''
        $content | Should -Match 'Common/ModuleHelpers\.ps1'
        $content | Should -Match '\[ValidateSet\("Pester",\s*"PSScriptAnalyzer"\)\]'
        $content | Should -Match 'Set-PSRepository\s+-Name\s+"PSGallery"\s+-InstallationPolicy\s+Trusted'
        $content | Should -Match 'Install-PowerShellQualityModuleRequirement'
        $content | Should -Match '\$installModuleParameters\["SkipPublisherCheck"\]\s*=\s*\$true'
        $content | Should -Match 'W_MODULE_BOOTSTRAP_SKIP_PUBLISHER_CHECK_FALLBACK'
        $content | Should -Not -Match 'Install-Module[^\r\n]*-SkipPublisherCheck'
        $content | Should -Match 'E_MODULE_BOOTSTRAP_INSTALL_FAILED'
        $content | Should -Match 'E_MODULE_BOOTSTRAP_VERIFY_FAILED'
    }

    It "uses bootstrap remediation commands in module prerequisite diagnostics" {
        $preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
        $fullValidationPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-FullValidation.ps1"
        $formatterPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Format-PowerShellFiles.ps1"
        $pesterGatePath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1"

        $preCommitContent = Get-Content -Path $preCommitPath -Raw
        $fullValidationContent = Get-Content -Path $fullValidationPath -Raw
        $formatterContent = Get-Content -Path $formatterPath -Raw
        $pesterGateContent = Get-Content -Path $pesterGatePath -Raw

        $preCommitContent | Should -Match 'Install-PowerShellQualityModules\.ps1 -Modules Pester'
        $preCommitContent | Should -Match 'Install-PowerShellQualityModules\.ps1 -Modules PSScriptAnalyzer'
        $fullValidationContent | Should -Match 'Install-PowerShellQualityModules\.ps1 -Modules Pester'
        $fullValidationContent | Should -Match 'Install-PowerShellQualityModules\.ps1 -Modules PSScriptAnalyzer'
        $formatterContent | Should -Match 'Install-PowerShellQualityModules\.ps1 -Modules PSScriptAnalyzer'
        $pesterGateContent | Should -Match 'Install-PowerShellQualityModules\.ps1 -Modules Pester'
    }

    It "documents module path diagnostics contract in context rule 16" {
        $contextPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/context.md'
        $content = Get-Content -Path $contextPath -Raw

        $content | Should -Match 'Module path candidate rejection reasons'
        $content | Should -Match 'PSModulePath.*entry counts plus preview'
        $content | Should -Match 'Avoid unbounded Process\.WaitForExit\(\)'
    }

    It "documents bootstrap remediation in context rule 17 and validation workflow" {
        $contextPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/context.md'
        $validationWorkflowPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/validation-workflow.md'

        $contextContent = Get-Content -Path $contextPath -Raw
        $validationWorkflowContent = Get-Content -Path $validationWorkflowPath -Raw

        $contextContent | Should -Match 'Install-PowerShellQualityModules\.ps1'
        $contextContent | Should -Match 'rerun preflight before any hook execution'
        $contextContent | Should -Match 'Register-PSRepository -Default'
        $validationWorkflowContent | Should -Match 'Install-PowerShellQualityModules\.ps1'
        $validationWorkflowContent | Should -Match 'Invoke-FullValidation\.ps1 -PreflightOnly'
    }

    It "documents hook timeout guardrails in context and precommit skill guidance" {
        $contextPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/context.md'
        $validationWorkflowPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/validation-workflow.md'
        $skillDetailPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/skill-details/precommit-hooks-and-fallbacks.md'

        $contextContent = Get-Content -Path $contextPath -Raw
        $validationWorkflowContent = Get-Content -Path $validationWorkflowPath -Raw
        $skillDetailContent = Get-Content -Path $skillDetailPath -Raw

        $contextContent | Should -Match 'E_HOOK_TIMEOUT'
        $contextContent | Should -Match 'WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS'
        $contextContent | Should -Match 'WALLSTOP_PREPUSH_TIMEOUT_SECONDS'
        $contextContent | Should -Match 'WALLSTOP_DEVCONTAINER_PREFLIGHT_TIMEOUT_SECONDS'
        $contextContent | Should -Match 'WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS'
        $contextContent | Should -Match 'pre-commit and pre-push recovery-backed outer timeout minimums 60s'
        $contextContent | Should -Match 'Diagnostic strings that must preserve stable `E_\*`/`W_\*` codes'
        $contextContent | Should -Match 'Copilot/agent-driven test execution'
        $contextContent | Should -Match 'avoid direct `Invoke-Pester` terminal calls'

        $validationWorkflowContent | Should -Match 'E_HOOK_TIMEOUT'
        $validationWorkflowContent | Should -Match 'WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS'
        $validationWorkflowContent | Should -Match 'WALLSTOP_PREPUSH_TIMEOUT_SECONDS'
        $validationWorkflowContent | Should -Match 'WALLSTOP_DEVCONTAINER_PREFLIGHT_TIMEOUT_SECONDS'
        $validationWorkflowContent | Should -Match 'WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS'
        $validationWorkflowContent | Should -Match 'override minimum is 60s'
        $validationWorkflowContent | Should -Match 'do not call `Invoke-Pester` directly'
        $validationWorkflowContent | Should -Match 'timeout -k 5s 300s pwsh -NoLogo -NoProfile -File Scripts/Utils/Quality/Invoke-PesterQualityGate\.ps1'
        $validationWorkflowContent | Should -Match 'OutputVerbosity None'

        $skillDetailContent | Should -Match 'Timeout-Guarded Hook Execution'
        $skillDetailContent | Should -Match 'Invoke-PreCommitWithRecovery\.ps1 -HookStage pre-push -FileListPath'
        $skillDetailContent | Should -Not -Match 'Invoke-PreCommitWithRecovery\.ps1 -HookStage pre-push -Files'
        $skillDetailContent | Should -Match 'parent `EXIT` trap'
        $skillDetailContent | Should -Match 'Invoke-PrePushPreCommitValidation\.ps1'
        $skillDetailContent | Should -Match 'Run-PreCommitValidation\.ps1 -TargetFiles'
        $skillDetailContent | Should -Match 'pwsh -File` misbinds the second filename'
        $skillDetailContent | Should -Match 'WALLSTOP_PRECOMMIT_TIMEOUT_SECONDS'
        $skillDetailContent | Should -Match 'WALLSTOP_PREPUSH_TIMEOUT_SECONDS'
        $skillDetailContent | Should -Match 'WALLSTOP_DEVCONTAINER_PREFLIGHT_TIMEOUT_SECONDS'
        $skillDetailContent | Should -Match 'WALLSTOP_DEVCONTAINER_PRECOMMIT_PREWARM_TIMEOUT_SECONDS'
        $skillDetailContent | Should -Match 'at least 60 seconds'
        $skillDetailContent | Should -Match 'do not run direct `Invoke-Pester` terminal commands'
    }

    It "documents shell git mutation fail-fast contract in context" {
        $contextPath = Join-Path -Path $script:repoRoot -ChildPath '.llm/context.md'
        $contextContent = Get-Content -Path $contextPath -Raw

        $contextContent | Should -Match 'Shell scripts that mutate git state'
        $contextContent | Should -Match 'command -v git'
        $contextContent | Should -Match 'git diff --cached --quiet --exit-code'
        $contextContent | Should -Match 'do not use `git add\|commit\|pull\|push'
        $contextContent | Should -Match 'avoid negated command-substitution exit capture'
        $contextContent | Should -Match 'E_\*_GIT_\*'
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

    It "uses explicit git availability preflight in git-consuming utility scripts" {
        $gitPreflightCases = @(
            @{ Path = 'Scripts/Utils/Run-PreCommitValidation.ps1'; ErrorCode = 'E_PRECOMMIT_VALIDATION_GIT_NOT_AVAILABLE'; InvocationPattern = '\$stagedFileArgs\s*=\s*@\("-C",\s*\$RepositoryRoot,\s*"diff",\s*"--cached",\s*"--name-only",\s*"--diff-filter=ACMR"\)[\s\S]*Invoke-GitCommandWithSplitOutput\s+-GitExecutable\s+\$GitExecutable\s+-Arguments\s+\$stagedFileArgs' },
            @{ Path = 'Scripts/Utils/Quality/Invoke-FullValidation.ps1'; ErrorCode = 'E_VALIDATION_GIT_NOT_AVAILABLE'; InvocationPattern = '&\s+\$GitExecutable\s+(?:@statusArgs|"-C",\s*\$RepositoryRoot,\s*"status",\s*"--porcelain=v1",\s*"--untracked-files=all")' },
            @{ Path = 'Scripts/Utils/Quality/Assert-CleanGitTree.ps1'; ErrorCode = 'E_ASSERT_CLEAN_GIT_TREE_GIT_NOT_AVAILABLE'; InvocationPattern = '&\s+\$gitExecutable\s+(?:@statusArgs|"-C",\s*\$RepositoryRoot,\s*"status",\s*"--porcelain=v1",\s*"--untracked-files=all")' },
            @{ Path = 'Scripts/Utils/Increment-Version.ps1'; ErrorCode = 'E_INCREMENT_VERSION_GIT_NOT_AVAILABLE'; InvocationPattern = '&\s+\$gitExecutable\s+rev-parse\s+--is-inside-work-tree' }
        )

        foreach ($case in $gitPreflightCases) {
            $content = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath $case.Path) -Raw) -replace "`r", ''
            $content | Should -Match 'Get-Command\s+-Name\s+"git"\s+-ErrorAction\s+SilentlyContinue' -Because (
                "{0} invokes git and must validate PATH availability first." -f $case.Path
            )
            $content | Should -Match $case.ErrorCode -Because (
                "{0} must emit stable diagnostics when git is unavailable." -f $case.Path
            )
            $content | Should -Match $case.InvocationPattern -Because (
                "{0} should invoke git through the resolved executable path after preflight." -f $case.Path
            )
        }
    }

    It "keeps actionable git status diagnostics in backup and quality scripts" {
        $diagnosticsHelpers = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/DiagnosticsHelpers.ps1') -Raw) -replace "`r", ''
        $backupScript = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Backup.ps1') -Raw) -replace "`r", ''
        $fullValidation = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-FullValidation.ps1') -Raw) -replace "`r", ''
        $assertClean = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Assert-CleanGitTree.ps1') -Raw) -replace "`r", ''

        $diagnosticsHelpers | Should -Match 'function\s+Get-OutputPreview'

        $backupScript | Should -Match 'DiagnosticsHelpers\.ps1'
        $backupScript | Should -Match 'E_BACKUP_DIAGNOSTICS_HELPER_MISSING'
        $backupScript | Should -Not -Match 'function\s+Get-OutputPreview'
        $backupScript | Should -Match 'Get-GitCommandDiagnosticsOutput\s+-GitExecutable\s+\$GitExecutable\s+-GitArguments\s+\$statusArgs'
        $backupScript | Should -Match 'E_BACKUP_GIT_STATUS_FAILED:[\s\S]*outputPreview='

        $fullValidation | Should -Match 'DiagnosticsHelpers\.ps1'
        $fullValidation | Should -Match 'E_VALIDATION_DIAGNOSTICS_HELPER_MISSING'
        $fullValidation | Should -Not -Match 'function\s+Get-OutputPreview'
        $fullValidation | Should -Match 'statusArgs\s*=\s*@\("-C",\s*\$RepositoryRoot,\s*"status",\s*"--porcelain=v1",\s*"--untracked-files=all"\)'
        $fullValidation | Should -Match 'Invoke-SafeGitIndexLockRecovery'
        $fullValidation | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_DETECTED'
        $fullValidation | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_RETRYING'
        $fullValidation | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_SKIPPED'
        $fullValidation | Should -Match 'E_PRECOMMIT_GIT_INDEX_LOCK_RECOVERY_FAILED'
        $fullValidation | Should -Match 'E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED'
        $fullValidation | Should -Match 'E_VALIDATION_GIT_NOT_REPOSITORY'
        $fullValidation | Should -Match 'E_VALIDATION_GIT_STATUS_FAILED:[^\n]*repositoryRoot=' -Because "Validation status failures should include repository context."
        $fullValidation | Should -Match 'E_VALIDATION_GIT_STATUS_FAILED:[^\n]*workingDirectory=' -Because "Validation status failures should include calling working-directory context."
        $fullValidation | Should -Match 'E_VALIDATION_GIT_STATUS_FAILED:[^\n]*outputPreview=' -Because "Validation status failures should include command output previews."

        $assertClean | Should -Match 'DiagnosticsHelpers\.ps1'
        $assertClean | Should -Match 'E_ASSERT_CLEAN_GIT_TREE_DIAGNOSTICS_HELPER_MISSING'
        $assertClean | Should -Not -Match 'function\s+Get-OutputPreview'
        $assertClean | Should -Match 'statusArgs\s*=\s*@\("-C",\s*\$RepositoryRoot,\s*"status",\s*"--porcelain=v1",\s*"--untracked-files=all"\)'
        $assertClean | Should -Match 'E_ASSERT_CLEAN_GIT_TREE_NOT_REPOSITORY'
        $assertClean | Should -Match 'E_GIT_STATUS_FAILED:[^\n]*repositoryRoot=' -Because "Assert-CleanGitTree status failures should include repository context."
        $assertClean | Should -Match 'E_GIT_STATUS_FAILED:[^\n]*workingDirectory=' -Because "Assert-CleanGitTree status failures should include calling working-directory context."
        $assertClean | Should -Match 'E_GIT_STATUS_FAILED:[^\n]*outputPreview=' -Because "Assert-CleanGitTree status failures should include command output previews."
    }

    It "centralizes output preview helpers in Scripts/Utils/Common/DiagnosticsHelpers.ps1" {
        $diagnosticsHelpers = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/DiagnosticsHelpers.ps1') -Raw) -replace "`r", ''
        $preCommit = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Run-PreCommitValidation.ps1') -Raw) -replace "`r", ''
        $windowsChecks = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1') -Raw) -replace "`r", ''

        $diagnosticsHelpers | Should -Match 'function\s+Get-OutputPreview'
        $diagnosticsHelpers | Should -Match 'switch\]\$HeadTailWhenTruncated'
        $diagnosticsHelpers | Should -Match 'switch\]\$CollapseWhitespace'
        $diagnosticsHelpers | Should -Match 'Alias\(\s*''MaxPreviewLines''\s*\)'
        $diagnosticsHelpers | Should -Match 'Alias\(\s*''MaxLength''\s*\)'
        $diagnosticsHelpers | Should -Match 'function\s+Test-IsGitIndexLockFailure'
        $diagnosticsHelpers | Should -Match 'function\s+Get-GitIndexLockPathFromOutput'
        $diagnosticsHelpers | Should -Match 'function\s+Get-GitIndexLockRecoveryConfig'
        $diagnosticsHelpers | Should -Match 'function\s+Invoke-SafeGitIndexLockRecovery'
        $diagnosticsHelpers | Should -Match 'WALLSTOP_GIT_INDEX_LOCK_RECOVERY_MODE'
        $diagnosticsHelpers | Should -Match 'WALLSTOP_GIT_INDEX_LOCK_STALE_SECONDS'
        $diagnosticsHelpers | Should -Match 'WALLSTOP_GIT_INDEX_LOCK_ALLOW_ACTIVE_GIT'
        $diagnosticsHelpers | Should -Match 'WALLSTOP_GIT_INDEX_LOCK_SLOW_PATH_MS'
        $diagnosticsHelpers | Should -Match 'E_PRECOMMIT_GIT_INDEX_LOCK_CONFIG'

        $preCommit | Should -Match 'Common/DiagnosticsHelpers\.ps1'
        $preCommit | Should -Not -Match 'function\s+Get-OutputPreview'
        $preCommit | Should -Match 'Get-OutputPreview\s+-OutputLines\s+\$redactedCombinedLines\s+-MaxPreviewLines\s+4\s+-FilterBlankLines\s+-HeadTailWhenTruncated\s+-PerLineMaxCharacters\s+240'
        $preCommit | Should -Match 'Get-StagedFilesWithIndexLockRecoveryOrThrow'
        $preCommit | Should -Match 'Invoke-SafeGitIndexLockRecovery'
        $preCommit | Should -Match 'W_PRECOMMIT_GIT_INDEX_LOCK_DETECTED'
        $preCommit | Should -Match 'E_PRECOMMIT_GIT_INDEX_LOCK_PERSISTED'

        $windowsChecks | Should -Match 'Common/DiagnosticsHelpers\.ps1'
        $windowsChecks | Should -Not -Match 'function\s+Get-OutputPreview'
        $windowsChecks | Should -Match 'Get-OutputPreview\s+-Output\s+@\(\$attempt\.Output\)\s+-MaxLength\s+240\s+-CollapseWhitespace'
    }

    It "keeps quality script diagnostics low-noise in Remove-BOM and Windows language checks" {
        $removeBomPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Remove-BOM.ps1'
        $removeBom = (Get-Content -Path $removeBomPath -Raw) -replace "`r", ''
        $removeBom | Should -Match 'Write-Verbose\s+"File discovery diagnostics:'
        $removeBom | Should -Not -Match 'Write-Host\s+"File discovery diagnostics:'
        $removeBom | Should -Match 'Write-Verbose\s+"Checked \$filesChecked files so far\.\.\."'

        $windowsChecksPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1'
        $windowsChecks = (Get-Content -Path $windowsChecksPath -Raw) -replace "`r", ''
        $windowsChecks | Should -Match 'Write-Verbose\s+"AutoHotkey checks: no \.ahk files found for selected scope; skipping\."'
        $windowsChecks | Should -Match 'Write-Verbose\s+"AutoHotkey checks: validating'
        $windowsChecks | Should -Match 'Write-Verbose\s+"Batch checks: running best-effort static smoke checks'
        $windowsChecks | Should -Match 'Write-Verbose\s+"Windows language checks: running in targeted mode'
        $windowsChecks | Should -Not -Match 'Write-Host\s+"Batch checks limitation:'
    }

    It "keeps portable process-tree cleanup from degrading to parent-only kills" {
        $compatibilityHelpersPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/CompatibilityHelpers.ps1'
        $compatibilityHelpers = (Get-Content -Path $compatibilityHelpersPath -Raw) -replace "`r", ''
        $preCommit = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Run-PreCommitValidation.ps1') -Raw) -replace "`r", ''
        $windowsChecks = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Quality/Invoke-WindowsLanguageChecks.ps1') -Raw) -replace "`r", ''
        $compatibilityTests = (Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'Tests/Utils/CompatibilityHelpers.Tests.ps1') -Raw) -replace "`r", ''

        $compatibilityHelpers | Should -Match 'function\s+Get-ChildProcessIdsPortably'
        $compatibilityHelpers | Should -Match 'function\s+Get-ProcessDescendantIdsPortably'
        $compatibilityHelpers | Should -Match 'function\s+Stop-ProcessTreeFallbackPortably'
        $compatibilityHelpers | Should -Match 'Get-CimInstance'
        $compatibilityHelpers | Should -Match '\bpgrep\b'
        $compatibilityHelpers | Should -Match '\bps\b'
        $compatibilityHelpers | Should -Match 'Stop-ProcessTreeFallbackPortably\s+-Process\s+\$Process'
        $preCommit | Should -Match 'Stop-ProcessTreePortably\s+-Process\s+\$process'
        $windowsChecks | Should -Match 'Stop-ProcessTreePortably\s+-Process\s+\$process'
        $compatibilityTests | Should -Match 'terminates descendants when using the explicit fallback path'
    }

    It "keeps Invoke-PesterQualityGate diagnostics low-noise" {
        $pesterGatePath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-PesterQualityGate.ps1"
        $content = Get-Content -Path $pesterGatePath -Raw

        $content | Should -Match '\$OutputVerbosity\s*=\s*"None"'
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: version='
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: modulePath='
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: hasNewPesterConfiguration='
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: passed='
        $content | Should -Match 'Write-Verbose\s*"\$DiagnosticsPrefix diagnostics: outputVerbosity='
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
                $relative = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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

    It "declares strict mode and ErrorActionPreference before dot-sourcing strict mode helpers in migrated scripts" {
        foreach ($scriptPath in $script:migratedScripts) {
            $fullPath = Join-Path -Path $script:repoRoot -ChildPath $scriptPath
            $content = (Get-Content -Path $fullPath -Raw) -replace "`r", ''

            $dotSourceIndex = $content.IndexOf('. $strictModeHelpersPath', [System.StringComparison]::Ordinal)
            if ($dotSourceIndex -lt 0) {
                continue
            }

            $strictModeIndex = $content.IndexOf('Set-StrictMode -Version Latest', [System.StringComparison]::Ordinal)
            $errorActionIndex = $content.IndexOf('$ErrorActionPreference = "Stop"', [System.StringComparison]::Ordinal)

            $strictModeIndex | Should -BeGreaterThan -1 -Because "$scriptPath must declare strict mode."
            $errorActionIndex | Should -BeGreaterThan -1 -Because "$scriptPath must set ErrorActionPreference."
            $strictModeIndex | Should -BeLessThan $dotSourceIndex -Because "$scriptPath must enable strict mode before dot-sourcing helper code."
            $errorActionIndex | Should -BeLessThan $dotSourceIndex -Because "$scriptPath must set ErrorActionPreference before dot-sourcing helper code."
        }
    }

    It "uses literal path semantics for FormatPowershellScripts variable-driven filesystem paths" {
        $formatScriptPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/FormatPowershellScripts.ps1'
        $content = (Get-Content -Path $formatScriptPath -Raw) -replace "`r", ''

        $content | Should -Match 'Test-Path\s+-LiteralPath\s+\$strictModeHelpersPath\s+-PathType\s+Leaf'
        $content | Should -Match 'Test-Path\s+-LiteralPath\s+\$ConfiguredPath\s+-PathType\s+Leaf'
        $content | Should -Match 'Get-ChildItem\s+-LiteralPath\s+\$rootDirectory\s+-Recurse\s+-File\s+-Filter\s+''\*\.ps1'''
        $content | Should -Match 'Get-ChildItem\s+-LiteralPath\s+\$rootDirectory\s+-Recurse\s+-File\s+-Filter\s+''\*\.psm1'''
        $content | Should -Not -Match 'Get-ChildItem\s+-Path\s+\$rootDirectory\s+-Recurse\s+-Include'
    }

    It "uses literal path semantics in LLM wrapper contract helper" {
        $helperPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/Common/LlmWrapperContractHelpers.ps1'
        $content = (Get-Content -Path $helperPath -Raw) -replace "`r", ''

        $content | Should -Match 'Test-Path\s+-LiteralPath\s+\$ContextFilePath\s+-PathType\s+Leaf'
        $content | Should -Not -Match 'Test-Path\s+-Path\s+\$ContextFilePath\s+-PathType\s+Leaf'
    }

    It "uses literal path validation for Pandoc input directory" {
        $pandocPath = Join-Path -Path $script:repoRoot -ChildPath 'Scripts/Utils/PandocConvertDirectory.ps1'
        $pandocContent = (Get-Content -Path $pandocPath -Raw) -replace "`r", ''
        $dotSourceIndex = $pandocContent.IndexOf('. $strictModeHelpersPath', [System.StringComparison]::Ordinal)
        if ($dotSourceIndex -lt 0) {
            $dotSourceIndex = $pandocContent.IndexOf('.$strictModeHelpersPath', [System.StringComparison]::Ordinal)
        }

        $pandocContent | Should -Match 'ValidateScript\(\{\s*Test-Path\s+-LiteralPath\s+\$_\s+-PathType\s+''Container''\s*\}\)'
        $dotSourceIndex | Should -BeGreaterThan -1 -Because 'PandocConvertDirectory.ps1 must dot-source StrictModeHelpers.'
        $pandocContent.IndexOf('Set-StrictMode -Version Latest', [System.StringComparison]::Ordinal) | Should -BeLessThan $dotSourceIndex
        $pandocContent.IndexOf('$ErrorActionPreference = "Stop"', [System.StringComparison]::Ordinal) | Should -BeLessThan $dotSourceIndex
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
                        $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $file.FullName
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
                        $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $file.FullName
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
    It "parses all Pester test files without parser errors" {
        $testRoot = Join-Path -Path $script:repoRoot -ChildPath "Tests"
        $testFiles = @(Get-ChildItem -Path $testRoot -Filter "*.Tests.ps1" -File -Recurse -ErrorAction Stop)
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($file in $testFiles) {
            $tokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)

            $fileParseErrors = @($parseErrors)
            if ($fileParseErrors.Count -eq 0) {
                continue
            }

            $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $file.FullName
            $errorSummary = ($fileParseErrors | ForEach-Object { $_.Message }) -join '; '
            $violations.Add(("{0}: {1}" -f $relativePath, $errorSummary)) | Out-Null
        }

        $violations.Count | Should -Be 0 -Because (
            "Pester test files must parse cleanly to avoid hidden zero-discovery CI failures. Violations: {0}" -f ($violations -join ' | ')
        )
    }

    It "forbids indented here-string terminators in Pester test files" {
        $testRoot = Join-Path -Path $script:repoRoot -ChildPath "Tests"
        $testFiles = @(Get-ChildItem -Path $testRoot -Filter "*.Tests.ps1" -File -Recurse -ErrorAction Stop)
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($file in $testFiles) {
            $lines = @(Get-Content -Path $file.FullName)
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match '^\s+''@$' -or $lines[$index] -match '^\s+"@$') {
                    $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $file.FullName
                    $violations.Add("${relativePath}:$($index + 1)") | Out-Null
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Here-string terminators must start at column 1. Violations: {0}" -f ($violations -join ', ')
        )
    }

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
                    $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $file.FullName
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
                    $relativePath = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $file.FullName
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
    It "keeps Copy, Truncate, and KeepMarkup parameters in the PR unresolved comments script" {
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $scriptPath -Raw

        $content | Should -Match '\[switch\]\$Truncate'
        $content | Should -Match '\[switch\]\$KeepMarkup'
        $content | Should -Match '\[switch\]\$Copy'
        $content | Should -Match '\.PARAMETER\s+Truncate'
        $content | Should -Match '\.PARAMETER\s+KeepMarkup'
        $content | Should -Match '\.PARAMETER\s+Copy'
    }

    It "keeps truncation conditional instead of unconditional in record conversion" {
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

        @($parseErrors).Count | Should -Be 0 -Because (
            "Get-UnresolvedPRComments.ps1 must parse cleanly before checking truncation policy."
        )

        $targetFunction = Get-RequiredFunctionDefinitionAst -Ast $ast -Name "Convert-ReviewThreadToOutputRecord" -Context "review-thread truncation policy"
        $parameterNames = @($targetFunction.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        ($parameterNames -ccontains "Truncate") | Should -BeTrue

        $topLevelCommentTruncation = @($targetFunction.Body.FindAll({
                    param($node)
                    if (-not ($node -is [System.Management.Automation.Language.IfStatementAst])) {
                        return $false
                    }

                    $text = $node.Extent.Text
                    return $text -match '\$Truncate\.IsPresent' -and
                    $text -match 'Normalize-CommentText' -and
                    $text -match '-MaxLength\s+500' -and
                    $text -match '-DisableTruncation'
                }, $true) | Select-Object -First 1)

        $topLevelCommentTruncation | Should -Not -BeNullOrEmpty -Because (
            "Top-level review comments must be truncated only when the Truncate switch is present."
        )
    }

    It "keeps bot markup cleanup and embedded location contracts for unresolved comments" {
        $scriptPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/GitHub/Get-UnresolvedPRComments.ps1"
        $content = Get-Content -Path $scriptPath -Raw
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        $testsPath = Join-Path -Path $script:repoRoot -ChildPath "Tests/GitHub/Get-UnresolvedPRComments.Tests.ps1"
        $testsContent = Get-Content -Path $testsPath -Raw

        @($parseErrors).Count | Should -Be 0 -Because (
            "Get-UnresolvedPRComments.ps1 must parse cleanly before checking bot cleanup policy."
        )

        $content | Should -Match 'function\s+Get-EmbeddedCommentLocations'
        $content | Should -Match 'function\s+Resolve-OutputCommentLocation'
        $content | Should -Match 'function\s+Remove-MarkupFromCommentText'
        $content | Should -Match 'Additional Locations'
        $content | Should -Match 'Cursor Bugbot'
        $content | Should -Match 'cursor\\\.com/\(\?:open\|agents\)'
        $content | Should -Match 'function\s+Normalize-CommentText[\s\S]*Remove-MarkupFromCommentText'
        $content | Should -Match 'function\s+Convert-ReviewThreadToOutputRecord[\s\S]*Get-EmbeddedCommentLocations'
        $content | Should -Match 'function\s+Convert-ReviewThreadToOutputRecord[\s\S]*Resolve-OutputCommentLocation'
        $content | Should -Match 'locationSource\s*=\s*\$outputLocation\.Source'
        $content | Should -Match 'githubLineStart\s*=\s*\$githubAnchor\.Start'
        $content | Should -Match 'embeddedLocations\s*=\s*@\(\$embeddedLocations\)'

        $normalizeFunction = Get-RequiredFunctionDefinitionAst -Ast $ast -Name "Normalize-CommentText" -Context "bot cleanup policy"
        $normalizeText = $normalizeFunction.Extent.Text
        $normalizeText | Should -Match '\$cleanedText\s*=\s*if\s*\(\$KeepMarkup\.IsPresent\)\s*\{\s*\$Text\s*\}\s*else\s*\{\s*Remove-MarkupFromCommentText\s+-Text\s+\$Text\s*\}'

        $testsContent | Should -Match 'Describe\s+"Normalize-CommentText"'
        $testsContent | Should -Match 'Describe\s+"Get-EmbeddedCommentLocations"'
        $testsContent | Should -Match 'extracts Cursor Bugbot LOCATIONS ranges in order'
        $testsContent | Should -Match 'uses embedded Cursor Bugbot locations for rendered output and strips bot chrome'
        $testsContent | Should -Match 'preserves markup with KeepMarkup while still using embedded locations'
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
                    $relative = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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
                    $relative = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
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

Describe "PowerShell diagnostic stability conventions" {
    It "does not invoke helper commands inside expandable diagnostic strings" {
        $scriptsRoot = Join-Path -Path $script:repoRoot -ChildPath "Scripts"
        $scripts = Get-ChildItem -Path $scriptsRoot -Filter "*.ps1" -File -Recurse -ErrorAction Stop
        $diagnosticEmitterNames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @("Write-Error", "Write-Warning", "Write-Verbose", "Write-Host")) {
            [void]$diagnosticEmitterNames.Add($name)
        }

        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($scriptFile in $scripts) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($null -eq $ast -or @($parseErrors).Count -gt 0) {
                continue
            }

            $diagnosticNodes = @($ast.FindAll({
                        param($node)

                        if ($node -is [System.Management.Automation.Language.ThrowStatementAst]) {
                            return $true
                        }

                        if (-not ($node -is [System.Management.Automation.Language.CommandAst])) {
                            return $false
                        }

                        $commandName = $node.GetCommandName()
                        return -not [string]::IsNullOrWhiteSpace($commandName) -and $diagnosticEmitterNames.Contains($commandName)
                    }, $true))
            if ($diagnosticNodes.Count -eq 0) {
                continue
            }

            $expandableStrings = @($ast.FindAll({
                        param($node)
                        return $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
                    }, $true))

            foreach ($stringNode in $expandableStrings) {
                $hasCommandSubexpression = $false
                foreach ($nestedExpression in $stringNode.NestedExpressions) {
                    if (-not ($nestedExpression -is [System.Management.Automation.Language.SubExpressionAst])) {
                        continue
                    }

                    $commandExpressions = @($nestedExpression.FindAll({
                                param($innerNode)
                                return $innerNode -is [System.Management.Automation.Language.CommandAst]
                            }, $true))
                    if ($commandExpressions.Count -gt 0) {
                        $hasCommandSubexpression = $true
                        break
                    }
                }

                if (-not $hasCommandSubexpression) {
                    continue
                }

                foreach ($diagnosticNode in $diagnosticNodes) {
                    if ($stringNode.Extent.StartOffset -ge $diagnosticNode.Extent.StartOffset -and $stringNode.Extent.EndOffset -le $diagnosticNode.Extent.EndOffset) {
                        $relative = Get-RelativePathCompat -BasePath $script:repoRoot -TargetPath $scriptFile.FullName
                        $violations.Add("${relative}:$($stringNode.Extent.StartLineNumber)") | Out-Null
                        break
                    }
                }
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Stable diagnostics must precompute helper output before throw/Write-* messages so helper failures cannot mask the primary E_/W_ code. Violations: {0}" -f ($violations -join ", ")
        )
    }
}

Describe "Quality tooling shared-helper conventions" {
    BeforeAll {
        $script:sharedHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/QualityToolingHelpers.ps1"
        $script:shellQualityPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-ShellQualityChecks.ps1"
        $script:nativeQualityPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-NativeQualityChecks.ps1"
        $script:qualityConsumerPaths = @($script:shellQualityPath, $script:nativeQualityPath)
    }

    It "ships the single-source shared helper module" {
        Test-Path -LiteralPath $script:sharedHelperPath -PathType Leaf | Should -BeTrue -Because (
            "Quality tooling infrastructure must live in a single shared helper at '$script:sharedHelperPath'."
        )
    }

    It "dot-sources the shared helper from both quality scripts" {
        foreach ($consumerPath in $script:qualityConsumerPaths) {
            # Normalize to LF so multiline regex anchors work on all platforms.
            $content = (Get-Content -Path $consumerPath -Raw) -replace "`r", ''
            $content | Should -Match 'QualityToolingHelpers\.ps1' -Because (
                "$consumerPath must dot-source the shared QualityToolingHelpers.ps1 module."
            )
        }
    }

    It "keeps web downloads out of the consumer scripts" {
        # A consumer must not perform its own network download by any of these means;
        # all downloads must be delegated to the shared helper. Word-bound the iwr alias
        # so unrelated identifiers are not falsely matched.
        $forbiddenDownloadPattern = '\bInvoke-WebRequest\b|\bInvoke-RestMethod\b|\biwr\b|System\.Net\.WebClient|System\.Net\.Http'
        foreach ($consumerPath in $script:qualityConsumerPaths) {
            $content = (Get-Content -Path $consumerPath -Raw) -replace "`r", ''
            $content | Should -Not -Match $forbiddenDownloadPattern -Because (
                "$consumerPath must delegate downloads to the shared helper, not perform its own network download (Invoke-WebRequest, Invoke-RestMethod, iwr, System.Net.WebClient, System.Net.Http)."
            )
        }
    }

    It "forbids unbounded WaitForExit() in consumer scripts" {
        foreach ($consumerPath in $script:qualityConsumerPaths) {
            $content = (Get-Content -Path $consumerPath -Raw) -replace "`r", ''
            $content | Should -Not -Match 'WaitForExit\(\s*\)' -Because (
                "$consumerPath must not call a bare no-arg WaitForExit(); bounded execution lives in the shared helper."
            )
        }
    }

    It "embeds bounded execution, retry, and OS-aware boundary fixes in the shared helper once" {
        $content = (Get-Content -Path $script:sharedHelperPath -Raw) -replace "`r", ''

        $content | Should -Match 'WaitForExit\(\s*\$TimeoutSeconds\s*\*\s*1000\s*\)' -Because (
            "shared helper must bound subprocess execution with an explicit timeout argument."
        )
        $content | Should -Match 'for\s*\(\s*\$attempt\s*=\s*1;\s*\$attempt\s*-le\s*3;' -Because (
            "shared helper download must retry up to three times with backoff."
        )
        $content | Should -Match 'Start-Sleep\s+-Seconds\s+\$backoffSeconds' -Because (
            "shared helper download retry must apply backoff between attempts."
        )
        $content | Should -Match 'Test-IsWindowsPlatform\s*\)\s*\{\s*\[System\.StringComparison\]::OrdinalIgnoreCase\s*\}' -Because (
            "shared helper repository-boundary check must use OrdinalIgnoreCase only on Windows (via the cross-version Test-IsWindowsPlatform helper)."
        )
        $content | Should -Match 'else\s*\{\s*\[System\.StringComparison\]::Ordinal\s*\}' -Because (
            "shared helper repository-boundary check must use Ordinal comparison on Linux/macOS."
        )
        $content | Should -Match '\$sha256\s*-notmatch\s*''\^\[a-f0-9\]\{64\}\$''' -Because (
            "shared helper asset resolution must validate sha256 format."
        )
    }

    It "does not use closure-captured install-lock callbacks" {
        $content = (Get-Content -Path $script:sharedHelperPath -Raw) -replace "`r", ''

        $content | Should -Match 'Invoke-QualityToolingInstallLock[\s\S]*\[object\[\]\]\$ArgumentList' -Because (
            "Install-lock callbacks must receive explicit arguments so callback visibility is not dependent on GetNewClosure."
        )
        $content | Should -Match '&\s+\$ScriptBlock\s+@ArgumentList' -Because (
            "The shared lock helper must splat explicit callback arguments."
        )
        $content | Should -Not -Match '\.GetNewClosure\s*\(' -Because (
            "Quality-tooling install-lock callbacks must not use GetNewClosure."
        )
    }
}
