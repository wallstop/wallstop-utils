Option Explicit
Dim fso, logFile, scriptDir
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set logFile = fso.OpenTextFile(scriptDir & "\unity_focus.log", 8, True)

Sub WriteLog(message)
    logFile.WriteLine Now & " - " & message
End Sub

WriteLog "Starting focus script..."
Dim searchString
searchString = WScript.Arguments(0)
WriteLog "Searching for window containing: " & searchString

Dim WshShell
Set WshShell = CreateObject("WScript.Shell")

WriteLog "Starting focus attempts..."
Dim i
For i = 1 To 3
    WriteLog "Attempt " & i & " of 3"
    
    Dim objWMIService, colProcesses
    Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")
    Set colProcesses = objWMIService.ExecQuery("Select * from Win32_Process")
    
    Dim Process
    For Each Process in colProcesses
        On Error Resume Next
        Dim title
        title = Process.CommandLine
        
        If Err.Number = 0 Then
            WriteLog "Found process: " & title
            If InStr(1, title, searchString, 1) > 0 Then
                WriteLog "Found matching window. Attempting to activate..."
                WshShell.AppActivate title
                WriteLog "Activate command sent"
                WScript.Sleep 50
                Exit For
            End If
        End If
        On Error Goto 0
    Next
    
    WriteLog "Completed attempt " & i
Next

WriteLog "Script complete"
logFile.Close