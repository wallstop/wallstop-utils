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

function Test-IsBinaryFile {
  param(
    [string]$filePath
  )

  try {
    # Check the file extension first for common binary types
    $extension = [System.IO.Path]::GetExtension($filePath).ToLower()
    $binaryExtensions = @(
      '.jpg','.jpeg','.png','.gif','.bmp','.ico','.tiff',
      '.zip','.gz','.tar','.7z','.rar',
      '.exe','.dll','.so','.dylib',
      '.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx',
      '.mp3','.mp4','.avi','.mov','.mkv'
    )

    if ($binaryExtensions -contains $extension) {
      return $true
    }

    # Read the first 8KB of the file to check for binary content
    $fs = [System.IO.File]::OpenRead($filePath)
    $buffer = New-Object byte[] 8192
    $bytesRead = $fs.Read($buffer,0,8192)
    $fs.Close()

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
    Write-Verbose "Error checking if file is binary: $($_.Exception.Message)"
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
    "*\.git\*",
    "*\.svn\*",
    "*\.hg\*",

    # Build directories
    "*\bin\*",
    "*\obj\*",
    "*\build\*",
    "*\dist\*",
    "*\target\*",
    "*\out\*",
    "*\output\*",
    "*\node_modules\*",
    "*\.next\*",
    "*\.nuxt\*",
    "*\.vite\*",
    "*\.svelte-kit\*",
    "*\.turbo\*",
    "*\cdk.out\*",

    # IDE files
    "*\.vs\*",
    "*\.idea\*",
    "*\.vscode\*",

    # Logs and temp files
    "*\logs\*",
    "*\coverage\*",
    "*\.nyc_output\*",
    "*\*.log",
    "*\*.tmp",
    "*\*.tsbuildinfo"
  )

  # Add binary file extensions
  $binaryExtensions = @(
    "*.jpg","*.jpeg","*.png","*.gif","*.ico","*.bmp","*.tiff",
    "*.zip","*.gz","*.tar","*.7z","*.rar",
    "*.exe","*.dll","*.so","*.dylib",
    "*.pdf","*.doc","*.docx","*.xls","*.xlsx","*.ppt","*.pptx",
    "*.mp3","*.mp4","*.avi","*.mov","*.mkv"
  )

  $patterns += $binaryExtensions

  # Read .gitignore if it exists
  $gitIgnorePath = Join-Path -Path $repoRoot -ChildPath ".gitignore"
  if (Test-Path -Path $gitIgnorePath) {
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

      # Remove leading/trailing slashes
      $pattern = $pattern.TrimStart('/').TrimEnd('/')

      # Handle directory wildcards
      if ($pattern.EndsWith('/')) {
        $pattern = $pattern.TrimEnd('/') + '\*'
      }

      # Handle ** wildcard (any directory depth)
      $pattern = $pattern -replace '\*\*','*'

      # Convert to full path
      if ($pattern -match '^\w') {
        # Pattern doesn't start with wildcard, make it relative to root
        $pattern = "*\$pattern*"
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

  foreach ($pattern in $ignorePatterns) {
    if ($path -like $pattern) {
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
    $fileStream = [System.IO.File]::OpenRead($filePath)
    $buffer = New-Object byte[] 3
    $bytesRead = $fileStream.Read($buffer,0,3)
    $fileStream.Close()

    # Check if file has UTF-8 BOM (EF BB BF)
    if ($bytesRead -eq 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
      # Use the built-in UTF8NoBOM encoding
      $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $false

      # Read the entire file content
      $content = [System.IO.File]::ReadAllText($filePath)

      # Write the content back without BOM
      # The UTF8Encoding with false parameter will write without BOM
      [System.IO.File]::WriteAllText($filePath,$content,$utf8NoBomEncoding)

      Write-Host "Removed BOM from: $filePath"
      return $true
    }
  }
  catch {
    Write-Host "Error processing file: $filePath - $($_.Exception.Message)" -ForegroundColor Red
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
    $fileStream = [System.IO.File]::OpenRead($file.FullName)
    $buffer = New-Object byte[] 3
    $bytesRead = $fileStream.Read($buffer,0,3)
    $fileStream.Close()

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
Write-Host "Time taken: $($elapsedTime.ToString('hh\:mm\:ss\.fff'))"
Write-Host "=========================" -ForegroundColor Cyan

if ($DetectOnly) {
  Write-Host "Run the script without -DetectOnly to remove BOMs from the files" -ForegroundColor Yellow
}
else {
  Write-Host "BOM removal completed. Total files processed with BOM: $bomCount" -ForegroundColor Green
}
