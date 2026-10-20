' SPDX-License-Identifier: GPL-3.0-or-later
Option Explicit
Dim shell, files, installer
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
installer = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "Install-SendTo.vbs")
If Not files.FileExists(installer) Then
    MsgBox "Install-SendTo.vbs was not found. Restore the project files before uninstalling.", vbCritical, "Send to AV1 setup"
    WScript.Quit 1
End If
On Error Resume Next
shell.Environment("PROCESS")("SEND_TO_AV1_SETUP_BOOTSTRAP") = installer
shell.Run "wscript.exe //nologo ""%SEND_TO_AV1_SETUP_BOOTSTRAP%"" --uninstall", 0, False
If Err.Number <> 0 Then
    MsgBox "Uninstall could not start: " & Err.Description, vbCritical, "Send to AV1 setup"
    WScript.Quit 1
End If
