$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$baseDirectory/Scripts/"
./Utils/FormatPowershellScripts.ps1
./WindowsTerminal/WindowsTerminalBackup.ps1
./Scoop/ScoopUpdate.ps1
./Scoop/ScoopBackup.ps1
./Komorebi/KomorebiBackup.ps1
$date = Get-Date
$dateString = "{0:yyyy/MM/dd hh:mm:ss}" -f $date
git add --all
git commit -m "Backup for $dateString"
git pull origin main
git push origin main
Pop-Location
