Option Explicit
Dim WshShell
Set WshShell = CreateObject("WScript.Shell")

Dim processName
processName = WScript.Arguments(0)

Dim i
For i = 1 To 3
    On Error Resume Next
    WshShell.AppActivate processName
    WScript.Sleep 50
Next