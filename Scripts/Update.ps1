Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptsDirectory = (Resolve-Path -LiteralPath $PSScriptRoot -ErrorAction Stop).Path
Push-Location -LiteralPath $scriptsDirectory
try {
    ./Utils/FormatPowershellScripts.ps1
    ./Komorebi/StopKomorebi.ps1
    ./Scoop/ScoopUpdate.ps1
    ./WinGet/WinGetUpdate.ps1
}
finally {
    Pop-Location
}
