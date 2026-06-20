Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-CanonicalScoopExportJson {
    # Re-emits `scoop export` output in the repository's canonical JSON form -- 2-space indent, LF
    # newlines, single trailing newline -- byte-identical to the pre-commit `pretty-format-json` hook
    # (which targets Config/scoopfile.json). Writing the canonical form HERE, rather than scoop's raw
    # 4-space output, is what prevents the recurring whole-file merge conflicts in scoopfile.json: an
    # unattended backup commit bypasses hooks with `git commit --no-verify`, so without this it would
    # land 4-space output while an attended/hook-formatted commit lands 2-space. Two indentations of the
    # same data conflict on every line. Normalizing at the source makes both paths emit the same bytes.
    #
    # System.Text.Json (PowerShell 7+) is used via JsonDocument so every string value -- in particular
    # the ISO-8601 `Updated` timestamps -- is preserved VERBATIM. ConvertFrom-Json | ConvertTo-Json must
    # NOT be used for this: it reparses timestamp strings into [datetime] and re-serializes them in a
    # different timezone, silently corrupting the data. UnsafeRelaxedJsonEscaping matches the hook's
    # Python json.dumps escaping for the ASCII data scoop emits. On Windows PowerShell 5.1, where
    # System.Text.Json is unavailable, it falls back to LF normalization and an attended commit's hook
    # canonicalizes the indentation; the timestamps are still preserved because the text is not reparsed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'System.Text.Json is runtime-gated to PowerShell 7+ via a "...-as [type]" probe; Windows PowerShell 5.1 takes the line-ending-normalizing fallback. This is the sanctioned runtime-guarded pattern in .llm/context.md.')]
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RawJson
    )

    $jsonDocumentType = "System.Text.Json.JsonDocument" -as [type]
    if ($null -ne $jsonDocumentType) {
        $document = $null
        try {
            $document = [System.Text.Json.JsonDocument]::Parse($RawJson)
            $serializerOptions = [System.Text.Json.JsonSerializerOptions]::new()
            $serializerOptions.WriteIndented = $true
            $serializerOptions.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
            return ([System.Text.Json.JsonSerializer]::Serialize($document.RootElement, $serializerOptions) + "`n")
        }
        finally {
            if ($null -ne $document) {
                $document.Dispose()
            }
        }
    }

    # Windows PowerShell 5.1 fallback: normalize line endings to LF with exactly one trailing newline so
    # an attended commit's pretty-format-json hook can canonicalize the indentation. The raw text is
    # preserved otherwise (no reparse), so timestamps are never corrupted.
    $normalized = ($RawJson -replace "`r`n", "`n") -replace "`r", "`n"
    if (-not $normalized.EndsWith("`n")) {
        $normalized += "`n"
    }
    return $normalized
}

function Invoke-ScoopBackup {
    [CmdletBinding()]
    param()

    $baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
    $baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
    $configDirectory = Join-Path -Path $baseDirectory -ChildPath "Config"

    Push-Location -LiteralPath $configDirectory
    try {
        $outputLines = @(& scoop export --no-colour 2>&1)
        $scoopExitCodeVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
        $scoopExitCode = if ($null -ne $scoopExitCodeVariable) { [int]$scoopExitCodeVariable } else { 0 }
        if ($scoopExitCode -ne 0) {
            $errorText = if ($outputLines.Count -gt 0) { $outputLines -join [Environment]::NewLine } else { "(no output)" }
            Write-Error ("E_SCOOP_BACKUP_EXPORT_FAILED: scoop export failed with code {0}. Output: {1}" -f $scoopExitCode, $errorText)
            exit 1
        }

        $outputText = $outputLines -join "`n"
        $canonicalText = ConvertTo-CanonicalScoopExportJson -RawJson $outputText

        $encoding = [System.Text.UTF8Encoding]::new($false)
        $outputPath = Join-Path -Path $configDirectory -ChildPath "scoopfile.json"
        [System.IO.File]::WriteAllText($outputPath, $canonicalText, $encoding)
        Write-Host "Scoop backup successful: $outputPath" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}

# Allow tests to dot-source the canonicalizer/helpers without running the backup (which requires scoop).
if ($MyInvocation.InvocationName -ne ".") {
    Invoke-ScoopBackup
}
