@echo off
echo Starting Unity launcher script...

set "EDITOR_RUNNING="
for /f %%i in ('tasklist ^| find "Unity.exe"') do set EDITOR_RUNNING=1

if defined EDITOR_RUNNING (
    echo Unity Editor process found
    echo Attempting to focus Unity Editor window...
    powershell -window hidden -command "$signature='[DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr hWnd);'; Add-Type -MemberDefinition $signature -Name Win32ShowWindow -Namespace Win32Functions; Get-Process Unity | ForEach-Object { [Win32Functions.Win32ShowWindow]::SetForegroundWindow($_.MainWindowHandle); }"
) else (
    echo Unity Editor process not found
    echo Checking for Unity Hub...
    
    set "HUB_RUNNING="
    for /f %%i in ('tasklist ^| find "Unity Hub.exe"') do set HUB_RUNNING=1
    
    if defined HUB_RUNNING (
        echo Unity Hub process found
        echo Attempting to focus Unity Hub...
        powershell -window hidden -command "$signature='[DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr hWnd);'; Add-Type -MemberDefinition $signature -Name Win32ShowWindow -Namespace Win32Functions; Get-Process 'Unity Hub' | ForEach-Object { [Win32Functions.Win32ShowWindow]::SetForegroundWindow($_.MainWindowHandle); }"
    ) else (
        echo No Unity processes found
        echo Launching Unity Editor...
        start "" "C:\Program Files\Unity\Hub\Editor\6000.0.23f1\Editor\Unity.exe"
    )
)