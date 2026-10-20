<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Shared encoding engine for the console and Windows progress window.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:EventSink = $null
$script:Cancellation = $null
$Script:KnownVideoExtensions = @(
    '.3g2', '.3gp', '.avi', '.divx', '.flv', '.m2ts', '.m4v', '.mkv',
    '.mov', '.mp4', '.mpeg', '.mpg', '.mts', '.mxf', '.ogm', '.ogv',
    '.ts', '.vob', '.webm', '.wmv'
)

function Send-AV1Event {
    param([string]$Type, [hashtable]$Data = @{})
    $event = [PSCustomObject]@{ Type = $Type; Data = [PSCustomObject]$Data }
    if ($null -ne $script:EventSink) { & $script:EventSink $event | Out-Null }
}

function Write-AV1Message {
    param([object]$Object = '', [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray)
    if ($null -eq $script:EventSink) { Write-Host $Object -ForegroundColor $ForegroundColor }
    else {
        Send-AV1Event -Type 'Message' -Data @{ Message = [string]$Object; Color = [string]$ForegroundColor }
    }
}

function Assert-AV1NotCancelled {
    if ($null -ne $script:Cancellation -and $script:Cancellation.IsCancellationRequested) {
        throw (New-Object OperationCanceledException 'Encoding cancelled.')
    }
}

function Write-Section {
    param([string]$Message)
    Write-AV1Message ''
    Write-AV1Message '============================================================'
    Write-AV1Message $Message
    Write-AV1Message '============================================================'
}

function Format-ByteSize {
    param([int64]$Bytes)

    $sign = ''
    $absoluteBytes = $Bytes
    if ($Bytes -lt 0) {
        $sign = '-'
        $absoluteBytes = [Math]::Abs($Bytes)
    }

    if ($absoluteBytes -ge 1TB) { return ('{0}{1:N2} TB' -f $sign, ($absoluteBytes / 1TB)) }
    if ($absoluteBytes -ge 1GB) { return ('{0}{1:N2} GB' -f $sign, ($absoluteBytes / 1GB)) }
    if ($absoluteBytes -ge 1MB) { return ('{0}{1:N2} MB' -f $sign, ($absoluteBytes / 1MB)) }
    if ($absoluteBytes -ge 1KB) { return ('{0}{1:N2} KB' -f $sign, ($absoluteBytes / 1KB)) }
    return ('{0}{1} B' -f $sign, $absoluteBytes)
}

function Format-CommandArgument {
    param([string]$Argument)

    if ($Argument -notmatch "[\s'`"&|<>;()]") {
        return $Argument
    }

    return ("'{0}'" -f ($Argument -replace "'", "''"))
}

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolName
    )

    $projectRoot = Split-Path -Parent $PSScriptRoot
    $localTool = Join-Path $projectRoot (Join-Path 'bin' ("$ToolName.exe"))
    if (Test-Path -LiteralPath $localTool -PathType Leaf) {
        return (Resolve-Path -LiteralPath $localTool).Path
    }

    $command = Get-Command $ToolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    return $null
}

function Invoke-AV1ToolQuery {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$Purpose,
        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds = 30
    )

    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $started = $false
    $stdout = $null
    $stderr = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Assert-AV1NotCancelled
        $started = $process.Start()
        # Drain both pipes concurrently, including when a query fails verbosely.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        Send-AV1Event -Type 'InspectionStarted' -Data @{ Purpose = $Purpose; ProcessId = $process.Id }
        do {
            Assert-AV1NotCancelled
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw (New-Object TimeoutException ('{0} timed out after {1} seconds.' -f $Purpose, $TimeoutSeconds))
            }
            $process.WaitForExit(100) | Out-Null
            if ($process.HasExited -and (-not $stdout.IsCompleted -or -not $stderr.IsCompleted)) {
                Start-Sleep -Milliseconds 20
            }
        } while (-not $process.HasExited -or -not $stdout.IsCompleted -or -not $stderr.IsCompleted)
        Assert-AV1NotCancelled
        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $stdout.GetAwaiter().GetResult()
            StandardError = $stderr.GetAwaiter().GetResult()
        }
    }
    finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }
            if ($null -ne $stdout) { $stdout.GetAwaiter().GetResult() | Out-Null }
            if ($null -ne $stderr) { $stderr.GetAwaiter().GetResult() | Out-Null }
        }
        finally {
            $process.Dispose()
            $clock.Stop()
        }
    }
}

function Get-FfmpegEncoderOutput {
    param([string]$FfmpegPath)

    $query = Invoke-AV1ToolQuery -Executable $FfmpegPath -Arguments @('-hide_banner', '-encoders') -Purpose 'FFmpeg encoder check'
    if ($query.ExitCode -ne 0) {
        throw 'Unable to query FFmpeg encoders.'
    }

    return $query.StandardOutput + $query.StandardError
}

function Test-FfmpegEncoder {
    param(
        [string]$EncoderOutput,
        [string]$EncoderName
    )

    return ($EncoderOutput -match ("(?im)^\s*[A-Z\.]+\s+{0}\s" -f [Regex]::Escape($EncoderName)))
}

function Get-NvencHelpOutput {
    param([string]$FfmpegPath)

    $query = Invoke-AV1ToolQuery -Executable $FfmpegPath -Arguments @('-hide_banner', '-h', 'encoder=av1_nvenc') -Purpose 'NVIDIA capability check'
    if ($query.ExitCode -ne 0) {
        throw 'Unable to query av1_nvenc options.'
    }

    return $query.StandardOutput + $query.StandardError
}

function Test-NvencTuneSupport {
    param(
        [string]$NvencHelpOutput,
        [string]$TuneName
    )

    return ($NvencHelpOutput -match ("(?im)^\s+{0}\s+" -f [Regex]::Escape($TuneName)))
}

function Resolve-NvencTune {
    param(
        [string]$NvencHelpOutput,
        [string]$RequestedTune
    )

    $supportsUhq = Test-NvencTuneSupport -NvencHelpOutput $NvencHelpOutput -TuneName 'uhq'
    $supportsHq = Test-NvencTuneSupport -NvencHelpOutput $NvencHelpOutput -TuneName 'hq'

    if ($RequestedTune -eq 'uhq') {
        if (-not $supportsUhq) {
            throw 'This FFmpeg build supports av1_nvenc, but it does not support -tune uhq. Update FFmpeg/NVIDIA drivers or use -NvencTune hq.'
        }
        return 'uhq'
    }

    if ($RequestedTune -eq 'hq') {
        if (-not $supportsHq) {
            throw 'This FFmpeg build supports av1_nvenc, but it does not support -tune hq.'
        }
        return 'hq'
    }

    if ($supportsUhq) {
        return 'uhq'
    }

    if ($supportsHq) {
        return 'hq'
    }

    throw 'This FFmpeg build supports av1_nvenc, but neither -tune uhq nor -tune hq was found.'
}

function Format-CapabilityStatus {
    param([bool]$Available)

    if ($Available) {
        return 'Available'
    }

    return 'Unavailable'
}

function Test-LikelyVideoFile {
    param([string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    return ($Script:KnownVideoExtensions -contains $extension)
}

function Get-ToolCapabilities {
    param(
        [string]$FfmpegPath,
        [string]$FfprobePath
    )

    $encoderOutput = Get-FfmpegEncoderOutput -FfmpegPath $FfmpegPath
    $hasSvt = Test-FfmpegEncoder -EncoderOutput $encoderOutput -EncoderName 'libsvtav1'
    $hasNvenc = Test-FfmpegEncoder -EncoderOutput $encoderOutput -EncoderName 'av1_nvenc'
    $nvencHelpOutput = $null
    $nvencSupportsUhq = $false
    $nvencSupportsHq = $false

    if ($hasNvenc) {
        try {
            $nvencHelpOutput = Get-NvencHelpOutput -FfmpegPath $FfmpegPath
            $nvencSupportsUhq = Test-NvencTuneSupport -NvencHelpOutput $nvencHelpOutput -TuneName 'uhq'
            $nvencSupportsHq = Test-NvencTuneSupport -NvencHelpOutput $nvencHelpOutput -TuneName 'hq'
        }
        catch [OperationCanceledException] { throw }
        catch {
            Write-AV1Message ('Warning: av1_nvenc was found, but its options could not be queried: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    return [PSCustomObject]@{
        EncoderOutput = $encoderOutput
        HasSvtAv1 = $hasSvt
        HasNvencAv1 = $hasNvenc
        NvencHelpOutput = $nvencHelpOutput
        NvencSupportsUhq = $nvencSupportsUhq
        NvencSupportsHq = $nvencSupportsHq
        HasFfprobe = (-not [string]::IsNullOrWhiteSpace($FfprobePath))
    }
}

function Write-CapabilitySummary {
    param([PSCustomObject]$Capabilities)

    $nvencTuneStatus = 'Unavailable'
    if ($Capabilities.HasNvencAv1) {
        if ($Capabilities.NvencSupportsUhq) {
            $nvencTuneStatus = 'UHQ available'
        }
        elseif ($Capabilities.NvencSupportsHq) {
            $nvencTuneStatus = 'HQ available; UHQ unavailable'
        }
        else {
            $nvencTuneStatus = 'Tune options unavailable'
        }
    }

    Write-AV1Message ''
    Write-AV1Message 'Capability summary:'
    Write-AV1Message ('  FFmpeg:            {0}' -f 'Found')
    Write-AV1Message ('  FFprobe:           {0}' -f (Format-CapabilityStatus $Capabilities.HasFfprobe))
    Write-AV1Message ('  CPU/SVT-AV1:       {0}' -f (Format-CapabilityStatus $Capabilities.HasSvtAv1))
    $nvencStatus = 'Unavailable'
    if ($Capabilities.HasNvencAv1) {
        $nvencStatus = 'Available in FFmpeg'
    }

    Write-AV1Message ('  NVIDIA AV1 NVENC:  {0}' -f $nvencStatus)
    Write-AV1Message ('  NVIDIA tune:       {0}' -f $nvencTuneStatus)
    if ($Capabilities.HasNvencAv1) {
        # Encoder presence only proves the FFmpeg build supports NVENC; the
        # active machine still needs compatible NVIDIA hardware and drivers.
        Write-AV1Message '  NVIDIA hardware:   Requires a GPU and driver with AV1 encode support'
    }
}

function New-EncoderConfiguration {
    param(
        [string]$FfmpegPath,
        [PSCustomObject]$Capabilities,
        [string]$EncoderName,
        [int]$CrfValue,
        [int]$PresetValue,
        [int]$NvencCqValue,
        [string]$NvencPresetValue,
        [string]$NvencTuneValue
    )

    Write-AV1Message ''
    Write-AV1Message 'Selected encoder:'
    $encoderOutput = $Capabilities.EncoderOutput

    if ($EncoderName -eq 'svt') {
        if (-not (Test-FfmpegEncoder -EncoderOutput $encoderOutput -EncoderName 'libsvtav1')) {
            throw 'This FFmpeg build does not appear to support libsvtav1. Use an FFmpeg build that includes the SVT-AV1 encoder.'
        }

        Write-AV1Message '  CPU/SVT-AV1'
        return [PSCustomObject]@{
            Encoder = 'svt'
            DisplayName = 'SVT-AV1 CPU'
            Summary = ('SVT-AV1, CRF {0}, preset {1}, keyframe interval ~10 seconds, tune 0, 10-bit' -f $CrfValue, $PresetValue)
            FfmpegVideoArgs = @(
                '-c:v', 'libsvtav1',
                '-crf', $CrfValue.ToString(),
                '-preset', $PresetValue.ToString(),
                '-svtav1-params', 'keyint=10s:tune=0',
                '-pix_fmt', 'yuv420p10le'
            )
        }
    }

    if (-not (Test-FfmpegEncoder -EncoderOutput $encoderOutput -EncoderName 'av1_nvenc')) {
        throw 'This FFmpeg build does not appear to support av1_nvenc. Use an FFmpeg build with NVIDIA NVENC AV1 support.'
    }

    Write-AV1Message '  NVIDIA AV1 NVENC'
    $nvencHelp = $Capabilities.NvencHelpOutput
    if ([string]::IsNullOrWhiteSpace($nvencHelp)) {
        $nvencHelp = Get-NvencHelpOutput -FfmpegPath $FfmpegPath
    }
    $resolvedTune = Resolve-NvencTune -NvencHelpOutput $nvencHelp -RequestedTune $NvencTuneValue

    if ($NvencTuneValue -eq 'auto' -and $resolvedTune -eq 'hq') {
        Write-AV1Message 'NVIDIA AV1 mode: HQ fallback - UHQ was not found in this FFmpeg build.' -ForegroundColor Yellow
    }
    else {
        Write-AV1Message ("NVIDIA AV1 mode: {0}" -f $resolvedTune.ToUpperInvariant())
    }

    return [PSCustomObject]@{
        Encoder = 'nvenc'
        DisplayName = 'NVIDIA AV1 NVENC'
        Summary = ('NVIDIA AV1 NVENC, preset {0}, tune {1}, CQ {2}, 10-bit' -f $NvencPresetValue, $resolvedTune, $NvencCqValue)
        FfmpegVideoArgs = @(
            '-c:v', 'av1_nvenc',
            '-preset', $NvencPresetValue,
            '-tune', $resolvedTune,
            '-rc', 'vbr',
            '-cq', $NvencCqValue.ToString(),
            '-b:v', '0',
            '-pix_fmt', 'p010le'
        )
    }
}

function Get-SourceMediaInfo {
    param([string]$FfprobePath, [string]$Path)

    if ([string]::IsNullOrWhiteSpace($FfprobePath)) { return $null }
    try {
        return Get-MediaInfo -FfprobePath $FfprobePath -Path $Path -Purpose 'Source media inspection'
    }
    catch [OperationCanceledException] { throw }
    catch [TimeoutException] {
        Write-AV1Message ('Warning: {0} The file will be skipped.' -f $_.Exception.Message) -ForegroundColor Yellow
        return $null
    }
    catch { return $null }
}

function Get-MediaInfo {
    param([string]$FfprobePath, [string]$Path, [string]$Purpose)

    $query = Invoke-AV1ToolQuery -Executable $FfprobePath -Arguments @(
        '-v', 'error', '-show_entries', 'format=duration,start_time,format_name:stream=codec_type,codec_name', '-of', 'json', $Path
    ) -Purpose $Purpose
    if ($query.ExitCode -ne 0) { throw ('{0} failed: {1}' -f $Purpose, $query.StandardError.Trim()) }
    try {
        $probe = $query.StandardOutput | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $probe -or -not $probe.PSObject.Properties['streams'] -or @($probe.streams).Count -eq 0) {
            throw 'No stream information was returned.'
        }
        # Unknown/data streams are not mapped into the output. Some have no
        # reported type, so count only the media types we actually preserve.
        $streams = @($probe.streams | Where-Object { $null -ne $_ -and $_.PSObject.Properties['codec_type'] })
        $duration = 0.0
        if ($probe.PSObject.Properties['format'] -and $null -ne $probe.format -and $probe.format.PSObject.Properties['duration']) {
            $parsed = 0.0
            if ([double]::TryParse([string]$probe.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and
                $parsed -gt 0 -and -not [double]::IsInfinity($parsed)) { $duration = $parsed }
            # Matroska reports the timeline's end when timestamps start above
            # zero. Other demuxers, including MOV/MP4 and MPEG-TS, already report
            # a duration; subtracting their start would shorten it incorrectly.
            if ($probe.format.PSObject.Properties['format_name'] -and $probe.format.PSObject.Properties['start_time'] -and
                $probe.format.format_name -match '(^|,)(matroska|webm)(,|$)') {
                $start = 0.0
                if ([double]::TryParse([string]$probe.format.start_time, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$start) -and
                    $start -gt 0 -and $start -lt $duration) { $duration -= $start }
            }
        }
        $video = @($streams | Where-Object { $_.codec_type -eq 'video' })
        $codecs = @($video | ForEach-Object {
            if ($_.PSObject.Properties['codec_name']) { ([string]$_.codec_name).Trim().ToLowerInvariant() } else { '' }
        })
        return [PSCustomObject]@{
            VideoCount = $video.Count; VideoCodecs = $codecs
            AudioCount = @($streams | Where-Object { $_.codec_type -eq 'audio' }).Count
            SubtitleCount = @($streams | Where-Object { $_.codec_type -eq 'subtitle' }).Count
            DurationSeconds = $duration
        }
    }
    catch { throw ('{0} returned invalid media information: {1}' -f $Purpose, $_.Exception.Message) }
}

function Assert-AV1Output {
    param([string]$FfprobePath, [string]$Path, [PSCustomObject]$Expected)

    $actual = Get-MediaInfo -FfprobePath $FfprobePath -Path $Path -Purpose 'Output verification'
    if ($actual.VideoCount -lt 1 -or @($actual.VideoCodecs | Where-Object { $_ -ne 'av1' }).Count -gt 0) {
        throw 'Output verification failed: the output does not contain only AV1 video streams.'
    }
    foreach ($kind in @('Video', 'Audio', 'Subtitle')) {
        $property = $kind + 'Count'
        if ($actual.$property -ne $Expected.$property) {
            throw ('Output verification failed: expected {0} {1} stream(s), found {2}.' -f $Expected.$property, $kind.ToLowerInvariant(), $actual.$property)
        }
    }
    if ($Expected.DurationSeconds -gt 0) {
        if ($actual.DurationSeconds -le 0) { throw 'Output verification failed: the output duration is unavailable.' }
        # Allow muxer/timebase rounding and small encoder delays, but reject
        # substantial truncation or an unexpectedly long result.
        $tolerance = [Math]::Max(2.0, $Expected.DurationSeconds * 0.001)
        if ([Math]::Abs($actual.DurationSeconds - $Expected.DurationSeconds) -gt $tolerance) {
            throw ('Output verification failed: duration changed from {0:N2}s to {1:N2}s (allowed difference {2:N2}s).' -f
                $Expected.DurationSeconds, $actual.DurationSeconds, $tolerance)
        }
    }
    else {
        Write-AV1Message 'Warning: Output stream checks passed, but the source duration was unavailable for comparison.' -ForegroundColor Yellow
    }
    Assert-AV1NotCancelled
}

function Format-ProgressTime {
    param([double]$Seconds)

    $wholeSeconds = [long][Math]::Max(0, [Math]::Floor($Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [long][Math]::Floor($wholeSeconds / 3600.0),
        [long][Math]::Floor(($wholeSeconds % 3600) / 60.0), ($wholeSeconds % 60))
}

function Get-EncodingProgress {
    param(
        [double]$DurationSeconds,
        [double]$ProcessedSeconds,
        [double]$ElapsedSeconds,
        [switch]$Finalizing
    )

    $percent = -1
    $remaining = -1
    $videoTime = Format-ProgressTime $ProcessedSeconds
    $elapsed = Format-ProgressTime $ElapsedSeconds
    if ($DurationSeconds -gt 0) {
        # FFmpeg may report the last audio timestamp before the muxer finishes.
        # Reserve 100% for a successfully finalized output.
        $percent = [int][Math]::Floor([Math]::Min(99, [Math]::Max(0, 100 * $ProcessedSeconds / $DurationSeconds)))
        $videoTime += ' / ' + (Format-ProgressTime $DurationSeconds)
        if ($ProcessedSeconds -gt 0 -and $ElapsedSeconds -ge 1) {
            $remaining = [int][Math]::Min([int]::MaxValue, [Math]::Ceiling([Math]::Max(0, $DurationSeconds - $ProcessedSeconds) * $ElapsedSeconds / $ProcessedSeconds))
        }
    }
    $status = 'Video: {0} | Elapsed: {1}' -f $videoTime, $elapsed
    if ($Finalizing) {
        $status += ' | Finalizing output...'
        $remaining = -1
    }
    elseif ($remaining -ge 0) { $status += ' | Remaining: ~' + (Format-ProgressTime $remaining) }
    elseif ($DurationSeconds -gt 0) { $status += ' | Remaining: calculating...' }
    else { $status += ' | Duration unavailable' }

    return [PSCustomObject]@{
        Percent = $percent; SecondsRemaining = $remaining; Status = $status
        ProcessedSeconds = $ProcessedSeconds; DurationSeconds = $DurationSeconds
        ElapsedSeconds = $ElapsedSeconds; Finalizing = [bool]$Finalizing
    }
}

function ConvertTo-ProcessArgument {
    param([string]$Argument)

    # ProcessStartInfo.Arguments is available in Windows PowerShell 5.1.
    # Quote directly for the native argv parser, without invoking a shell.
    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Show-EncodingDiagnostics {
    param([string]$LogPath, [int]$ExitCode)

    try {
        if ($ExitCode -ne 0) {
            Write-AV1Message 'FFmpeg error details:' -ForegroundColor Red
            Get-Content -LiteralPath $LogPath -Encoding UTF8 -Tail 25 | ForEach-Object { Write-AV1Message $_ }
        }
        else {
            # FFmpeg may recover from decoder errors and still return zero.
            # Match severity tags, not words in file names or normal info lines.
            $errorPattern = '(?i)^\s*(?:(?:\[[^\]]+\]\s*)*\[(?:error|fatal|panic)\]|Svt\[(?:error|fatal|panic)\]:)'
            $errors = @(Get-Content -LiteralPath $LogPath -Encoding UTF8 |
                Where-Object { $_ -match $errorPattern } | Select-Object -Last 25)
            if ($errors.Count -gt 0) {
                Write-AV1Message 'Warning: FFmpeg reported errors despite exiting successfully. Check the output before relying on it.' -ForegroundColor Yellow
                $errors | ForEach-Object { Write-AV1Message $_ -ForegroundColor Yellow }
            }
        }
        return $true
    }
    catch {
        Write-AV1Message ('Warning: Could not read encoder diagnostics; retaining log: {0}. {1}' -f $LogPath, $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

function Invoke-FfmpegEncode {
    param(
        [string]$FfmpegPath,
        [string[]]$Arguments,
        [string]$Activity,
        [double]$DurationSeconds,
        [switch]$KeepLog
    )

    $logPath = Join-Path ([IO.Path]::GetTempPath()) ('send-to-av1-' + [Guid]::NewGuid().ToString('N') + '.log')
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $FfmpegPath
    $process.StartInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $logStream = $null
    $stderrCopy = $null
    $started = $false
    $retainLog = [bool]$KeepLog
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $processed = 0.0
    $finalizing = $false
    $lastUpdate = -1.0
    try {
        $logStream = [IO.File]::Open($logPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        Assert-AV1NotCancelled
        $started = $process.Start()
        Send-AV1Event -Type 'EncoderStarted' -Data @{ ProcessId = $process.Id }
        # Drain stderr independently so a verbose encoder cannot block stdout.
        # A .NET copy task avoids PowerShell callbacks on threads without runspaces.
        $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($logStream)
        $nextLine = $process.StandardOutput.ReadLineAsync()
        $stdoutEnded = $false
        while (-not $stdoutEnded -or -not $process.HasExited) {
            Assert-AV1NotCancelled
            if ($stderrCopy.IsFaulted) { $stderrCopy.GetAwaiter().GetResult() | Out-Null }
            if (-not $stdoutEnded -and $nextLine.Wait(100)) {
                $line = $nextLine.GetAwaiter().GetResult()
                if ($null -eq $line) { $stdoutEnded = $true }
                else {
                    if ($line -match '^out_time_us=(-?\d+)$') {
                        $processed = [Math]::Max($processed, [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) / 1000000.0)
                    }
                    elseif ($line -match '^out_time=(.+)$') {
                        $timestamp = [TimeSpan]::Zero
                        if ([TimeSpan]::TryParse($Matches[1], [Globalization.CultureInfo]::InvariantCulture, [ref]$timestamp)) {
                            $processed = [Math]::Max($processed, $timestamp.TotalSeconds)
                        }
                    }
                    elseif ($line -eq 'progress=end') { $finalizing = $true }
                    $nextLine = $process.StandardOutput.ReadLineAsync()
                }
            }
            elseif ($stdoutEnded) { $process.WaitForExit(100) | Out-Null }

            if ($clock.Elapsed.TotalSeconds - $lastUpdate -ge 0.5 -or $stdoutEnded) {
                $progress = Get-EncodingProgress -DurationSeconds $DurationSeconds -ProcessedSeconds $processed -ElapsedSeconds $clock.Elapsed.TotalSeconds -Finalizing:$finalizing
                Send-AV1Event -Type 'Progress' -Data @{ Activity = $Activity; Progress = $progress }
                if ($null -eq $script:EventSink) {
                    Write-Progress -Id 1 -Activity $Activity -Status $progress.Status -PercentComplete $progress.Percent
                }
                $lastUpdate = $clock.Elapsed.TotalSeconds
            }
        }
        $process.WaitForExit()
        $stderrCopy.GetAwaiter().GetResult() | Out-Null
        $logStream.Dispose()
        $logStream = $null
        if (-not (Show-EncodingDiagnostics -LogPath $logPath -ExitCode $process.ExitCode)) {
            $retainLog = $true
        }
        return $process.ExitCode
    }
    finally {
        # Also stop our encoder and release handles when the user presses Ctrl+C.
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }
            if ($null -ne $stderrCopy) { $stderrCopy.GetAwaiter().GetResult() | Out-Null }
        }
        finally {
            if ($null -ne $logStream) { $logStream.Dispose() }
            $process.Dispose()
            $clock.Stop()
            # Diagnostic cleanup must not invalidate an otherwise successful encode.
            try {
                if (Test-Path -LiteralPath $logPath) {
                    if ($retainLog) { Write-AV1Message ('Diagnostic log: {0}' -f $logPath) }
                    else { Remove-Item -LiteralPath $logPath -Force -ErrorAction Stop }
                }
            }
            catch {
                Write-AV1Message ('Warning: Could not delete temporary diagnostic log: {0}. {1}' -f $logPath, $_.Exception.Message) -ForegroundColor Yellow
            }
            if ($null -eq $script:EventSink) { Write-Progress -Id 1 -Activity $Activity -Completed }
        }
    }
}

function New-UniqueOutputPath {
    param(
        [string]$InputFile,
        [string]$Container
    )

    $directory = Split-Path -Parent $InputFile
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $candidate = Join-Path $directory ("{0}_AV1.{1}" -f $baseName, $Container)

    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    for ($index = 2; $index -lt 10000; $index++) {
        $candidate = Join-Path $directory ("{0}_AV1_{1}.{2}" -f $baseName, $index, $Container)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw "Could not generate a unique output path for '$InputFile'."
}

function Complete-OutputFile {
    param(
        [string]$TemporaryPath,
        [string]$OutputPath,
        [string]$InputFile,
        [string]$Container
    )

    for ($attempt = 0; $attempt -lt 10000; $attempt++) {
        try {
            # The two-argument File.Move never replaces an existing destination.
            # A separate existence check followed by Move-Item -Force can race.
            [System.IO.File]::Move($TemporaryPath, $OutputPath)
            return $OutputPath
        }
        catch [System.IO.IOException] {
            # Only retry name collisions; preserve the encoded temporary file
            # and surface unrelated errors such as missing files or I/O failures.
            if (-not (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $OutputPath)) {
                throw
            }
            $OutputPath = New-UniqueOutputPath -InputFile $InputFile -Container $Container
        }
    }

    throw "Could not finalize output without overwriting an existing file. Encoded video remains at '$TemporaryPath'."
}

function New-TemporaryOutputPath {
    param(
        [string]$FinalOutputPath,
        [string]$Container
    )

    $directory = Split-Path -Parent $FinalOutputPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FinalOutputPath)
    $guid = [Guid]::NewGuid().ToString('N')
    return (Join-Path $directory ("{0}.{1}.tmp.{2}" -f $baseName, $guid, $Container))
}

function Convert-VideoToAv1 {
    param(
        [string]$FfmpegPath,
        [string]$FfprobePath,
        [PSCustomObject]$EncoderConfiguration,
        [string]$Container,
        [switch]$DryRun,
        [switch]$Small,
        [switch]$KeepLog,
        [int]$FileNumber = 1,
        [int]$FileCount = 1,
        [string]$Path
    )

    $resolvedInput = (Resolve-Path -LiteralPath $Path).Path
    $inputItem = Get-Item -LiteralPath $resolvedInput

    Write-Section ("File {0} of {1}: {2}" -f $FileNumber, $FileCount, $inputItem.Name)
    Write-AV1Message ("Input:  {0}" -f $resolvedInput)

    # Inspect once and reuse the same snapshot for skipping, progress, and
    # output verification. Do not cache across files or later batch invocations.
    $sourceInfo = Get-SourceMediaInfo -FfprobePath $FfprobePath -Path $resolvedInput
    $codec = $null
    if ($null -ne $sourceInfo -and $sourceInfo.VideoCount -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($sourceInfo.VideoCodecs[0])) {
        $codec = $sourceInfo.VideoCodecs[0]
    }
    if ($codec -eq 'av1' -and -not $Small) {
        Write-AV1Message 'Skipped: source video codec is already AV1.' -ForegroundColor Yellow
        $Script:SkippedCount++
        Send-AV1Event -Type 'FileResult' -Data @{ Path = $resolvedInput; Status = 'Skipped'; Message = 'Already AV1' }
        return
    }

    if ($null -eq $codec) {
        if (-not [string]::IsNullOrWhiteSpace($FfprobePath)) {
            Write-AV1Message 'Skipped: ffprobe did not find a primary video stream.' -ForegroundColor Yellow
            $Script:SkippedCount++
            Send-AV1Event -Type 'FileResult' -Data @{ Path = $resolvedInput; Status = 'Skipped'; Message = 'No supported video stream' }
            return
        }

        # Without ffprobe we cannot inspect streams safely, so use only a
        # conservative extension check before attempting conversion.
        if (-not (Test-LikelyVideoFile -Path $resolvedInput)) {
            Write-AV1Message 'Skipped: file extension is not recognized as a common video type, and ffprobe is unavailable.' -ForegroundColor Yellow
            $Script:SkippedCount++
            Send-AV1Event -Type 'FileResult' -Data @{ Path = $resolvedInput; Status = 'Skipped'; Message = 'No supported video stream' }
            return
        }

        Write-AV1Message 'Warning: ffprobe is unavailable, so the source video codec could not be checked. Continuing because the extension looks like video.' -ForegroundColor Yellow
    }
    else {
        Write-AV1Message ("Detected video codec: {0}" -f $codec)
    }

    $finalOutput = New-UniqueOutputPath -InputFile $resolvedInput -Container $Container
    # FFmpeg writes to a temporary file first so an interrupted or failed encode
    # never leaves an incomplete file with the final output name.
    $tempOutput = New-TemporaryOutputPath -FinalOutputPath $finalOutput -Container $Container

    Write-AV1Message ("Output: {0}" -f $finalOutput)
    Write-AV1Message ("Preset: {0}" -f $EncoderConfiguration.Summary)
    Write-AV1Message ("Container: {0}" -f $Container.ToUpperInvariant())
    Write-AV1Message ''

    if ($Container -eq 'mp4') {
        Write-AV1Message 'Warning: MP4 output may reject some copied subtitle, attachment, or metadata streams. Use MKV for maximum preservation.' -ForegroundColor Yellow
        Write-AV1Message ''
    }

    # Select supported media types explicitly; data/unknown tracks (for example,
    # MOV timecode) can prevent the output muxer from writing an otherwise valid video.
    $ffmpegArgs = @(
        '-hide_banner',
        '-loglevel', 'level+info',
        '-nostdin',
        '-nostats',
        '-progress', 'pipe:1',
        '-stats_period', '1',
        '-y',
        '-i', $resolvedInput,
        '-map', '0:v',
        '-map', '0:a?',
        '-map', '0:s?',
        '-map', '0:t?',
        '-map_metadata', '0',
        '-map_chapters', '0',
        '-c', 'copy'
    )
    $ffmpegArgs += @($EncoderConfiguration.FfmpegVideoArgs)
    $ffmpegArgs += $tempOutput

    if ($DryRun) {
        Write-AV1Message 'Dry run: FFmpeg was not started.'
        $commandPreview = (@($FfmpegPath) + $ffmpegArgs | ForEach-Object { Format-CommandArgument -Argument $_ }) -join ' '
        Write-AV1Message ('Command: & {0}' -f $commandPreview)
        $Script:PlannedCount++
        return
    }

    Assert-AV1NotCancelled
    $duration = 0.0
    if ($null -ne $sourceInfo) { $duration = $sourceInfo.DurationSeconds }
    $activity = 'Encoding file {0} of {1}: {2}' -f $FileNumber, $FileCount, $inputItem.Name
    $encodeReturned = $false
    try {
        $exitCode = Invoke-FfmpegEncode -FfmpegPath $FfmpegPath -Arguments $ffmpegArgs -Activity $activity -DurationSeconds $duration -KeepLog:$KeepLog
        $encodeReturned = $true
    }
    finally {
        if (-not $encodeReturned -and (Test-Path -LiteralPath $tempOutput)) {
            Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
        }
    }

    if ($exitCode -ne 0) {
        if (Test-Path -LiteralPath $tempOutput) {
            Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
        }

        Write-AV1Message ''
        Write-AV1Message ("Failed: FFmpeg exited with code {0}." -f $exitCode) -ForegroundColor Red
        if ($EncoderConfiguration.Encoder -eq 'nvenc') {
            Write-AV1Message 'Hint: FFmpeg exposes av1_nvenc, but the active NVIDIA GPU, driver, or session may still not support AV1 encoding.' -ForegroundColor Yellow
            Write-AV1Message 'Try updating the NVIDIA driver, confirming the GPU supports AV1 encode, or using the default CPU preset.' -ForegroundColor Yellow
        }
        elseif ($Container -eq 'mp4') {
            Write-AV1Message 'Hint: MP4 output can fail when copied streams are not MP4-compatible. Try the default MKV container.' -ForegroundColor Yellow
        }
        $Script:FailedCount++
        Send-AV1Event -Type 'FileResult' -Data @{ Path = $resolvedInput; Status = 'Failed'; Message = 'Encoding failed; see details.' }
        return
    }

    if (-not (Test-Path -LiteralPath $tempOutput -PathType Leaf)) {
        Write-AV1Message ''
        Write-AV1Message 'Failed: FFmpeg completed but no output file was found.' -ForegroundColor Red
        $Script:FailedCount++
        Send-AV1Event -Type 'FileResult' -Data @{ Path = $resolvedInput; Status = 'Failed'; Message = 'Encoding failed; see details.' }
        return
    }

    try {
        Assert-AV1NotCancelled
        if ($null -ne $sourceInfo) {
            Send-AV1Event -Type 'VerificationStarted'
            Write-AV1Message 'Verifying output...'
            if ($null -eq $script:EventSink) { Write-Progress -Id 1 -Activity $activity -Status 'Verifying output...' -PercentComplete 99 }
            Assert-AV1Output -FfprobePath $FfprobePath -Path $tempOutput -Expected $sourceInfo
            if ($sourceInfo.DurationSeconds -gt 0) { Write-AV1Message 'Output verification passed.' }
        }
        else {
            Write-AV1Message 'Warning: Output verification was skipped because ffprobe is unavailable.' -ForegroundColor Yellow
        }
        Assert-AV1NotCancelled
    }
    catch {
        # Failed verification or cancellation must never publish the temporary
        # encode. Leave output-move failures below to their existing recovery path.
        Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        if ($null -eq $script:EventSink) { Write-Progress -Id 1 -Activity $activity -Completed }
    }
    $completedOutput = Complete-OutputFile -TemporaryPath $tempOutput -OutputPath $finalOutput -InputFile $resolvedInput -Container $Container
    if ($completedOutput -ne $finalOutput) {
        Write-AV1Message ("Output name was taken during encoding; saved as: {0}" -f $completedOutput)
    }
    $finalOutput = $completedOutput

    $outputItem = Get-Item -LiteralPath $finalOutput
    $Script:TotalInputBytes += [int64]$inputItem.Length
    $Script:TotalOutputBytes += [int64]$outputItem.Length
    $Script:ProcessedCount++

    $savedBytes = [int64]$inputItem.Length - [int64]$outputItem.Length
    $savedPercent = 0
    if ($inputItem.Length -gt 0) {
        $savedPercent = ($savedBytes / [double]$inputItem.Length) * 100
    }

    Write-AV1Message ''
    Send-AV1Event -Type 'FileResult' -Data @{
        Path = $resolvedInput; Status = 'Completed'; OutputPath = $finalOutput
        InputBytes = [int64]$inputItem.Length; OutputBytes = [int64]$outputItem.Length
        Message = ('{0:N1}% saved | {1} -> {2}' -f $savedPercent, (Format-ByteSize $inputItem.Length), (Format-ByteSize $outputItem.Length))
    }
    Write-AV1Message 'Completed.' -ForegroundColor Green
    Write-AV1Message ("Original size:  {0}" -f (Format-ByteSize $inputItem.Length))
    Write-AV1Message ("AV1 size:       {0}" -f (Format-ByteSize $outputItem.Length))
    Write-AV1Message ("Saved:          {0:N1}% ({1})" -f $savedPercent, (Format-ByteSize $savedBytes))

    if ($savedBytes -lt 0) {
        Write-AV1Message 'Warning: output is larger than the original. Original file was not modified.' -ForegroundColor Yellow
    }
}

function Invoke-AV1Batch {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$InputPath,

        [switch]$Diagnostics,

        [switch]$DryRun,

        [switch]$Small,

        [switch]$KeepLog,

        [ValidateSet('svt', 'nvenc')]
        [string]$Encoder = 'svt',

        [ValidateSet('mkv', 'mp4')]
        [string]$OutputContainer = 'mkv',

        [ValidateRange(0, 63)]
        [int]$Crf = 34,

        [ValidateRange(0, 13)]
        [int]$Preset = 5,

        [ValidateRange(0, 63)]
        [int]$NvencCq = 32,

        [ValidateSet('p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7')]
        [string]$NvencPreset = 'p7',

        [ValidateSet('auto', 'hq', 'uhq')]
        [string]$NvencTune = 'auto',

        [scriptblock]$EventSink,

        [Threading.CancellationTokenSource]$Cancellation
    )

    $Script:ProcessedCount = 0
    $Script:PlannedCount = 0
    $Script:SkippedCount = 0
    $Script:FailedCount = 0
    $Script:TotalInputBytes = [int64]0
    $Script:TotalOutputBytes = [int64]0

    $script:EventSink = $EventSink
    $script:Cancellation = $Cancellation
    $cancelled = $false
    try {
        try {
            Assert-AV1NotCancelled
            Write-Section 'Send to AV1'

            if ($Small) {
                if ($Encoder -ne 'svt') {
                    throw '-Small uses CPU/SVT-AV1 and cannot be combined with -Encoder nvenc.'
                }
                if (-not $PSBoundParameters.ContainsKey('Crf')) {
                    $Crf = 38
                }
                Write-AV1Message 'Small-file mode: fit within 1280x720, allow AV1 re-encoding, copy audio unchanged.'
            }

            $ffmpeg = Resolve-ToolPath -ToolName 'ffmpeg'
            if ([string]::IsNullOrWhiteSpace($ffmpeg)) {
                throw 'FFmpeg was not found. Put ffmpeg.exe in the project root .\bin folder or install FFmpeg so it is available on PATH.'
            }

            $ffprobe = Resolve-ToolPath -ToolName 'ffprobe'
            if ([string]::IsNullOrWhiteSpace($ffprobe)) {
                Write-AV1Message 'Warning: ffprobe was not found. Codec detection and AV1 skipping may be unavailable.' -ForegroundColor Yellow
            }

            $capabilities = Get-ToolCapabilities -FfmpegPath $ffmpeg -FfprobePath $ffprobe

            if ($Diagnostics) {
                Write-AV1Message ("FFmpeg:  {0}" -f $ffmpeg)
                if (-not [string]::IsNullOrWhiteSpace($ffprobe)) {
                    Write-AV1Message ("FFprobe: {0}" -f $ffprobe)
                }
                Write-CapabilitySummary -Capabilities $capabilities
                Write-AV1Message ''
                Write-AV1Message 'Diagnostics complete. No input files were processed.'
                return
            }

            if ($null -eq $InputPath -or $InputPath.Count -eq 0) {
                throw 'No input files were provided. Use the Windows Send To menu, pass one or more file paths, or run -Diagnostics.'
            }

            Assert-AV1NotCancelled
            $encoderConfiguration = New-EncoderConfiguration `
                -FfmpegPath $ffmpeg `
                -Capabilities $capabilities `
                -EncoderName $Encoder `
                -CrfValue $Crf `
                -PresetValue $Preset `
                -NvencCqValue $NvencCq `
                -NvencPresetValue $NvencPreset `
                -NvencTuneValue $NvencTune

            if ($Small) {
                # Fit inside 720p without upscaling; even dimensions support 4:2:0 video.
                $encoderConfiguration.FfmpegVideoArgs += @(
                    '-vf', "scale=w='min(1280,iw)':h='min(720,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
                )
                $encoderConfiguration.DisplayName = 'SVT-AV1 CPU - Small'
                $encoderConfiguration.Summary += ', fit within 1280x720 without upscaling'
            }

            $fileNumber = 0
            foreach ($path in $InputPath) {
                Assert-AV1NotCancelled
                $fileNumber++
                Send-AV1Event -Type 'FileStarted' -Data @{
                    Path = $path; FileNumber = $fileNumber; FileCount = $InputPath.Count
                    Encoder = $encoderConfiguration.DisplayName
                }
                if ([string]::IsNullOrWhiteSpace($path)) {
                    continue
                }

                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    Write-Section ("Skipping missing path: {0}" -f $path)
                    Write-AV1Message 'Skipped: path does not exist or is not a file.' -ForegroundColor Yellow
                    $Script:SkippedCount++
                    Send-AV1Event -Type 'FileResult' -Data @{ Path = $path; Status = 'Skipped'; Message = 'File not found' }
                    continue
                }

                try {
                    Convert-VideoToAv1 -FfmpegPath $ffmpeg -FfprobePath $ffprobe -EncoderConfiguration $encoderConfiguration -Container $OutputContainer -DryRun:$DryRun -Small:$Small -KeepLog:$KeepLog -FileNumber $fileNumber -FileCount $InputPath.Count -Path $path
                }
                catch [OperationCanceledException] { throw }
                catch {
                    Send-AV1Event -Type 'FileResult' -Data @{ Path = $path; Status = 'Failed'; Message = $_.Exception.Message }
                    Write-AV1Message ''
                    Write-AV1Message ('Failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
                    $Script:FailedCount++
                }
            }

            Write-Section 'Summary'
            Write-AV1Message ("Encoder:   {0}" -f $encoderConfiguration.DisplayName)
            Write-AV1Message ("Container: {0}" -f $OutputContainer.ToUpperInvariant())
            if ($DryRun) {
                Write-AV1Message ("Planned:   {0}" -f $Script:PlannedCount)
            }
            Write-AV1Message ("Processed: {0}" -f $Script:ProcessedCount)
            Write-AV1Message ("Skipped:   {0}" -f $Script:SkippedCount)
            Write-AV1Message ("Failed:    {0}" -f $Script:FailedCount)

            if ($Script:ProcessedCount -gt 0) {
                $totalSaved = $Script:TotalInputBytes - $Script:TotalOutputBytes
                $totalPercent = 0
                if ($Script:TotalInputBytes -gt 0) {
                    $totalPercent = ($totalSaved / [double]$Script:TotalInputBytes) * 100
                }

                Write-AV1Message ("Input total:  {0}" -f (Format-ByteSize $Script:TotalInputBytes))
                Write-AV1Message ("Output total: {0}" -f (Format-ByteSize $Script:TotalOutputBytes))
                Write-AV1Message ("Total saved:  {0:N1}% ({1})" -f $totalPercent, (Format-ByteSize $totalSaved))
            }
        }
        catch [OperationCanceledException] {
            $cancelled = $true
            Write-AV1Message 'Cancelled. Completed outputs have been kept.' -ForegroundColor Yellow
        }
        catch {
            Write-AV1Message ''
            Write-AV1Message 'Fatal error:' -ForegroundColor Red
            Write-AV1Message $_.Exception.Message -ForegroundColor Red
            $Script:FailedCount++
        }
        $savedBytes = $Script:TotalInputBytes - $Script:TotalOutputBytes
        $summary = [PSCustomObject]@{
            Processed = $Script:ProcessedCount; Skipped = $Script:SkippedCount; Failed = $Script:FailedCount
            Planned = $Script:PlannedCount; Cancelled = $cancelled
            InputBytes = $Script:TotalInputBytes; OutputBytes = $Script:TotalOutputBytes
            SavedBytes = $savedBytes; SavedText = (Format-ByteSize $savedBytes)
        }
        Send-AV1Event -Type 'Summary' -Data @{ Summary = $summary }
        return $summary
    }
    finally {
        $script:EventSink = $null
        $script:Cancellation = $null
    }
}

Export-ModuleMember -Function Invoke-AV1Batch
