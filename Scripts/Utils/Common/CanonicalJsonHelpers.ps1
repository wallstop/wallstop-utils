Set-StrictMode -Version Latest

function ConvertTo-LfTextWithSingleTrailingNewline {
    # Normalizes arbitrary text to the deterministic on-disk form the repository's pre-commit hooks
    # (`mixed-line-ending --fix=lf` plus `end-of-file-fixer`) converge on: LF-only newlines with exactly
    # one trailing newline. Centralizing this is what lets unattended backups -- which commit with
    # `git commit --no-verify` and bypass the formatter hooks -- land bytes identical to an attended/hook
    # commit, so the same data never produces two formats that conflict on every line.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    # Collapse any trailing blank lines to exactly one terminating newline (end-of-file-fixer semantics).
    $normalized = $normalized.TrimEnd("`n")
    return ($normalized + "`n")
}

function ConvertTo-AsciiEscapedJsonText {
    # Normalizes a serialized JSON string's escaping to match Python json.dumps' default
    # `ensure_ascii=True` (what the pre-commit `pretty-format-json` hook uses):
    #   (a) every raw non-ASCII code unit (> U+007F) is escaped as a lowercase \uXXXX sequence -- astral
    #       characters become their UTF-16 surrogate pair (\udXXX\udYYY) and U+2028/U+2029 are escaped too,
    #       matching Python; and
    #   (b) every \uXXXX escape the upstream serializer already emitted is lowercased, because
    #       System.Text.Json escapes control characters, DEL, and astral characters as UPPERCASE \uXXXX
    #       while Python emits lowercase. Without this, an input containing an emoji or control character
    #       would canonicalize to bytes that differ from the hook only by escape case -- reintroducing the
    #       merge-conflict drift the canonicalizer exists to prevent.
    # Backslash escapes are tracked so a literal "\\uABCD" in string data (a backslash followed by the
    # characters u,A,B,C,D) is copied verbatim and never mis-lowercased as if it were an escape sequence.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $builder = [System.Text.StringBuilder]::new($Text.Length)
    $index = 0
    $length = $Text.Length
    while ($index -lt $length) {
        $character = $Text[$index]
        if ($character -eq '\') {
            # Inside a JSON string a backslash always begins a valid escape. A six-character \uXXXX run is
            # lowercased; every other escape (\", \\, \/, \b, \f, \n, \r, \t) is copied as a verbatim pair,
            # which is also what keeps a literal "\\uABCD" from being treated as an escape on the next loop.
            if (($index + 5) -lt $length -and $Text[$index + 1] -eq 'u') {
                [void]$builder.Append('\u')
                [void]$builder.Append($Text.Substring($index + 2, 4).ToLowerInvariant())
                $index += 6
            }
            else {
                [void]$builder.Append($character)
                if (($index + 1) -lt $length) {
                    [void]$builder.Append($Text[$index + 1])
                }
                $index += 2
            }
        }
        elseif ([int][char]$character -gt 0x7F) {
            [void]$builder.Append('\u')
            [void]$builder.Append(("{0:x4}" -f [int][char]$character))
            $index += 1
        }
        else {
            [void]$builder.Append($character)
            $index += 1
        }
    }

    return $builder.ToString()
}

function ConvertTo-JsonNodeWithSortedObjectKeys {
    # Rebuilds a System.Text.Json.Nodes JsonNode tree so every JSON object's properties appear in
    # [System.StringComparer]::Ordinal key order, recursively. Array element order is preserved (only
    # object MEMBERS are reordered -- never array items). This exists because some upstream generators,
    # notably `scoop export` (which builds each app object from a PowerShell hashtable whose iteration
    # order varies per invocation), emit the same data with different member order on every run: without
    # sorting, a byte-stable committed artifact is impossible and backups churn whole-file diffs daily.
    #
    # Leaf values are copied by round-tripping their exact JSON text through JsonNode so string payloads
    # (ISO-8601 timestamps), number tokens, booleans, and nulls survive verbatim without type-specific
    # GetValue<T> probing. Duplicate input member names cannot be represented by a rebuilt JsonObject:
    # JsonNode.Parse rejects them outright, and ConvertTo-CanonicalJsonText wraps that failure in the
    # stable E_CANONICAL_JSON_SORT_FAILED diagnostic so it fails CLOSED instead of silently dropping data.
    # Callers must runtime-gate invocation on "System.Text.Json.Nodes.JsonNode" -as [type]; Windows
    # PowerShell 5.1 never reaches this function.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'System.Text.Json.Nodes is runtime-gated to PowerShell 7+ via a "...JsonNode" -as [type]" probe at the call site; Windows PowerShell 5.1 never invokes this function. This is the sanctioned runtime-guarded pattern in .llm/context.md.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [System.Text.Json.Nodes.JsonNode]$Node
    )

    if ($null -eq $Node) {
        return $null
    }

    if ($Node -is [System.Text.Json.Nodes.JsonObject]) {
        $sortedObject = [System.Text.Json.Nodes.JsonObject]::new()
        # Ordinal insertion sort over the member pairs: deterministic across machines and cultures
        # (context.md portability rule 15) with no follow-up key lookup. Object member counts here are
        # tiny (scoop app objects carry five members), so quadratic insertion cost is irrelevant.
        $sortedPairs = New-Object System.Collections.Generic.List[object]
        foreach ($property in $Node.AsObject()) {
            $insertIndex = $sortedPairs.Count
            for ($pairIndex = 0; $pairIndex -lt $sortedPairs.Count; $pairIndex++) {
                $ordinalComparison = [System.String]::CompareOrdinal($property.Key, [string]$sortedPairs[$pairIndex].Key)
                if ($ordinalComparison -lt 0) {
                    $insertIndex = $pairIndex
                    break
                }
            }

            $sortedPairs.Insert($insertIndex, $property)
        }

        foreach ($pair in $sortedPairs) {
            $sortedChild = ConvertTo-JsonNodeWithSortedObjectKeys -Node $pair.Value
            [void]$sortedObject.Add([string]$pair.Key, $sortedChild)
        }

        # Comma-wrapped returns throughout: JsonObject/JsonArray implement IDictionary/IEnumerable, so
        # bare `return $node` would be UNROLLED by the PowerShell pipeline into KeyValuePairs/elements and
        # callers would receive object[] instead of the rebuilt node (see .llm/context.md "PowerShell Empty
        # Array Return Safety"). The comma operator preserves the node as a single pipeline item.
        return , $sortedObject
    }

    if ($Node -is [System.Text.Json.Nodes.JsonArray]) {
        $sortedArray = [System.Text.Json.Nodes.JsonArray]::new()
        foreach ($element in $Node.AsArray()) {
            $sortedChild = ConvertTo-JsonNodeWithSortedObjectKeys -Node $element
            [void]$sortedArray.Add($sortedChild)
        }

        # Comma-wrapped return: JsonArray is IEnumerable, so a bare `return $sortedArray` would be
        # unrolled by the PowerShell pipeline into its elements and callers would receive object[]
        # instead of the rebuilt node (see .llm/context.md "PowerShell Empty Array Return Safety").
        return , $sortedArray
    }

    # Leaf value: copy via its exact serialized text (comma-wrapped for the same pipeline-unroll safety).
    $rawLeafText = $Node.ToJsonString()
    return , ([System.Text.Json.JsonSerializer]::Deserialize($rawLeafText, [System.Text.Json.Nodes.JsonNode]))
}

function ConvertTo-CanonicalJsonText {
    # Re-emits JSON in the repository's canonical committed form -- 2-space indent, LF newlines, exactly
    # one trailing newline, non-ASCII escaped to \uXXXX -- byte-identical to the pre-commit
    # `pretty-format-json --no-sort-keys --indent 2` hook (Python `json.dumps`, `ensure_ascii=True`) plus
    # `end-of-file-fixer`/`mixed-line-ending`. Writing this canonical form at the SOURCE (rather than
    # whatever indentation/line endings/escaping the upstream tool emitted) is what prevents recurring
    # whole-file merge conflicts in committed config artifacts: an unattended backup commits with
    # `--no-verify` and bypasses the formatter hooks, so without canonicalization it would land
    # non-canonical bytes while an attended/hook commit lands canonical bytes.
    #
    # System.Text.Json (PowerShell 7+) parses via JsonDocument so every string value is preserved VERBATIM
    # -- in particular ISO-8601 timestamps. ConvertFrom-Json | ConvertTo-Json must NOT be used here: it
    # reparses timestamp strings into [datetime] and re-serializes them in a shifted timezone, silently
    # corrupting the data. UnsafeRelaxedJsonEscaping is used because it leaves the ASCII characters Python
    # also leaves raw (`<`, `>`, `&`, `'`, `+`); the non-ASCII escaping that ensure_ascii adds on top is
    # applied separately by ConvertTo-AsciiEscapedJsonText, so the two together match json.dumps exactly --
    # no single built-in .NET encoder does (Default/Create over-escape those ASCII characters). Comments and
    # trailing commas in the input are tolerated and dropped, because the committed form is strict JSON --
    # exactly what `pretty-format-json`/`check-json` require. On Windows PowerShell 5.1, where
    # System.Text.Json is unavailable, it falls back to line-ending/trailing-newline normalization only and
    # an attended commit's hook canonicalizes the indentation; timestamps are still preserved (no reparse).
    #
    # -SortObjectKeys additionally rebuilds every JSON object with Ordinal-sorted member names (nested
    # recursively; array element order untouched) before serialization, for upstream generators whose own
    # member order is non-deterministic across runs (`scoop export` app objects built from PowerShell
    # hashtables). The sorted form stays a byte-identical fixed point of `pretty-format-json` because that
    # hook preserves key order -- sorting at the source is what removes the daily whole-file churn.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'System.Text.Json (including Nodes for -SortObjectKeys) is runtime-gated to PowerShell 7+ via a "...-as [type]" probe; Windows PowerShell 5.1 takes the line-ending-normalizing fallback. This is the sanctioned runtime-guarded pattern in .llm/context.md.')]
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RawJson,

        [switch]$SortObjectKeys
    )

    # Sorted-path availability is probed once up front so BOTH degradation modes (no System.Text.Json at
    # all on Windows PowerShell 5.1, or an older Core build without the Nodes API) surface the same
    # actionable warning instead of silently returning unsorted output.
    if ($SortObjectKeys -and $null -eq ("System.Text.Json.Nodes.JsonNode" -as [type])) {
        Write-Warning "W_CANONICAL_JSON_SORT_UNAVAILABLE: -SortObjectKeys was requested but System.Text.Json.Nodes is unavailable on this runtime; output member order was NOT normalized."
    }

    $jsonDocumentType = "System.Text.Json.JsonDocument" -as [type]
    if ($null -ne $jsonDocumentType) {
        $document = $null
        try {
            $documentOptions = [System.Text.Json.JsonDocumentOptions]::new()
            $documentOptions.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
            $documentOptions.AllowTrailingCommas = $true

            $serializerOptions = [System.Text.Json.JsonSerializerOptions]::new()
            $serializerOptions.WriteIndented = $true
            $serializerOptions.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping

            # Sorted path: parse into an editable JsonNode tree, rebuild it Ordinal-sorted, and serialize
            # the rebuilt tree through the same serializer options as the default path so formatting is
            # identical. A scalar "null" document parses to a null node and falls through to the default
            # path, which has no member order to sort.
            $sortedRootNode = $null
            if ($SortObjectKeys) {
                $jsonNodeType = "System.Text.Json.Nodes.JsonNode" -as [type]
                if ($null -ne $jsonNodeType) {
                    try {
                        $jsonNodeOptions = [System.Text.Json.Nodes.JsonNodeOptions]::new()
                        $jsonNodeOptions.PropertyNameCaseInsensitive = $false
                        $sortedRootNode = ConvertTo-JsonNodeWithSortedObjectKeys -Node ($jsonNodeType::Parse($RawJson, $jsonNodeOptions, $documentOptions))
                    }
                    catch {
                        # Fail closed with a stable code: unlike the default path, a sorted rebuild cannot
                        # represent every input (duplicate member names are rejected by JsonNode.Parse), so
                        # callers must never mistake a silent unsorted fallback for success.
                        $sortFailureDetail = [string]$_.Exception.Message
                        throw ("E_CANONICAL_JSON_SORT_FAILED: -SortObjectKeys could not rebuild the JSON tree for sorted serialization. Detail: {0}" -f $sortFailureDetail)
                    }
                }
            }

            # WriteIndented uses CRLF on .NET running under Windows (the indented Utf8JsonWriter newline was
            # hard-coded to "`r`n" before .NET 9 / the configurable JsonWriterOptions.NewLine). The LF
            # normalization below is what makes the output LF-only on every platform, not just Linux/macOS.
            if ($null -ne $sortedRootNode) {
                $serialized = [System.Text.Json.JsonSerializer]::Serialize($sortedRootNode, $serializerOptions)
            }
            else {
                $document = [System.Text.Json.JsonDocument]::Parse($RawJson, $documentOptions)
                $serialized = [System.Text.Json.JsonSerializer]::Serialize($document.RootElement, $serializerOptions)
            }

            $serialized = ConvertTo-AsciiEscapedJsonText -Text $serialized
            return (ConvertTo-LfTextWithSingleTrailingNewline -Text $serialized)
        }
        finally {
            if ($null -ne $document) {
                $document.Dispose()
            }
        }
    }

    return (ConvertTo-LfTextWithSingleTrailingNewline -Text $RawJson)
}

function Write-CanonicalJsonFile {
    # Reads a JSON file, canonicalizes it via ConvertTo-CanonicalJsonText, and rewrites it in place as
    # UTF-8 (no BOM) only when the bytes actually change. Used by backup writers to guarantee committed
    # JSON artifacts under pretty-format-json scope are canonical even on the unattended `--no-verify` path.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $rawJson = [System.IO.File]::ReadAllText($resolvedPath, [System.Text.Encoding]::UTF8)
    $canonical = ConvertTo-CanonicalJsonText -RawJson $rawJson
    if ($canonical -ceq $rawJson) {
        return $false
    }

    [System.IO.File]::WriteAllText($resolvedPath, $canonical, [System.Text.UTF8Encoding]::new($false))
    return $true
}
