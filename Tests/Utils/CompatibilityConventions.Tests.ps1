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

    It "keeps Config PowerShell profile snapshots guarded for PSReadLine prediction options" {
        $profileSnapshots = @(
            'Config/Powershell/CurrentUserCurrentHost_Microsoft.PowerShell_profile.ps1',
            'Config/Powershell/Microsoft.PowerShell_profile.ps1',
            'Config/Powershell/WindowsPowerShellFallback_Microsoft.PowerShell_profile.ps1'
        )

        foreach ($relativePath in $profileSnapshots) {
            $fullPath = Join-Path -Path $script:repoRoot -ChildPath $relativePath
            Test-Path -LiteralPath $fullPath -PathType Leaf | Should -BeTrue

            $content = (Get-Content -LiteralPath $fullPath -Raw) -replace "`r", ''
            $content | Should -Match '\$setPSReadLineOption\s*=\s*Get-Command\s+Set-PSReadLineOption'
            $content | Should -Match "Parameters\.ContainsKey\('PredictionSource'\)"
            $content | Should -Match "Parameters\.ContainsKey\('PredictionViewStyle'\)"
            $content | Should -Match '\[Diagnostics\.CodeAnalysis\.SuppressMessageAttribute\(''PSUseCompatibleCommands'''
            $content | Should -Not -Match '(?m)(?-i)^\s*Set-PSReadLineOption\s+-PredictionViewStyle\s+InLineView\b'
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

Describe "Cross-version compatibility - Core-only .NET member scan (dependency-free)" {
    BeforeAll {
        # Mirrors Get-CoreOnlyMemberViolation in Invoke-CompatibilityChecks.ps1 so the invariant
        # is ALSO enforced on the Windows PowerShell 5.1 runtime lane (no PSScriptAnalyzer). A
        # deliberately runtime-guarded native access opts out with an inline
        # '# compat-core-member-ok' marker; there is no whole-file allowlist.
        $script:coreOnlyMemberRules = @{
            'ArgumentList'      = @{ RequireInvocation = $false; MinArgumentCount = 0 }
            'ResolveLinkTarget' = @{ RequireInvocation = $true; MinArgumentCount = 0 }
            'LinkTarget'        = @{ RequireInvocation = $false; MinArgumentCount = 0 }
            'Kill'              = @{ RequireInvocation = $true; MinArgumentCount = 1 }
        }

        function Get-CoreOnlyMemberViolationFromAst {
            # Pure detection over a parsed AST + its source lines, so the same logic backs both
            # the file scan and the string-based positive test (without writing a temp file).
            param(
                [System.Management.Automation.Language.Ast]$Ast,
                [string[]]$Lines,
                [hashtable]$Rules
            )

            $found = New-Object System.Collections.Generic.List[object]
            if ($null -eq $Ast) {
                return , @($found.ToArray())
            }

            $memberAsts = @($Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.MemberExpressionAst]
                    }, $true))
            foreach ($memberAst in $memberAsts) {
                if (-not ($memberAst.Member -is [System.Management.Automation.Language.StringConstantExpressionAst])) {
                    continue
                }
                $name = $memberAst.Member.Value
                if (-not $Rules.ContainsKey($name)) {
                    continue
                }
                $rule = $Rules[$name]
                $isInvocation = ($memberAst -is [System.Management.Automation.Language.InvokeMemberExpressionAst])
                if ($rule.RequireInvocation -and -not $isInvocation) {
                    continue
                }
                if ($rule.MinArgumentCount -gt 0) {
                    if (-not $isInvocation) {
                        continue
                    }
                    $argCount = 0
                    if ($null -ne $memberAst.Arguments) {
                        $argCount = @($memberAst.Arguments).Count
                    }
                    if ($argCount -lt $rule.MinArgumentCount) {
                        continue
                    }
                }
                # Scan every line the member expression spans for the opt-out marker (mirrors
                # the gate's Get-CoreOnlyMemberViolation).
                $isMarked = $false
                for ($markerLine = $memberAst.Extent.StartLineNumber; $markerLine -le $memberAst.Extent.EndLineNumber; $markerLine++) {
                    if ($markerLine -ge 1 -and $markerLine -le $Lines.Length -and $Lines[$markerLine - 1].Contains('compat-core-member-ok')) {
                        $isMarked = $true
                        break
                    }
                }
                if ($isMarked) {
                    continue
                }
                $found.Add([pscustomobject]@{ Name = $name; Line = $memberAst.Extent.StartLineNumber }) | Out-Null
            }
            return , @($found.ToArray())
        }
    }

    It "has no unguarded .NET Core-only member access in production scripts" {
        $scriptsRoot = Join-Path -Path $script:repoRoot -ChildPath 'Scripts'
        $files = @(Get-ChildItem -Path $scriptsRoot -Recurse -File -Include *.ps1, *.psm1)

        $violations = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $lines = [System.IO.File]::ReadAllLines($file.FullName)
            foreach ($v in (Get-CoreOnlyMemberViolationFromAst -Ast $ast -Lines $lines -Rules $script:coreOnlyMemberRules)) {
                $violations.Add(("{0}:{1} .{2}" -f $file.Name, $v.Line, $v.Name)) | Out-Null
            }
        }

        $violations.Count | Should -Be 0 -Because (
            "ProcessStartInfo.ArgumentList / FileSystemInfo.ResolveLinkTarget / .LinkTarget / Process.Kill([bool]) throw on Windows PowerShell 5.1; route them through the CompatibilityHelpers shims (Set-PortableProcessArguments / Get-PortableLinkTarget / Stop-ProcessTreePortably) or annotate a deliberately-guarded access with '# compat-core-member-ok'. Violations: " + ($violations -join '; '))
    }

    It "flags unguarded Core-only access (incl. Kill([bool]) overload), honors the opt-out marker, and ignores look-alikes" {
        # Parse from a string (no temp file) so the detection logic is verified directly.
        $sample = @'
param([string[]]$ArgumentList)
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.ArgumentList.Add("x")
$probe = [System.Diagnostics.ProcessStartInfo].GetProperty('ArgumentList')
$item.ResolveLinkTarget($true)
$count = $ArgumentList.Count
$process.Kill()
$process.Kill($true)
$guarded.ResolveLinkTarget($true) # compat-core-member-ok
'@
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($sample, [ref]$null, [ref]$null)
        $lines = $sample -split "`r?`n"
        # Get-CoreOnlyMemberViolationFromAst comma-wraps its return for empty-safety, so the
        # call site must NOT wrap with @() (that would nest the array). See .llm/context.md
        # "PowerShell Empty Array Return Safety".
        $flagged = Get-CoreOnlyMemberViolationFromAst -Ast $ast -Lines $lines -Rules $script:coreOnlyMemberRules
        $names = @($flagged | ForEach-Object { $_.Name })

        # Caught: unguarded $startInfo.ArgumentList, unguarded $item.ResolveLinkTarget, and the
        # Core-only Process.Kill($true) OVERLOAD.
        ($names -contains 'ArgumentList') | Should -BeTrue
        ($names -contains 'ResolveLinkTarget') | Should -BeTrue
        ($names -contains 'Kill') | Should -BeTrue

        # Kill() (no argument) is present on both editions and must NOT be flagged; only the
        # Kill($true) overload is. So exactly one 'Kill' violation.
        (@($names | Where-Object { $_ -eq 'Kill' }).Count) | Should -Be 1
        # The marked $guarded.ResolveLinkTarget is exempt, so exactly one 'ResolveLinkTarget'.
        (@($names | Where-Object { $_ -eq 'ResolveLinkTarget' }).Count) | Should -Be 1
        # Look-alikes ($ArgumentList param/Count, GetProperty('ArgumentList') string arg) excluded.
        (@($names | Where-Object { $_ -eq 'ArgumentList' }).Count) | Should -Be 1
        $flagged.Count | Should -Be 3
    }
}
