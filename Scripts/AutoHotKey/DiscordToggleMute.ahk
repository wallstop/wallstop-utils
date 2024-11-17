^Space::
    ; Check if Discord is running
    IfWinExist, ahk_exe Discord.exe
    {
        ; Activate Discord window
        WinActivate, ahk_exe Discord.exe
        ; Wait for the window to be active
        WinWaitActive, ahk_exe Discord.exe
        ; Send the Discord mute toggle keybind
        Send, ^+m
    }
    else
    {
        MsgBox, Discord is not running.
    }
    return
