Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourcePath = "$HOME\scoop\apps\windows-terminal\current\settings\settings.json"
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
$backupFolder = "$baseDirectory\Config\WindowsTerminal"
Push-Location -LiteralPath $baseDirectory

try {
    if (-not (Test-Path -LiteralPath $backupFolder -PathType Container)) {
        New-Item -LiteralPath $backupFolder -ItemType Directory | Out-Null
    }

    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        $backupFile = "$backupFolder\settings.json"
        Copy-Item -LiteralPath $sourcePath -Destination $backupFile
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
