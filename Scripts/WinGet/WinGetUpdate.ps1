winget upgrade --all --silent
$wingetExitCode = $LASTEXITCODE

# WinGet reports "no applicable upgrade found" as a non-zero HRESULT even
# though the requested no-op update completed successfully.
if ($wingetExitCode -eq -1978335189) {
    Write-Host "WinGet: no applicable upgrades found; treating the no-op as successful."
    exit 0
}

exit $wingetExitCode
