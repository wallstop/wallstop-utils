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
        throw "E_CONFIG_ERROR: Failed to parse Run-PreCommitValidation.ps1 for array-shape tests."
    }

    foreach ($functionName in @("Get-RedactedFailureLine", "Convert-ToRedactedOutputLines")) {
        $targetFunction = @($script:preCommitAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
                }, $true) | Select-Object -First 1)

        if ($targetFunction.Count -ne 1) {
            throw "E_CONFIG_ERROR: Expected function '$functionName' in Run-PreCommitValidation.ps1."
        }

        . ([scriptblock]::Create($targetFunction[0].Extent.Text))
    }
}

AfterAll {
    Remove-Item -Path Function:Convert-ToRedactedOutputLines -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Get-RedactedFailureLine -ErrorAction SilentlyContinue
}

Describe "Run-PreCommitValidation array-shape contract" {
    It "returns empty arrays for null and empty input when callers wrap with @()" {
        $nullResult = @(Convert-ToRedactedOutputLines -OutputLines $null)
        $emptyResult = @(Convert-ToRedactedOutputLines -OutputLines @())

        $nullResult.Count | Should -Be 0
        $emptyResult.Count | Should -Be 0
    }

    It "returns a flat string array for non-empty output" {
        $result = @(Convert-ToRedactedOutputLines -OutputLines @('line-one', 'line-two', 'line-three'))

        $result.Count | Should -Be 3
        $result[0] | Should -Be 'line-one'
        $result[1] | Should -Be 'line-two'
        $result[2] | Should -Be 'line-three'

        foreach ($line in $result) {
            $line | Should -BeOfType [string]
        }
    }

    It "redacts sensitive values line-by-line" {
        $result = @(Convert-ToRedactedOutputLines -OutputLines @('Authorization: Bearer "secretjwt"', 'access_token: abc123', 'safe-line'))

        $result.Count | Should -Be 3
        $result[0] | Should -Be 'Authorization: [REDACTED]'
        $result[1] | Should -Be 'access_token: [REDACTED]'
        $result[2] | Should -Be 'safe-line'
    }
}

Describe "Run-PreCommitValidation call-site and helper ownership contracts" {
    It "keeps all Convert-ToRedactedOutputLines call sites wrapped with @()" {
        $callSites = @($script:preCommitAst.FindAll({
                    param($node)
                    if (-not ($node -is [System.Management.Automation.Language.CommandAst])) {
                        return $false
                    }

                    $commandName = $node.GetCommandName()
                    return ($commandName -eq "Convert-ToRedactedOutputLines")
                }, $true))

        $callSites.Count | Should -BeGreaterThan 0 -Because "Expected at least one Convert-ToRedactedOutputLines call site in Run-PreCommitValidation.ps1."

        foreach ($callSite in $callSites) {
            $isArrayWrapped = $false
            $parentNode = $callSite.Parent
            while ($null -ne $parentNode) {
                if ($parentNode -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                    $isArrayWrapped = $true
                    break
                }

                $parentNode = $parentNode.Parent
            }

            $isArrayWrapped | Should -BeTrue -Because (
                "Convert-ToRedactedOutputLines must be called inside @() to preserve empty-array semantics. Offending line: {0}" -f $callSite.Extent.StartLineNumber
            )
        }
    }

    It "keeps Convert-ToRedactedOutputLines return paths wrapper-safe and non-nested" {
        $targetFunction = @($script:preCommitAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Convert-ToRedactedOutputLines"
                }, $true) | Select-Object -First 1)

        $targetFunction.Count | Should -Be 1
        $functionText = ($targetFunction[0].Extent.Text -replace "`r", "")

        $functionText | Should -Match 'return\s+@\(\)\s+#\s*array-unwrap-safe:\s*callers always wrap with @\(\)'
        $functionText | Should -Match 'return\s+@\(\$redactedLines\.ToArray\(\)\)\s+#\s*array-unwrap-safe:\s*callers always wrap with @\(\)'
        $functionText | Should -Not -Match 'return\s*,\s*@\('
    }

    It "does not duplicate Convert-CapturedTextToLines in Run-PreCommitValidation" {
        $script:preCommitContent | Should -Not -Match 'function\s+Convert-CapturedTextToLines\b'
    }

    It "keeps exactly one Convert-CapturedTextToLines definition across Scripts/Utils" {
        $utilsRoot = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils"
        $scriptFiles = @(Get-ChildItem -Path $utilsRoot -Filter "*.ps1" -File -Recurse -ErrorAction Stop)
        $definitions = New-Object System.Collections.Generic.List[string]

        foreach ($scriptFile in $scriptFiles) {
            $lineNumber = 0
            foreach ($line in @(Get-Content -Path $scriptFile.FullName)) {
                $lineNumber++
                if ($line -match '^\s*function\s+Convert-CapturedTextToLines\b') {
                    $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                    $portableRelativePath = $relativePath -replace '\\', '/'
                    $definitions.Add("${portableRelativePath}:$lineNumber") | Out-Null
                }
            }
        }

        $definitions.Count | Should -Be 1 -Because (
            "Convert-CapturedTextToLines should have a single implementation to avoid drift. Definitions: {0}" -f ($definitions -join ', ')
        )
        $definitions[0] | Should -Match '^Scripts/Utils/Quality/Invoke-WindowsLanguageChecks\.ps1:\d+$'
    }

    It "prevents comma-wrapped non-empty array returns from being consumed via @() call sites" {
        $utilsRoot = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils"
        $scriptFiles = @(Get-ChildItem -Path $utilsRoot -Filter "*.ps1" -File -Recurse -ErrorAction Stop)
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($scriptFile in $scriptFiles) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count -gt 0) {
                continue
            }

            $functionByName = @{}
            $riskyFunctions = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
            $functionDefinitions = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                    }, $true))

            foreach ($functionDefinition in $functionDefinitions) {
                $functionByName[$functionDefinition.Name] = $functionDefinition
                $functionText = ($functionDefinition.Extent.Text -replace "`r", "")
                if ($functionText -match '(?m)^\s*return\s*,\s*@\(\s*(?!\))') {
                    [void]$riskyFunctions.Add($functionDefinition.Name)
                }
            }

            if ($riskyFunctions.Count -eq 0) {
                continue
            }

            $commandNodes = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true))

            foreach ($commandNode in $commandNodes) {
                $commandName = $commandNode.GetCommandName()
                if ([string]::IsNullOrWhiteSpace($commandName) -or -not $riskyFunctions.Contains($commandName)) {
                    continue
                }

                $isArrayWrapped = $false
                $parentNode = $commandNode.Parent
                while ($null -ne $parentNode) {
                    if ($parentNode -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                        $isArrayWrapped = $true
                        break
                    }

                    $parentNode = $parentNode.Parent
                }

                if (-not $isArrayWrapped) {
                    continue
                }

                $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $scriptFile.FullName)
                $portableRelativePath = $relativePath -replace '\\', '/'
                $violations.Add("${portableRelativePath}:$($commandNode.Extent.StartLineNumber) command '$commandName'") | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Do not consume comma-wrapped non-empty array returns with @() wrappers; this creates nested arrays. Violations: {0}" -f ($violations -join ', ')
        )
    }
}
