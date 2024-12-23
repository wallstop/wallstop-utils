Import-Module ~/scoop/apps/powershell-beautifier/current/PowerShell-Beautifier.psd1

$rootDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location $rootDirectory

# Get all .ps1 files recursively in the directory
$ps1Files = Get-ChildItem -Path $rootDirectory -Recurse -Include *.ps1,*.psm1

# Check if any .ps1 files were found
if ($ps1Files.Count -eq 0) {
  Write-Host "No PowerShell script files (.ps1) found in the directory: $rootDirectory" -ForegroundColor Red
  Pop-Location
  exit 0
}

# Loop through each .ps1 file and beautify it
foreach ($file in $ps1Files) {
  try {
    Write-Host "Beautifying $($file.FullName)..." -ForegroundColor Cyan
    Edit-DTWBeautifyScript $file
    Write-Host "$($file.FullName) has been beautified successfully!" -ForegroundColor Green
  } catch {
    Write-Host "Failed to beautify $($file.FullName): $_" -ForegroundColor Red
  }
}

Write-Host "Completed beautifying all PowerShell script files." -ForegroundColor Green
Pop-Location
