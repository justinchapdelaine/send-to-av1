# Local tools

Place optional portable FFmpeg binaries here:

```text
bin/ffmpeg.exe
bin/ffprobe.exe
```

These binaries are not included in the source repository. If they are not present, Send to AV1 falls back to `ffmpeg` and `ffprobe` from the system PATH.

You can install or update BtbN portable FFmpeg tools with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ..\src\Download-FFmpeg.ps1
```

The Send to installer also builds `SendToAV1.Launcher.exe` here from `src/SendToAv1Launcher.cs`, using the .NET Framework C# compiler included with Windows. This small GUI executable starts PowerShell without creating a console window. Re-running the installer rebuilds it and updates the shortcuts. The generated executable is ignored by Git.
