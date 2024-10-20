$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$baseDirectory/Scripts/"
./Scoop/ScoopRestore.ps1
./WindowsTerminal/WindowsTerminalRestore.ps1
/.Config/ConfigRestore.ps1
Pop-Location