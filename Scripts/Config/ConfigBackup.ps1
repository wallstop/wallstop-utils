Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path

Push-Location -LiteralPath $baseDirectory
try {
    $configFolder = Join-Path -Path $HOME -ChildPath ".config"
    if (-not (Test-Path -LiteralPath $configFolder -PathType Container)) {
        Write-Error "E_CONFIG_BACKUP_SOURCE_MISSING: Source .config folder not found at '$configFolder'."
        exit 1
    }

    $backupFolder = Join-Path -Path (Join-Path -Path $baseDirectory -ChildPath "Config") -ChildPath ".config"
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
    }
    else {
        $backupEntries = @(Get-ChildItem -LiteralPath $backupFolder -Force -ErrorAction Stop)
        if ($backupEntries.Count -gt 0) {
            Remove-Item -Path (Join-Path -Path $backupFolder -ChildPath '*') -Recurse -Force -ErrorAction Stop
        }
    }

    $backupParent = (Split-Path -Path $backupFolder -Parent)
    try {
        Copy-Item -Path $configFolder -Destination $backupParent -Recurse -Force
        Write-Host "Backup successful! .config folder saved to $backupFolder" -ForegroundColor Green
    }
    catch {
        Write-Error ("E_CONFIG_BACKUP_COPY_FAILED: Failed to back up .config from '{0}' to '{1}': {2}" -f $configFolder, $backupParent, $_.Exception.Message)
        exit 1
    }
}
finally {
    Pop-Location
}
