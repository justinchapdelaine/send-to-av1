# Contributing

[Back to the README](README.md)

Send to AV1 targets Windows. Changes to the GUI, installer, or launcher need validation on an interactive Windows desktop; PowerShell parsing or Linux checks alone cannot verify WPF and Explorer behavior.

Run commands below from the project folder. Use temporary clips for encoding checks and keep generated binaries out of Git.

## Project structure

| Path | Purpose |
| --- | --- |
| `src/AV1.Core.psm1` | Shared encoding engine, tool inspection, progress, and output handling |
| `src/Optimize-AV1.ps1` | Console interface |
| `src/Show-AV1Progress.ps1` | WPF progress window |
| `src/AV1.Worker.psm1` | Background runspace and event queue |
| `src/AV1.ViewModel.psm1` | Time estimates and result formatting |
| `src/AV1.Theme.psm1` | Windows theme detection, palettes, and window color resources |
| `src/SendToAv1Launcher.cs` | Windowless PowerShell launcher |
| `src/Build-Launcher.ps1` | Build the launcher with the Windows .NET Framework compiler |
| `src/Install-SendTo.ps1` | Per-user shortcut installation and removal |
| `src/Download-FFmpeg.ps1` | Optional portable FFmpeg installation and updates |
| `resources/` | Application icon and editable SVG source |
| `tests/` | Repository, encoding, worker, and Windows integration checks |

## Validation

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

Check human-readable time estimates and result presentation without WPF, including unknown durations, finalization, long encodes, larger outputs, and completion summaries for success, cancellation, and failures:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GuiPresentation.ps1
```

Check light/dark palette completeness, status-color mapping, and text contrast without WPF:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GuiTheme.ps1
```

Audit the actual GUI XAML and theme module against WPF's public APIs, including inherited and attached properties, dependency properties, style setters, template bindings, palette references, enums, and events:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WpfApi.ps1
```

This check also supports metadata-only inspection on PowerShell 7.4+ without Windows. Extract the [Microsoft.NETFramework.ReferenceAssemblies.net48 1.0.3](https://www.nuget.org/packages/Microsoft.NETFramework.ReferenceAssemblies.net48/1.0.3) and [System.Reflection.MetadataLoadContext 8.0.0](https://www.nuget.org/packages/System.Reflection.MetadataLoadContext/8.0.0) packages, then supply their assembly paths:

```powershell
pwsh -NoProfile -File ./tests/Test-WpfApi.ps1 -ReferenceDirectory /path/to/net48/build/.NETFramework/v4.8 -MetadataLoadContextPath /path/to/metadataloadcontext/lib/net8.0/System.Reflection.MetadataLoadContext.dll
```

The metadata check executes no WPF code. It catches invalid API/property references but does not replace the Windows runtime checks below.

On Windows, validate the actual WPF layout, automatic results visibility, live palette changes, button styles, and shortcut installation, upgrade, reinstallation, and removal. The test also builds the real launcher, checks its GUI executable type, and runs it with a recording script to verify all three modes, selected file paths, and the absence of a console in the PowerShell child. This test uses a temporary destination and does not alter the user's Send to entries or installed launcher. Run it with both Windows PowerShell 5.1 and PowerShell 7 when available:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-WindowsIntegration.ps1
pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-WindowsIntegration.ps1
```

Before release, verify on an interactive Windows desktop that all three Send to entries open a compact window without a console flash; multi-file selections (including spaces and Unicode paths) arrive intact; progress remains responsive; the results area appears when needed; warnings and errors are visible; Cancel and closing an active window clean up; and completed results and output-folder navigation work. Verify NVIDIA encoding on supported hardware. The Windows integration test does not automate these Explorer and interactive window behaviors.

Also switch Windows' app theme during an encode and after completion, and check high-contrast mode. Verify the caption, result cards, tooltips, and expanded Details, plus button hover, press, disabled appearance, and Tab/Space keyboard interaction in both themes. These checks must not change progress, completed results, or cancellation behavior.
