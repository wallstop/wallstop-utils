; ============================================
; WindowManager.ahk
; ============================================
; This script assigns custom hotkeys for window management:
; - Win + Down: Minimize the active window.
; - Win + Up: Restore the last minimized window or toggle full-screen if no windows are minimized.
; ============================================

; Initialize an empty array to keep track of minimized window IDs
minimizedWindows := []

; Hotkey: Win + Down to minimize the active window
#Down::
    ; Get the ID of the currently active window
    WinGet, activeWin, ID, A
    if (activeWin)
    {
        ; Minimize the active window
        WinMinimize, ahk_id %activeWin%
        ; Add the window ID to the stack
        minimizedWindows.Push(activeWin)
    }
    return

; Hotkey: Win + Up to restore the last minimized window or toggle maximize/unmaximize
#Up::
    if (minimizedWindows.Length() > 0)
    {
        ; There are minimized windows to restore
        lastMinimized := minimizedWindows.Pop()
        ; Restore the window
        WinRestore, ahk_id %lastMinimized%
        ; Activate the window to bring it to the foreground
        WinActivate, ahk_id %lastMinimized%
    }
    else
    {
        ; No minimized windows; toggle maximize/unmaximize on the active window
        ; Get the active window's state
        WinGet, winState, MinMax, A
        if (winState == 1) ; If maximized
        {
            ; Unmaximize the window (restore to original size)
            WinRestore, A
        }
        else if (winState == 0) ; If in normal state
        {
            ; Maximize the window
            WinMaximize, A
        }
        ; No action needed if the window is minimized, as it's already handled
    }
    return

; Optional: Remove window from stack if it's closed
; This ensures that the stack remains accurate even if windows are closed externally
#Persistent
SetTimer, WatchWindows, 1000
return

WatchWindows:
    ; Iterate through the minimizedWindows stack backwards and remove any window IDs that no longer exist
    Loop, % minimizedWindows.Length()
    {
        index := minimizedWindows.Length() - A_Index + 1
        winID := minimizedWindows[index]
        if (!WinExist("ahk_id " winID))
        {
            minimizedWindows.RemoveAt(index)
        }
    }
    return
