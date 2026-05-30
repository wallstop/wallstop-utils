Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1"
    $script:gatePath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-CompatibilityChecks.ps1"
    $script:allowlistPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/compatibility-allowlist.psd1"
}

Describe "Cross-version compatibility infrastructure" {
    It "ships the keystone compatibility helper, gate, and allowlist" {
        Test-Path -LiteralPath $script:helperPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:gatePath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:allowlistPath -PathType Leaf | Should -BeTrue
    }

    It "exposes the documented portable helper functions" {
        $content = Get-Content -LiteralPath $script:helperPath -Raw
        foreach ($fn in @(
                'Test-IsWindowsPlatform', 'Test-IsMacOSPlatform', 'Test-IsLinuxPlatform',
                'Get-RelativePathCompat', 'ConvertTo-JsonArrayCompat', 'ConvertFrom-JsonCompat')) {
            $content | Should -Match ("function\s+" + [regex]::Escape($fn) + "\b")
        }
    }

    It "reads OS automatic variables only by name (never as a bare reference) in the helper" {
        # The keystone helper must access $IsWindows/$IsMacOS/$IsLinux via Get-Variable so
        # it is itself safe under StrictMode on Windows PowerShell 5.1. Use the AST so
        # comment mentions of the variable names do not count.
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:helperPath, [ref]$null, [ref]$parseErrors)
        $bareReferences = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    @('IsWindows', 'IsMacOS', 'IsLinux') -contains $node.VariablePath.UserPath
                }, $true))
        $bareReferences.Count | Should -Be 0
    }

    It "never allowlists a real PowerShell cmdlet whose parameters differ across editions" {
        $allowlist = Import-PowerShellDataFile -LiteralPath $script:allowlistPath
        $allEntries = @($allowlist.ExternalExecutables) + @($allowlist.ModuleCommands)
        $forbidden = @('ConvertTo-Json', 'ConvertFrom-Json', 'New-Item', 'Get-Content', 'Set-Content', 'Set-Clipboard', 'Set-PSReadLineOption')
        foreach ($command in $forbidden) {
            $allEntries | Should -Not -Contain $command
        }
    }
}

Describe "Cross-version compatibility - automatic variable scan (dependency-free)" {
    It "has no bare 5.1-undefined automatic variable references in repository PowerShell scripts" {
        # Mirrors the gate's AST scan but needs no PSScriptAnalyzer, so it runs on every
        # lane (including the Windows PowerShell 5.1 test lane). $IsWindows/$IsMacOS/$IsLinux
        # do not exist on Desktop edition and throw under StrictMode; $PSStyle is 7.2+.
        $forbidden = @('IsWindows', 'IsMacOS', 'IsLinux', 'IsCoreCLR', 'PSStyle')
        $scanRoots = @('Scripts', 'Config', 'Tests') |
            ForEach-Object { Join-Path -Path $script:repoRoot -ChildPath $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Container }
        $files = @(Get-ChildItem -Path $scanRoots -Recurse -File -Include *.ps1, *.psm1)

        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) {
            if ($file.Name -eq 'CompatibilityHelpers.ps1') {
                continue
            }
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
            if ($null -eq $ast) {
                continue
            }
            $bare = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        @('IsWindows', 'IsMacOS', 'IsLinux', 'IsCoreCLR', 'PSStyle') -contains $node.VariablePath.UserPath
                    }, $true))
            foreach ($reference in $bare) {
                $violations.Add(("{0}:{1} `${2}" -f $file.Name, $reference.Extent.StartLineNumber, $reference.VariablePath.UserPath)) | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "Use the Test-Is*Platform helpers (or Get-Variable) instead of bare automatic variables. Violations: " + ($violations -join '; '))
    }
}

Describe "Cross-version compatibility gate (PSScriptAnalyzer)" {
    It "reports zero cross-version incompatibilities across the repository" {
        # The full static gate depends on pwsh + PSScriptAnalyzer. When either is unavailable
        # (for example the runtime-only Windows PowerShell 5.1 test lane) this is covered by
        # the dedicated powershell-compat-analyzer CI lane instead.
        if ($null -eq (Get-Command pwsh -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "pwsh is unavailable; the compat gate is enforced by the powershell-compat-analyzer CI lane."
            return
        }
        $analyzerAvailable = & pwsh -NoProfile -Command "[bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)"
        if ($analyzerAvailable -ne 'True' -and $analyzerAvailable -ne $true) {
            Set-ItResult -Skipped -Because "PSScriptAnalyzer is not available; the compat gate is enforced by the powershell-compat-analyzer CI lane."
            return
        }

        $gateJson = & pwsh -NoProfile -File $script:gatePath -OutputFormat json
        $gateResult = ($gateJson | Out-String) | ConvertFrom-Json
        $messages = @($gateResult.findings | ForEach-Object { "$($_.file):$($_.line) [$($_.ruleName)]" })
        $gateResult.findingCount | Should -Be 0 -Because (
            "All PowerShell scripts must run on Windows PowerShell 5.1 and PowerShell 7+. Remaining findings: " + ($messages -join '; '))
        # Sanity check that the allowlist is actually engaged (external exes / Pester DSL).
        $gateResult.allowedFindingCount | Should -BeGreaterThan 0
    }
}
