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
