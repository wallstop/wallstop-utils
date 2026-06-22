Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:preCommitPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Run-PreCommitValidation.ps1"
    $script:preCommitContent = (Get-Content -Path $script:preCommitPath -Raw) -replace "`r", ""

    $tokens = $null
    $parseErrors = $null
    $script:preCommitAst = [System.Management.Automation.Language.Parser]::ParseFile($script:preCommitPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "E_CONFIG_ERROR: Failed to parse Run-PreCommitValidation.ps1 for fast-local tests."
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

    function Get-RequiredVariableAssignmentAst {
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

                    if ($node -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
                        return $false
                    }

                    $left = $node.Left
                    return (
                        $left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $left.VariablePath.UserPath -eq $Name
                    )
                }, $true))

        if ($matches.Count -ne 1) {
            throw "E_CONFIG_ERROR: Expected exactly one assignment to '$Name' for $Context; found $($matches.Count)."
        }

        return $matches[0]
    }

    function Get-VariableReferenceNames {
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.Language.Ast]$Ast
        )

        return @(
            $Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true) |
                ForEach-Object { $_.VariablePath.UserPath } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
    }

    function Get-IsolatedPesterExecutionGateNames {
        param(
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.Language.Ast]$Ast
        )

        $pesterIfStatements = @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Extent.Text -match 'Invoke-PesterQualityGateInIsolatedProcess'
                }, $true))

        $gateNames = @(
            foreach ($ifStatement in $pesterIfStatements) {
                foreach ($clause in $ifStatement.Clauses) {
                    Get-VariableReferenceNames -Ast $clause.Item1 |
                        Where-Object { $_ -match '^run[A-Z].*' }
                }
            }
        )

        return @($gateNames | Sort-Object -Unique)
    }
}

AfterAll {
    Remove-Item -Path Function:Get-RequiredFunctionDefinitionAst -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Get-RequiredVariableAssignmentAst -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Get-VariableReferenceNames -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Get-IsolatedPesterExecutionGateNames -ErrorAction SilentlyContinue
}

Describe "Run-PreCommitValidation fast local mode" {
    It "accepts explicit target files for pre-push without using staged discovery" {
        $script:preCommitContent | Should -Match '\[string\[\]\]\$TargetFiles\s*=\s*@\(\)'
        $script:preCommitContent | Should -Match '\[string\[\]\]\$RemainingTargetFiles\s*=\s*@\(\)'
        $script:preCommitContent | Should -Match '\[string\]\$TargetFileListPath\s*=\s*""'
        $script:preCommitContent | Should -Match 'ValueFromRemainingArguments\s*=\s*\$true'
        $script:preCommitContent | Should -Match '\$normalizedTargetFiles\s*=\s*@\('
        $script:preCommitContent | Should -Match 'Get-PreCommitValidationTargetFiles\s+-ExplicitFiles\s+\(@\(\$TargetFiles\)\s*\+\s*@\(\$RemainingTargetFiles\)\)\s+-ListPath\s+\$TargetFileListPath'
        $script:preCommitContent | Should -Match 'if\s*\(\$normalizedTargetFiles\.Count\s+-gt\s+0\)\s*\{\s*\$stagedFiles\s*=\s*@\(\$normalizedTargetFiles\)'
        $script:preCommitContent | Should -Match 'E_PRECOMMIT_VALIDATION_ARG_CONFLICT'
        $script:preCommitContent | Should -Match '\[switch\]\$IncludePreCommitOwnedChecks'
        $script:preCommitContent | Should -Match '\[switch\]\$AllowPreCommitOwnedFixes'
    }

    It "keeps Pester gate '<Variable>' scoped as expected" -ForEach @(
        @{
            Variable = 'runUtilsTests'
            Pattern  = '\$runUtilsTests\s*=\s*\$All\s+-and\s+\$utilsTestTargets\.Count\s+-gt\s+0'
        }
        @{
            Variable = 'runKomorebiProfileTests'
            Pattern  = '\$runKomorebiProfileTests\s*=\s*\(-not\s+\$All\)\s+-and\s+\$komorebiProfileFiles\.Count\s+-gt\s+0'
        }
        @{
            Variable = 'runKomorebiPolicyTests'
            Pattern  = '\$runKomorebiPolicyTests\s*=\s*\(-not\s+\$All\)\s+-and\s+\$komorebiPolicyFiles\.Count\s+-gt\s+0'
        }
        @{
            Variable = 'runGitHubTests'
            Pattern  = '(?m)^\s*\$runGitHubTests\s*=\s*\$All\s*$'
        }
        @{
            Variable = 'runShellSafetySuite'
            Pattern  = '\$runShellSafetySuite\s*=\s*\$All\s+-and\s+-not\s+\$runUtilsTests'
        }
    ) {
        $script:preCommitContent | Should -Match $Pattern
    }

    It "requires the Pester module for every isolated Pester execution gate" {
        $pesterExecutionGates = @(Get-IsolatedPesterExecutionGateNames -Ast $script:preCommitAst)
        $pesterExecutionGates.Count | Should -BeGreaterThan 0

        $requiresPesterAssignment = Get-RequiredVariableAssignmentAst -Ast $script:preCommitAst -Name "requiresPesterModule" -Context "fast-local Pester module gate"
        $requiresPesterReferences = @(Get-VariableReferenceNames -Ast $requiresPesterAssignment.Right)

        $requiresPesterReferences.Count | Should -Be $pesterExecutionGates.Count
        foreach ($pesterExecutionGate in $pesterExecutionGates) {
            $requiresPesterReferences | Should -Contain $pesterExecutionGate
        }

        $script:preCommitContent | Should -Match 'Invoke-PesterQualityGateInIsolatedProcess'
    }

    It "runs cross-version compatibility checks for targeted PowerShell files without enabling Pester fast-lane work" {
        $script:preCommitContent | Should -Match '\$compatibilityTargetFiles\s*=\s*@\(\s*\$trackedFileOutput[\s\S]*?\$compatibilityTargetPattern'
        $script:preCommitContent | Should -Match '\$stagedFiles[\s\S]*?\$compatibilityTargetPattern[\s\S]*?Test-Path\s+-LiteralPath\s+\$_\s+-PathType\s+Leaf'
        $script:preCommitContent | Should -Match '\$runCompatibilityGate\s*=\s*\$compatibilityTargetFiles\.Count\s+-gt\s+0'
        $script:preCommitContent | Should -Match '\$requiresCompatibilityAnalyzerModule\s*=\s*\$runCompatibilityGate'
        $script:preCommitContent | Should -Match '\$requiresLintAnalyzerModule\s*=\s*\(-not\s+\$SkipAnalyzer\)\s+-and\s+\$runAnalyzer'
        $script:preCommitContent | Should -Match '\$requiresScriptAnalyzerModule\s*=\s*\$requiresCompatibilityAnalyzerModule\s+-or\s+\$requiresLintAnalyzerModule'
        $script:preCommitContent | Should -Match 'SkipAnalyzer to skip only the ScriptAnalyzer lint step'
        $script:preCommitContent.IndexOf('$requiresCompatibilityAnalyzerModule = $runCompatibilityGate') | Should -BeLessThan $script:preCommitContent.IndexOf('if ($runCompatibilityGate)')
        $script:preCommitContent | Should -Match 'Invoke-CompatibilityChecks\.ps1'
        $script:preCommitContent | Should -Match 'Running cross-version compatibility gate for \{0\} staged target\(s\)'
        $script:preCommitContent | Should -Match 'Invoke-PreCommitExternalCommand[\s\S]*-ContextLabel "cross-version compatibility gate"'
        $script:preCommitContent | Should -Match '"-NonInteractive"'
        $script:preCommitContent | Should -Match 'Invoke-CompatibilityChecks\.ps1[\s\S]*-OutputFormat json -TargetFiles'
        $script:preCommitContent | Should -Not -Match 'Invoke-CompatibilityChecks\.ps1[\s\S]*-OutputFormat json -NoExit -TargetFiles'
        $script:preCommitContent | Should -Match 'ConvertFrom-CompatibilityGateOutput\s+-Output\s+\(\[string\]\$compatibilityResult\.Stdout\)'
        $script:preCommitContent | Should -Match '\[System\.Environment\]::Exit\(\`\$exitCode\)'
        $script:preCommitContent | Should -Match '\[int\]\$compatibilityResult\.ExitCode\s+-eq\s+0'
        $script:preCommitContent | Should -Match '-not\s+\[bool\]\$compatibilityResult\.TimedOut'
        $script:preCommitContent | Should -Not -Match 'W_PRECOMMIT_COMPATIBILITY_PROCESS_DEGRADED_AFTER_PASS'
        $script:preCommitContent | Should -Not -Match '\$compatibilityOutput\s*=\s*@\(&\s+\$pwshExecutable\s+-NoLogo\s+-NoProfile\s+-EncodedCommand'
    }

    It "parses compatibility gate JSON from captured subprocess output" {
        . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/StrictModeHelpers.ps1")
        $targetFunction = Get-RequiredFunctionDefinitionAst -Ast $script:preCommitAst -Name "ConvertFrom-CompatibilityGateOutput" -Context "compatibility gate output parsing"

        . ([scriptblock]::Create($targetFunction.Extent.Text))
        try {
            $result = ConvertFrom-CompatibilityGateOutput -Output "diagnostic before JSON {with braces}`n{`"status`":`"pass`",`"findingCount`":0}`ndiagnostic after JSON {with braces}"

            $result | Should -Not -BeNullOrEmpty
            $result.status | Should -BeExactly "pass"
            [int]$result.findingCount | Should -Be 0
            ConvertFrom-CompatibilityGateOutput -Output "no json here" | Should -BeNullOrEmpty
            ConvertFrom-CompatibilityGateOutput -Output "" | Should -BeNullOrEmpty
        }
        finally {
            Remove-Item -Path Function:ConvertFrom-CompatibilityGateOutput -ErrorAction SilentlyContinue
        }
    }

    It "keeps shell and native quality checks as all-mode-only orchestrator work" {
        $script:preCommitContent | Should -Match '(?s)if\s*\(\$All\)\s*\{.*?\$shellQualityFiles\s*=.*?\$nativeQualityFiles\s*='
        $script:preCommitContent | Should -Match '(?s)elseif\s*\(\$IncludePreCommitOwnedChecks\)\s*\{.*?\$shellQualityFiles\s*=.*?\$nativeQualityFiles\s*='
        $script:preCommitContent | Should -Match '(?s)else\s*\{.*?\$shellQualityFiles\s*=\s*@\(\).*?\$nativeQualityFiles\s*=\s*@\(\)'
        $script:preCommitContent | Should -Match '\$runShellQualityChecks\s*=\s*\$All\s+-or\s+\$shellQualityFiles\.Count\s+-gt\s+0'
        $script:preCommitContent | Should -Match '\$runNativeQualityChecks\s*=\s*\$All\s+-or\s+\$nativeQualityFiles\.Count\s+-gt\s+0'
        $script:preCommitContent | Should -Match 'Invoke-ShellQualityChecks\.ps1'
        $script:preCommitContent | Should -Match 'Invoke-NativeQualityChecks\.ps1'
        $script:preCommitContent | Should -Match '& \$shellQualityScriptPath -Tool All @shellQualityFiles'
        $script:preCommitContent | Should -Match '& \$nativeQualityScriptPath -Tool All @nativeQualityFiles'
    }

    It "runs format-operator safety on target files in fast local mode instead of full roots" {
        $script:preCommitContent | Should -Match '\$formatOperatorTargetFiles\s*=\s*@\('
        $script:preCommitContent | Should -Match 'Assert-NoFormatOperatorContinuationViolations\s+-RootPath\s+\$repoRoot\s+-TargetFiles\s+\$formatOperatorTargetFiles'
        $script:preCommitContent | Should -Match 'Assert-NoFormatOperatorContinuationViolations\s+-RootPath\s+\$repoRoot\s+-RelativeRoots\s+@\("Scripts",\s*"Tests"\)'
    }

    It "keeps helper extraction exact for structural tests" {
        $targetFunction = Get-RequiredFunctionDefinitionAst -Ast $script:preCommitAst -Name "ConvertTo-NormalizedRelativeTargetPath" -Context "fast-local tests"

        $targetFunction.Name | Should -Be "ConvertTo-NormalizedRelativeTargetPath"
    }
}
