$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$baseDirectory = "$baseDirectory\..\"
Push-Location $baseDirectory

# Define the path to the current user's .config directory
$configDir = "$env:USERPROFILE\.config"

# Define the path to the backup directory (you should set this to your backup location)
# For example: "C:\Backups\.config_backup_20231005"
$backupDir = "$baseDirectory\Config\.config"
try {
  # Check if the backup directory exists
  if (-not (Test-Path -Path $backupDir)) {
    Write-Host "Backup directory not found: $backupDir" -ForegroundColor Red
    exit 1
  }

  # Check if the .config directory exists; if not, create it
  if (-not (Test-Path -Path $configDir)) {
    Write-Host ".config directory not found, creating it at: $configDir"
    New-Item -Path $configDir -ItemType Directory
  }

  # Restore the contents of the backup to the .config directory
  try {
    Copy-Item -Path "$backupDir\*" -Destination $configDir -Recurse -Force
    Write-Host ".config directory restored from backup successfully." -ForegroundColor Green
  } catch {
    Write-Host "An error occurred while restoring the .config directory: $_" -ForegroundColor Red
  }
}
finally {
  Pop-Location
}
