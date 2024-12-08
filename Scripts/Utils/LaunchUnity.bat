@echo off
echo Starting Unity launcher script...

set "EDITOR_RUNNING="
for /f %%i in ('tasklist ^| find "Unity.exe"') do set EDITOR_RUNNING=1

if defined EDITOR_RUNNING (
    echo Unity Editor process found
    echo Attempting to focus Unity Editor window...
    start "" wscript //nologo "%~dp0Focus.vbs" "6000.0.23f1"
    echo Focus attempt completed
) else (
    echo Unity Editor process not found
    echo Checking for Unity Hub...
    
    set "HUB_RUNNING="
    for /f %%i in ('tasklist ^| find "Unity Hub.exe"') do set HUB_RUNNING=1
    
    if defined HUB_RUNNING (
        echo Unity Hub process found
        echo Attempting to focus Unity Hub...
        start "" wscript //nologo "%~dp0Focus.vbs" "Unity Hub"
        echo Focus attempt completed
    ) else (
        echo No Unity processes found
        echo Launching Unity Editor...
        start "" "C:\Program Files\Unity\Hub\Editor\6000.0.23f1\Editor\Unity.exe"
        echo Launch command sent
    )
)
echo Script complete
pause