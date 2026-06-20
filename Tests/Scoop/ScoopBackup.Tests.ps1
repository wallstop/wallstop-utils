Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    # Dot-source the backup script. The run guard ($MyInvocation.InvocationName -eq ".") prevents the
    # backup (which requires the Windows-only `scoop` CLI) from executing on dot-source, exposing only
    # the pure functions for testing.
    . "$PSScriptRoot/../../Scripts/Scoop/ScoopBackup.ps1"

    # A representative `scoop export` payload in scoop's native 4-space indentation, including the
    # ISO-8601 `Updated` timestamps (with timezone offset and sub-second precision) that must survive
    # canonicalization verbatim.
    $script:rawFourSpace = @"
{
    "buckets": [
        {
            "Name": "main",
            "Source": "https://github.com/ScoopInstaller/Main",
            "Updated": "2026-06-19T22:48:12-07:00",
            "Manifests": 1579
        }
    ],
    "apps": [
        {
            "Source": "main",
            "Name": "7zip",
            "Version": "24.09",
            "Updated": "2026-04-27T23:30:18.9329513-07:00",
            "Info": ""
        }
    ]
}
"@ -replace "`r`n", "`n"

    $script:hasSystemTextJson = $null -ne ("System.Text.Json.JsonDocument" -as [type])
}

Describe "ConvertTo-CanonicalScoopExportJson" {
    It "preserves ISO-8601 timestamps verbatim (never reparses them into a shifted timezone)" {
        # This is the load-bearing anti-corruption guard. ConvertFrom-Json | ConvertTo-Json would parse
        # these strings into [datetime] and re-emit them as UTC (for example -07:00 -> +00:00), silently
        # changing the data. The canonicalizer must keep the original strings byte-for-byte.
        $canonical = ConvertTo-CanonicalScoopExportJson -RawJson $script:rawFourSpace
        $canonical | Should -Match ([regex]::Escape('"Updated": "2026-06-19T22:48:12-07:00"'))
        $canonical | Should -Match ([regex]::Escape('"Updated": "2026-04-27T23:30:18.9329513-07:00"'))
        $canonical | Should -Not -Match '\+00:00' -Because "timestamps must not be normalized to UTC"
    }

    It "emits LF line endings with exactly one trailing newline and no carriage returns" {
        $canonical = ConvertTo-CanonicalScoopExportJson -RawJson $script:rawFourSpace
        $canonical.Contains([char]13) | Should -BeFalse -Because "output must be LF-only"
        $canonical.EndsWith([char]10) | Should -BeTrue
        $canonical.EndsWith([string][char]10 + [string][char]10) | Should -BeFalse -Because "exactly one trailing newline"
    }

    It "normalizes CRLF input to LF" {
        $crlfInput = $script:rawFourSpace -replace "`n", "`r`n"
        $canonical = ConvertTo-CanonicalScoopExportJson -RawJson $crlfInput
        $canonical.Contains([char]13) | Should -BeFalse
    }

    It "preserves the data (valid JSON with the same buckets and apps)" {
        $canonical = ConvertTo-CanonicalScoopExportJson -RawJson $script:rawFourSpace
        $parsed = $canonical | ConvertFrom-Json
        @($parsed.buckets).Count | Should -Be 1
        @($parsed.apps).Count | Should -Be 1
        $parsed.apps[0].Name | Should -Be "7zip"
        $parsed.apps[0].Version | Should -Be "24.09"
        $parsed.buckets[0].Manifests | Should -Be 1579
    }

    It "produces a stable fixed point (canonicalizing the output again yields identical bytes)" {
        # The committed file must be a fixed point of the formatter so attended (hook) and unattended
        # (--no-verify) backup commits land identical bytes, which is what prevents the merge conflicts.
        $once = ConvertTo-CanonicalScoopExportJson -RawJson $script:rawFourSpace
        $twice = ConvertTo-CanonicalScoopExportJson -RawJson $once
        $twice | Should -BeExactly $once
    }

    It "canonicalizes scoop's 4-space indentation to 2-space (PowerShell 7+ / System.Text.Json)" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "System.Text.Json is unavailable (Windows PowerShell 5.1 fallback only normalizes line endings)"
            return
        }

        $canonical = ConvertTo-CanonicalScoopExportJson -RawJson $script:rawFourSpace
        $lines = $canonical -split "`n"
        ($lines[1]) | Should -Be '  "buckets": [' -Because "top-level members must use 2-space indentation"
        # The deepest nested members sit at 6 spaces (member -> array -> object) under 2-space indent.
        @($lines | Where-Object { $_ -match '^      "Name": "main"' }).Count | Should -BeGreaterThan 0
        # No residual 4-space (scoop) indentation for a top-level key.
        $canonical | Should -Not -Match '(?m)^    "buckets":'
    }

    It "accepts an already-canonical payload unchanged (idempotent on canonical input)" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "2-space canonical form requires System.Text.Json"
            return
        }

        $canonical = ConvertTo-CanonicalScoopExportJson -RawJson $script:rawFourSpace
        (ConvertTo-CanonicalScoopExportJson -RawJson $canonical) | Should -BeExactly $canonical
    }
}
