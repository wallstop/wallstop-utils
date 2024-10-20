$script_directory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location $script_directory
./ScoopRestore.ps1
Pop-Location