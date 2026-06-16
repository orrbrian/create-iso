' Launches New-IsoFromFolder.ps1 with no visible console window.
'
' powershell.exe is a console-subsystem process, so even with
' -WindowStyle Hidden it briefly flashes a console. wscript.exe is
' GUI-subsystem, so when it starts powershell with Run(..., 0, False)
' the console is created hidden and nothing is ever shown on screen.
'
' Arguments passed to this script are forwarded verbatim to the .ps1
' (the shell passes the clicked folder path as the first argument).

Option Explicit

Dim fso, shell, scriptDir, ps1Path, argString, i, cmdLine

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path   = fso.BuildPath(scriptDir, "New-IsoFromFolder.ps1")

argString = ""
For i = 0 To WScript.Arguments.Count - 1
    argString = argString & " """ & WScript.Arguments(i) & """"
Next

cmdLine = "powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File """ _
        & ps1Path & """" & argString

' 0 = SW_HIDE, False = don't wait for PowerShell to exit
shell.Run cmdLine, 0, False
