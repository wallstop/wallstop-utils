<#
.SYNOPSIS
    Recursively converts all HTML files in the input directory to Markdown files in the output directory using Pandoc.

.DESCRIPTION
    This script takes an input directory and an output directory as parameters.
    It searches for all .html files within the input directory and its subdirectories,
    converts each to a .md file using Pandoc, and saves them in the output directory,
    preserving the original directory structure.

.PARAMETER InputDir
    The path to the input directory containing HTML files.

.PARAMETER OutputDir
    The path to the output directory where Markdown files will be saved.

.EXAMPLE
    .\ConvertHtmlToMarkdown.ps1 -InputDir "C:\HTMLFiles" -OutputDir "C:\MarkdownFiles"

.NOTES
    - Ensure Pandoc is installed and added to the system PATH.
    - The script preserves the directory structure from the input to the output directory.
#>

param(
  [Parameter(Mandatory = $true,HelpMessage = "Path to the input directory containing HTML files.")]
  [ValidateScript({ Test-Path $_ -PathType 'Container' })]
  [string]$InputDir,

  [Parameter(Mandatory = $true,HelpMessage = "Path to the output directory for Markdown files.")]
  [string]$OutputDir
)

# Function to Convert HTML to Markdown
function Convert-HtmlToMarkdown {
  param(
    [string]$SourceFile,
    [string]$DestinationFile
  )

  try {
    # Execute Pandoc command
    pandoc -f html -t markdown -o "`"$DestinationFile`"" "`"$SourceFile`""
    Write-Host "Converted: $SourceFile -> $DestinationFile" -ForegroundColor Green
  }
  catch {
    Write-Warning "Failed to convert: $SourceFile. Error: $_"
  }
}

# Verify Pandoc is installed
if (-not (Get-Command pandoc -ErrorAction SilentlyContinue)) {
  Write-Error "Pandoc is not installed or not found in PATH. Please install Pandoc from https://pandoc.org/installing.html"
  exit 1
}

# Create Output Directory if it doesn't exist
if (-not (Test-Path -Path $OutputDir)) {
  try {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
    Write-Host "Created output directory: $OutputDir" -ForegroundColor Cyan
  }
  catch {
    Write-Error "Failed to create output directory: $OutputDir. Error: $_"
    exit 1
  }
}

# Get all .html files recursively from InputDir
try {
  $htmlFiles = Get-ChildItem -Path $InputDir -Recurse -Include *.html,*.htm
}
catch {
  Write-Error "Error accessing files in input directory: $InputDir. Error: $_"
  exit 1
}

if ($htmlFiles.Count -eq 0) {
  Write-Warning "No HTML files found in the input directory: $InputDir"
  exit 0
}

# Process each HTML file
foreach ($file in $htmlFiles) {
  # Determine the relative path from the input directory
  $relativePath = $file.FullName.Substring($InputDir.Length).TrimStart('\','/')

  # Change the file extension to .md
  $relativeMdPath = [System.IO.Path]::ChangeExtension($relativePath,".md")

  # Determine the full path for the output Markdown file
  $destinationFile = Join-Path -Path $OutputDir -ChildPath $relativeMdPath

  # Ensure the destination directory exists
  $destinationDir = Split-Path -Path $destinationFile -Parent
  if (-not (Test-Path -Path $destinationDir)) {
    try {
      New-Item -Path $destinationDir -ItemType Directory -Force | Out-Null
      Write-Host "Created directory: $destinationDir" -ForegroundColor Cyan
    }
    catch {
      Write-Warning "Failed to create directory: $destinationDir. Skipping file: $($file.FullName)"
      continue
    }
  }

  # Convert the HTML file to Markdown
  Convert-HtmlToMarkdown -SourceFile $file.FullName -DestinationFile $destinationFile
}

Write-Host "Conversion complete. Markdown files are saved in: $OutputDir" -ForegroundColor Yellow
