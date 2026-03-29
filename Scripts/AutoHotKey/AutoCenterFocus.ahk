#Requires AutoHotkey v2.0

SendMode("Input")
SetWorkingDir(A_ScriptDir)
CoordMode("Mouse", "Screen")
CoordMode("Win", "Screen")

global lastActiveWindow := ""

; Define excluded window classes (including taskbar previews)
global excludedClasses := ["Progman", "WorkerW", "Shell_TrayWnd", "Button", "ApplicationFrameWindow", "Windows.UI.Core.CoreWindow", "#32770", "msctls_progress32", "DirectUIHWND"]
global progressBarTitles := ["Progress", "Loading...", "Copying...", "Loading", "Copying", "Hold On", "Hold On..."]

SetTimer(WatchActiveWindow, 100)

; Function to write logs
WriteLog(msg) {
}

; Returns true if val equals any element in arr (case-insensitive)
ArrayIncludes(arr, val) {
    for _, item in arr {
        if (item = val) {
            return true
        }
    }
    return false
}

; Function to check if a window is a descendant of another via owner chain
IsDescendantWindow(ancestorHWND, descendantHWND) {
    if (!ancestorHWND || !descendantHWND) {
        return false
    }
    current := descendantHWND
    while (current) {
        if (current = ancestorHWND) {
            return true
        }
        ; Get owner window using Windows API GetWindow with GW_OWNER (4)
        owner := DllCall("GetWindow", "Ptr", current, "UInt", 4, "Ptr")
        if (!owner) {
            break
        }
        current := owner
    }
    return false
}

; Helper function to get window rect via WinAPI
GetWindowRect(hWnd) {
    rect := Buffer(16, 0)
    if (DllCall("GetWindowRect", "Ptr", hWnd, "Ptr", rect)) {
        left   := NumGet(rect, 0,  "Int")
        top    := NumGet(rect, 4,  "Int")
        right  := NumGet(rect, 8,  "Int")
        bottom := NumGet(rect, 12, "Int")
        return {left: left, top: top, right: right, bottom: bottom}
    }
    return {left: 0, top: 0, right: 0, bottom: 0}
}

WatchActiveWindow() {
    global lastActiveWindow, excludedClasses, progressBarTitles

    try {
        activeWinID := WinGetID("A")
    } catch {
        return
    }
    if (!activeWinID) {
        return
    }

    ; Check if the active window has changed
    if (activeWinID != lastActiveWindow) {
        ; Get window title and class
        try {
            winTitle := WinGetTitle("ahk_id " activeWinID)
            winClass := WinGetClass("ahk_id " activeWinID)
        } catch {
            lastActiveWindow := activeWinID
            return
        }

        WriteLog("New Active Window ID: " . activeWinID . " | Title: " . winTitle . " | Class: " . winClass)

        ; Check if window class is excluded
        excluded := false
        for index, className in excludedClasses {
            if (winClass = className) {
                excluded := true
                WriteLog("Excluded Window Detected: " . winClass)
                lastActiveWindow := activeWinID
                break
            }
        }

        if (ArrayIncludes(progressBarTitles, winTitle)) {
            excluded := true
            return
        }

        if (excluded) {
            return
        }

        ; If there was a previously active window, check if the new window is its descendant
        if (lastActiveWindow) {
            if (IsDescendantWindow(lastActiveWindow, activeWinID)) {
                WriteLog("New active window is a descendant of the last active window. No mouse movement.")
                lastActiveWindow := activeWinID
                return
            }
        }

        Sleep(50)

        ; Get the window's position and size
        try {
            WinGetPos(&winX, &winY, &winWidth, &winHeight, "ahk_id " activeWinID)
        } catch {
            WriteLog("Failed to get window position for ID: " . activeWinID)
            lastActiveWindow := activeWinID
            return
        }

        if (winHeight < 400) {
            return
        }

        if (winWidth < 400) {
            return
        }

        WriteLog("Window Position: " . winX . "," . winY . " Size: " . winWidth . "x" . winHeight)

        ; Calculate the center coordinates of the window
        centerX := winX + (winWidth // 2)
        centerY := winY + (winHeight // 2)

        ; Get the current mouse position
        MouseGetPos(&mouseX, &mouseY)

        WriteLog("Current Mouse Position: " . mouseX . "," . mouseY)

        ; Check if the mouse is within the window's bounds
        if (mouseX >= winX && mouseX <= (winX + winWidth) && mouseY >= winY && mouseY <= (winY + winHeight)) {
            WriteLog("Mouse is already within the active window. No movement.")
            lastActiveWindow := activeWinID
            return
        }

        ; Check if the mouse is within any child controls of the active window
        try {
            childControls := WinGetControlsHwnd("ahk_id " activeWinID)
        } catch {
            childControls := []
        }
        for childHwnd in childControls {
            rect := GetWindowRect(childHwnd)
            if (mouseX >= rect.left && mouseX <= rect.right && mouseY >= rect.top && mouseY <= rect.bottom) {
                WriteLog("Mouse is within a child window/control of the active window. No movement.")
                lastActiveWindow := activeWinID
                return
            }
        }

        ; Mouse is not inside the active window or any child windows — move it to center
        MouseMove(centerX, centerY, 0)
        WriteLog("Mouse moved to center: " . centerX . "," . centerY)

        lastActiveWindow := activeWinID
    }
}
