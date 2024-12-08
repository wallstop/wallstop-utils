@echo off
echo Starting Unity launcher script...

set "EDITOR_RUNNING="
set "EDITOR_NAME="
for /f "tokens=*" %%i in ('tasklist ^| find "Unity.exe"') do (
    set EDITOR_RUNNING=1
    set "EDITOR_NAME=%%i"
)

if defined EDITOR_RUNNING (
    echo Unity Editor process found: %EDITOR_NAME%
    echo Attempting to focus Unity Editor window...
    start "" wscript //nologo "%~dp0Focus.vbs" "%EDITOR_NAME%"
    echo Focus attempt completed
) else (
    echo Unity Editor process not found
    echo Checking for Unity Hub...
    
    set "HUB_RUNNING="
    set "HUB_NAME="
    for /f "tokens=*" %%i in ('tasklist ^| find "Unity Hub.exe"') do (
        set HUB_RUNNING=1U
        set "HUB_NAME=%%i"
    )
    
    if defined HUB_RUNNING (
        echo Unity Hub process found: %HUB_NAME%
        echo Attempting to focus Unity Hub...
        start "" wscript //nologo "%~dp0Focus.vbs" "%HUB_NAME%"
        echo Focus attempt completed
    ) else (
        echo No Unity processes found
        echo Launching Unity Editor...
        start "" "C:\Program Files\Unity\Hub\Editor\6000.0.23f1\Editor\Unity.exe"
        echo Launch command sent
    )
)
echo Script complete