$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location $baseDirectory

# Define the path to the `.config` folder in the user's home directory
$configFolder = "$env:USERPROFILE\.config"

# Define the destination folder where you want to store the backup
# You can modify this path to any preferred backup location
$backupFolder = "$baseDirectory/Config"

# Create the backup folder if it doesn't exist
if (-not (Test-Path -Path $backupFolder)) {
  New-Item -Path $backupFolder -ItemType Directory
}

$backupFolder = "$backupFolder/.config"
# Create the backup folder if it doesn't exist
if (-not (Test-Path -Path $backupFolder)) {
  New-Item -Path $backupFolder -ItemType Directory
}
else {
  Remove-Item -Path "$backupFolder\*" -Recurse -Force
}

# Check if the .config folder exists
if (Test-Path -Path $configFolder) {
  # Copy the .config folder to the backup destination
  Copy-Item -Path $configFolder -Destination $backupFolder -Recurse -Force

  Write-Host "Backup successful! .config folder saved to $backupFolder"
} else {
  Write-Host "The .config folder does not exist at $configFolder."
}
Pop-Location
