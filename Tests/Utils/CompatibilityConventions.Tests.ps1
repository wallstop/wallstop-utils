Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeDiscovery {
    $compatibilityRepoRootForDiscovery = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $profileSnapshotCases = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $compatibilityRepoRootForDiscovery -ChildPath 'Config/Powershell') -Filter '*profile*.ps1' -File |
            Sort-Object -Property Name |
            ForEach-Object {
                @{
                    RelativePath = ("Config/Powershell/{0}" -f $_.Name)
                }
            }
    )
    $profileStartupHostCases = @()
    $profileStartupHostDefinitions = @(
        @{ HostName = 'PowerShell 7+'; CommandName = 'pwsh' },
        @{ HostName = 'Windows PowerShell 5.1'; CommandName = 'powershell.exe' }
    )
    foreach ($hostDefinition in $profileStartupHostDefinitions) {
        $hostCommand = Get-Command -Name $hostDefinition.CommandName -ErrorAction SilentlyContinue
        if ($null -eq $hostCommand) {
            continue
        }

        foreach ($profileSnapshotCase in $profileSnapshotCases) {
            $profileStartupHostCases += @{
                HostName     = $hostDefinition.HostName
                CommandPath  = $hostCommand.Source
                RelativePath = $profileSnapshotCase.RelativePath
            }
        }
    }
}

BeforeAll {
    function Resolve-CanonicalTempRoot {
        param([string]$Path)

        $resolvedItem = Get-Item -LiteralPath $Path -ErrorAction Stop
        return $resolvedItem.FullName
    }

    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1"
    $script:psReadLineProfileHelperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/PSReadLineProfilePortabilityHelpers.ps1"
    $script:gatePath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/Invoke-CompatibilityChecks.ps1"
    $script:allowlistPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Quality/compatibility-allowlist.psd1"
    $script:profileSnapshotCount = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'Config/Powershell') -Filter '*profile*.ps1' -File
    ).Count
    if (Test-Path -LiteralPath $script:psReadLineProfileHelperPath -PathType Leaf) {
        . $script:psReadLineProfileHelperPath
    }
}

Describe "Cross-version compatibility infrastructure" {
    It "ships the keystone compatibility helper, gate, and allowlist" {
        Test-Path -LiteralPath $script:helperPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:psReadLineProfileHelperPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:gatePath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:allowlistPath -PathType Leaf | Should -BeTrue
    }

    It "exposes the documented portable helper functions" {
        $content = Get-Content -LiteralPath $script:helperPath -Raw
        foreach ($fn in @(
                'Test-IsWindowsPlatform', 'Test-IsMacOSPlatform', 'Test-IsLinuxPlatform',
                'Get-RelativePathCompat', 'ConvertTo-JsonArrayCompat', 'ConvertFrom-JsonCompat',
                'Set-PortableProcessEnvironmentVariable')) {
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

    It "discovers Config PowerShell profile files for PSReadLine guard coverage" {
        $script:profileSnapshotCount | Should -BeGreaterThan 0
    }

    It "keeps <RelativePath> guarded for PSReadLine capability differences" -TestCases $profileSnapshotCases {
        param([string]$RelativePath)

        $fullPath = Join-Path -Path $script:repoRoot -ChildPath $RelativePath
        Test-Path -LiteralPath $fullPath -PathType Leaf | Should -BeTrue

        $content = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8) -replace "`r", ''
        $violations = @(Get-PSReadLineProfilePortabilityViolation -Path $fullPath)
        $violations.Count | Should -Be 0 -Because "$RelativePath PSReadLine setup must be structurally guarded. Violations: $($violations -join ', ')"
        $content | Should -Match '\$setPSReadLineOption\s*=\s*Get-Command\s+Set-PSReadLineOption' -Because "$RelativePath must probe Set-PSReadLineOption before using version-specific parameters."
        $content | Should -Match "Parameters\.ContainsKey\('PredictionSource'\)" -Because "$RelativePath must guard PSReadLine 2.2+ prediction source support."
        $content | Should -Match "Parameters\.ContainsKey\('PredictionViewStyle'\)" -Because "$RelativePath must guard PSReadLine 2.2+ prediction view support."
        $content | Should -Match '\$canConfigurePSReadLinePrediction\s*=' -Because "$RelativePath must skip prediction setup when the host cannot render it."
        $content | Should -Match '\[Console\]::IsOutputRedirected' -Because "$RelativePath must skip PSReadLine prediction setup for redirected output."
        $content | Should -Match '\$Host\.UI\.SupportsVirtualTerminal' -Because "$RelativePath must skip PSReadLine prediction setup when VT rendering is unavailable."
        $content | Should -Match '\$setPSReadLineKeyHandler\s*=\s*Get-Command\s+Set-PSReadLineKeyHandler' -Because "$RelativePath must not fail profile startup when PSReadLine is unavailable."
        $content | Should -Not -Match '\[Diagnostics\.CodeAnalysis\.SuppressMessageAttribute\(''PSUseCompatibleCommands''' -Because "$RelativePath must rely on structural guard filtering, not a file-wide compatibility suppression."
        $content | Should -Not -Match '(?m)(?-i)^\s*Set-PSReadLineOption\s+-PredictionViewStyle\s+InLineView\b'
    }

    It "classifies synthetic PSReadLine profile guard case: <Name>" -TestCases @(
        @{
            Name               = 'valid guarded profile'
            ExpectedViolations = @()
            Content            = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
}
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionViewStyle')) {
    Set-PSReadLineOption -PredictionViewStyle InlineView -ErrorAction SilentlyContinue
}
$setPSReadLineKeyHandler = Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue
if ($setPSReadLineKeyHandler) { Set-PSReadLineKeyHandler -Key Tab -Function Complete -ErrorAction SilentlyContinue }
'@
        }
        @{
            Name               = 'valid guarded profile with case-insensitive PSReadLine guard spelling'
            ExpectedViolations = @()
            Content            = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [environment]::UserInteractive -and -not [console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setpsreadlineoption -and $setpsreadlineoption.parameters.containskey('predictionsource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
}
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.PARAMETERS.CONTAINSKEY('predictionviewstyle')) {
    Set-PSReadLineOption -PredictionViewStyle InlineView -ErrorAction SilentlyContinue
}
'@
        }
        @{
            Name               = 'unguarded prediction source'
            ExpectedViolations = @('unguarded-PredictionSource')
            Content            = @'
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
'@
        }
        @{
            Name               = 'wrong parameter guard target'
            ExpectedViolations = @('unguarded-PredictionSource')
            Content            = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
$other = @{ Parameters = @{} }
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $other.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
}
'@
        }
        @{
            Name               = 'unsafe prediction host guard variable'
            ExpectedViolations = @('unguarded-PredictionViewStyle')
            Content            = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = $true
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionViewStyle')) {
    Set-PSReadLineOption -PredictionViewStyle InlineView
}
'@
        }
        @{
            Name               = 'unsafe boolean host guard composition'
            ExpectedViolations = @('unguarded-PredictionSource')
            Content            = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = $true -or ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal)
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
}
'@
        }
        @{
            Name               = 'post-probe virtual terminal overwrite'
            ExpectedViolations = @('unguarded-PredictionViewStyle')
            Content            = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$supportsVirtualTerminal = $true
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionViewStyle')) {
    Set-PSReadLineOption -PredictionViewStyle InlineView
}
'@
        }
        @{
            Name               = 'missing standalone command probe'
            ExpectedViolations = @('unguarded-PredictionSource')
            Content            = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
}
'@
        }
        @{
            Name               = 'unguarded key handler'
            ExpectedViolations = @('unguarded-Set-PSReadLineKeyHandler')
            Content            = @'
Set-PSReadLineKeyHandler -Key Tab -Function Complete
'@
        }
        @{
            Name               = 'guard assignment after command'
            ExpectedViolations = @('unguarded-PredictionSource')
            Content            = @'
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
}
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
'@
        }
        @{
            Name               = 'noncanonical prediction view spelling'
            ExpectedViolations = @('noncanonical-InLineView')
            Content            = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionViewStyle')) {
    Set-PSReadLineOption -PredictionViewStyle InLineView
}
'@
        }
    ) {
        param(
            [string]$Name,
            [string]$Content,
            [string[]]$ExpectedViolations
        )

        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("psreadline-profile-{0}" -f [guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
        $tempRoot = Resolve-CanonicalTempRoot -Path $tempRoot
        $tempPath = Join-Path -Path $tempRoot -ChildPath 'profile.ps1'
        try {
            [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
            $violations = @(Get-PSReadLineProfilePortabilityViolation -Path $tempPath)

            foreach ($expectedViolation in @($ExpectedViolations)) {
                $violations | Should -Contain $expectedViolation -Because "$Name should report $expectedViolation."
            }

            $unexpectedViolations = @(
                $violations |
                    Where-Object { @($ExpectedViolations) -notcontains $_ }
            )
            $unexpectedViolations.Count | Should -Be 0 -Because "$Name should not report unexpected violations. Actual: $($violations -join ', ')"
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "classifies PSReadLine compatibility finding guard case: <Name>" -TestCases @(
        @{
            Name            = 'valid guarded prediction source finding'
            ParameterName   = 'PredictionSource'
            ExpectedGuarded = $true
            Content         = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
}
'@
        }
        @{
            Name            = 'valid guarded prediction source finding with case-insensitive guard spelling'
            ParameterName   = 'PredictionSource'
            ExpectedGuarded = $true
            Content         = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [environment]::UserInteractive -and -not [console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setpsreadlineoption -and $setpsreadlineoption.parameters.containskey('predictionsource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
}
'@
        }
        @{
            Name            = 'valid guarded prediction view finding with case-insensitive guard spelling'
            ParameterName   = 'PredictionViewStyle'
            ExpectedGuarded = $true
            Content         = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.PARAMETERS.CONTAINSKEY('predictionviewstyle')) {
    Set-PSReadLineOption -PredictionViewStyle InlineView
}
'@
        }
        @{
            Name            = 'rejects missing standalone command probe'
            ParameterName   = 'PredictionSource'
            ExpectedGuarded = $false
            Content         = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
}
'@
        }
        @{
            Name            = 'rejects unsafe boolean host guard composition'
            ParameterName   = 'PredictionSource'
            ExpectedGuarded = $false
            Content         = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$canConfigurePSReadLinePrediction = $true -or ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal)
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionSource')) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
}
'@
        }
        @{
            Name            = 'rejects post-probe virtual terminal overwrite'
            ParameterName   = 'PredictionViewStyle'
            ExpectedGuarded = $false
            Content         = @'
$supportsVirtualTerminal = $false
try { $supportsVirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal } catch { $supportsVirtualTerminal = $false }
$supportsVirtualTerminal = $true
$canConfigurePSReadLinePrediction = [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and $supportsVirtualTerminal
$setPSReadLineOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
if ($canConfigurePSReadLinePrediction -and $setPSReadLineOption -and $setPSReadLineOption.Parameters.ContainsKey('PredictionViewStyle')) {
    Set-PSReadLineOption -PredictionViewStyle InlineView
}
'@
        }
    ) {
        param(
            [string]$Name,
            [string]$Content,
            [string]$ParameterName,
            [bool]$ExpectedGuarded
        )

        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("psreadline-compat-finding-{0}" -f [guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
        $tempRoot = Resolve-CanonicalTempRoot -Path $tempRoot
        $tempPath = Join-Path -Path $tempRoot -ChildPath 'profile.ps1'
        try {
            [System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
            $lines = @($Content -split "`r?`n")
            $commandLine = 0
            for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
                if ($lines[$lineIndex] -match ('Set-PSReadLineOption\s+-{0}\b' -f [regex]::Escape($ParameterName))) {
                    $commandLine = $lineIndex + 1
                    break
                }
            }

            $commandLine | Should -BeGreaterThan 0 -Because "$Name must include a Set-PSReadLineOption -$ParameterName command."
            $guarded = Test-PSReadLineCompatibilityFindingGuarded -Path $tempPath -Line $commandLine -ParameterName $ParameterName
            $guarded | Should -Be $ExpectedGuarded -Because "$Name should return guarded=$ExpectedGuarded for the compatibility-gate filter."
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps Config PowerShell profiles quiet when output is redirected under <HostName>: <RelativePath>" -TestCases $profileStartupHostCases {
        param(
            [string]$HostName,
            [string]$CommandPath,
            [string]$RelativePath
        )

        $fullPath = Join-Path -Path $script:repoRoot -ChildPath $RelativePath
        $output = @(& $CommandPath -NoLogo -NoProfile -File $fullPath 2>&1)
        $exitCode = $LASTEXITCODE
        $psReadLineErrors = @(
            $output |
                Where-Object { [string]$_ -match 'predictive suggestion feature cannot be enabled|Set-PSReadLineOption|PredictionSource|PredictionViewStyle' }
        )

        $exitCode | Should -Be 0 -Because "$RelativePath must not fail in redirected/non-interactive $HostName validation hosts."
        $psReadLineErrors.Count | Should -Be 0 -Because "$RelativePath must not emit PSReadLine prediction errors under $HostName when output is redirected. Output: $($output -join '; ')"
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

Describe "Cross-version compatibility gate wiring" {
    It "keeps the static compatibility rules and diagnostics wired into the gate" {
        $gateContent = [System.IO.File]::ReadAllText($script:gatePath, [System.Text.Encoding]::UTF8) -replace "`r", ''

        $gateContent | Should -Match 'PSUseCompatibleSyntax'
        $gateContent | Should -Match 'PSUseCompatibleCommands'
        $gateContent | Should -Match 'PSUseCompatibleTypes'
        $gateContent | Should -Match 'E_COMPAT_INCOMPATIBILITY'
    }

    It "filters PSReadLine prediction findings only through structural guards" {
        $gateContent = [System.IO.File]::ReadAllText($script:gatePath, [System.Text.Encoding]::UTF8) -replace "`r", ''
        $helperContent = [System.IO.File]::ReadAllText($script:psReadLineProfileHelperPath, [System.Text.Encoding]::UTF8) -replace "`r", ''

        $gateContent | Should -Match 'PSReadLineProfilePortabilityHelpers\.ps1'
        $gateContent | Should -Match 'Get-FindingParameterName'
        $gateContent | Should -Match 'Test-PSReadLineCompatibilityFindingGuarded'
        $helperContent | Should -Match 'Get-PSReadLineGuardConditionAstForCommand'
        $helperContent | Should -Match 'Test-PSReadLineCommandGuardedForPredictionParameter'
        $helperContent | Should -Match 'Test-PSReadLineAstContainsPSReadLineOptionParameterGuard'
        $helperContent | Should -Match 'Test-PSReadLineAstHasSafePredictionHostGuard'
        $helperContent | Should -Match 'Test-PSReadLineAstContainsHostUISupportsVirtualTerminalAccess'
        $helperContent | Should -Match "ContainsKey"
        $helperContent | Should -Match "PredictionSource"
        $helperContent | Should -Match "PredictionViewStyle"
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
