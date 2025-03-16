$sourcePath = "D:\Code\DxMessaging-Unity"
$backupDir = "Z:\Backup\Code\DxMessaging"
$date = Get-Date -Format "yyyy-MM-dd"
$zipFileName = "$date.zip"
$zipFilePath = "$env:TEMP\$zipFileName"
$maxBackups = 7

# Ensure destination directory exists
if (!(Test-Path $backupDir)) {
  Write-Host "Destination directory does not exist: $backupDir"
  exit 1
}

# Create ZIP archive excluding 'Library' directory
$excludedDirs = @("Library","obj","Builds","CodeCoverage","Logs","Temp")
$itemsToArchive = Get-ChildItem -Path $sourcePath -Exclude $excludedDirs | ForEach-Object { $_.FullName }
Compress-Archive -Path $itemsToArchive -DestinationPath $zipFilePath -Force

# Copy ZIP archive to network location using robocopy for speed
$robocopyCmd = "robocopy $env:TEMP $backupDir $zipFileName /MOV /NFL /NDL /NP /NJH"
Invoke-Expression $robocopyCmd

$backups = Get-ChildItem -Path $backupDir -Filter "*.zip" | Sort-Object LastWriteTime
if ($backups.Count -gt $maxBackups) {
  $toDelete = $backups | Select-Object -First ($backups.Count - $maxBackups)
  foreach ($file in $toDelete) {
    Remove-Item -Path $file.FullName -Force
  }
}


$backupCount = (Get-ChildItem -Path $backupDir -Filter "*.zip" | Measure-Object).Count
Write-Host "Backup completed: $backupDir\\$zipFileName"
Write-Host "Total backups in directory: $backupCount"
