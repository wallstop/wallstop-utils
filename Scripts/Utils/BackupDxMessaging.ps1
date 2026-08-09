Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Configuration ---
$strictModeHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/StrictModeHelpers.ps1"
if (-not (Test-Path -LiteralPath $strictModeHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Strict mode helper file not found at '$strictModeHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

.$strictModeHelpersPath

$compatibilityHelpersPath = Join-Path -Path $PSScriptRoot -ChildPath "Common/CompatibilityHelpers.ps1"
if (-not (Test-Path -LiteralPath $compatibilityHelpersPath -PathType Leaf)) {
    throw "E_CONFIG_ERROR: Compatibility helper file not found at '$compatibilityHelpersPath' (PSScriptRoot='$PSScriptRoot')."
}

.$compatibilityHelpersPath

if (-not (Test-IsWindowsPlatform)) {
    Write-Error "E_DXMSG_BACKUP_WINDOWS_ONLY: This script requires Windows (Robocopy). Current OS is not Windows."
    exit 1
}

function Invoke-BackupProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    Set-PortableProcessArguments -StartInfo $startInfo -ArgumentList $ArgumentList

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        if (-not $process.WaitForExit($processTimeoutMilliseconds)) {
            $terminationError = $null
            try {
                Stop-ProcessTreePortably -Process $process
            }
            catch {
                $terminationError = $_.Exception.Message
            }

            if (-not $process.WaitForExit(10000)) {
                throw "E_DXMSG_BACKUP_PROCESS_TERMINATION_FAILED: Timed-out $Description remained active after termination was requested. Detail: $terminationError"
            }

            throw "E_DXMSG_BACKUP_PROCESS_TIMEOUT: $Description exceeded the $processTimeoutMinutes minute timeout."
        }

        return $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
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
    "TestResults",
    "Logs",
    "Temp",
    "UserSettings",
    ".vs",
    ".idea",
    ".tmp",
    ".artifacts",
    "artifacts",
    ".venv",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".tox",
    ".codex-home",
    "coverage"
)
$excludedFiles = @(
    # Unix tools can create this legal POSIX name, but Win32 treats it as a device.
    "nul",
    ".DS_Store",
    "Thumbs.db"
)

$date = Get-Date -Format "yyyy-MM-dd"
$zipFileName = "$date.zip"
$runId = Get-Date -Format 'yyyyMMddHHmmssffff'
$partialZipFileName = "dxmsg-$runId.partial.zip"
$rollbackZipFileName = "dxmsg-$runId.rollback.zip"
$zipFilePath = Join-Path ([System.IO.Path]::GetTempPath()) $partialZipFileName
$tempStagePath = Join-Path ([System.IO.Path]::GetTempPath()) "TempBackupStage_$runId"
$networkPartialPath = Join-Path -Path $backupDir -ChildPath $partialZipFileName
$networkRollbackPath = Join-Path -Path $backupDir -ChildPath $rollbackZipFileName
$networkFinalPath = Join-Path -Path $backupDir -ChildPath $zipFileName
$maxBackups = 7
$processTimeoutMinutes = 120
$processTimeoutMilliseconds = $processTimeoutMinutes * 60 * 1000
$backupPublished = $false

$robocopyCommands = @(Get-Command -Name "Robocopy.exe" -CommandType Application -ErrorAction SilentlyContinue)
if ($robocopyCommands.Count -eq 0) {
    Write-Error "E_DXMSG_BACKUP_ROBOCOPY_NOT_AVAILABLE: Robocopy.exe is required but was not found."
    exit 1
}
$robocopyCommand = $robocopyCommands[0]

$tarCommands = @(Get-Command -Name "tar.exe" -CommandType Application -ErrorAction SilentlyContinue)
if ($tarCommands.Count -eq 0) {
    Write-Error "E_DXMSG_BACKUP_TAR_NOT_AVAILABLE: tar.exe is required to create a reliable ZIP archive but was not found."
    exit 1
}
$tarCommand = $tarCommands[0]

Write-Verbose (
    "DX messaging backup path diagnostics: sourcePath='{0}'; backupDir='{1}'; tempStagePath='{2}'; zipFilePath='{3}'" -f
    $sourcePath,
    $backupDir,
    $tempStagePath,
    $zipFilePath
)

# --- Pre-flight Checks ---
# Ensure destination directory exists
if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
    Write-Host "Destination directory does not exist, attempting to create: $backupDir"
    try {
        [System.IO.Directory]::CreateDirectory($backupDir) | Out-Null
        Write-Host "Destination directory created successfully."
    }
    catch {
        Write-Error "E_DXMSG_BACKUP_DEST_CREATE_FAILED: Failed to create destination directory '$backupDir'. Error: $($_.Exception.Message)"
        exit 1
    }
}

# Ensure source directory exists
if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    Write-Error "E_DXMSG_BACKUP_SOURCE_MISSING: Source directory does not exist at '$sourcePath'."
    exit 1
}

# --- Main Backup Process ---
Write-Host "Starting backup process..."
try {
    # 1. Create Temporary Staging Directory
    Write-Host "Creating temporary staging directory: $tempStagePath"
    [System.IO.Directory]::CreateDirectory($tempStagePath) | Out-Null

    # 2. Copy Source to Staging using Robocopy (includes hidden, excludes specified)
    Write-Host "Copying files from '$sourcePath' to staging area, excluding specified items..."

    $robocopyArgs = @(
        $sourcePath,# Source
        $tempStagePath,# Destination
        '/E',# Copy Subdirectories, including Empty ones.
        '/COPY:DT',# Copy source data and timestamps; generated attributes are not backup-critical.
        '/DCOPY:T',# Preserve directory timestamps without copying problematic attributes.
        '/Z',# Use restartable mode for transient read failures.
        '/XJ',# Exclude junctions that cannot be archived reliably.
        '/XJD',# Explicitly exclude directory junctions/reparse points.
        '/XJF',# Explicitly exclude file junctions/reparse points (for example Unix venv links).
        '/R:3',# Keep retries bounded (Robocopy defaults to one million).
        '/W:2',# Retry transient failures quickly.
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
    foreach ($file in $excludedFiles) {
        $robocopyArgs += '/XF',$file
    }

    # Execute Robocopy
    Write-Host "Running Robocopy..."
    $robocopyExitCode = Invoke-BackupProcess -FilePath $robocopyCommand.Source -ArgumentList $robocopyArgs -Description "staging copy"

    # Check Robocopy Exit Code (See Robocopy documentation for meanings)
    # 0 = No errors, no files copied
    # 1 = No errors, files were copied
    # 2 = Extra files/dirs detected (ok if destination wasn't empty)
    # 3 = 1 + 2
    # >= 8 indicates errors (e.g., 8=some failures, 16=serious error)
    if ($robocopyExitCode -ge 8) {
        throw "E_DXMSG_BACKUP_STAGING_COPY_FAILED: Robocopy failed during staging copy with exit code $robocopyExitCode."
    }
    else {
        Write-Host "Robocopy completed staging copy successfully (Exit Code: $robocopyExitCode)."
    }

    # 3. Create ZIP Archive from the Staged Directory Contents
    Write-Host "Creating ZIP archive '$zipFilePath' from staged files..."
    if (Test-Path -LiteralPath $zipFilePath -PathType Leaf) {
        Remove-Item -LiteralPath $zipFilePath -Force
    }
    $archiveArgs = @('-a','-c','-f',$zipFilePath,'-C',$tempStagePath,'.')
    $archiveExitCode = Invoke-BackupProcess -FilePath $tarCommand.Source -ArgumentList $archiveArgs -Description "ZIP archive creation"
    if ($archiveExitCode -ne 0 -or -not (Test-Path -LiteralPath $zipFilePath -PathType Leaf) -or (Get-Item -LiteralPath $zipFilePath).Length -eq 0) {
        throw "E_DXMSG_BACKUP_ARCHIVE_FAILED: tar.exe failed to create '$zipFilePath' (exit code $archiveExitCode)."
    }
    $requiredArchiveEntry = './Packages/com.wallstop-studios.dxmessaging/package.json'
    $verifyArgs = @('-t','-f',$zipFilePath,$requiredArchiveEntry)
    $verifyExitCode = Invoke-BackupProcess -FilePath $tarCommand.Source -ArgumentList $verifyArgs -Description "ZIP archive verification"
    if ($verifyExitCode -ne 0) {
        throw "E_DXMSG_BACKUP_ARCHIVE_VERIFY_FAILED: '$zipFilePath' is unreadable or is missing '$requiredArchiveEntry' (exit code $verifyExitCode)."
    }
    Write-Host "ZIP archive created."

    # 4. Copy to a unique network partial, then atomically publish the date-named archive.
    Write-Host "Transferring ZIP file to '$backupDir'..."
    $robocopyMoveArgs = @(
        ([System.IO.Path]::GetTempPath()),
        $backupDir,
        $partialZipFileName,
        '/Z',
        '/R:3',
        '/W:5',
        '/NFL',
        '/NDL',
        '/NP',
        '/NJH',
        '/NJS'
    )
    $moveExitCode = Invoke-BackupProcess -FilePath $robocopyCommand.Source -ArgumentList $robocopyMoveArgs -Description "backup transfer"
    if ($moveExitCode -ge 8) {
        throw "E_DXMSG_BACKUP_TRANSFER_FAILED: Robocopy failed during ZIP transfer with exit code $moveExitCode."
    }

    $localArchiveLength = (Get-Item -LiteralPath $zipFilePath).Length
    if (-not (Test-Path -LiteralPath $networkPartialPath -PathType Leaf) -or (Get-Item -LiteralPath $networkPartialPath).Length -ne $localArchiveLength) {
        throw "E_DXMSG_BACKUP_TRANSFER_VERIFY_FAILED: Network partial '$networkPartialPath' does not match the local archive size."
    }
    try {
        if (Test-Path -LiteralPath $networkFinalPath -PathType Leaf) {
            [System.IO.File]::Replace($networkPartialPath,$networkFinalPath,$networkRollbackPath,$true)
        }
        else {
            [System.IO.File]::Move($networkPartialPath,$networkFinalPath)
        }
    }
    catch {
        throw "E_DXMSG_BACKUP_PUBLISH_FAILED: Failed to atomically publish '$networkFinalPath': $($_.Exception.Message)"
    }
    $backupPublished = $true
    if (Test-Path -LiteralPath $networkRollbackPath -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $networkRollbackPath -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "W_DXMSG_BACKUP_ROLLBACK_CLEANUP_FAILED: Published backup is valid, but failed to remove rollback '$networkRollbackPath': $($_.Exception.Message)"
        }
    }
    Write-Host "ZIP file published successfully to network share."

    # 5. Cleanup: Delete Old Backups on the Network Share
    Write-Host "Checking for old backups to remove..."
    $backups = Get-ChildItem -LiteralPath $backupDir -Filter "????-??-??.zip" | Sort-Object LastWriteTime
    $backupTotal = Get-SafeCount -InputObject $backups
    if ($backupTotal -gt $maxBackups) {
        $toDelete = @($backups | Select-Object -First ($backupTotal - $maxBackups))
        $deleteCount = Get-SafeCount -InputObject $toDelete
        Write-Host "Found $deleteCount old backup(s) to remove."
        foreach ($file in $toDelete) {
            Write-Host "Removing old backup: $($file.FullName)"
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
    else {
        Write-Host "No old backups need removal (Limit: $maxBackups, Found: $backupTotal)."
    }

    # --- Final Report ---
    $backupCount = Get-SafeCount -InputObject (Get-ChildItem -LiteralPath $backupDir -Filter "????-??-??.zip")
    Write-Host "----------------------------------------"
    Write-Host "Backup completed successfully!"
    Write-Host "Backup file: $networkFinalPath"
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
    if (Test-Path -LiteralPath $networkPartialPath -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $networkPartialPath -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "W_DXMSG_BACKUP_NETWORK_PARTIAL_CLEANUP_FAILED: Failed to remove '$networkPartialPath': $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $networkRollbackPath -PathType Leaf) {
        Write-Warning "W_DXMSG_BACKUP_ROLLBACK_RETAINED: Previous published archive retained at '$networkRollbackPath'."
    }
    if (Test-Path -LiteralPath $zipFilePath -PathType Leaf) {
        if ($backupPublished) {
            try {
                Remove-Item -LiteralPath $zipFilePath -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "W_DXMSG_BACKUP_TEMP_ZIP_CLEANUP_FAILED: Failed to remove temporary zip file '$zipFilePath': $($_.Exception.Message)"
            }
        }
        else {
            Write-Warning "W_DXMSG_BACKUP_RECOVERY_ARCHIVE_RETAINED: Backup failed; complete local archive retained at '$zipFilePath'."
        }
    }
    Write-Host "Cleanup complete."
}
