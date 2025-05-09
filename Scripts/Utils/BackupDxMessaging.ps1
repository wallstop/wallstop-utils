# --- Configuration ---
$sourcePath = "D:\Code\Packages"
$backupDir = "Z:\Backup\Code\Packages"
# Define directories/files to exclude relative to the source path
# Robocopy's /XD excludes directories matching these names *anywhere* in the tree
$excludedDirs = @(
  "Library",
  "obj",
  "Builds",
  "CodeCoverage",
  "Logs",
  "Temp",
  "UserSettings",# Often excluded in Unity projects
  ".vs" # Visual Studio temporary files, often hidden
)
# You can also exclude specific files using /XF (e.g., "*.log") if needed
# $excludedFiles = @("*.log", "*.tmp")

$date = Get-Date -Format "yyyy-MM-dd"
$zipFileName = "$date.zip"
$zipFilePath = Join-Path $env:TEMP $zipFileName # Final Zip location before move
# Temporary location to stage files before zipping
$tempStagePath = Join-Path $env:TEMP "TempBackupStage_$(Get-Date -Format 'yyyyMMddHHmmssffff')" # Unique temp dir name
$maxBackups = 7

# --- Pre-flight Checks ---
# Ensure destination directory exists
if (!(Test-Path $backupDir)) {
  Write-Host "Destination directory does not exist, attempting to create: $backupDir"
  try {
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
    Write-Host "Destination directory created successfully."
  } catch {
    Write-Error "Failed to create destination directory: $backupDir. Error: $($_.Exception.Message)"
    exit 1
  }
}

# Ensure source directory exists
if (!(Test-Path $sourcePath)) {
  Write-Error "Source directory does not exist: $sourcePath"
  exit 1
}

# --- Main Backup Process ---
Write-Host "Starting backup process..."
try {
  # 1. Create Temporary Staging Directory
  Write-Host "Creating temporary staging directory: $tempStagePath"
  New-Item -Path $tempStagePath -ItemType Directory -Force | Out-Null

  # 2. Copy Source to Staging using Robocopy (includes hidden, excludes specified)
  Write-Host "Copying files from '$sourcePath' to staging area, excluding specified items..."

  $robocopyArgs = @(
    $sourcePath,# Source
    $tempStagePath,# Destination
    '/E',# Copy Subdirectories, including Empty ones.
    '/COPY:DAT',# Copy ALL file info (Data, Attributes, Timestamps, Security, Owner, Auditing). Use /COPY:DAT if less info is needed.
    '/R:2',# Number of Retries on failed copies (default is 1 million!)
    '/W:5',# Wait time between retries in seconds (default is 30)
    '/NFL',# No File List - Suppress file names being logged.
    '/NDL',# No Directory List - Suppress directory names being logged.
    '/NJH',# No Job Header.
    '/NJS',# No Job Summary.
    '/NP' # No Progress - Don't display percentage copied.
    # '/MT:8'         # Optional: Enable multi-threaded copying (e.g., 8 threads) - faster on fast networks/disks but uses more resources.
  )
  # Add directory exclusions
  foreach ($dir in $excludedDirs) {
    $robocopyArgs += '/XD',$dir
  }
  # Add file exclusions (if you defined $excludedFiles)
  # foreach ($file in $excludedFiles) {
  #    $robocopyArgs += '/XF', $file
  # }

  # Execute Robocopy
  Write-Host "Running Robocopy..."
  $process = Start-Process Robocopy.exe -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru

  # Check Robocopy Exit Code (See Robocopy documentation for meanings)
  # 0 = No errors, no files copied
  # 1 = No errors, files were copied
  # 2 = Extra files/dirs detected (ok if destination wasn't empty)
  # 3 = 1 + 2
  # >= 8 indicates errors (e.g., 8=some failures, 16=serious error)
  if ($process.ExitCode -ge 8) {
    Write-Error "Robocopy failed during staging copy with exit code $($process.ExitCode). Backup aborted. Check logs or run manually for details."
    # Consider leaving the $tempStagePath for diagnosis, or clean it up in finally
    exit 1 # Exit the script
  } else {
    Write-Host "Robocopy completed staging copy successfully (Exit Code: $($process.ExitCode))."
  }

  # 3. Create ZIP Archive from the Staged Directory Contents
  Write-Host "Creating ZIP archive '$zipFilePath' from staged files..."
  # Use "$tempStagePath\*" to zip the *contents* of the directory, not the directory itself
  Compress-Archive -Path "$tempStagePath\*" -DestinationPath $zipFilePath -Force
  Write-Host "ZIP archive created."

  # 4. Move ZIP Archive to Network Location using Robocopy
  Write-Host "Moving ZIP file to '$backupDir'..."
  $robocopyMoveArgs = @(
    $env:TEMP,# Source Directory (where the zip file is)
    $backupDir,# Destination Directory
    $zipFileName,# File to move
    '/MOV',# Move file (Copy then Delete source)
    '/NFL',# No File List
    '/NDL',# No Directory List
    '/NP',# No Progress
    '/NJH',# No Job Header
    '/NJS' # No Job Summary
  )
  $processMove = Start-Process Robocopy.exe -ArgumentList $robocopyMoveArgs -Wait -NoNewWindow -PassThru
  if ($processMove.ExitCode -ge 8) {
    Write-Error "Robocopy failed during ZIP file move with exit code $($processMove.ExitCode). The ZIP might still be in '$env:TEMP'."
    exit 1 # Exit the script
  } else {
    Write-Host "ZIP file moved successfully to network share."
  }

  # 5. Cleanup: Delete Old Backups on the Network Share
  Write-Host "Checking for old backups to remove..."
  $backups = Get-ChildItem -Path $backupDir -Filter "*.zip" | Sort-Object LastWriteTime
  if ($backups.Count -gt $maxBackups) {
    $toDelete = $backups | Select-Object -First ($backups.Count - $maxBackups)
    Write-Host "Found $($toDelete.Count) old backup(s) to remove."
    foreach ($file in $toDelete) {
      Write-Host "Removing old backup: $($file.FullName)"
      Remove-Item -Path $file.FullName -Force
    }
  } else {
    Write-Host "No old backups need removal (Limit: $maxBackups, Found: $($backups.Count))."
  }

  # --- Final Report ---
  $backupCount = (Get-ChildItem -Path $backupDir -Filter "*.zip").Count
  Write-Host "----------------------------------------"
  Write-Host "Backup completed successfully!"
  Write-Host "Backup file: $backupDir\$zipFileName"
  Write-Host "Total backups now in directory: $backupCount"
  Write-Host "----------------------------------------"

} catch {
  # Catch any unexpected errors during the process
  Write-Error "An unexpected error occurred: $($_.Exception.Message)"
  # Stack trace can be helpful for debugging: $_.ScriptStackTrace
} finally {
  # 6. Cleanup: Always remove the temporary staging directory
  if (Test-Path $tempStagePath) {
    Write-Host "Cleaning up temporary staging directory '$tempStagePath'..."
    Remove-Item -Path $tempStagePath -Recurse -Force
  }
  # Optional: Clean up the zip file from TEMP if it still exists (e.g., if move failed but script didn't exit)
  if (Test-Path $zipFilePath) {
    Write-Warning "Temporary zip file '$zipFilePath' still exists in $env:TEMP. Removing it."
    Remove-Item -Path $zipFilePath -Force
  }
  Write-Host "Cleanup complete."
}
