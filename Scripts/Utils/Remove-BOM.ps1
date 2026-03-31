# Remove-BOM PowerShell Script
# This script removes the UTF-8 BOM (Byte Order Mark) from text files in a repository
#
# Features:
# - Uses git-native file discovery for accurate .gitignore semantics
# - Falls back to filesystem traversal when git discovery is unavailable
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

function Get-DefaultExclusionPatterns {
    return @(
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
}

function Test-PathAgainstPatterns {
    param(
        [string]$path,
        [string[]]$patterns
    )

    # Normalize to forward slashes for cross-platform matching (patterns use '/')
    $normalizedPath = $path -replace '\\', '/'

    foreach ($pattern in $patterns) {
        if ($normalizedPath -like $pattern) {
            return $true
        }
    }

    return $false
}

function Test-IsPathUnderRoot {
    param(
        [string]$path,
        [string]$root
    )

    $normalizedPath = ([System.IO.Path]::GetFullPath($path) -replace '\\', '/').TrimEnd('/')
    $normalizedRoot = ([System.IO.Path]::GetFullPath($root) -replace '\\', '/').TrimEnd('/')

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    if ($normalizedPath.Equals($normalizedRoot, $comparison)) {
        return $true
    }

    return $normalizedPath.StartsWith("$normalizedRoot/", $comparison)
}

function Get-ScannableFiles {
    param(
        [string]$scanRoot
    )

    $resolvedScanRoot = (Resolve-Path -LiteralPath $scanRoot -ErrorAction Stop).Path
    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    $gitDiscoveryFailureReason = ""

    if ($null -ne $gitCommand) {
        $gitRootOutput = @(& $gitCommand.Source -C $resolvedScanRoot rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitRootOutput.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($gitRootOutput[0])) {
            $gitRoot = [System.IO.Path]::GetFullPath($gitRootOutput[0].Trim())
            $relativeScanRoot = ([System.IO.Path]::GetRelativePath($gitRoot, $resolvedScanRoot) -replace '\\', '/').Trim()
            $gitListArguments = @("ls-files", "--cached", "--others", "--exclude-standard")
            if (-not [string]::IsNullOrWhiteSpace($relativeScanRoot) -and $relativeScanRoot -ne ".") {
                $gitListArguments += @("--", $relativeScanRoot)
            }

            $relativePaths = @(& $gitCommand.Source -C $gitRoot @gitListArguments 2>$null)

            if ($LASTEXITCODE -eq 0) {
                $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
                foreach ($relativePath in $relativePaths) {
                    $trimmedRelativePath = $relativePath.Trim()
                    if ([string]::IsNullOrWhiteSpace($trimmedRelativePath)) {
                        continue
                    }

                    $candidatePath = Join-Path -Path $gitRoot -ChildPath $trimmedRelativePath
                    if (-not (Test-IsPathUnderRoot -path $candidatePath -root $resolvedScanRoot)) {
                        continue
                    }

                    try {
                        $candidateItem = Get-Item -LiteralPath $candidatePath -ErrorAction Stop
                        if ($candidateItem -is [System.IO.FileInfo]) {
                            $files.Add($candidateItem)
                        }
                    }
                    catch {
                        Write-Verbose "W_REMOVE_BOM_GIT_DISCOVERY_ITEM_SKIP: Unable to materialize '$candidatePath' from git file list - $($_.Exception.Message)"
                    }
                }

                return [PSCustomObject]@{
                    Files       = @($files)
                    Mode        = "git-ls-files"
                    Diagnostics = "gitRoot=$gitRoot scanRoot=$resolvedScanRoot listedPaths=$($relativePaths.Count) selectedFiles=$($files.Count)"
                }
            }

            $gitDiscoveryFailureReason = "git ls-files failed with exit code $LASTEXITCODE"
        }
        else {
            $gitDiscoveryFailureReason = "git rev-parse did not resolve a worktree for '$resolvedScanRoot'"
        }
    }
    else {
        $gitDiscoveryFailureReason = "git command not found on PATH"
    }

    $gitIgnorePath = Join-Path -Path $resolvedScanRoot -ChildPath ".gitignore"
    if (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf) {
        throw "E_REMOVE_BOM_GIT_DISCOVERY_REQUIRED: .gitignore found at '$gitIgnorePath', but git-native file discovery is unavailable ($gitDiscoveryFailureReason). Refusing unsafe fallback because ignore-rule semantics cannot be guaranteed."
    }

    if (-not [string]::IsNullOrWhiteSpace($gitDiscoveryFailureReason)) {
        Write-Warning "W_REMOVE_BOM_GIT_DISCOVERY_FALLBACK: $gitDiscoveryFailureReason. Falling back to filesystem traversal (no .gitignore found under scan root)."
    }

    $defaultExclusionPatterns = Get-DefaultExclusionPatterns
    $fallbackFiles = @(
        Get-ChildItem -LiteralPath $resolvedScanRoot -File -Recurse |
            Where-Object {
                -not (Test-PathAgainstPatterns -path $_.FullName -patterns $defaultExclusionPatterns)
            }
    )

    return [PSCustomObject]@{
        Files       = @($fallbackFiles)
        Mode        = "filesystem-fallback"
        Diagnostics = "fallbackPatterns=$($defaultExclusionPatterns.Count) selectedFiles=$($fallbackFiles.Count)"
    }
}

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
        $hasUtf8BomPrefix = $bytesRead -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF
        $contentStartIndex = if ($hasUtf8BomPrefix) { 3 } else { 0 }

        # Check if the content has null bytes (common in binary files)
        for ($i = $contentStartIndex; $i -lt $bytesRead; $i++) {
            if ($buffer[$i] -eq 0) {
                return $true
            }
        }

        # Check for high proportion of non-printable characters
        $nonPrintableCount = 0
        for ($i = $contentStartIndex; $i -lt $bytesRead; $i++) {
            # Consider bytes outside typical ASCII text range as non-printable
            # Excluding common whitespace: tab (9), newline (10), carriage return (13), space (32)
            if (($buffer[$i] -lt 32 -and $buffer[$i] -ne 9 -and $buffer[$i] -ne 10 -and $buffer[$i] -ne 13) -or $buffer[$i] -gt 126) {
                $nonPrintableCount++
            }
        }

        # If more than 10% of characters are non-printable, consider it binary
        $analyzedLength = $bytesRead - $contentStartIndex
        if ($analyzedLength -gt 0 -and ($nonPrintableCount / $analyzedLength) -gt 0.1) {
            return $true
        }
    }
    catch {
        # On error, assume it's not binary to be safe
        Write-Verbose "W_REMOVE_BOM_BINARY_CHECK_FAILED: Error checking if file is binary '$filePath' - $($_.Exception.Message)"
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
            $utf8NoBomEncoding = [System.Text.UTF8Encoding]::new($false)

            # Read the entire file content
            $content = [System.IO.File]::ReadAllText($filePath, [System.Text.Encoding]::UTF8)

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


function Invoke-Main {
    param(
        [switch]$DetectOnly,
        [switch]$ShowProgress,
        [string]$Path = ""
    )

    # Main script execution
    $repoRoot = if ($Path) {
        (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }
    else {
        (Get-Location).Path
    }

    $bomCount = 0
    $filesChecked = 0
    $script:prefixReadFailures = 0

    # Show execution mode
    if ($DetectOnly) {
        Write-Host "Running in detection-only mode - no changes will be made" -ForegroundColor Yellow
    }

    $scanPlan = Get-ScannableFiles -scanRoot $repoRoot
    $scanFiles = @($scanPlan.Files)

    Write-Host "File discovery mode: $($scanPlan.Mode)"
    Write-Host "File discovery diagnostics: $($scanPlan.Diagnostics)"
    Write-Host "Scanning files for BOM (this may take a while for large repositories)..."

    # Create a timer to measure performance
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($file in $scanFiles) {
        $filesChecked++

        # Status update every 1000 files to show progress
        if ($filesChecked % 1000 -eq 0) {
            Write-Host "Checked $filesChecked files so far..." -ForegroundColor Cyan
        }

        # Show file being processed if ShowProgress is enabled
        if ($ShowProgress) {
            Write-Host "Processing: $($file.FullName)" -ForegroundColor DarkGray
        }

        if ($DetectOnly) {
            # Just check for BOM but don't remove
            $prefixRead = Read-FilePrefixBytes -filePath $file.FullName -byteCount 3 -context "DetectOnly"
            if ($null -eq $prefixRead) {
                continue
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
    Write-Host "File discovery mode: $($scanPlan.Mode)"
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
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-Main -DetectOnly:$DetectOnly -ShowProgress:$ShowProgress -Path $Path
}
