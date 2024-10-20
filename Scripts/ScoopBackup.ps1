$script_directory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$script_directory/../Config/"
scoop export -c > scoopfile.json
$content = Get-Content -Path scoopfile.json -Encoding Unicode
$content | Out-File -FilePath scoopfile.json -Encoding utf8
Pop-Location