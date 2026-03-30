Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..") -ErrorAction Stop).Path
$baseDirectory = (Resolve-Path -LiteralPath (Join-Path -Path $baseDirectory -ChildPath "..") -ErrorAction Stop).Path
$configDirectory = Join-Path -Path $baseDirectory -ChildPath "Config"

Push-Location -Path $configDirectory
try {
    $outputLines = @(& scoop export --no-colour 2>&1)
    $scoopExitCodeVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
    $scoopExitCode = if ($null -ne $scoopExitCodeVariable) { [int]$scoopExitCodeVariable } else { 0 }
    if ($scoopExitCode -ne 0) {
        $errorText = if ($outputLines.Count -gt 0) { $outputLines -join [Environment]::NewLine } else { "(no output)" }
        Write-Error ("E_SCOOP_BACKUP_EXPORT_FAILED: scoop export failed with code {0}. Output: {1}" -f $scoopExitCode, $errorText)
        exit 1
    }

    $outputText = $outputLines -join [Environment]::NewLine

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $outputPath = Join-Path -Path $configDirectory -ChildPath "scoopfile.json"
    [System.IO.File]::WriteAllText($outputPath, $outputText, $encoding)
    Write-Host "Scoop backup successful: $outputPath" -ForegroundColor Green
}
finally {
    Pop-Location
}
