# Send to AV1

Send to AV1 is a small Windows utility that adds **Send to AV1** items to the Windows **Send to** menu.

It converts selected video files to AV1 using FFmpeg, writing MKV by default while preserving the original files.

## Quick start

1. Double-click `Install-SendTo.cmd`.
2. Approve the FFmpeg download prompt if you want a portable FFmpeg install.
3. Select one or more videos in File Explorer.
4. Right-click, choose **Send to**, then choose **Send to AV1**, **Send to AV1 - NVIDIA**, or **Send to AV1 - Small**.

The installer creates these per-user launchers:

```text
%APPDATA%\Microsoft\Windows\SendTo\Send to AV1.lnk
%APPDATA%\Microsoft\Windows\SendTo\Send to AV1 - NVIDIA.lnk
%APPDATA%\Microsoft\Windows\SendTo\Send to AV1 - Small.lnk
```

No administrator rights are required. The shortcuts open a WPF progress window using `src\Show-AV1Progress.ps1` in the current project folder, so run `Install-SendTo.cmd` again if you move the folder. Re-running the installer upgrades existing `.cmd` launchers to shortcuts and removes the old entries. Encoding starts automatically with the mode chosen in the Send to menu.

The installer also builds `bin\SendToAV1.Launcher.exe` from the included C# source using Windows' .NET Framework compiler. The shortcuts use this small Windows GUI executable to start PowerShell without creating a console window. No separate SDK download is needed on a standard Windows desktop installation. Run the installer again to upgrade older shortcuts that pointed directly to PowerShell.

## What it does

Send to AV1 will:

- create a new AV1 file beside the original video, using MKV by default
- leave the original video untouched
- copy audio, subtitles, chapters, attachments, and metadata where possible
- omit data and unknown streams, such as MOV timecode tracks, that can prevent conversion to MKV
- skip obvious non-video files with a clear message
- skip files that are already AV1 when `ffprobe` is available, except in Small mode
- show a progress window with processed video time, elapsed time, and estimated time remaining
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
CRF: 34
Preset: 5
Keyframe interval: approximately 10 seconds (adapts to frame rate)
SVT parameters: keyint=10s:tune=0
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
CQ: 32
Pixel format: p010le
Audio/subtitles/metadata/chapters: copied where possible
```

NVIDIA mode requires both FFmpeg `av1_nvenc` support and an NVIDIA GPU/driver with AV1 encode support. Seeing `av1_nvenc` in the capability summary means the FFmpeg build exposes the encoder; it does not prove this computer has NVIDIA hardware.

### Send to AV1 - Small

The small-file preset uses CPU/SVT-AV1 at **CRF 38**, with preset 5, the same approximately 10-second keyframe interval, and the same 10-bit settings as the default CPU mode. Video fits within **1280x720**, preserving aspect ratio and never upscaling smaller inputs (output dimensions are even for 4:2:0 video).

Small mode **allows re-encoding existing AV1 files**, including OBS NVENC AV1 recordings. Re-encoding and downscaling sacrifice quality to reduce size; a smaller output is not guaranteed. All audio tracks are copied unchanged, along with other non-video streams where supported. Originals and existing outputs are preserved using the usual output naming rules.

Run `Install-SendTo.cmd` again to add the new menu entry to an existing installation.

## Manual usage

The console interface remains available for scripts and troubleshooting. It uses the same encoding engine as the progress window. Run it directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 "C:\Path\Video.mp4"
```

NVIDIA mode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -Encoder nvenc "C:\Path\Video.mp4"
```

Small-file mode (also accepts AV1 input):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -Small "C:\Path\Recording.mkv"
```

`-Small` defaults to CRF 38; pass `-Crf` to override it, for example `-Small -Crf 40`. It cannot be combined with `-Encoder nvenc`. Other modes retain their existing defaults and skip already-AV1 files.

Advanced parameters:

```powershell
# CPU/SVT tuning
-Crf 34 -Preset 5

# NVIDIA tuning
-NvencPreset p7 -NvencTune auto -NvencCq 32  # CQ range: 0-63

# Output container
-OutputContainer mkv  # default
-OutputContainer mp4  # optional, less compatible with copied streams

# Checks without encoding
-Diagnostics
-DryRun

# Keep detailed encoder diagnostics in the system temp folder
-KeepLog
```

Diagnostics mode prints FFmpeg, FFprobe, SVT-AV1, NVIDIA AV1 NVENC, and NVIDIA tune support without requiring input files:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -Diagnostics
```

Dry-run mode resolves inputs, chooses output names, and prints the FFmpeg command without starting an encode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -DryRun "C:\Path\Video.mp4"
```

## Encoding progress and diagnostics

The Send to entries use a windowless launcher to open the Windows WPF window without a console flash. The current filename is the main heading, with the mode and batch position beneath it. A blue progress bar and prominent percentage show encoding progress. Separate timing fields show an approximate remaining time (for example, "About 8 minutes"), elapsed time, and processed video time. Hover over the estimate for a precise timestamp. A background worker performs the encoding so the window remains responsive. Manual console use shows the corresponding text progress bar.

FFprobe supplies the total duration and FFmpeg supplies structured progress timestamps. The estimate changes with encoding speed; completion is reported only after FFmpeg succeeds and the output file is finalized.

Use **Cancel** to stop the current encode and the remaining batch. The worker stops FFmpeg and removes the incomplete output; previously completed outputs and original files are kept. Closing the window during encoding asks whether to cancel, then leaves the window open until cleanup finishes. Afterward, use **Close** to dismiss it.

Cancellation also stops FFprobe and capability checks during video inspection. Each inspection process has a 30-second timeout. A timed-out codec probe skips that file with a warning; a timed-out duration probe continues without a duration estimate. Timeouts on required capability checks are reported as failures.

The window starts compact, with the results list hidden until there is a completed, skipped, failed, or cancelled file to report. It grows to show results and expanded details, with scrolling for longer batches and smaller screens. Each result has a status icon, filename, and readable size comparison; the full output path is secondary. Green indicates successful completion, amber indicates warnings or larger outputs, and red indicates failures. **Open output folder** opens the folder of the most recently completed output. **Details** opens automatically for errors and includes precise progress timestamps; it remains collapsed during normal operation. The window stays open when the batch finishes so the results can be reviewed.

The window and Send to shortcuts use the bundled AV1 icon. Re-run the installer after updating to rebuild the launcher with the new icon and refresh the shortcut icons.

If the duration is unavailable, the display shows processed and elapsed time without a percentage or remaining-time estimate. Full capability information remains available with `-Diagnostics`.

Detailed FFmpeg/SVT output goes to a temporary diagnostic log. Error-level diagnostics are still shown as a warning when FFmpeg recovers and exits successfully; inspect the output before relying on it. Normal completion deletes the log. On failure, the most recent diagnostic lines appear in **Details** (or in the console for manual use) before the log is deleted. If a log cannot be deleted, its path is reported and the encoded video is preserved. Handled interruptions also clean up; a forced shutdown may leave a temporary log behind.

To retain diagnostics for troubleshooting, use `-KeepLog`. The log stays in the system temp folder and its location is printed, whether the encode succeeds or fails:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -Small -KeepLog "C:\Path\Recording.mkv"
```

To open the progress window manually, including with retained diagnostics:

```powershell
powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File .\src\Show-AV1Progress.ps1 -Small -KeepLog "C:\Path\Recording.mkv"
```

The WPF window requires Windows and STA mode. The launcher looks for PowerShell 7 on PATH at startup and falls back to the built-in Windows PowerShell 5.1 if it is unavailable or cannot be started. No separate GUI runtime installation is required on a standard Windows desktop installation.

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

Run the output-safety regression checks without FFmpeg. These verify tool discovery with duplicate PATH matches and preserve both results when two processes finalize the same output name:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-OutputSafety.ps1
```

Run the Small-mode integration checks with FFmpeg (including SVT-AV1 and NVENC encoder support) and FFprobe available. These generate short test clips in a temporary directory and verify AV1 re-encoding, resolution limits, unchanged audio tracks, output collisions, and existing-mode behavior. They also cover MOV timecode inputs and preservation of supported subtitles, attachments, metadata, and chapters. No NVIDIA GPU is needed for these checks.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SmallMode.ps1
```

Run the progress and diagnostic-log checks with FFmpeg/SVT-AV1 and FFprobe available. These cover progress calculations, real encoding timestamps, missing durations, native argument quoting, diagnostic retention and cleanup failures, recovered decoder errors, portable-only tool discovery, verbose failures, and encoder interruption:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-EncodingProgress.ps1
```

Exercise the actual GUI background worker without opening a window. These checks cover structured progress, skipped files, startup failures, and cancellation during a batch, including child-process termination, temporary-file cleanup, and retention of earlier completed outputs:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GuiWorker.ps1
```

Check inspection cancellation and timeouts, including termination of stalled child processes, concurrent stdout/stderr capture, and cancellation propagation through every inspection stage:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Inspection.ps1
```

Verify the C# launcher's process options, mode selection, and native argument handling without opening a window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Launcher.ps1
```

Check human-readable time estimates and result presentation without WPF, including unknown durations, finalization, long encodes, larger outputs, and non-completed files:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GuiPresentation.ps1
```

On Windows, validate the actual WPF layout, automatic results visibility, and shortcut installation, upgrade, reinstallation, and removal. The test also builds the real launcher, checks its GUI executable type, and runs it with a recording script to verify all three modes, selected file paths, and the absence of a console in the PowerShell child. This test uses a temporary destination and does not alter the user's Send to entries or installed launcher. Run it with both Windows PowerShell 5.1 and PowerShell 7 when available:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-WindowsIntegration.ps1
pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-WindowsIntegration.ps1
```

Before release, verify on an interactive Windows desktop that all three Send to entries open a compact window without a console flash; multi-file selections (including spaces and Unicode paths) arrive intact; progress remains responsive; the results area appears when needed; warnings and errors are visible; Cancel and closing an active window clean up; and completed results and output-folder navigation work. Verify NVIDIA encoding on supported hardware. The Windows integration test does not automate these Explorer and interactive window behaviors.

## Known limitations

- Windows 11 may place **Send to** under the legacy context menu path depending on your system and Explorer behavior.
- This is not a video editor or general-purpose converter.
- Dolby Vision/HDR edge cases are not specially handled in v1.
- If `ffprobe` is unavailable, the script may not detect already-AV1 inputs before attempting conversion. It will still skip files with extensions that are not recognized as common video types.
- NVIDIA mode requires an NVIDIA GPU with AV1 encode support. Having an NVIDIA GPU is not enough by itself.
- NVIDIA UHQ support depends on your FFmpeg build, NVIDIA driver, and Video Codec SDK support. If UHQ is unavailable, the script falls back to HQ.
- MP4 output can fail when copied streams are not compatible with the MP4 container. Use the default MKV container for maximum preservation.
- Portable FFmpeg downloads require GitHub access because BtbN publishes builds through GitHub releases.
- Install/uninstall use CMD wrappers and PowerShell helpers. The GUI and console interface use PowerShell, with the same shared encoding engine. If your computer is heavily locked down by Group Policy, PowerShell script execution may still be blocked.

## License

Send to AV1 is licensed under the GNU General Public License v3.0 or later.

See [`LICENSE`](LICENSE).

## Third-party software

This project uses FFmpeg when available, but the source repository does not include FFmpeg binaries.

The optional downloader retrieves BtbN FFmpeg builds from GitHub releases. FFmpeg and BtbN builds are separate projects with their own license terms. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
