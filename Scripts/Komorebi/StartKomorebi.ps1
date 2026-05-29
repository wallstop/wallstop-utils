$configPath = Join-Path $env:USERPROFILE "komorebi.json"
komorebic start --config $configPath --whkd --clean-state
