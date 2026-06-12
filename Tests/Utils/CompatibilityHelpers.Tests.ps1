Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    function Resolve-CanonicalTempRoot {
        param([string]$Path)

        # Match FileInfo.FullName canonicalization so path comparisons are stable under
        # symlink aliases (for example /var vs /private/var on macOS); see .llm/context.md
        # "Test Temp Directory Canonicalization".
        $resolvedItem = Get-Item -LiteralPath $Path -ErrorAction Stop
        return $resolvedItem.FullName
    }

    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    $script:helperPath = Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CompatibilityHelpers.ps1"
    . $script:helperPath
}

Describe "CompatibilityHelpers OS detection" {
    It "exposes the Test-Is*Platform helpers" {
        Get-Command Test-IsWindowsPlatform -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-IsMacOSPlatform -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-IsLinuxPlatform -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "returns booleans without throwing under StrictMode" {
        { Test-IsWindowsPlatform } | Should -Not -Throw
        { Test-IsMacOSPlatform } | Should -Not -Throw
        { Test-IsLinuxPlatform } | Should -Not -Throw
        (Test-IsWindowsPlatform) | Should -BeOfType [bool]
        (Test-IsMacOSPlatform) | Should -BeOfType [bool]
        (Test-IsLinuxPlatform) | Should -BeOfType [bool]
    }

    It "identifies exactly one of Windows/macOS/Linux as the current platform" {
        $trueCount = @((Test-IsWindowsPlatform), (Test-IsMacOSPlatform), (Test-IsLinuxPlatform) | Where-Object { $_ }).Count
        $trueCount | Should -Be 1
    }

    It "agrees with the running edition's platform on PowerShell 7+ (read via Get-Variable, 5.1-safe)" {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            # Read the automatic variables by name so this test itself never references a
            # 5.1-undefined automatic variable directly.
            $rawWindows = [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
            $rawMac = [bool](Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue)
            $rawLinux = [bool](Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue)
            (Test-IsWindowsPlatform) | Should -Be $rawWindows
            (Test-IsMacOSPlatform) | Should -Be $rawMac
            (Test-IsLinuxPlatform) | Should -Be $rawLinux
        } else {
            # Desktop edition (Windows PowerShell 5.1) only runs on Windows.
            (Test-IsWindowsPlatform) | Should -BeTrue
            (Test-IsMacOSPlatform) | Should -BeFalse
            (Test-IsLinuxPlatform) | Should -BeFalse
        }
    }
}

Describe "Resolve-PowerShellExecutablePath" {
    It "exposes the runtime resolver helper" {
        Get-Command Resolve-PowerShellExecutablePath -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "returns the discovered pwsh path when pwsh is available" {
        $pwshCommand = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
        if ($null -eq $pwshCommand) {
            Set-ItResult -Skipped -Because "pwsh is not available in this environment."
            return
        }

        $resolvedExecutable = Resolve-PowerShellExecutablePath
        $resolvedExecutable | Should -Not -BeNullOrEmpty
        (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) | Should -BeTrue

        $pwshCandidates = @(
            Get-Command -Name 'pwsh' -All -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($null -eq $_) {
                        return
                    }

                    if ($null -ne $_.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$_.Source)) {
                        [string]$_.Source
                        return
                    }

                    if ($null -ne $_.PSObject.Properties['Path'] -and -not [string]::IsNullOrWhiteSpace([string]$_.Path)) {
                        [string]$_.Path
                    }
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $pwshCandidates | Should -Contain $resolvedExecutable
    }

    It "prefers pwsh over powershell.exe on Windows-capable probes" {
        Mock -CommandName Test-IsWindowsPlatform -MockWith { return $true }
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'pwsh' } -MockWith {
            return [pscustomobject]@{ Source = 'C:\Program Files\PowerShell\7\pwsh.exe' }
        }
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'powershell.exe' } -MockWith {
            return [pscustomobject]@{ Source = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
        }
        Mock -CommandName Test-PowerShellExecutableCandidate -ParameterFilter { $ExecutablePath -eq 'C:\Program Files\PowerShell\7\pwsh.exe' } -MockWith {
            return [pscustomobject]@{ Usable = $true; Diagnostic = 'ok' }
        }
        Mock -CommandName Test-PowerShellExecutableCandidate -ParameterFilter { $ExecutablePath -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } -MockWith {
            return [pscustomobject]@{ Usable = $true; Diagnostic = 'ok' }
        }

        $verboseRecords = @(& { Resolve-PowerShellExecutablePath -Verbose } 4>&1 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        $selectedExecutable = Resolve-PowerShellExecutablePath
        $selectedExecutable | Should -BeExactly 'C:\Program Files\PowerShell\7\pwsh.exe'
        (@($verboseRecords | ForEach-Object { $_.Message }) -join [Environment]::NewLine) | Should -Match "selectedExecutable='C:\\Program Files\\PowerShell\\7\\pwsh\.exe'; source='pwsh'"
    }

    It "falls back to powershell.exe on Windows when pwsh is unavailable" {
        Mock -CommandName Test-IsWindowsPlatform -MockWith { return $true }
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'pwsh' } -MockWith { return $null }
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'powershell.exe' } -MockWith {
            return [pscustomobject]@{ Source = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
        }
        Mock -CommandName Test-PowerShellExecutableCandidate -ParameterFilter { $ExecutablePath -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } -MockWith {
            return [pscustomobject]@{ Usable = $true; Diagnostic = 'ok' }
        }

        $resolvedExecutable = Resolve-PowerShellExecutablePath
        $resolvedExecutable | Should -BeExactly 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    It "throws a stable E_* diagnostic when no PowerShell executable is available" {
        Mock -CommandName Test-IsWindowsPlatform -MockWith { return $false }
        Mock -CommandName Test-IsMacOSPlatform -MockWith { return $false }
        Mock -CommandName Test-IsLinuxPlatform -MockWith { return $true }
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'pwsh' } -MockWith { return $null }
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'powershell.exe' } -MockWith { return $null }

        {
            Resolve-PowerShellExecutablePath
        } | Should -Throw -Because 'Resolver must fail with a stable E_* diagnostic when no runtime is available.'

        {
            Resolve-PowerShellExecutablePath
        } | Should -Throw -ExpectedMessage '*E_COMPATIBILITY_POWERSHELL_EXECUTABLE_NOT_FOUND*'
    }
}

Describe "Read-RedirectedProcessText" {
    BeforeEach {
        $script:redirectedTextPath = Join-Path -Path $TestDrive -ChildPath ("redirected-{0}.txt" -f [guid]::NewGuid().ToString("N"))
    }

    It "decodes redirected process text with BOM detection (<Name>)" -ForEach @(
        @{
            Name       = "utf8-no-bom"
            Encoding   = [System.Text.UTF8Encoding]::new($false, $true)
            IncludeBom = $false
        },
        @{
            Name       = "utf8-bom"
            Encoding   = [System.Text.UTF8Encoding]::new($true, $true)
            IncludeBom = $true
        },
        @{
            Name       = "utf16le-bom"
            Encoding   = [System.Text.UnicodeEncoding]::new($false, $true, $true)
            IncludeBom = $true
        },
        @{
            Name       = "utf16be-bom"
            Encoding   = [System.Text.UnicodeEncoding]::new($true, $true, $true)
            IncludeBom = $true
        },
        @{
            Name       = "utf32le-bom"
            Encoding   = [System.Text.UTF32Encoding]::new($false, $true, $true)
            IncludeBom = $true
        },
        @{
            Name       = "utf32be-bom"
            Encoding   = [System.Text.UTF32Encoding]::new($true, $true, $true)
            IncludeBom = $true
        }
    ) {
        param(
            [string]$Name,
            [System.Text.Encoding]$Encoding,
            [bool]$IncludeBom
        )

        $text = "fatal: diagnostics for $Name"
        $preamble = if ($IncludeBom) { $Encoding.GetPreamble() } else { [byte[]]@() }
        [byte[]]$bytes = @($preamble + $Encoding.GetBytes($text))
        [System.IO.File]::WriteAllBytes($script:redirectedTextPath, $bytes)

        Read-RedirectedProcessText -Path $script:redirectedTextPath | Should -Be $text
    }

    It "falls back without throwing for malformed no-BOM bytes" {
        [System.IO.File]::WriteAllBytes($script:redirectedTextPath, [byte[]](0xC3, 0x28))

        { $script:malformedText = Read-RedirectedProcessText -Path $script:redirectedTextPath } | Should -Not -Throw
        [string]$script:malformedText | Should -Not -BeNullOrEmpty
    }

    It "returns empty text for missing redirected files" {
        Read-RedirectedProcessText -Path $script:redirectedTextPath | Should -Be ""
    }
}

Describe "Get-RelativePathCompat" {
    # Expected values use '/' separators; the actual result is normalized to '/' so the
    # contract is asserted identically on Windows ('\') and Unix ('/'). These expectations
    # are hardcoded rather than compared to [System.IO.Path]::GetRelativePath because that
    # native method does not exist on Windows PowerShell 5.1.
    It "computes the relative path for <Case>" -ForEach @(
        @{ Case = "child";            Base = "/a/b";       Target = "/a/b/c";                  Expected = "c" }
        @{ Case = "deep child";       Base = "/home/user"; Target = "/home/user/docs/file.txt"; Expected = "docs/file.txt" }
        @{ Case = "parent";           Base = "/a/b/c";     Target = "/a/b";                    Expected = ".." }
        @{ Case = "grandparent";      Base = "/a/b/c/d";   Target = "/a/b";                    Expected = "../.." }
        @{ Case = "sibling";          Base = "/a/b";       Target = "/a/x/y";                  Expected = "../x/y" }
        @{ Case = "identical";        Base = "/a/b/c";     Target = "/a/b/c";                  Expected = "." }
        @{ Case = "identical w/slash"; Base = "/a/b/c";    Target = "/a/b/c/";                 Expected = "." }
        @{ Case = "spaces";           Base = "/a b/c";     Target = "/a b/c/d e";              Expected = "d e" }
        @{ Case = "from root";        Base = "/";          Target = "/etc/hosts";              Expected = "etc/hosts" }
    ) {
        $actual = (Get-RelativePathCompat -BasePath $Base -TargetPath $Target) -replace '\\', '/'
        $actual | Should -BeExactly $Expected
    }

    It "the .NET Framework fallback computes the same relative path for <Case>" -ForEach @(
        @{ Case = "child";       Base = "/a/b";     Target = "/a/b/c"; Expected = "c" }
        @{ Case = "parent";      Base = "/a/b/c";   Target = "/a/b";   Expected = ".." }
        @{ Case = "grandparent"; Base = "/a/b/c/d"; Target = "/a/b";   Expected = "../.." }
        @{ Case = "sibling";     Base = "/a/b";     Target = "/a/x/y"; Expected = "../x/y" }
        @{ Case = "identical";   Base = "/a/b/c";   Target = "/a/b/c"; Expected = "." }
        @{ Case = "from root";   Base = "/";        Target = "/etc/hosts"; Expected = "etc/hosts" }
    ) {
        $actual = (Get-RelativePathCompat -BasePath $Base -TargetPath $Target -ForceFallback) -replace '\\', '/'
        $actual | Should -BeExactly $Expected
    }

    It "the fallback matches the native method exactly when native is available (differential)" {
        # When the native [System.IO.Path]::GetRelativePath exists (PowerShell 7+/.NET 5+),
        # the -ForceFallback path must produce byte-identical results to it. The native
        # method is invoked via reflection so this comparison itself stays 5.1-safe (a raw
        # [System.IO.Path]::GetRelativePath token would be a 5.1 incompatibility).
        $nativeMethod = [System.IO.Path].GetMethod('GetRelativePath', [type[]]@([string], [string]))
        if ($null -eq $nativeMethod) {
            Set-ItResult -Skipped -Because "native GetRelativePath is unavailable (Windows PowerShell 5.1); the fallback is the only implementation."
            return
        }
        $cases = @(
            @('/a/b', '/a/b/c'), @('/a/b/c', '/a/b'), @('/a/b/c/d', '/a/b'),
            @('/a/b', '/a/x/y'), @('/a/b/c', '/a/b/c'), @('/a/b/c', '/a/b/c/'),
            @('/home/user', '/home/user/docs/file.txt'), @('/a b/c', '/a b/c/d e'),
            @('/', '/etc/hosts'), @('/a', '/a')
        )
        foreach ($case in $cases) {
            $native = $nativeMethod.Invoke($null, @([string]$case[0], [string]$case[1]))
            $fallback = Get-RelativePathCompat -BasePath $case[0] -TargetPath $case[1] -ForceFallback
            $fallback | Should -BeExactly $native -Because "fallback must match native for base='$($case[0])' target='$($case[1])'"
        }
    }
}

Describe "ConvertTo-JsonArrayCompat" {
    It "emits a JSON array for a single object" {
        $json = ConvertTo-JsonArrayCompat -InputObject ([pscustomobject]@{ name = "one" }) -Compress
        $json | Should -BeExactly '[{"name":"one"}]'
    }

    It "emits an empty JSON array for an empty collection" {
        $json = ConvertTo-JsonArrayCompat -InputObject @() -Compress
        $json | Should -BeExactly '[]'
    }

    It "emits a JSON array for multiple objects" {
        $json = ConvertTo-JsonArrayCompat -InputObject @([pscustomobject]@{ n = 1 }, [pscustomobject]@{ n = 2 }) -Compress
        $json | Should -BeExactly '[{"n":1},{"n":2}]'
    }

    It "accepts pipeline input and preserves array shape" {
        $json = @([pscustomobject]@{ n = 1 }) | ConvertTo-JsonArrayCompat -Compress
        $json | Should -BeExactly '[{"n":1}]'
    }

    It "always produces a leading bracket (array shape) regardless of count" {
        foreach ($count in 0, 1, 2, 5) {
            $items = @(1..$count | ForEach-Object { [pscustomobject]@{ i = $_ } })
            $json = ConvertTo-JsonArrayCompat -InputObject $items -Compress
            $json.TrimStart()[0] | Should -BeExactly '['
        }
    }
}

Describe "ConvertFrom-JsonCompat" {
    It "parses an object" {
        $obj = '{"a":1,"b":"two"}' | ConvertFrom-JsonCompat
        $obj.a | Should -Be 1
        $obj.b | Should -Be "two"
    }

    It "preserves top-level array shape with -NoEnumerate" {
        $arr = '[1,2,3]' | ConvertFrom-JsonCompat -NoEnumerate
        $arr.Count | Should -Be 3
    }

    It "preserves a single-element top-level array with -NoEnumerate" {
        $arr = '[42]' | ConvertFrom-JsonCompat -NoEnumerate
        , $arr | Should -BeOfType [System.Array]
        $arr.Count | Should -Be 1
        $arr[0] | Should -Be 42
    }

    It "returns a top-level object as-is with -NoEnumerate" {
        $obj = '{"a":1}' | ConvertFrom-JsonCompat -NoEnumerate
        $obj.a | Should -Be 1
    }

    It "honors -Depth without throwing" {
        { '{"a":{"b":{"c":1}}}' | ConvertFrom-JsonCompat -Depth 5 } | Should -Not -Throw
    }
}

Describe "ConvertTo-ProcessArgumentString" {
    # Expected strings are computed by hand from the .NET Core PasteArguments algorithm so the
    # exact rendered command line is documented and locked. The round-trip test below proves
    # the strings actually parse back to the original argument vector.
    It "renders <Case> exactly" -ForEach @(
        @{ Case = "no arguments";              Arguments = @();                       Expected = "" }
        @{ Case = "single empty argument";     Arguments = @("");                     Expected = '""' }
        @{ Case = "simple token";              Arguments = @("simple");               Expected = "simple" }
        @{ Case = "two tokens";                Arguments = @("a", "b");               Expected = "a b" }
        @{ Case = "embedded space";            Arguments = @("has space");            Expected = '"has space"' }
        @{ Case = "literal backslashes";       Arguments = @("C:\path\file");         Expected = "C:\path\file" }
        @{ Case = "trailing backslash, no ws"; Arguments = @("trailing\");            Expected = "trailing\" }
        @{ Case = "trailing backslash, ws";    Arguments = @("with space\");          Expected = '"with space\\"' }
        @{ Case = "embedded quote";            Arguments = @('quote"inside');         Expected = '"quote\"inside"' }
        @{ Case = "empty then value";          Arguments = @("", "value");            Expected = '"" value' }
    ) {
        param($Arguments, $Expected)
        (ConvertTo-ProcessArgumentString -ArgumentList $Arguments) | Should -BeExactly $Expected
    }

    It "treats a null argument list as empty" {
        (ConvertTo-ProcessArgumentString -ArgumentList $null) | Should -BeExactly ""
    }
}

Describe "Set-PortableProcessArguments" {
    BeforeAll {
        $script:hostPwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        # A tiny echo script: emit each received argument on its own line behind a marker so
        # empty arguments and surrounding whitespace survive the round-trip unambiguously.
        $script:echoScript = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("compat-echo-{0}.ps1" -f ([System.Guid]::NewGuid().ToString("N")))
        Set-Content -LiteralPath $script:echoScript -Value '$args | ForEach-Object { [Console]::Out.WriteLine("ARG:" + $_) }' -Encoding utf8

        function Invoke-ArgumentRoundTrip {
            param(
                [string[]]$Arguments,
                [switch]$ForceFallback
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:hostPwsh
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $launchArguments = @("-NoLogo", "-NoProfile", "-File", $script:echoScript) + $Arguments
            Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList $launchArguments -ForceFallback:$ForceFallback

            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            try {
                [void]$process.Start()
                $stdout = $process.StandardOutput.ReadToEnd()
                [void]$process.WaitForExit(30000)
            }
            finally {
                $process.Dispose()
            }

            $observed = @(($stdout -split "`r?`n") |
                    Where-Object { $_.StartsWith("ARG:") } |
                    ForEach-Object { $_.Substring(4) })
            return , $observed
        }
    }

    AfterAll {
        if ($script:echoScript -and (Test-Path -LiteralPath $script:echoScript)) {
            Remove-Item -LiteralPath $script:echoScript -Force -ErrorAction SilentlyContinue
        }
    }

    It "round-trips <Case> via the native ArgumentList path" -ForEach @(
        @{ Case = "plain";            Arguments = @("plain") }
        @{ Case = "embedded space";   Arguments = @("with space") }
        @{ Case = "two tokens";       Arguments = @("two", "args") }
        @{ Case = "embedded quote";   Arguments = @('embedded"quote') }
        @{ Case = "trailing slash";   Arguments = @("trailing\") }
        @{ Case = "backslash run";    Arguments = @("back\\slash\\\\path") }
        @{ Case = "quote and space";  Arguments = @('quote" and space') }
        @{ Case = "empty argument";   Arguments = @("alpha", "", "omega") }
    ) {
        param($Arguments)
        (Invoke-ArgumentRoundTrip -Arguments $Arguments) | Should -Be $Arguments
    }

    It "round-trips <Case> via the Windows PowerShell 5.1 (.Arguments string) fallback" -ForEach @(
        @{ Case = "plain";            Arguments = @("plain") }
        @{ Case = "embedded space";   Arguments = @("with space") }
        @{ Case = "two tokens";       Arguments = @("two", "args") }
        @{ Case = "embedded quote";   Arguments = @('embedded"quote') }
        @{ Case = "trailing slash";   Arguments = @("trailing\") }
        @{ Case = "backslash run";    Arguments = @("back\\slash\\\\path") }
        @{ Case = "quote and space";  Arguments = @('quote" and space') }
        @{ Case = "empty argument";   Arguments = @("alpha", "", "omega") }
    ) {
        param($Arguments)
        # The forced fallback proves ConvertTo-ProcessArgumentString escapes exactly as the
        # native ArgumentList does: both paths must yield identical child argv.
        (Invoke-ArgumentRoundTrip -Arguments $Arguments -ForceFallback) | Should -Be $Arguments
    }

    It "selects the native ArgumentList collection on PowerShell 7+" {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            Set-ItResult -Skipped -Because "ArgumentList is only present on PowerShell 7+ / .NET Core."
            return
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("alpha", "beta")
        $startInfo.ArgumentList.Count | Should -Be 2
        $startInfo.Arguments | Should -BeNullOrEmpty
    }

    It "writes the escaped string to .Arguments under the forced fallback" {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("a", "b c") -ForceFallback
        $startInfo.Arguments | Should -BeExactly 'a "b c"'
    }
}

Describe "Set-PortableProcessEnvironmentVariable" {
    It "replaces existing case variants when case-insensitive environment matching is active" {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.Environment["Path"] = "real-tools"
        $startInfo.Environment["OTHER"] = "keep"

        Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "PATH" -Value "fake-tools" -CaseInsensitive

        $pathKeys = @($startInfo.Environment.Keys | Where-Object { [string]::Equals([string]$_, "PATH", [System.StringComparison]::OrdinalIgnoreCase) })
        $pathKeys.Count | Should -Be 1
        $pathKeys[0] | Should -BeExactly "PATH"
        $startInfo.Environment["PATH"] | Should -BeExactly "fake-tools"
        $startInfo.Environment["OTHER"] | Should -BeExactly "keep"
    }

    It "removes existing case variants when a null value is supplied" {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.Environment["Path"] = "real-tools"

        Set-PortableProcessEnvironmentVariable -StartInfo $startInfo -Name "PATH" -Value $null -CaseInsensitive

        @($startInfo.Environment.Keys | Where-Object { [string]::Equals([string]$_, "PATH", [System.StringComparison]::OrdinalIgnoreCase) }).Count |
            Should -Be 0
    }
}

Describe "Get-PortableLinkTarget" {
    BeforeAll {
        $script:linkRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("compat-link-{0}" -f ([System.Guid]::NewGuid().ToString("N")))
        New-Item -ItemType Directory -Path $script:linkRoot -Force | Out-Null
        # Canonicalize so GetFullPath comparisons below are stable under macOS /var aliasing.
        $script:linkRoot = Resolve-CanonicalTempRoot -Path $script:linkRoot

        $script:realTarget = Join-Path -Path $script:linkRoot -ChildPath "real"
        New-Item -ItemType Directory -Path $script:realTarget -Force | Out-Null

        # Symbolic-link creation can require privilege (notably on Windows without Developer
        # Mode). Probe once and skip the link scenarios cleanly when it is unavailable.
        $script:directLink = Join-Path -Path $script:linkRoot -ChildPath "direct"
        $script:chainLink = Join-Path -Path $script:linkRoot -ChildPath "chain"
        $script:symlinksAvailable = $false
        try {
            New-Item -ItemType SymbolicLink -Path $script:directLink -Target $script:realTarget -ErrorAction Stop | Out-Null
            New-Item -ItemType SymbolicLink -Path $script:chainLink -Target $script:directLink -ErrorAction Stop | Out-Null
            $script:symlinksAvailable = $true
        }
        catch {
            $script:symlinksAvailable = $false
        }
    }

    AfterAll {
        if ($script:linkRoot -and (Test-Path -LiteralPath $script:linkRoot)) {
            Remove-Item -LiteralPath $script:linkRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "returns `$null for a non-link directory" {
        $item = Get-Item -LiteralPath $script:realTarget -Force
        Get-PortableLinkTarget -Item $item | Should -BeNullOrEmpty
    }

    It "resolves a direct symbolic link to its final target" {
        if (-not $script:symlinksAvailable) { Set-ItResult -Skipped -Because "symbolic links are unavailable on this runner"; return }
        $item = Get-Item -LiteralPath $script:directLink -Force
        $resolved = Get-PortableLinkTarget -Item $item
        [System.IO.Path]::GetFullPath($resolved) | Should -Be ([System.IO.Path]::GetFullPath($script:realTarget))
    }

    It "follows a symbolic-link chain to its final target" {
        if (-not $script:symlinksAvailable) { Set-ItResult -Skipped -Because "symbolic links are unavailable on this runner"; return }
        $item = Get-Item -LiteralPath $script:chainLink -Force
        $resolved = Get-PortableLinkTarget -Item $item
        [System.IO.Path]::GetFullPath($resolved) | Should -Be ([System.IO.Path]::GetFullPath($script:realTarget))
    }

    It "matches the native method under the forced 5.1 (ETS) fallback for <Case>" -ForEach @(
        @{ Case = "direct link" }
        @{ Case = "chain link" }
    ) {
        param($Case)
        if (-not $script:symlinksAvailable) { Set-ItResult -Skipped -Because "symbolic links are unavailable on this runner"; return }

        $linkPath = if ($Case -eq "direct link") { $script:directLink } else { $script:chainLink }
        $item = Get-Item -LiteralPath $linkPath -Force
        $native = Get-PortableLinkTarget -Item $item
        $fallback = Get-PortableLinkTarget -Item $item -ForceFallback
        [System.IO.Path]::GetFullPath($fallback) | Should -Be ([System.IO.Path]::GetFullPath($native)) -Because "the 5.1 ETS fallback must resolve to the same final target as the native ResolveLinkTarget."
    }

    It "terminates (does not loop) on a symbolic-link cycle under the 5.1 fallback" {
        $cycleA = Join-Path -Path $script:linkRoot -ChildPath "cycle-a"
        $cycleB = Join-Path -Path $script:linkRoot -ChildPath "cycle-b"
        $cycleCreated = $false
        try {
            # Dangling targets are permitted at creation time on POSIX, forming a 2-node cycle.
            New-Item -ItemType SymbolicLink -Path $cycleA -Target $cycleB -ErrorAction Stop | Out-Null
            New-Item -ItemType SymbolicLink -Path $cycleB -Target $cycleA -ErrorAction Stop | Out-Null
            $cycleCreated = $true
        }
        catch {
            $cycleCreated = $false
        }
        if (-not $cycleCreated) { Set-ItResult -Skipped -Because "symbolic-link cycles cannot be created on this runner"; return }

        $item = Get-Item -LiteralPath $cycleA -Force
        # The visited-target set (plus the MaxDepth bound) must break the cycle rather than hang,
        # and return $null to match the native ResolveLinkTarget($true) "unresolved" outcome.
        $cycleResult = $null
        { $cycleResult = Get-PortableLinkTarget -Item $item -ForceFallback } | Should -Not -Throw
        $cycleResult | Should -BeNullOrEmpty -Because "a symbolic-link cycle is unresolvable, mirroring native ResolveLinkTarget."
    }
}

Describe "Stop-ProcessTreePortably" {
    BeforeAll {
        $script:killHostPwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

        function Start-LongRunningProcess {
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:killHostPwsh
            $startInfo.UseShellExecute = $false
            Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("-NoLogo", "-NoProfile", "-Command", "Start-Sleep -Seconds 120")
            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            return $process
        }

        function Test-ProcessIdAlive {
            param(
                [Parameter(Mandatory = $true)]
                [int]$ProcessId
            )

            try {
                $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
                try {
                    return (-not $process.HasExited)
                }
                finally {
                    $process.Dispose()
                }
            }
            catch {
                return $false
            }
        }

        function Wait-ProcessIdExit {
            param(
                [Parameter(Mandatory = $true)]
                [int]$ProcessId,

                [Parameter(Mandatory = $false)]
                [int]$TimeoutMilliseconds = 20000
            )

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
                if (-not (Test-ProcessIdAlive -ProcessId $ProcessId)) {
                    return $true
                }

                Start-Sleep -Milliseconds 100
            }

            return $false
        }

        function Wait-FileText {
            param(
                [Parameter(Mandatory = $true)]
                [string]$Path,

                [Parameter(Mandatory = $false)]
                [int]$TimeoutMilliseconds = 10000
            )

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
                if (Test-Path -LiteralPath $Path -PathType Leaf) {
                    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($content)) {
                        return $content
                    }
                }

                Start-Sleep -Milliseconds 100
            }

            throw "Timed out waiting for file text at '$Path'."
        }

        function Start-LongRunningProcessWithChild {
            param(
                [Parameter(Mandatory = $true)]
                [string]$ChildPidPath
            )

            $escapedPowerShellPath = ([string]$script:killHostPwsh).Replace("'", "''")
            $escapedChildPidPath = ([string]$ChildPidPath).Replace("'", "''")
            $commandText = @"
`$childStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
`$childStartInfo.FileName = '$escapedPowerShellPath'
`$childStartInfo.UseShellExecute = `$false
`$childStartInfo.CreateNoWindow = `$true
`$childStartInfo.Arguments = '-NoLogo -NoProfile -Command "Start-Sleep -Seconds 120"'
`$child = [System.Diagnostics.Process]::Start(`$childStartInfo)
[System.IO.File]::WriteAllText('$escapedChildPidPath', [string]`$child.Id, [System.Text.Encoding]::UTF8)
Start-Sleep -Seconds 120
"@

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:killHostPwsh
            $startInfo.UseShellExecute = $false
            Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList @("-NoLogo", "-NoProfile", "-Command", $commandText)
            $process = [System.Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            return $process
        }
    }

    It "terminates a running process via <Case>" -ForEach @(
        @{ Case = "the native tree-kill path"; ForceFallback = $false }
        @{ Case = "the Windows PowerShell 5.1 parameterless-Kill fallback"; ForceFallback = $true }
    ) {
        param($ForceFallback)

        $process = Start-LongRunningProcess
        try {
            $process.HasExited | Should -BeFalse -Because "the sleep process should still be running before we kill it."
            Stop-ProcessTreePortably -Process $process -ForceFallback:$ForceFallback
            $process.WaitForExit(20000) | Should -BeTrue -Because "the process must be terminated by Stop-ProcessTreePortably."
            $process.HasExited | Should -BeTrue
        }
        finally {
            if (-not $process.HasExited) {
                $process.Kill()
            }
            $process.Dispose()
        }
    }

    It "terminates descendants when using the explicit fallback path" {
        $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wallstop-process-tree-test-{0}" -f [guid]::NewGuid().ToString("N"))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $childPidPath = Join-Path -Path $tempRoot -ChildPath "child.pid"

        $parentProcess = Start-LongRunningProcessWithChild -ChildPidPath $childPidPath
        $childProcessId = -1
        try {
            $childPidText = Wait-FileText -Path $childPidPath
            $childProcessId = [int]$childPidText
            Test-ProcessIdAlive -ProcessId $childProcessId | Should -BeTrue -Because "the child process should still be running before fallback cleanup."

            Stop-ProcessTreePortably -Process $parentProcess -ForceFallback
            $parentProcess.WaitForExit(20000) | Should -BeTrue -Because "the parent process must be terminated by fallback cleanup."
            Wait-ProcessIdExit -ProcessId $childProcessId | Should -BeTrue -Because "the fallback cleanup must also terminate descendants."
        }
        finally {
            if ($childProcessId -gt 0 -and (Test-ProcessIdAlive -ProcessId $childProcessId)) {
                Stop-ProcessByIdPortably -ProcessId $childProcessId
            }

            if (-not $parentProcess.HasExited) {
                $parentProcess.Kill()
            }

            $parentProcess.Dispose()
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
