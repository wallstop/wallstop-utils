Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
$scriptsDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
$rootDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $scriptsDirectory -ChildPath "..") -ErrorAction Stop).Path
Push-Location -LiteralPath $baseDirectory
try {
    # Thunderbird's profiles.ini maps install-specific defaults to real profile
    # directories; without it a restored install can silently create an empty new
    # profile instead of reattaching the user's mail store (issue #68).
    $sourcePath = Join-Path -Path $env:APPDATA -ChildPath "Thunderbird/profiles.ini"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Write-Warning (
            "W_THUNDERBIRD_BACKUP_SOURCE_MISSING: Thunderbird profiles.ini not found at '{0}'. Skipping backup." -f
            $sourcePath
        )
        exit 0
    }

    $backupFolder = Join-Path -Path $rootDirectory -ChildPath "Config/Thunderbird"
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($backupFolder)
    }

    $destinationPath = Join-Path -Path $backupFolder -ChildPath "profiles.ini"
    $copyFailureDetail = ''

    # Normalize to LF with one trailing newline in UTF-8 (no BOM): unattended
    # backups commit with --no-verify, so the committed form must already match
    # what the repository's text hooks would produce.
    $sourceContent = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8)
    $normalizedContent = ($sourceContent -replace "\r\n?", "`n").TrimEnd() + "`n"
    $existingContent = ''
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        $existingContent = [System.IO.File]::ReadAllText($destinationPath, [System.Text.Encoding]::UTF8)
    }

    if ($normalizedContent -ne $existingContent) {
        try {
            [System.IO.File]::WriteAllText($destinationPath, $normalizedContent, [System.Text.UTF8Encoding]::new($false))
        }
        catch {
            $copyFailureDetail = [string]$_.Exception.Message
        }
    }

    if (-not [string]::IsNullOrEmpty($copyFailureDetail)) {
        # Emitted via Write-Error (ErrorActionPreference=Stop), which terminates
        # with a non-zero exit for the orchestrator's per-step classification.
        Write-Error ("E_THUNDERBIRD_BACKUP_COPY_FAILED: Failed to back up Thunderbird profiles.ini. Detail: {0}" -f $copyFailureDetail)
        return
    }

    Write-Host "Thunderbird profiles.ini has been backed up to $destinationPath." -ForegroundColor Green
}
finally {
    Pop-Location
}
