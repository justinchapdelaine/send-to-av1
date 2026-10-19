# Send to AV1

Convert videos to AV1 from the Windows **Send to** menu, with a simple progress window and your original files kept intact.

Choose CPU encoding for quality and compression, NVIDIA encoding for speed, or Small mode for smaller files. Outputs are saved beside the originals as MKV files, with audio and other supported streams copied without re-encoding.

[Installation](#installation) · [Usage](#usage) · [Encoding modes](#encoding-modes) · [Troubleshooting](#troubleshooting) · [Contributing](CONTRIBUTING.md)

## Features

- Encode one video or a batch directly from File Explorer.
- See progress, elapsed time, and an estimated time remaining in a responsive window.
- Compare input and output sizes when each file finishes.
- Preserve audio tracks, subtitles, chapters, attachments, and metadata where supported.
- Cancel an encode while keeping completed outputs and original files.
- Install for the current user without administrator rights.

## Requirements

- A Windows desktop with Windows PowerShell 5.1 or PowerShell 7. The launcher prefers PowerShell 7 when available on `PATH`.
- FFmpeg with `libsvtav1` support for CPU and Small modes, or `av1_nvenc` support for NVIDIA mode. The installer can download portable tools for x64 or ARM64 Windows.
- FFprobe for duration estimates and detection of existing AV1 video. It is included in the optional portable download.
- For NVIDIA mode, a GPU and driver that support **AV1 encoding**.

FFmpeg binaries are downloaded separately and are not included in this repository. Standard Windows desktop installations already include the .NET Framework compiler used to build the small launcher; no separate SDK is needed.

## Installation

1. Download this repository using **Code → Download ZIP** and extract it, or clone it with Git.
2. Keep the extracted project folder somewhere permanent.
3. Double-click **`Install-SendTo.cmd`**.
4. Approve the portable FFmpeg download if you need it. You can also provide your own tools in `bin` or on `PATH`.

The installer adds three shortcuts to your Windows **Send to** menu. They point to the project folder, so re-run the installer if you move it.

To update, replace the project files or pull the latest changes, then run `Install-SendTo.cmd` again. This rebuilds the launcher, refreshes the shortcuts and icons, and checks for portable FFmpeg updates. Encoding itself does not check for or download updates.

## Usage

1. Select one or more videos in File Explorer.
2. Right-click and choose **Send to**.
3. Select an encoding mode from the table below.

On Windows 11, you may need **Show more options → Send to**.

Encoding starts automatically. The window shows the current file, its position in the batch, progress, and timing estimates. Files are processed one at a time. Hover over the remaining-time estimate for a precise timestamp.

Use **Cancel** to stop the current encode and the rest of the batch. Incomplete output is removed; completed files remain. When finished, review the size comparisons or choose **Open output folder**. **Details** opens automatically for errors and can be expanded for other diagnostic information.

## Encoding modes

| Send to entry | Encoder | Best for | Resolution | Existing AV1 input |
| --- | --- | --- | --- | --- |
| **Send to AV1** | CPU / SVT-AV1, CRF 34 | Balancing quality and compression | Preserved | Skipped when detected |
| **Send to AV1 - NVIDIA** | NVIDIA AV1 NVENC, CQ 32 | Faster encoding on supported GPUs | Preserved | Skipped when detected |
| **Send to AV1 - Small** | CPU / SVT-AV1, CRF 38 | Prioritizing smaller files | Fits within 1280×720, without upscaling | Re-encoded |

Small mode trades visual quality for file size and can recompress existing AV1 recordings, including OBS NVENC AV1 captures. All modes copy audio unchanged. A smaller output is not guaranteed; larger outputs are kept and flagged with a warning.

See the [encoding reference](docs/encoding.md#presets) for complete settings and command-line overrides.

## Output files

Outputs are written beside their source files. Originals and existing outputs are never overwritten.

```text
Recording.mp4         ← original, kept unchanged
Recording_AV1.mkv     ← encoded output
Recording_AV1_2.mkv   ← next output if the first name already exists
```

MKV is the default because it supports a wide range of copied streams. Data and unknown streams, such as MOV timecode tracks, are omitted. Optional MP4 output is available through the command line, but incompatible copied streams can cause it to fail.

## Command-line usage

Run these commands from the project folder:

```powershell
# Default CPU mode
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 "C:\Videos\Recording.mp4"

# Small mode, including existing AV1 inputs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -Small "C:\Videos\Recording.mkv"

# NVIDIA mode
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\Optimize-AV1.ps1 -Encoder nvenc "C:\Videos\Recording.mp4"
```

The console interface uses the same encoding engine as the window. See the [encoding reference](docs/encoding.md) for quality settings, dry runs, diagnostics, retained logs, and manual GUI launch commands.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| Send to entries are missing or still use an older window/icon | Re-run `Install-SendTo.cmd`. On Windows 11, check **Show more options**. |
| FFmpeg is missing or the download fails | Re-run the installer with GitHub access, or place `ffmpeg.exe` and `ffprobe.exe` in `bin`. Local tools take priority over `PATH`. |
| NVIDIA encoding fails | Check that both your FFmpeg build and GPU/driver support AV1 encoding. An encoder listed by FFmpeg does not confirm hardware support. |
| A video is skipped as already AV1 | Use Small mode to allow re-encoding. |
| No percentage or remaining time is shown | FFprobe could not determine the duration. Processed and elapsed times remain available. |
| An encode fails or reports warnings | Expand **Details**. For retained diagnostic logs, use `-KeepLog` from the command line. |

Diagnostic logs normally live in the system temporary folder and are deleted after use, including after a failure has been displayed. `-KeepLog` retains them and reports their location. See [progress and diagnostics](docs/encoding.md#encoding-progress-and-diagnostics) for cleanup behavior and inspection timeouts.

HDR and Dolby Vision edge cases are not specially handled. PowerShell restrictions enforced by Group Policy may prevent the scripts from running.

If you report an issue, include the chosen mode, the error shown in Details, and relevant FFmpeg diagnostics.

## Uninstall

Double-click **`Uninstall-SendTo.cmd`** to remove the Send to entries. It leaves the project folder, portable tools, and your videos in place. You can delete the project folder afterward if you no longer need it.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the project structure, automated checks, and Windows validation steps.

## License

Licensed under [GNU GPL v3.0 or later](LICENSE). FFmpeg and the optional [BtbN builds](https://github.com/BtbN/FFmpeg-Builds) are separate projects with their own license terms; see [third-party notices](THIRD_PARTY_NOTICES.md).
