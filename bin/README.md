# Local FFmpeg tools

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
