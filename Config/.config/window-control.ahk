#Requires AutoHotkey v2.0

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
#Down:: {
    global minimizedWindows
    try {
        activeWin := WinGetID("A")
    } catch {
        return
    }
    if (activeWin) {
        WinMinimize("ahk_id " activeWin)
        minimizedWindows.Push(activeWin)
    }
}

; Hotkey: Win + Up to restore the last minimized window or toggle maximize/unmaximize
#Up:: {
    global minimizedWindows
    if (minimizedWindows.Length > 0) {
        lastMinimized := minimizedWindows.Pop()
        WinRestore("ahk_id " lastMinimized)
        WinActivate("ahk_id " lastMinimized)
    } else {
        try {
            winState := WinGetMinMax("A")
        } catch {
            return
        }
        if (winState == 1) {
            WinRestore("A")
        } else if (winState == 0) {
            WinMaximize("A")
        }
        ; No action needed if the window is minimized, as it's already handled
    }
}

#+Up:: {
    try {
        winState := WinGetMinMax("A")
    } catch {
        return
    }
    if (winState == 1) {
        WinRestore("A")
    } else if (winState == 0) {
        WinMaximize("A")
    }
}

; Remove window from stack if it's closed so the stack stays accurate
SetTimer(WatchWindows, 1000)

WatchWindows() {
    global minimizedWindows
    Loop minimizedWindows.Length {
        index := minimizedWindows.Length - A_Index + 1
        winID := minimizedWindows[index]
        if (!WinExist("ahk_id " winID)) {
            minimizedWindows.RemoveAt(index)
        }
    }
}
