# Encoding reference

[Back to the README](../README.md)

Settings, command-line options, FFmpeg maintenance, and diagnostic behavior. Run the commands below from the project folder.

## Presets

### Send to AV1

The default storage preset uses CPU-based SVT-AV1 to balance quality and compression:

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

To refresh the Send to entries in an existing installation, open `Install-SendTo.vbs` and choose **Install**.

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

## FFmpeg

FFmpeg is **not included** in the source repository.

Send to AV1 looks for FFmpeg in this order:

1. Local tools in the project root:
   - `bin/ffmpeg.exe`
   - `bin/ffprobe.exe`
2. System PATH:
   - `ffmpeg`
   - `ffprobe`

Encoding uses installed tools without checking for updates.

To install or update portable tools in `bin`, open `Install-SendTo.vbs`, leave **Download or update portable FFmpeg** selected, and choose **Install**. Clear the checkbox if you provide your own tools. If GitHub cannot be reached but local FFmpeg tools are already installed, the installer keeps using them.

Download or update portable FFmpeg manually:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Download-FFmpeg.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Download-FFmpeg.ps1 -Architecture x64
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Download-FFmpeg.ps1 -Architecture arm64
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Download-FFmpeg.ps1 -Force
```

The downloader uses BtbN's GPL Windows builds, supports x64 and ARM64, chooses the native Windows architecture by default, installs only `ffmpeg.exe` and `ffprobe.exe` into `bin`, and prints whether the installed FFmpeg exposes `libsvtav1`, `av1_nvenc`, and NVIDIA HQ/UHQ tune support.

## Output verification

When FFprobe is available, Send to AV1 inspects the source once, reusing its codec, duration, and stream counts for AV1 skipping, progress estimates, and output verification. It checks the temporary encoded file before assigning its final filename or reporting success. All video streams must be AV1, and video, audio, and subtitle stream counts must match the source. Container duration and each corresponding video stream's duration must match within two seconds or 0.1% of that source duration, whichever is larger. Checking video streams separately prevents longer copied audio or subtitles from hiding truncated video. Matroska video timing uses its DURATION tag and stream start timestamp when a stream duration is not reported; shifted timestamps are normalized before comparison.

If a source container or video duration is unavailable, the remaining metadata checks still run and a warning identifies the unavailable comparison. If a known source video duration has no corresponding output duration, verification fails. If FFprobe is unavailable, encoding continues with a warning that output verification was skipped. The portable tool download includes FFprobe.

The window shows **Verifying output** during the check. Verification queries have a 30-second timeout and can be cancelled. An unreadable output, stream mismatch, container/video duration mismatch, missing required output duration, or failed/timed-out verification is reported as a failed file, and its temporary encode is removed. The batch then continues with the next file unless cancelled. Originals and previously completed outputs are kept.

Verification checks metadata, not every encoded frame or packet. It cannot guarantee a corruption-free file or equivalent visual quality, and does not compare attachment contents, metadata, or chapter values. Recovered decoder errors reported by FFmpeg remain warnings even when metadata checks pass.

## Encoding progress and diagnostics

The Send to entries use a windowless launcher to open the Windows WPF window without a console flash. The current filename is the main heading, with a prominent percentage at the top right. A quiet line beneath combines the batch position, encoding mode, and current phase. A full-width blue progress bar aligns with the timing panel below. Separate timing fields show an approximate remaining time (for example, "About 8 minutes"), elapsed time, and processed video time. Hover over the estimate for a precise timestamp. A background worker performs the encoding so the window remains responsive. Manual console use shows the corresponding text progress bar.

FFprobe supplies the total duration and FFmpeg supplies structured progress timestamps. The estimate changes with encoding speed; completion is reported only after FFmpeg succeeds and the output file is finalized.

Use **Cancel** to stop the current encode and the remaining batch. The worker stops FFmpeg and removes the incomplete output; previously completed outputs and original files are kept. Closing the window during encoding asks whether to cancel, then leaves the window open until cleanup finishes. Afterward, use **Close** to dismiss it.

Cancellation also stops FFprobe and capability checks during video inspection. Each inspection process has a 30-second timeout. A timed-out source inspection skips that file with a warning. If inspection succeeds but no valid container duration is reported, encoding continues without a duration estimate; verification still checks stream counts and any available video durations. Timeouts on required capability checks are reported as failures.

The window starts compact, with the results list hidden until there is a completed, skipped, failed, or cancelled file to report. It grows to show results and expanded details, with scrolling for longer batches and smaller screens. Each result has a status icon, filename, and readable size comparison; the full output path is secondary. Green indicates successful completion, amber indicates warnings or larger outputs, and red indicates failures. **Open output folder** opens the folder of the most recently completed output. **Details** opens automatically for errors and includes precise progress timestamps; it remains collapsed during normal operation. The window stays open when the batch finishes so the results can be reviewed.

After encoding stops, the percentage, progress bar, and timing panel are hidden. A completion heading replaces the current filename, with the total time taken and encoding mode underneath, including time spent on inspection and cleanup. Single-file success shows the result card without extra counts or a repeated completion label. Batches show completed, skipped, and failed counts together with total savings above the result cards. Cancellation, warnings, and failures retain their outcome messages and per-file statuses.

The window and Send to shortcuts use the bundled AV1 icon. Re-run the installer after updating to rebuild the launcher with the new icon and refresh the shortcut icons.

The interface follows the current user's Windows **app** light/dark preference, checking for changes every two seconds while the window is open. Cards, progress and result colors, details, tooltips, and buttons update together without restarting encoding or changing the finished layout. High-contrast mode uses Windows system colors. The native title bar requests the matching theme on supported Windows versions and otherwise keeps its normal appearance. Buttons provide hover, pressed, disabled, and keyboard-focus states; Cancel is outlined with a red hover state, Open output folder is outlined, and Close uses the primary blue style.

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
