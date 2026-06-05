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
}

AfterAll {
    Remove-Item -Path Function:Get-RequiredFunctionDefinitionAst -ErrorAction SilentlyContinue
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

    It "keeps Pester execution gated out of fast local mode" {
        $script:preCommitContent | Should -Match '\$runUtilsTests\s*=\s*\$All\s+-and\s+\$utilsTestTargets\.Count\s+-gt\s+0'
        $script:preCommitContent | Should -Match '(?m)^\s*\$runGitHubTests\s*=\s*\$All\s*$'
        $script:preCommitContent | Should -Match '\$runShellSafetySuite\s*=\s*\$All\s+-and\s+-not\s+\$runUtilsTests'
        $script:preCommitContent | Should -Match '\$requiresPesterModule\s*=\s*\$runUtilsTests\s+-or\s+\$runGitHubTests\s+-or\s+\$runShellSafetySuite'
        $script:preCommitContent | Should -Match 'Invoke-PesterQualityGateInIsolatedProcess'
    }

    It "keeps cross-version compatibility checks in all-mode deep validation" {
        $script:preCommitContent | Should -Match '\$compatibilityTargetFiles\s*=\s*@\(\s*\$trackedFileOutput[\s\S]*?\$compatibilityTargetPattern'
        $script:preCommitContent | Should -Match '\$runCompatibilityGate\s*=\s*\$All\s+-and\s+\$compatibilityTargetFiles\.Count\s+-gt\s+0'
        $script:preCommitContent | Should -Not -Match '\$runCompatibilityGate\s*=\s*-not\s+\$All'
        $script:preCommitContent | Should -Match 'Invoke-CompatibilityChecks\.ps1'
    }

    It "keeps shell and native quality checks as all-mode-only orchestrator work" {
        $script:preCommitContent | Should -Match '(?s)if\s*\(\$All\)\s*\{.*?\$shellQualityFiles\s*=.*?\$nativeQualityFiles\s*=.*?\}\s*elseif\s*\(\$IncludePreCommitOwnedChecks\)\s*\{.*?\$shellQualityFiles\s*=.*?\$nativeQualityFiles\s*=.*?\}\s*else\s*\{\s*\$shellQualityFiles\s*=\s*@\(\)\s*\$nativeQualityFiles\s*=\s*@\(\)\s*\}'
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
