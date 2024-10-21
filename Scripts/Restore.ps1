$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$baseDirectory/Scripts/"
try {
  ./Scoop/ScoopRestore.ps1
  ./WindowsTerminal/WindowsTerminalRestore.ps1
  ./Config/ConfigRestore.ps1
  ./Komorebi/KomorebRestore.ps1
}
finally {
  Pop-Location
}
