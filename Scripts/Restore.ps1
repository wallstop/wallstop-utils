$base_directory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$base_directory/Scripts/"
./ScoopRestore.ps1
Pop-Location