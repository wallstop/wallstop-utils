$script_directory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$script_directory/../Config/"
scoop import scoopfile.json
Pop-Location