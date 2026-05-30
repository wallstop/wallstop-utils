Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
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
