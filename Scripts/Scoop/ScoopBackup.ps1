$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
$baseDirectory = "$baseDirectory\.."
Push-Location "$baseDirectory/Config/"
scoop export --no-colour | Out-File -FilePath "scoopfile.json" -Encoding utf8
Pop-Location
