Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    # Dot-source the backup script. The run guard ($MyInvocation.InvocationName -eq ".") prevents the
    # backup (which requires the Windows-only `scoop` CLI) from executing on dot-source, exposing only
    # the pure functions for testing.
    . "$PSScriptRoot/../../Scripts/Scoop/ScoopBackup.ps1"

    # A representative `scoop export` payload in scoop's native 4-space indentation. Object member order
    # is deliberately NOT alphabetical (scoop builds app objects from hashtables, so real exports arrive
    # in varying orders), including the ISO-8601 `Updated` timestamps (with timezone offset and sub-second
    # precision) that must survive canonicalization verbatim.
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

    # The same data with every object's members emitted in a different order: scoop export produces this
    # kind of permutation on another day/run, and the canonical output must be byte-identical for both.
    $script:rawFourSpacePermuted = @"
{
    "apps": [
        {
            "Info": "",
            "Updated": "2026-04-27T23:30:18.9329513-07:00",
            "Version": "24.09",
            "Name": "7zip",
            "Source": "main"
        }
    ],
    "buckets": [
        {
            "Manifests": 1579,
            "Updated": "2026-06-19T22:48:12-07:00",
            "Source": "https://github.com/ScoopInstaller/Main",
            "Name": "main"
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
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "byte-exact canonical form requires System.Text.Json"
            return
        }

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
        # Member names sort Ordinally, so "apps" precedes "buckets" at the top level.
        ($lines[1]) | Should -Be '  "apps": [' -Because "top-level members must use 2-space indentation and sorted key order"
        # The deepest nested members sit at 6 spaces (member -> array -> object) under 2-space indent.
        @($lines | Where-Object { $_ -match '^      "Name": "main"' }).Count | Should -BeGreaterThan 0
        # No residual 4-space (scoop) indentation for a top-level key.
        $canonical | Should -Not -Match '(?m)^    "buckets":'
    }

    It "emits object members in Ordinal-sorted order regardless of scoop's per-run ordering" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "member sorting requires System.Text.Json (Windows PowerShell 5.1 fallback cannot rewrite JSON)"
            return
        }

        $canonical = ConvertTo-CanonicalScoopExportJson -RawJson $script:rawFourSpace
        $canonicalFromPermutation = ConvertTo-CanonicalScoopExportJson -RawJson $script:rawFourSpacePermuted
        $canonicalFromPermutation | Should -BeExactly $canonical -Because "identical data must produce identical bytes no matter what member order scoop emitted"

        # Pin the deterministic shape: nested members appear Ordinally sorted inside BOTH arrays
        # (app: Info, Name, Source, Updated, Version; bucket: Manifests, Name, Source, Updated) and the
        # ISO timestamps survive verbatim inside the sorted form.
        $memberLines = @($canonical -split "`n" | Where-Object { $_ -match '^      "' })
        $memberLines | Should -BeExactly @(
            '      "Info": "",'
            '      "Name": "7zip",'
            '      "Source": "main",'
            '      "Updated": "2026-04-27T23:30:18.9329513-07:00",'
            '      "Version": "24.09"'
            '      "Manifests": 1579,'
            '      "Name": "main",'
            '      "Source": "https://github.com/ScoopInstaller/Main",'
            '      "Updated": "2026-06-19T22:48:12-07:00"'
        )
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
