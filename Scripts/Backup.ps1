$script_directory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Write-Host "Found: $script_directory"
Push-Location $script_directory
./ScoopUpdate.ps1
./ScoopBackup.ps1
$date = Get-Date
$date_string = "{0:yyyy/MM/dd hh:mm:ss}" -f $date
git add --all
git commit -m "Backup for $date_string"
git pull origin main
git push origin main
Pop-Location