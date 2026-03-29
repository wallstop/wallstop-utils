#Requires AutoHotkey v2.0

^Space:: {
    if WinExist("ahk_exe Discord.exe") {
        WinActivate("ahk_exe Discord.exe")
        WinWaitActive("ahk_exe Discord.exe")
        Send("^+m")
    } else {
        MsgBox("Discord is not running.")
    }
}
