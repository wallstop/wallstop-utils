Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location -Path $baseDirectory
try {
  $sourcePath = "$env:LOCALAPPDATA\Microsoft\PowerToys"
  if (-not (Test-Path -Path $sourcePath -PathType Container)) {
    Write-Error "E_POWERTOYS_BACKUP_SOURCE_MISSING: Failed to detect PowerToys config directory at '$sourcePath'."
    exit 1
  }

  $backupFolder = "$baseDirectory\..\Config\PowerToys"
  if (-not (Test-Path -Path $backupFolder -PathType Container)) {
    New-Item -Path $backupFolder -ItemType Directory -Force | Out-Null
  }
  else {
    $backupEntries = @(Get-ChildItem -Path $backupFolder -Force -ErrorAction Stop)
    if ($backupEntries.Count -gt 0) {
      Remove-Item -Path "$backupFolder\*" -Recurse -Force -ErrorAction Stop
    }
  }

  Robocopy.exe $sourcePath $backupFolder *.json /S > $null 2>&1
  $robocopyExitCodeVariable = Get-Variable -Name "LASTEXITCODE" -ValueOnly -ErrorAction SilentlyContinue
  $robocopyExitCode = if ($null -ne $robocopyExitCodeVariable) { [int]$robocopyExitCodeVariable } else { 0 }

  # Robocopy semantics: exit codes 0-7 indicate success classes, >=8 indicates failure.
  if ($robocopyExitCode -ge 8) {
    Write-Error ("E_POWERTOYS_BACKUP_ROBOCOPY_FAILED: Robocopy failed with exit code {0}." -f $robocopyExitCode)
    exit 1
  }

  if ($robocopyExitCode -ge 2) {
    Write-Warning ("W_POWERTOYS_BACKUP_ROBOCOPY_CLASS_{0}: Robocopy reported non-fatal differences." -f $robocopyExitCode)
  }

  Write-Host "PowerToys configuration settings have been backed up to $backupFolder." -ForegroundColor Green
}
finally {
  Pop-Location
}
