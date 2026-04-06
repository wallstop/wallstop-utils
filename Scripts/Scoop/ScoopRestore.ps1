Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
$configDirectory = Join-Path -Path $baseDirectory -ChildPath "Config"
$scoopFilePath = Join-Path -Path $configDirectory -ChildPath "scoopfile.json"

if (-not (Test-Path -LiteralPath $scoopFilePath -PathType Leaf)) {
    Write-Error "E_SCOOP_RESTORE_SOURCE_MISSING: Scoop backup manifest not found at '$scoopFilePath'."
    exit 1
}

Push-Location -LiteralPath $configDirectory
try {
    $outputLines = @(& scoop import $scoopFilePath 2>&1)
    $scoopExitCodeVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    $scoopExitCode = if ($null -ne $scoopExitCodeVariable) { [int]$scoopExitCodeVariable } else { 0 }

    if ($scoopExitCode -ne 0) {
        $errorText = if ($outputLines.Count -gt 0) { $outputLines -join [Environment]::NewLine } else { "(no output)" }
        Write-Error ("E_SCOOP_RESTORE_IMPORT_FAILED: scoop import failed with code {0}. Output: {1}" -f $scoopExitCode, $errorText)
        exit 1
    }

    Write-Host "Scoop restore successful: $scoopFilePath" -ForegroundColor Green
}
finally {
    Pop-Location
}
