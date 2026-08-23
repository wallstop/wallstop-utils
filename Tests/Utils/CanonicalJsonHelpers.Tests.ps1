Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
    . (Join-Path -Path $script:repoRoot -ChildPath "Scripts/Utils/Common/CanonicalJsonHelpers.ps1")
    $script:hasSystemTextJson = $null -ne ("System.Text.Json.JsonDocument" -as [type])

    $script:lf = [string][char]10
}

Describe "ConvertTo-LfTextWithSingleTrailingNewline" {
    It "normalizes <name> to LF with exactly one trailing newline" -ForEach @(
        @{ name = "CRLF newlines"; source = "a`r`nb`r`n"; expected = "a`nb`n" }
        @{ name = "bare CR newlines"; source = "a`rb`r"; expected = "a`nb`n" }
        @{ name = "no trailing newline"; source = "a`nb"; expected = "a`nb`n" }
        @{ name = "multiple trailing newlines"; source = "a`nb`n`n`n"; expected = "a`nb`n" }
        @{ name = "already canonical"; source = "a`nb`n"; expected = "a`nb`n" }
        @{ name = "mixed CRLF and trailing blanks"; source = "a`r`n`r`n`r`n"; expected = "a`n" }
    ) {
        (ConvertTo-LfTextWithSingleTrailingNewline -Text $source) | Should -BeExactly $expected
    }

    It "never leaves a carriage return in the output" {
        $result = ConvertTo-LfTextWithSingleTrailingNewline -Text "x`r`ny`r`nz`r`n"
        $result.Contains([char]13) | Should -BeFalse
    }
}

Describe "ConvertTo-AsciiEscapedJsonText" {
    It "escapes <name> to lowercase \uXXXX" -ForEach @(
        @{ name = "a CJK BMP character (U+56FE)"; codePoint = 0x56FE; expected = '\u56fe' }
        @{ name = "the U+2028 line separator"; codePoint = 0x2028; expected = '\u2028' }
        @{ name = "the U+2029 paragraph separator"; codePoint = 0x2029; expected = '\u2029' }
    ) {
        $text = [System.Char]::ConvertFromUtf32($codePoint)
        (ConvertTo-AsciiEscapedJsonText -Text $text) | Should -BeExactly $expected
    }

    It "leaves printable ASCII (including the characters Python leaves raw) untouched" {
        (ConvertTo-AsciiEscapedJsonText -Text 'abc <>&''+ 123') | Should -BeExactly 'abc <>&''+ 123'
    }

    It "emits an astral character as its surrogate pair (matching Python ensure_ascii)" {
        # U+1F600 GRINNING FACE -> UTF-16 surrogate pair D83D DE00.
        $grinning = [System.Char]::ConvertFromUtf32(0x1F600)
        (ConvertTo-AsciiEscapedJsonText -Text $grinning) | Should -BeExactly '\ud83d\ude00'
    }

    It "lowercases an upstream uppercase \uXXXX escape (System.Text.Json emits uppercase; Python lowercase)" {
        # A single-backslash \uXXXX escape (as System.Text.Json emits for astral/control chars)
        # must be lowercased to match Python's ensure_ascii output.
        (ConvertTo-AsciiEscapedJsonText -Text '\uD83D\uDE00') | Should -BeExactly '\ud83d\ude00'
    }

    It "preserves a literal escaped-backslash sequence verbatim (does not treat \\uABCD as an escape)" {
        # In JSON data a backslash is itself escaped as \\, so \"\\uABCD\" is the characters
        # u,A,B,C,D and must be copied verbatim -- only a genuine single-backslash \uXXXX may lowercase.
        (ConvertTo-AsciiEscapedJsonText -Text 'C:\\uABCD') | Should -BeExactly 'C:\\uABCD'
    }
}

Describe "ConvertTo-CanonicalJsonText" {
    It "preserves ISO-8601 timestamps verbatim (never reparses them into a shifted timezone)" {
        # The load-bearing anti-corruption guard: ConvertFrom-Json | ConvertTo-Json would parse these
        # strings into [datetime] and re-emit them as UTC, silently changing the data.
        $raw = '{ "Updated": "2026-04-27T23:30:18.9329513-07:00" }'
        $canonical = ConvertTo-CanonicalJsonText -RawJson $raw
        $canonical | Should -Match ([regex]::Escape('"Updated": "2026-04-27T23:30:18.9329513-07:00"'))
        $canonical | Should -Not -Match '\+00:00'
    }

    It "emits LF line endings with exactly one trailing newline and no carriage returns" {
        # Cross-platform regression guard for the Windows-only System.Text.Json CRLF defect: WriteIndented
        # emits CRLF on .NET under Windows, so the canonicalizer must normalize regardless of platform.
        $canonical = ConvertTo-CanonicalJsonText -RawJson "{`r`n  `"a`": 1`r`n}"
        $canonical.Contains([char]13) | Should -BeFalse -Because "output must be LF-only on every platform"
        $canonical.EndsWith([char]10) | Should -BeTrue
        $canonical.EndsWith($script:lf + $script:lf) | Should -BeFalse -Because "exactly one trailing newline"
    }

    It "produces a stable fixed point (canonicalizing the output again yields identical bytes)" {
        $once = ConvertTo-CanonicalJsonText -RawJson '{ "b": [1, 2], "a": "x" }'
        $twice = ConvertTo-CanonicalJsonText -RawJson $once
        $twice | Should -BeExactly $once
    }

    It "canonicalizes to 2-space indentation (PowerShell 7+ / System.Text.Json)" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "2-space reindent requires System.Text.Json"
            return
        }

        $canonical = ConvertTo-CanonicalJsonText -RawJson "{`n    `"buckets`": []`n}"
        ($canonical -split "`n")[1] | Should -Be '  "buckets": []'
    }

    It "escapes non-ASCII string values to match pretty-format-json (ensure_ascii=True)" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "string-value escaping requires System.Text.Json"
            return
        }

        $cjk = [System.Char]::ConvertFromUtf32(0x56FE)
        $canonical = ConvertTo-CanonicalJsonText -RawJson ('{ "id": "' + $cjk + '" }')
        $canonical | Should -Match ([regex]::Escape('"id": "\u56fe"'))
        $canonical.Contains([char]0x56FE) | Should -BeFalse -Because "raw non-ASCII must be escaped"
    }

    It "tolerates and drops JSONC comments and trailing commas (committed form is strict JSON)" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "comment/trailing-comma tolerance requires System.Text.Json"
            return
        }

        $canonical = ConvertTo-CanonicalJsonText -RawJson "{`n  // a comment`n  `"a`": 1,`n}"
        $canonical | Should -Not -Match '//'
        ($canonical | ConvertFrom-Json).a | Should -Be 1
    }
}

Describe "ConvertTo-CanonicalJsonText -SortObjectKeys" {
    # Regression guard for the daily whole-file scoopfile.json churn (2026-08-12..2026-08-22): scoop
    # export rebuilds app objects from hashtables whose iteration order differs per invocation, so the
    # canonicalizer must be able to make the bytes data-determined by sorting member names Ordinally.

    It "preserves source member order by default (no switch)" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "member-order preservation requires System.Text.Json"
            return
        }

        # Other canonicalizer consumers rely on order preservation; sorting must be strictly opt-in.
        $canonical = ConvertTo-CanonicalJsonText -RawJson '{ "b": 1, "a": 2 }'
        $canonical | Should -BeExactly "{`n  `"b`": 1,`n  `"a`": 2`n}`n"
    }

    It "sorts <description> with -SortObjectKeys" -ForEach @(
        @{
            description = "top-level members alphabetically"
            source      = '{ "buckets": {}, "apps": {} }'
            expected    = "{`n  `"apps`": {},`n  `"buckets`": {}`n}`n"
        }
        @{
            description = "members Ordinally (uppercase before lowercase, culture-independent)"
            source      = '{ "a": 1, "B": 2 }'
            expected    = "{`n  `"B`": 2,`n  `"a`": 1`n}`n"
        }
        @{
            description = "an empty-string member name first"
            source      = '{ "b": 2, "": 1 }'
            expected    = "{`n  `"`": 1,`n  `"b`": 2`n}`n"
        }
        @{
            description = "nested objects recursively"
            source      = '{ "outer": { "z": 1, "a": { "y": 2, "b": 3 } } }'
            expected    = "{`n  `"outer`": {`n    `"a`": {`n      `"b`": 3,`n      `"y`": 2`n    },`n    `"z`": 1`n  }`n}`n"
        }
    ) {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "member sorting requires System.Text.Json"
            return
        }

        (ConvertTo-CanonicalJsonText -RawJson $source -SortObjectKeys) | Should -BeExactly $expected
    }

    It "fails closed with a stable diagnostic on duplicate member names instead of dropping data" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "duplicate-member rejection requires System.Text.Json"
            return
        }

        # The unsorted path preserves duplicate members; a sorted rebuild cannot represent them, so it
        # must surface E_CANONICAL_JSON_SORT_FAILED rather than silently returning unsorted output.
        { ConvertTo-CanonicalJsonText -RawJson '{ "a": 1, "a": 2 }' -SortObjectKeys } |
            Should -Throw 'E_CANONICAL_JSON_SORT_FAILED*'
    }

    It "produces byte-identical output for differently ordered inputs (permutation invariance)" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "permutation invariance requires System.Text.Json"
            return
        }

        $first = ConvertTo-CanonicalJsonText -RawJson '{ "Name": "main", "Manifests": 5, "Source": "x" }' -SortObjectKeys
        $second = ConvertTo-CanonicalJsonText -RawJson '{ "Source": "x", "Name": "main", "Manifests": 5 }' -SortObjectKeys
        $second | Should -BeExactly $first
        $first | Should -BeExactly "{`n  `"Manifests`": 5,`n  `"Name`": `"main`",`n  `"Source`": `"x`"`n}`n"
    }

    It "preserves array element order while sorting members of objects inside arrays" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "array-aware sorting requires System.Text.Json"
            return
        }

        # Array ITEMS must never be reordered -- only object members within them.
        $canonical = ConvertTo-CanonicalJsonText -RawJson '{ "apps": [ { "Version": "1", "Name": "zeta" }, { "Version": "2", "Name": "alpha" } ] }' -SortObjectKeys
        $parsed = $canonical | ConvertFrom-Json
        @($parsed.apps).Count | Should -Be 2
        $parsed.apps[0].Name | Should -Be "zeta"
        $parsed.apps[1].Name | Should -Be "alpha"

        ($canonical -split "`n") | Where-Object { $_ -match '"Name"' } | Should -BeExactly @(
            '      "Name": "zeta",'
            '      "Name": "alpha",'
        ) -Because "members inside each array element must appear sorted (Name before Version)"
    }

    It "keeps leaf payloads verbatim under sorting (timestamps, number tokens, literals)" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "leaf fidelity checks require System.Text.Json"
            return
        }

        $raw = '{ "Updated": "2026-04-27T23:30:18.9329513-07:00", "Ratio": 1.50, "On": true, "Nothing": null }'
        $canonical = ConvertTo-CanonicalJsonText -RawJson $raw -SortObjectKeys
        $canonical | Should -Match ([regex]::Escape('"Updated": "2026-04-27T23:30:18.9329513-07:00"'))
        $canonical | Should -Not -Match '\+00:00' -Because "timestamps must not be normalized to UTC"
        $canonical | Should -Match ([regex]::Escape('"Ratio": 1.50')) -Because "number tokens must not be re-formatted"
        $canonical | Should -Match ([regex]::Escape('"Nothing": null'))
        ($canonical | ConvertFrom-Json).On | Should -BeTrue
    }

    It "is idempotent under -SortObjectKeys (sorted output re-canonicalizes to identical bytes)" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "idempotence requires System.Text.Json"
            return
        }

        $once = ConvertTo-CanonicalJsonText -RawJson '{ "b": [ { "y": 1, "a": 2 } ], "a": "x" }' -SortObjectKeys
        $twice = ConvertTo-CanonicalJsonText -RawJson $once -SortObjectKeys
        $twice | Should -BeExactly $once
    }

    It "tolerates JSONC comments and trailing commas on the sorted path" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "JSONC tolerance on the sorted path requires System.Text.Json"
            return
        }

        $canonical = ConvertTo-CanonicalJsonText -RawJson "{ // comment`n  `"b`": 1,`n  `"a`": 2,`n}" -SortObjectKeys
        $canonical | Should -BeExactly "{`n  `"a`": 2,`n  `"b`": 1`n}`n"
    }

    It "leaves a scalar-null document unchanged on the sorted path" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "scalar handling requires System.Text.Json"
            return
        }

        (ConvertTo-CanonicalJsonText -RawJson 'null' -SortObjectKeys) | Should -BeExactly "null`n"
    }
}

Describe "Committed JSON artifacts are byte-identical to the canonicalizer" {
    # The strongest guard: every committed artifact under pretty-format-json scope must already be a fixed
    # point of the shared canonicalizer, proving the canonicalizer reproduces the hook output byte-for-byte.
    # If a writer or this helper ever drifts from the hook, this fails deterministically on every platform.
    It "reproduces <path> exactly" -ForEach @(
        @{ path = "Config/scoopfile.json" }
        @{ path = "Config/WindowsTerminal/settings.json" }
        @{ path = "Config/Komorebi/profiles/default/komorebi.json" }
        @{ path = "Config/Komorebi/profiles/default/komorebi.bar.json" }
        @{ path = "Config/Komorebi/profiles/default/applications.json" }
    ) {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "byte-exact canonical form requires System.Text.Json"
            return
        }

        $fullPath = Join-Path -Path $script:repoRoot -ChildPath $path
        $raw = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
        (ConvertTo-CanonicalJsonText -RawJson $raw) | Should -BeExactly $raw -Because "$path must be a fixed point of the pretty-format-json hook"
    }

    It "reproduces Config/scoopfile.json exactly under -SortObjectKeys (data-determined member order)" {
        # scoopfile.json is written by ScoopBackup through -SortObjectKeys because `scoop export` emits
        # app members in varying order per invocation. The committed form must therefore also be a fixed
        # point of the SORTED canonicalizer, proving the daily backup cannot churn whole-file diffs again.
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "byte-exact canonical form requires System.Text.Json"
            return
        }

        $fullPath = Join-Path -Path $script:repoRoot -ChildPath "Config/scoopfile.json"
        $raw = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
        (ConvertTo-CanonicalJsonText -RawJson $raw -SortObjectKeys) | Should -BeExactly $raw -Because "the committed scoopfile.json must already be in sorted-key canonical form"
    }
}

Describe "Write-CanonicalJsonFile" {
    BeforeAll {
        $script:fixtureRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("canonical-json-" + [System.Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($script:fixtureRoot) | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:fixtureRoot) {
            Remove-Item -LiteralPath $script:fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rewrites a non-canonical file to canonical bytes and reports the change" {
        if (-not $script:hasSystemTextJson) {
            Set-ItResult -Skipped -Because "in-place 2-space reindent requires System.Text.Json"
            return
        }

        $path = Join-Path -Path $script:fixtureRoot -ChildPath "dirty.json"
        [System.IO.File]::WriteAllText($path, "{`r`n    `"a`": 1`r`n}", [System.Text.UTF8Encoding]::new($false))
        $changed = Write-CanonicalJsonFile -Path $path
        $changed | Should -BeTrue
        $result = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $result | Should -BeExactly "{`n  `"a`": 1`n}`n"
    }

    It "leaves an already-canonical file untouched and reports no change" {
        $path = Join-Path -Path $script:fixtureRoot -ChildPath "clean.json"
        $canonical = "{`n  `"a`": 1`n}`n"
        [System.IO.File]::WriteAllText($path, $canonical, [System.Text.UTF8Encoding]::new($false))
        $changed = Write-CanonicalJsonFile -Path $path
        $changed | Should -BeFalse
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | Should -BeExactly $canonical
    }
}
