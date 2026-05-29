Stop-Process -Name "komorebi" -ErrorAction SilentlyContinue
Stop-Process -Name "whkd" -ErrorAction SilentlyContinue

$configPath = Join-Path $env:USERPROFILE "komorebi.json"
komorebic start --config $configPath --whkd --clean-state
