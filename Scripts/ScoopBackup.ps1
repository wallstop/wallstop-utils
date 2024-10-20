$root_directory = git rev-parse --show-toplevel
Push-Location "$root_directory"
scoop export -c > Config/scoopfile.json
$content = Get-Content -Path Config/scoopfile.json -Encoding Unicode
$content | Out-File -FilePath COnfig/scoopfile.json -Encoding utf8
Pop-Location