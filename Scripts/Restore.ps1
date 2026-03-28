$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$baseDirectory/Scripts/"
try {
  ./Scoop/ScoopRestore.ps1
  ./Powershell/PowerShellRestore.ps1
  ./PowerToys/PowerToysRestore.ps1
  ./Config/ConfigRestore.ps1
  ./Komorebi/KomorebiRestore.ps1
  ./WindowsTerminal/WindowsTerminalRestore.ps1
}
finally {
  Pop-Location
}
