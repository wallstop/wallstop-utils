# Remove-BOM PowerShell Script
# This script removes the UTF-8 BOM (Byte Order Mark) from text files in a repository
#
# Features:
# - Uses lazy directory traversal for better performance with large repositories
# - Respects .gitignore patterns to avoid processing ignored files
# - Has a detection mode to find BOMs without removing them
# - Provides detailed progress feedback and performance metrics
# - Automatically detects and skips binary files
#
# Usage:
#   .\remove-bom.ps1                      # Remove BOMs from all text files in current directory and subdirectories
#   .\remove-bom.ps1 -DetectOnly          # Just detect BOMs without removing them
#   .\remove-bom.ps1 -ShowProgress        # Show detailed processing information for each file
#   .\remove-bom.ps1 -Path "D:\MyRepo"    # Process files in a specific directory

# Script parameters
param(
    [switch]$DetectOnly,
    [switch]$ShowProgress,
    [string]$Path = ""
)

$script:prefixReadFailures = 0

function Read-FilePrefixBytes {
    param(
        [string]$filePath,
        [ValidateRange(1, 1048576)]
        [int]$byteCount,
        [string]$context
    )

    $fileStream = $null
    try {
        $fileStream = [System.IO.File]::OpenRead($filePath)
        $buffer = New-Object byte[] $byteCount
        $bytesRead = $fileStream.Read($buffer, 0, $byteCount)

        return @{
            Buffer    = $buffer
            BytesRead = $bytesRead
        }
    }
    catch {
        $script:prefixReadFailures++
        Write-Verbose "W_REMOVE_BOM_READ_PREFIX_FAILED ($context): Could not read '$filePath' - $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
    }
}

function Test-IsBinaryFile {
    param(
        [string]$filePath
    )

    try {
        # Check the file extension first for common binary types
        $extension = [System.IO.Path]::GetExtension($filePath).ToLower()
        $binaryExtensions = @(
            '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.ico', '.tiff',
            '.zip', '.gz', '.tar', '.7z', '.rar',
            '.exe', '.dll', '.so', '.dylib',
            '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
            '.mp3', '.mp4', '.avi', '.mov', '.mkv'
        )

        if ($binaryExtensions -contains $extension) {
            return $true
        }

        # Read the first 8KB of the file to check for binary content
        $prefixRead = Read-FilePrefixBytes -filePath $filePath -byteCount 8192 -context "Test-IsBinaryFile"
        if ($null -eq $prefixRead) {
            return $false
        }

        $buffer = $prefixRead.Buffer
        $bytesRead = $prefixRead.BytesRead

        # Check if the content has null bytes (common in binary files)
        for ($i = 0; $i -lt $bytesRead; $i++) {
            if ($buffer[$i] -eq 0) {
                return $true
            }
        }

        # Check for high proportion of non-printable characters
        $nonPrintableCount = 0
        for ($i = 0; $i -lt $bytesRead; $i++) {
            # Consider bytes outside typical ASCII text range as non-printable
            # Excluding common whitespace: tab (9), newline (10), carriage return (13), space (32)
            if (($buffer[$i] -lt 32 -and $buffer[$i] -ne 9 -and $buffer[$i] -ne 10 -and $buffer[$i] -ne 13) -or $buffer[$i] -gt 126) {
                $nonPrintableCount++
            }
        }

        # If more than 10% of characters are non-printable, consider it binary
        if ($bytesRead -gt 0 -and ($nonPrintableCount / $bytesRead) -gt 0.1) {
            return $true
        }
    }
    catch {
        # On error, assume it's not binary to be safe
        Write-Verbose "W_REMOVE_BOM_BINARY_CHECK_FAILED: Error checking if file is binary '$filePath' - $($_.Exception.Message)"
    }

    return $false
}

function Get-GitIgnorePatterns {
    param(
        [string]$repoRoot
    )

    # Start with common exclusions from typical repositories
    $patterns = @(
        # Version control
        "*/.git/*",
        "*/.svn/*",
        "*/.hg/*",

        # Build directories
        "*/bin/*",
        "*/obj/*",
        "*/build/*",
        "*/dist/*",
        "*/target/*",
        "*/out/*",
        "*/output/*",
        "*/node_modules/*",
        "*/.next/*",
        "*/.nuxt/*",
        "*/.vite/*",
        "*/.svelte-kit/*",
        "*/.turbo/*",
        "*/cdk.out/*",

        # IDE files
        "*/.vs/*",
        "*/.idea/*",
        "*/.vscode/*",

        # Logs and temp files
        "*/logs/*",
        "*/coverage/*",
        "*/.nyc_output/*",
        "*/*.log",
        "*/*.tmp",
        "*/*.tsbuildinfo"
    )

    # Add binary file extensions
    $binaryExtensions = @(
        "*.jpg", "*.jpeg", "*.png", "*.gif", "*.ico", "*.bmp", "*.tiff",
        "*.zip", "*.gz", "*.tar", "*.7z", "*.rar",
        "*.exe", "*.dll", "*.so", "*.dylib",
        "*.pdf", "*.doc", "*.docx", "*.xls", "*.xlsx", "*.ppt", "*.pptx",
        "*.mp3", "*.mp4", "*.avi", "*.mov", "*.mkv"
    )

    $patterns += $binaryExtensions

    # Read .gitignore if it exists
    $gitIgnorePath = Join-Path -Path $repoRoot -ChildPath ".gitignore"
    if (Test-Path -Path $gitIgnorePath -PathType Leaf) {
        $gitignoreContent = Get-Content -Path $gitIgnorePath |
            Where-Object {
                # Filter out comments and empty lines
                $_ -match '\S' -and $_ -notmatch '^\s*#'
            } |
            ForEach-Object {
                $pattern = $_.Trim()

                # Skip negation patterns for simplicity
                if ($pattern.StartsWith('!')) {
                    return
                }

                # Convert gitignore pattern to PowerShell wildcard pattern

                # Preserve directory intent before trimming trailing slash.
                $isDirectoryPattern = $pattern.EndsWith('/')

                # Remove leading/trailing slashes
                $pattern = $pattern.TrimStart('/').TrimEnd('/')

                if ([string]::IsNullOrWhiteSpace($pattern)) {
                    return
                }

                # Handle directory wildcards
                if ($isDirectoryPattern) {
                    $pattern = "$pattern/*"
                }

                # Handle ** wildcard (any directory depth)
                $pattern = $pattern -replace '\*\*', '*'

                # Convert to full path using forward slash (normalized for cross-platform matching)
                if ($pattern -match '^\w') {
                    # Pattern doesn't start with wildcard, make it relative to root
                    if ($isDirectoryPattern) {
                        $pattern = "*/$pattern"
                    }
                    else {
                        $pattern = "*/$pattern*"
                    }
                }
                elseif ($pattern.StartsWith('*')) {
                    # Pattern starts with wildcard, make it search anywhere
                    $pattern = "*$pattern*"
                }

                return $pattern
            }

        $patterns += $gitignoreContent
    }

    # Remove duplicates and nulls
    $patterns = $patterns | Where-Object { $_ } | Select-Object -Unique

    return $patterns
}

function Test-PathAgainstGitIgnore {
    param(
        [string]$path,
        [string[]]$ignorePatterns
    )

    # Normalize to forward slashes for cross-platform matching (patterns use '/')
    $normalizedPath = $path -replace '\\', '/'

    foreach ($pattern in $ignorePatterns) {
        if ($normalizedPath -like $pattern) {
            return $true
        }
    }

    return $false
}

function Remove-BOMFromFile {
    param(
        [string]$filePath
    )

    try {
        # First check if the file is binary to avoid unnecessary processing
        if (Test-IsBinaryFile -FilePath $filePath) {
            return $false
        }

        # Check if file has BOM by reading just the first few bytes (more efficient)
        $prefixRead = Read-FilePrefixBytes -filePath $filePath -byteCount 3 -context "Remove-BOMFromFile"
        if ($null -eq $prefixRead) {
            return $false
        }

        $buffer = $prefixRead.Buffer
        $bytesRead = $prefixRead.BytesRead

        # Check if file has UTF-8 BOM (EF BB BF)
        if ($bytesRead -eq 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
            # Use the built-in UTF8NoBOM encoding
            $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $false

            # Read the entire file content
            $content = [System.IO.File]::ReadAllText($filePath)

            # Write the content back without BOM
            # The UTF8Encoding with false parameter will write without BOM
            [System.IO.File]::WriteAllText($filePath, $content, $utf8NoBomEncoding)

            Write-Host "Removed BOM from: $filePath"
            return $true
        }
    }
    catch {
        Write-Warning "W_REMOVE_BOM_PROCESS_FILE_FAILED: Error processing '$filePath' - $($_.Exception.Message)"
    }

    return $false
}


# Main script execution
$repoRoot = if ($Path) { $Path } else { Get-Location }
$bomCount = 0
$filesChecked = 0

# Show execution mode
if ($DetectOnly) {
    Write-Host "Running in detection-only mode - no changes will be made" -ForegroundColor Yellow
}

# Get gitignore patterns
$ignorePatterns = Get-GitIgnorePatterns -repoRoot $repoRoot
Write-Host "Loaded gitignore patterns and default exclusions."

# Get all files lazily using Recurse parameter with immediate filtering
Write-Host "Scanning files for BOM (this may take a while for large repositories)..."

# Create a timer to measure performance
$timer = [System.Diagnostics.Stopwatch]::StartNew()

# Use pipeline for lazy evaluation
Get-ChildItem -Path $repoRoot -File -Recurse |
    Where-Object {
        $filesChecked++

        # Status update every 1000 files to show progress
        if ($filesChecked % 1000 -eq 0) {
            Write-Host "Checked $filesChecked files so far..." -ForegroundColor Cyan
        }

        # Skip files that match gitignore patterns
        -not (Test-PathAgainstGitIgnore -Path $_.FullName -ignorePatterns $ignorePatterns)
    } |
    ForEach-Object {
        $file = $_

        # Show file being processed if ShowProgress is enabled
        if ($ShowProgress) {
            Write-Host "Processing: $($file.FullName)" -ForegroundColor DarkGray
        }

        if ($DetectOnly) {
            # Just check for BOM but don't remove
            $prefixRead = Read-FilePrefixBytes -filePath $file.FullName -byteCount 3 -context "DetectOnly"
            if ($null -eq $prefixRead) {
                return
            }

            $buffer = $prefixRead.Buffer
            $bytesRead = $prefixRead.BytesRead

            if ($bytesRead -eq 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
                Write-Host "BOM found in: $($file.FullName)" -ForegroundColor Yellow
                $bomCount++
            }
        }
        else {
            # Remove BOM
            if (Remove-BOMFromFile -FilePath $file.FullName) {
                $bomCount++
            }
        }
    }

# Stop the timer
$timer.Stop()
$elapsedTime = $timer.Elapsed

# Show summary
Write-Host ""
Write-Host "======== Summary ========" -ForegroundColor Cyan
Write-Host "Mode: $(if ($DetectOnly) { 'Detection only' } else { 'Active (BOM removal)' })"
Write-Host "Files checked: $filesChecked"
Write-Host "Files with BOM: $bomCount"
Write-Host "Prefix read failures: $script:prefixReadFailures"
Write-Host "Time taken: $($elapsedTime.ToString('hh\:mm\:ss\.fff'))"
Write-Host "=========================" -ForegroundColor Cyan

if ($script:prefixReadFailures -gt 0) {
    Write-Warning "W_REMOVE_BOM_PREFIX_READ_FAILURES: $script:prefixReadFailures file(s) could not be read while scanning file prefixes. Re-run with -Verbose for per-file details."
}

if ($DetectOnly) {
    Write-Host "Run the script without -DetectOnly to remove BOMs from the files" -ForegroundColor Yellow
}
else {
    Write-Host "BOM removal completed. Total files processed with BOM: $bomCount" -ForegroundColor Green
}
