$baseDirectory = [IO.Path]::GetDirectoryName((Split-Path -Path $MyInvocation.MyCommand.Definition))
Push-Location "$baseDirectory/Scripts/"
try {
  ./Utils/FormatPowershellScripts.ps1
  ./Komorebi/StopKomorebi.ps1
  ./Scoop/ScoopUpdate.ps1
  ./WinGet/WinGetUpdate.ps1
} finally {
  Pop-Location
}
