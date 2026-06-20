Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptsRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$canonicalJsonHelpersPath = Join-Path -Path $scriptsRoot -ChildPath "Utils/Common/CanonicalJsonHelpers.ps1"
if (-not (Test-Path -LiteralPath $canonicalJsonHelpersPath -PathType Leaf)) {
    throw "E_SCOOP_BACKUP_CANONICAL_JSON_HELPER_MISSING: canonical JSON helper file not found at '$canonicalJsonHelpersPath'."
}

. $canonicalJsonHelpersPath

function ConvertTo-CanonicalScoopExportJson {
    # Thin Scoop-facing wrapper over the shared canonicalizer. `scoop export` emits 4-space JSON, but the
    # committed Config/scoopfile.json must be byte-identical to the pre-commit `pretty-format-json` hook
    # output (2-space, LF, single trailing newline). Writing the canonical form HERE, rather than scoop's
    # raw output, is what prevents recurring whole-file merge conflicts: an unattended backup commits with
    # `git commit --no-verify` and bypasses the hook, so without this it would land non-canonical bytes
    # while an attended/hook commit lands canonical bytes, and two formats of the same data conflict on
    # every line. The shared helper parses via System.Text.Json's JsonDocument so the ISO-8601 `Updated`
    # timestamps are preserved verbatim (ConvertFrom-Json/ConvertTo-Json would reparse and timezone-shift
    # them); see Scripts/Utils/Common/CanonicalJsonHelpers.ps1 for the full contract.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RawJson
    )

    return ConvertTo-CanonicalJsonText -RawJson $RawJson
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
