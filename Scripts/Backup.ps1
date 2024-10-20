.\ScoopUpdate.ps1
.\ScoopBackup.ps1
git add --all
$date = Get-Date
$date_string = "{0:yyyy/MM/dd hh:mm:ss}" -f $date
git commit -m "Backup for $date_string"
git push origin main