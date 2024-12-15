#NoEnv  ; Recommended for performance and compatibility with future AutoHotkey releases.
SendMode Input  ; Recommended for new scripts due to its superior speed and reliability.
SetWorkingDir %A_ScriptDir%  ; Ensures a consistent starting directory.
#Persistent  ; Keeps the script running

; Initialize variables
lastActiveWindow := ""
CoordMode, Mouse, Screen  ; Ensure mouse coordinates are in screen mode
CoordMode, Win, Screen    ; Ensure window coordinates are in screen mode

; Setup logging (optional, useful for debugging)
logFile := A_ScriptDir "\MouseCenterLog.txt"

; Function to write logs
WriteLog(msg) {
    global logFile
    FormatTime, timestamp,, yyyy-MM-dd HH:mm:ss
    FileAppend, % "[" timestamp "] " msg "`n", %logFile%
}

; Define excluded window classes (including taskbar previews)
excludedClasses := ["Progman", "WorkerW", "Shell_TrayWnd", "Button", "ApplicationFrameWindow", "Windows.UI.Core.CoreWindow", "#32770", "msctls_progress32", "DirectUIHWND"]
progressBarTitles := ["Progress", "Loading...", "Copying...", "Loading", "Copying", "Hold On", "Hold On..."]

; Set a timer to check active window every 100 milliseconds
SetTimer, WatchActiveWindow, 100
return  ; End of the auto-execute section

; Function to check if a window is a descendant of another
IsDescendantWindow(ancestorHWND, descendantHWND) {
    if (!ancestorHWND || !descendantHWND)
        return false
    current := descendantHWND
    while (current) {
        if (current = ancestorHWND)
            return true
        ; Get owner window using Windows API GetWindow with GW_OWNER (4)
        owner := DllCall("GetWindow", "ptr", current, "uint", 4, "ptr")
        if (!owner)
            break
        current := owner
    }
    return false
}

; Helper function to get window rect via WinAPI
GetWindowRect(hWnd) {
    VarSetCapacity(rect, 16, 0)
    if (DllCall("GetWindowRect", "ptr", hWnd, "ptr", &rect)) {
        left := NumGet(rect, 0, "int")
        top := NumGet(rect, 4, "int")
        right := NumGet(rect, 8, "int")
        bottom := NumGet(rect, 12, "int")
        return {left: left, top: top, right: right, bottom: bottom}
    }
    return {left: 0, top: 0, right: 0, bottom: 0}
}

WatchActiveWindow:
    ; Get the ID of the currently active window
    WinGet, activeWinID, ID, A

    ; Check if the active window has changed
    if (activeWinID != lastActiveWindow)
    {
        ; Get window title and class
        WinGetTitle, winTitle, ahk_id %activeWinID%
        WinGetClass, winClass, ahk_id %activeWinID%

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

        if (winTitle in progressBarTitles) {
            excluded := true
            return
        }

        if (excluded)
            return  ; Skip processing excluded windows

        ; If there was a previously active window, check if the new window is its descendant
        if (lastActiveWindow) {
            if (IsDescendantWindow(lastActiveWindow, activeWinID)) {
                WriteLog("New active window is a descendant of the last active window. No mouse movement.")
                ; Update last active window and exit
                lastActiveWindow := activeWinID
                return
            }
        }

        ; Optional: Add a short delay to ensure the window is ready
        Sleep, 50

        ; Get the window's position and size
        WinGetPos, winX, winY, winWidth, winHeight, ahk_id %activeWinID%

        ; Handle potential errors in retrieving window position
        if ErrorLevel {
            WriteLog("Failed to get window position for ID: " . activeWinID)
            ; Update last active window and exit
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
        MouseGetPos, mouseX, mouseY

        WriteLog("Current Mouse Position: " . mouseX . "," . mouseY)

        ; Check if the mouse is within the window's bounds
        if (mouseX >= winX && mouseX <= (winX + winWidth) && mouseY >= winY && mouseY <= (winY + winHeight)) {
            WriteLog("Mouse is already within the active window. No movement.")
            lastActiveWindow := activeWinID
            return
        }

        ; Check if the mouse is within any child controls of the active window
        ; This helps if there are child windows/controls outside the main window bounds
        WinGet, ChildList, ControlListHwnd, ahk_id %activeWinID%
        Loop, Parse, ChildList, `n
        {
            childHwnd := A_LoopField
            rect := GetWindowRect(childHwnd)
            if (mouseX >= rect.left && mouseX <= rect.right && mouseY >= rect.top && mouseY <= rect.bottom) {
                WriteLog("Mouse is within a child window/control of the active window. No movement.")
                lastActiveWindow := activeWinID
                return
            }
        }

        ; If we reach here, mouse is not inside the active window or any child windows/controls
        MouseMove, %centerX%, %centerY%, 0  ; The '0' speed makes the movement instant
        WriteLog("Mouse moved to center: " . centerX . "," . centerY)

        ; Update the last active window
        lastActiveWindow := activeWinID
    }
return
