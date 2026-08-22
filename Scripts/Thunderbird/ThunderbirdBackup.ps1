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
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force -ErrorAction Stop

    Write-Host "Thunderbird profiles.ini has been backed up to $destinationPath." -ForegroundColor Green
}
catch {
    Write-Error ("E_THUNDERBIRD_BACKUP_COPY_FAILED: Failed to back up Thunderbird profiles.ini. Detail: {0}" -f [string]$_.Exception.Message)
    exit 1
}
finally {
    Pop-Location
}
