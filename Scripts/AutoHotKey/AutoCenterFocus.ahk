#NoEnv  ; Recommended for performance and compatibility with future AutoHotkey releases.
SendMode Input  ; Recommended for new scripts due to its superior speed and reliability.
SetWorkingDir %A_ScriptDir%  ; Ensures a consistent starting directory.
#Persistent  ; Keeps the script running

; Initialize variables
lastActiveWindow := ""
CoordMode, Mouse, Screen  ; Ensure mouse coordinates are in screen mode
CoordMode, Win, Screen  ; Ensure window coordinates are in screen mode

; Set a timer to check active window every 100 milliseconds
SetTimer, WatchActiveWindow, 100
return  ; End of the auto-execute section

WatchActiveWindow:
    ; Get the ID of the currently active window
    WinGet, activeWinID, ID, A

    ; Check if the active window has changed
    if (activeWinID != lastActiveWindow)
    {
        lastActiveWindow := activeWinID  ; Update the last active window ID

       ; Optional: Add a short delay to ensure the window is ready
        Sleep, 50

        ; Get the position and size of the active window
        WinGetPos, winX, winY, winWidth, winHeight, ahk_id %activeWinID%

        ; Handle potential errors in retrieving window position
        if ErrorLevel
        {
            ; Could not get window position, exit the subroutine
            return
        }

        ; Calculate the center coordinates of the window
        centerX := winX + (winWidth // 2)
        centerY := winY + (winHeight // 2)

        ; Get the current mouse position
        MouseGetPos, mouseX, mouseY

        ; Check if the mouse is within the window's bounds
        if (mouseX >= winX && mouseX <= (winX + winWidth) && mouseY >= winY && mouseY <= (winY + winHeight))
        {
            ; Mouse is already within the active window; do not move
            return
        }

        ; Move the mouse cursor to the center of the active window
        MouseMove, %centerX%, %centerY%, 0  ; The '0' speed makes the movement instant
    }
return