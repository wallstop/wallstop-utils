Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Configuration ---
$strictModeHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/StrictModeHelpers.ps1"
if (-not (Test-Path -Path $strictModeHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Strict mode helper file not found at '$strictModeHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

. $strictModeHelpersPath

if (-not $IsWindows) {
    Write-Error "E_DXMSG_BACKUP_WINDOWS_ONLY: This script requires Windows (Robocopy). Current OS is not Windows."
    exit 1
}

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
$zipFilePath = Join-Path ([System.IO.Path]::GetTempPath()) $zipFileName # Final Zip location before move
# Temporary location to stage files before zipping
$tempStagePath = Join-Path ([System.IO.Path]::GetTempPath()) "TempBackupStage_$(Get-Date -Format 'yyyyMMddHHmmssffff')" # Unique temp dir name
$maxBackups = 7

# --- Pre-flight Checks ---
# Ensure destination directory exists
if (-not (Test-Path -Path $backupDir -PathType Container)) {
    Write-Host "Destination directory does not exist, attempting to create: $backupDir"
    try {
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
        Write-Host "Destination directory created successfully."
    }
    catch {
        Write-Error "Failed to create destination directory: $backupDir. Error: $($_.Exception.Message)"
        exit 1
    }
}

# Ensure source directory exists
if (-not (Test-Path -Path $sourcePath -PathType Container)) {
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
        $robocopyArgs += '/XD', $dir
    }
    # Add file exclusions (if you defined $excludedFiles)
    # foreach ($file in $excludedFiles) {
    #    $robocopyArgs += '/XF', $file
    # }

    # Execute Robocopy
    Write-Host "Running Robocopy..."
    $process = Start-Process Robocopy.exe -ArgumentList $robocopyArgs -Wait -NoNewWindow -Passthru
    [void]$process.WaitForExit(30000)

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
    }
    else {
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
        ([System.IO.Path]::GetTempPath()),# Source Directory (where the zip file is)
        $backupDir,# Destination Directory
        $zipFileName,# File to move
        '/MOV',# Move file (Copy then Delete source)
        '/NFL',# No File List
        '/NDL',# No Directory List
        '/NP',# No Progress
        '/NJH',# No Job Header
        '/NJS' # No Job Summary
    )
    $processMove = Start-Process Robocopy.exe -ArgumentList $robocopyMoveArgs -Wait -NoNewWindow -Passthru
    [void]$processMove.WaitForExit(30000)
    if ($processMove.ExitCode -ge 8) {
        Write-Error "Robocopy failed during ZIP file move with exit code $($processMove.ExitCode). The ZIP might still be in '$([System.IO.Path]::GetTempPath())'."
        exit 1 # Exit the script
    }
    else {
        Write-Host "ZIP file moved successfully to network share."
    }

    # 5. Cleanup: Delete Old Backups on the Network Share
    Write-Host "Checking for old backups to remove..."
    $backups = Get-ChildItem -Path $backupDir -Filter "*.zip" | Sort-Object LastWriteTime
    $backupTotal = Get-SafeCount -InputObject $backups
    if ($backupTotal -gt $maxBackups) {
        $toDelete = @($backups | Select-Object -First ($backupTotal - $maxBackups))
        $deleteCount = Get-SafeCount -InputObject $toDelete
        Write-Host "Found $deleteCount old backup(s) to remove."
        foreach ($file in $toDelete) {
            Write-Host "Removing old backup: $($file.FullName)"
            Remove-Item -Path $file.FullName -Force
        }
    }
    else {
        Write-Host "No old backups need removal (Limit: $maxBackups, Found: $backupTotal)."
    }

    # --- Final Report ---
    $backupCount = Get-SafeCount -InputObject (Get-ChildItem -Path $backupDir -Filter "*.zip")
    Write-Host "----------------------------------------"
    Write-Host "Backup completed successfully!"
    Write-Host "Backup file: $backupDir\$zipFileName"
    Write-Host "Total backups now in directory: $backupCount"
    Write-Host "----------------------------------------"

}
catch {
    # Catch any unexpected errors during the process
    Write-Error "E_DXMSG_BACKUP_UNEXPECTED: An unexpected error occurred: $($_.Exception.Message)"
    # Stack trace can be helpful for debugging: $_.ScriptStackTrace
    exit 1
}
finally {
    # 6. Cleanup: Always remove the temporary staging directory
    if (Test-Path -LiteralPath $tempStagePath -PathType Container) {
        Write-Host "Cleaning up temporary staging directory '$tempStagePath'..."
        try {
            Remove-Item -LiteralPath $tempStagePath -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "W_DXMSG_BACKUP_TEMP_STAGE_CLEANUP_FAILED: Failed to remove temporary staging directory '$tempStagePath': $($_.Exception.Message)"
        }
    }
    # Optional: Clean up the zip file from TEMP if it still exists (e.g., if move failed but script didn't exit)
    if (Test-Path -LiteralPath $zipFilePath -PathType Leaf) {
        Write-Warning "Temporary zip file '$zipFilePath' still exists in $([System.IO.Path]::GetTempPath()). Removing it."
        try {
            Remove-Item -LiteralPath $zipFilePath -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "W_DXMSG_BACKUP_TEMP_ZIP_CLEANUP_FAILED: Failed to remove temporary zip file '$zipFilePath': $($_.Exception.Message)"
        }
    }
    Write-Host "Cleanup complete."
}
