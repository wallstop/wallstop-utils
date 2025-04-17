Stop-Process -Name "komorebi" -ErrorAction SilentlyContinue
Stop-Process -Name "whkd" -ErrorAction SilentlyContinue
komorebic start --whkd
