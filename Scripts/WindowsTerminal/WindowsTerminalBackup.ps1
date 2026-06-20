Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$canonicalJsonHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "../Utils/Common/CanonicalJsonHelpers.ps1"
if (-not (Test-Path -LiteralPath $canonicalJsonHelpersPath -PathType Leaf)) {
    throw "E_WT_BACKUP_CANONICAL_JSON_HELPER_MISSING: canonical JSON helper file not found at '$canonicalJsonHelpersPath'."
}

. $canonicalJsonHelpersPath

$sourcePath = "$HOME\scoop\apps\windows-terminal\current\settings\settings.json"
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
$backupFolder = "$baseDirectory\Config\WindowsTerminal"
Push-Location -LiteralPath $baseDirectory

try {
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($backupFolder) | Out-Null
    }

    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        $backupFile = "$backupFolder\settings.json"
        Copy-Item -LiteralPath $sourcePath -Destination $backupFile
        # Windows Terminal writes settings.json with its own indentation/line endings (and sometimes JSONC
        # comments/trailing commas). Canonicalize the committed copy to the pretty-format-json hook form so
        # an unattended `--no-verify` backup lands the same bytes an attended/hook commit would, preventing
        # recurring whole-file merge conflicts.
        [void](Write-CanonicalJsonFile -Path $backupFile)
        Write-Host "Windows Terminal settings exported successfully." -ForegroundColor Green
    }
    else {
        Write-Error "E_WT_BACKUP_SOURCE_MISSING: Windows Terminal settings file not found at '$sourcePath'."
        exit 1
    }
}
finally {
    Pop-Location
}
