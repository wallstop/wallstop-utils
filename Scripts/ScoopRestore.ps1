$base_directory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$base_directory/Config/"
scoop import scoopfile.json
Pop-Location