' SPDX-License-Identifier: GPL-3.0-or-later
Option Explicit
Dim shell, files, scriptPath, hostPath, command, uninstall
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
scriptPath = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "src\Show-AV1Setup.ps1")
If Not files.FileExists(scriptPath) Then
    MsgBox "The setup script was not found. Extract the entire project before running setup.", vbCritical, "Send to AV1 setup"
    WScript.Quit 1
End If
uninstall = False
If WScript.Arguments.Count > 0 Then
    If WScript.Arguments.Count <> 1 Or LCase(WScript.Arguments(0)) <> "--uninstall" Then WScript.Quit 1
    uninstall = True
End If
' Windows PowerShell is included with Windows and supports WPF without an SDK.
hostPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
Dim environment
Set environment = shell.Environment("PROCESS")
environment("SEND_TO_AV1_SETUP_HOST") = hostPath
environment("SEND_TO_AV1_SETUP_SCRIPT") = scriptPath
' Run expands environment variables once; placeholders preserve literal % in paths.
command = """%SEND_TO_AV1_SETUP_HOST%"" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%SEND_TO_AV1_SETUP_SCRIPT%"""
If uninstall Then command = command & " -Uninstall"
' Starting hidden through Windows Script Host keeps the console hidden from startup.
On Error Resume Next
shell.Run command, 0, False
If Err.Number <> 0 Then
    MsgBox "Setup could not start: " & Err.Description, vbCritical, "Send to AV1 setup"
    WScript.Quit 1
End If
