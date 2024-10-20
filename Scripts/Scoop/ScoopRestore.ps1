$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$baseDirectory/Config/"
scoop import scoopfile.json
Pop-Location