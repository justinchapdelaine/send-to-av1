# Send to AV1

Send to AV1 is a small Windows utility that adds **Send to AV1** items to the Windows **Send to** menu.

It converts selected video files to AV1 using FFmpeg, writing MKV by default while preserving the original files.

## Quick start

1. Double-click `Install-SendTo.cmd`.
2. Approve the FFmpeg download prompt if you want a portable FFmpeg install.
3. Select one or more videos in File Explorer.
4. Right-click, choose **Send to**, then choose **Send to AV1** or **Send to AV1 - NVIDIA**.

The installer creates these per-user launchers:

```text
%APPDATA%\Microsoft\Windows\SendTo\Send to AV1.cmd
%APPDATA%\Microsoft\Windows\SendTo\Send to AV1 - NVIDIA.cmd
```

No administrator rights are required. The launchers point to `src\Optimize-AV1.ps1` in the current project folder, so run `Install-SendTo.cmd` again if you move the folder.

## What it does

Send to AV1 will:

- create a new AV1 file beside the original video, using MKV by default
- leave the original video untouched
- copy audio, subtitles, chapters, attachments, and metadata where possible
- skip obvious non-video files with a clear message
- skip files that are already AV1 when `ffprobe` is available
- print FFmpeg capability and progress information in a console window
- process multiple selected files sequentially
- print a summary at the end

## FFmpeg

FFmpeg is **not included** in the source repository.

Send to AV1 looks for FFmpeg in this order:

1. Local tools in the project root:
   - `bin/ffmpeg.exe`
   - `bin/ffprobe.exe`
2. System PATH:
   - `ffmpeg`
   - `ffprobe`

During install, Send to AV1 checks the local `bin` folder and can download or update portable FFmpeg tools when you approve the prompt. If GitHub cannot be reached but local FFmpeg tools are already installed, the installer keeps using them.

Download or update portable FFmpeg manually:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Download-FFmpeg.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Download-FFmpeg.ps1 -Architecture x64
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Download-FFmpeg.ps1 -Architecture arm64
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Download-FFmpeg.ps1 -Force
```

The downloader uses BtbN's GPL Windows builds, supports x64 and ARM64, chooses the native Windows architecture by default, installs only `ffmpeg.exe` and `ffprobe.exe` into `bin`, and prints whether the installed FFmpeg exposes `libsvtav1`, `av1_nvenc`, and NVIDIA HQ/UHQ tune support.

## Presets

### Send to AV1

The default storage preset uses CPU-based SVT-AV1 for maximum compression efficiency:

```text
Container: MKV
Video encoder: libsvtav1
CRF: 30
Preset: 6
Pixel format: yuv420p10le
Audio/subtitles/metadata/chapters: copied where possible
```

### Send to AV1 - NVIDIA

The NVIDIA preset uses GPU-based AV1 NVENC for much faster conversion on supported NVIDIA GPUs:

```text
Container: MKV
Video encoder: av1_nvenc
Preset: p7
Tune: uhq when available, otherwise hq
Rate control: vbr
CQ: 28
Pixel format: p010le
Audio/subtitles/metadata/chapters: copied where possible
```

NVIDIA mode requires both FFmpeg `av1_nvenc` support and an NVIDIA GPU/driver with AV1 encode support. Seeing `av1_nvenc` in the capability summary means the FFmpeg build exposes the encoder; it does not prove this computer has NVIDIA hardware.

## Manual usage

Run the optimizer directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 "C:\Path\Video.mp4"
```

NVIDIA mode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -Encoder nvenc "C:\Path\Video.mp4"
```

Advanced parameters:

```powershell
# CPU/SVT tuning
-Crf 30 -Preset 6

# NVIDIA tuning
-NvencPreset p7 -NvencTune auto -NvencCq 28  # CQ range: 0-63

# Output container
-OutputContainer mkv  # default
-OutputContainer mp4  # optional, less compatible with copied streams

# Checks without encoding
-Diagnostics
-DryRun
```

Diagnostics mode prints FFmpeg, FFprobe, SVT-AV1, NVIDIA AV1 NVENC, and NVIDIA tune support without requiring input files:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -Diagnostics
```

Dry-run mode resolves inputs, chooses output names, and prints the FFmpeg command without starting an encode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -DryRun "C:\Path\Video.mp4"
```

## Safety behavior

Send to AV1 is designed to be conservative:

- original files are never modified
- original files are never deleted
- FFmpeg downloads are explicit and prompted; conversion does not auto-download binaries
- incomplete temporary output files are deleted if encoding fails
- final output filenames are collision-safe
- successful outputs are kept even if they are larger than the original, but a warning is printed

## Output naming

For an input file named:

```text
Example.mp4
```

The default output will be:

```text
Example_AV1.mkv
```

If that file already exists, Send to AV1 will use:

```text
Example_AV1_2.mkv
Example_AV1_3.mkv
...
```

You can choose MP4 with `-OutputContainer mp4`, but MKV remains the default because it is more forgiving when copying audio, subtitles, attachments, chapters, and metadata from many source formats.

## Uninstall

Double-click `Uninstall-SendTo.cmd`, or run it from Command Prompt:

```cmd
Uninstall-SendTo.cmd
```

## Development checks

Run the lightweight repository checks without FFmpeg:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Repository.ps1
```

## Known limitations

- Windows 11 may place **Send to** under the legacy context menu path depending on your system and Explorer behavior.
- This is not a video editor or general-purpose converter.
- Dolby Vision/HDR edge cases are not specially handled in v1.
- If `ffprobe` is unavailable, the script may not detect already-AV1 inputs before attempting conversion. It will still skip files with extensions that are not recognized as common video types.
- NVIDIA mode requires an NVIDIA GPU with AV1 encode support. Having an NVIDIA GPU is not enough by itself.
- NVIDIA UHQ support depends on your FFmpeg build, NVIDIA driver, and Video Codec SDK support. If UHQ is unavailable, the script falls back to HQ.
- MP4 output can fail when copied streams are not compatible with the MP4 container. Use the default MKV container for maximum preservation.
- Portable FFmpeg downloads require GitHub access because BtbN publishes builds through GitHub releases.
- Install/uninstall are CMD-based, but the optimizer itself still uses PowerShell. The launcher prefers PowerShell 7 when installed and falls back to Windows PowerShell 5.1. If your computer is heavily locked down by Group Policy, PowerShell script execution may still be blocked.

## License

Send to AV1 is licensed under the GNU General Public License v3.0 or later.

See [`LICENSE`](LICENSE).

## Third-party software

This project uses FFmpeg when available, but the source repository does not include FFmpeg binaries.

The optional downloader retrieves BtbN FFmpeg builds from GitHub releases. FFmpeg and BtbN builds are separate projects with their own license terms. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
