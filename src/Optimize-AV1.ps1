<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Optimize one or more videos for storage by converting video streams to AV1.

.DESCRIPTION
    Send to AV1 is designed to be launched from the Windows Send To menu.
    It preserves original files, writes AV1 outputs next to the source files,
    and copies non-video streams where possible.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputPath,

    [switch]$NoPause,

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
    [string]$NvencTune = 'auto'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:ProcessedCount = 0
$Script:PlannedCount = 0
$Script:SkippedCount = 0
$Script:FailedCount = 0
$Script:TotalInputBytes = [int64]0
$Script:TotalOutputBytes = [int64]0

$Script:KnownVideoExtensions = @(
    '.3g2', '.3gp', '.avi', '.divx', '.flv', '.m2ts', '.m4v', '.mkv',
    '.mov', '.mp4', '.mpeg', '.mpg', '.mts', '.mxf', '.ogm', '.ogv',
    '.ts', '.vob', '.webm', '.wmv'
)

function Write-Section {
    param([string]$Message)
    Write-Host ''
    Write-Host '============================================================'
    Write-Host $Message
    Write-Host '============================================================'
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

function Get-FfmpegEncoderOutput {
    param([string]$FfmpegPath)

    $encoderOutput = & $FfmpegPath -hide_banner -encoders 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to query FFmpeg encoders.'
    }

    return $encoderOutput
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

    $helpOutput = & $FfmpegPath -hide_banner -h encoder=av1_nvenc 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to query av1_nvenc options.'
    }

    return $helpOutput
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
        catch {
            Write-Host ('Warning: av1_nvenc was found, but its options could not be queried: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
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

    Write-Host ''
    Write-Host 'Capability summary:'
    Write-Host ('  FFmpeg:            {0}' -f 'Found')
    Write-Host ('  FFprobe:           {0}' -f (Format-CapabilityStatus $Capabilities.HasFfprobe))
    Write-Host ('  CPU/SVT-AV1:       {0}' -f (Format-CapabilityStatus $Capabilities.HasSvtAv1))
    $nvencStatus = 'Unavailable'
    if ($Capabilities.HasNvencAv1) {
        $nvencStatus = 'Available in FFmpeg'
    }

    Write-Host ('  NVIDIA AV1 NVENC:  {0}' -f $nvencStatus)
    Write-Host ('  NVIDIA tune:       {0}' -f $nvencTuneStatus)
    if ($Capabilities.HasNvencAv1) {
        # Encoder presence only proves the FFmpeg build supports NVENC; the
        # active machine still needs compatible NVIDIA hardware and drivers.
        Write-Host '  NVIDIA hardware:   Requires a GPU and driver with AV1 encode support'
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

    Write-Host ''
    Write-Host 'Selected encoder:'
    $encoderOutput = $Capabilities.EncoderOutput

    if ($EncoderName -eq 'svt') {
        if (-not (Test-FfmpegEncoder -EncoderOutput $encoderOutput -EncoderName 'libsvtav1')) {
            throw 'This FFmpeg build does not appear to support libsvtav1. Use an FFmpeg build that includes the SVT-AV1 encoder.'
        }

        Write-Host '  CPU/SVT-AV1'
        return [PSCustomObject]@{
            Encoder = 'svt'
            DisplayName = 'SVT-AV1 CPU'
            Summary = ('SVT-AV1, CRF {0}, preset {1}, GOP 240, tune 0, 10-bit' -f $CrfValue, $PresetValue)
            FfmpegVideoArgs = @(
                '-c:v', 'libsvtav1',
                '-crf', $CrfValue.ToString(),
                '-preset', $PresetValue.ToString(),
                '-g', '240',
                '-svtav1-params', 'tune=0',
                '-pix_fmt', 'yuv420p10le'
            )
        }
    }

    if (-not (Test-FfmpegEncoder -EncoderOutput $encoderOutput -EncoderName 'av1_nvenc')) {
        throw 'This FFmpeg build does not appear to support av1_nvenc. Use an FFmpeg build with NVIDIA NVENC AV1 support.'
    }

    Write-Host '  NVIDIA AV1 NVENC'
    $nvencHelp = $Capabilities.NvencHelpOutput
    if ([string]::IsNullOrWhiteSpace($nvencHelp)) {
        $nvencHelp = Get-NvencHelpOutput -FfmpegPath $FfmpegPath
    }
    $resolvedTune = Resolve-NvencTune -NvencHelpOutput $nvencHelp -RequestedTune $NvencTuneValue

    if ($NvencTuneValue -eq 'auto' -and $resolvedTune -eq 'hq') {
        Write-Host 'NVIDIA AV1 mode: HQ fallback - UHQ was not found in this FFmpeg build.' -ForegroundColor Yellow
    }
    else {
        Write-Host ("NVIDIA AV1 mode: {0}" -f $resolvedTune.ToUpperInvariant())
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

function Get-PrimaryVideoCodec {
    param(
        [string]$FfprobePath,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($FfprobePath)) {
        return $null
    }

    try {
        $probeArgs = @(
            '-v', 'error',
            '-select_streams', 'v:0',
            '-show_entries', 'stream=codec_name,codec_type',
            '-of', 'json',
            $Path
        )

        $probeOutput = & $FfprobePath @probeArgs 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($probeOutput)) {
            return $null
        }

        $probe = $probeOutput | ConvertFrom-Json
        $stream = @($probe.streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
        if ($null -eq $stream -or [string]::IsNullOrWhiteSpace($stream.codec_name)) {
            return $null
        }

        return $stream.codec_name.Trim().ToLowerInvariant()
    }
    catch {
        return $null
    }
}

function Get-MediaDuration {
    param([string]$FfprobePath, [string]$Path)

    if ([string]::IsNullOrWhiteSpace($FfprobePath)) { return 0.0 }
    try {
        $text = & $FfprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $Path 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) { return 0.0 }
        $duration = 0.0
        if ([double]::TryParse($text.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration) -and
            $duration -gt 0 -and -not [double]::IsInfinity($duration)) {
            return $duration
        }
    }
    catch { }
    return 0.0
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

    return [PSCustomObject]@{ Percent = $percent; SecondsRemaining = $remaining; Status = $status }
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
            Write-Host 'FFmpeg error details:' -ForegroundColor Red
            Get-Content -LiteralPath $LogPath -Encoding UTF8 -Tail 25 | ForEach-Object { Write-Host $_ }
        }
        else {
            # FFmpeg may recover from decoder errors and still return zero.
            # Match severity tags, not words in file names or normal info lines.
            $errorPattern = '(?i)^\s*(?:(?:\[[^\]]+\]\s*)*\[(?:error|fatal|panic)\]|Svt\[(?:error|fatal|panic)\]:)'
            $errors = @(Get-Content -LiteralPath $LogPath -Encoding UTF8 |
                Where-Object { $_ -match $errorPattern } | Select-Object -Last 25)
            if ($errors.Count -gt 0) {
                Write-Host 'Warning: FFmpeg reported errors despite exiting successfully. Check the output before relying on it.' -ForegroundColor Yellow
                $errors | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
            }
        }
        return $true
    }
    catch {
        Write-Host ('Warning: Could not read encoder diagnostics; retaining log: {0}. {1}' -f $LogPath, $_.Exception.Message) -ForegroundColor Yellow
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
        $started = $process.Start()
        # Drain stderr independently so a verbose encoder cannot block stdout.
        # A .NET copy task avoids PowerShell callbacks on threads without runspaces.
        $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($logStream)
        $nextLine = $process.StandardOutput.ReadLineAsync()
        $stdoutEnded = $false
        while (-not $stdoutEnded -or -not $process.HasExited) {
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
                Write-Progress -Id 1 -Activity $Activity -Status $progress.Status -PercentComplete $progress.Percent
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
                    if ($retainLog) { Write-Host ('Diagnostic log: {0}' -f $logPath) }
                    else { Remove-Item -LiteralPath $logPath -Force -ErrorAction Stop }
                }
            }
            catch {
                Write-Host ('Warning: Could not delete temporary diagnostic log: {0}. {1}' -f $logPath, $_.Exception.Message) -ForegroundColor Yellow
            }
            Write-Progress -Id 1 -Activity $Activity -Completed
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
    Write-Host ("Input:  {0}" -f $resolvedInput)

    $codec = Get-PrimaryVideoCodec -FfprobePath $FfprobePath -Path $resolvedInput
    if ($codec -eq 'av1' -and -not $Small) {
        Write-Host 'Skipped: source video codec is already AV1.' -ForegroundColor Yellow
        $Script:SkippedCount++
        return
    }

    if ($null -eq $codec) {
        if (-not [string]::IsNullOrWhiteSpace($FfprobePath)) {
            Write-Host 'Skipped: ffprobe did not find a primary video stream.' -ForegroundColor Yellow
            $Script:SkippedCount++
            return
        }

        # Without ffprobe we cannot inspect streams safely, so use only a
        # conservative extension check before attempting conversion.
        if (-not (Test-LikelyVideoFile -Path $resolvedInput)) {
            Write-Host 'Skipped: file extension is not recognized as a common video type, and ffprobe is unavailable.' -ForegroundColor Yellow
            $Script:SkippedCount++
            return
        }

        Write-Host 'Warning: ffprobe is unavailable, so the source video codec could not be checked. Continuing because the extension looks like video.' -ForegroundColor Yellow
    }
    else {
        Write-Host ("Detected video codec: {0}" -f $codec)
    }

    $finalOutput = New-UniqueOutputPath -InputFile $resolvedInput -Container $Container
    # FFmpeg writes to a temporary file first so an interrupted or failed encode
    # never leaves an incomplete file with the final output name.
    $tempOutput = New-TemporaryOutputPath -FinalOutputPath $finalOutput -Container $Container

    Write-Host ("Output: {0}" -f $finalOutput)
    Write-Host ("Preset: {0}" -f $EncoderConfiguration.Summary)
    Write-Host ("Container: {0}" -f $Container.ToUpperInvariant())
    Write-Host ''

    if ($Container -eq 'mp4') {
        Write-Host 'Warning: MP4 output may reject some copied subtitle, attachment, or metadata streams. Use MKV for maximum preservation.' -ForegroundColor Yellow
        Write-Host ''
    }

    $ffmpegArgs = @(
        '-hide_banner',
        '-loglevel', 'level+info',
        '-nostdin',
        '-nostats',
        '-progress', 'pipe:1',
        '-stats_period', '1',
        '-y',
        '-i', $resolvedInput,
        '-map', '0',
        '-map_metadata', '0',
        '-map_chapters', '0',
        '-c', 'copy'
    )
    $ffmpegArgs += @($EncoderConfiguration.FfmpegVideoArgs)
    $ffmpegArgs += $tempOutput

    if ($DryRun) {
        Write-Host 'Dry run: FFmpeg was not started.'
        $commandPreview = (@($FfmpegPath) + $ffmpegArgs | ForEach-Object { Format-CommandArgument -Argument $_ }) -join ' '
        Write-Host ('Command: & {0}' -f $commandPreview)
        $Script:PlannedCount++
        return
    }

    $duration = Get-MediaDuration -FfprobePath $FfprobePath -Path $resolvedInput
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

        Write-Host ''
        Write-Host ("Failed: FFmpeg exited with code {0}." -f $exitCode) -ForegroundColor Red
        if ($EncoderConfiguration.Encoder -eq 'nvenc') {
            Write-Host 'Hint: FFmpeg exposes av1_nvenc, but the active NVIDIA GPU, driver, or session may still not support AV1 encoding.' -ForegroundColor Yellow
            Write-Host 'Try updating the NVIDIA driver, confirming the GPU supports AV1 encode, or using the default CPU preset.' -ForegroundColor Yellow
        }
        elseif ($Container -eq 'mp4') {
            Write-Host 'Hint: MP4 output can fail when copied streams are not MP4-compatible. Try the default MKV container.' -ForegroundColor Yellow
        }
        $Script:FailedCount++
        return
    }

    if (-not (Test-Path -LiteralPath $tempOutput -PathType Leaf)) {
        Write-Host ''
        Write-Host 'Failed: FFmpeg completed but no output file was found.' -ForegroundColor Red
        $Script:FailedCount++
        return
    }

    $completedOutput = Complete-OutputFile -TemporaryPath $tempOutput -OutputPath $finalOutput -InputFile $resolvedInput -Container $Container
    if ($completedOutput -ne $finalOutput) {
        Write-Host ("Output name was taken during encoding; saved as: {0}" -f $completedOutput)
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

    Write-Host ''
    Write-Host 'Completed.' -ForegroundColor Green
    Write-Host ("Original size:  {0}" -f (Format-ByteSize $inputItem.Length))
    Write-Host ("AV1 size:       {0}" -f (Format-ByteSize $outputItem.Length))
    Write-Host ("Saved:          {0:N1}% ({1})" -f $savedPercent, (Format-ByteSize $savedBytes))

    if ($savedBytes -lt 0) {
        Write-Host 'Warning: output is larger than the original. Original file was not modified.' -ForegroundColor Yellow
    }
}

try {
    Write-Section 'Send to AV1'

    if ($Small) {
        if ($Encoder -ne 'svt') {
            throw '-Small uses CPU/SVT-AV1 and cannot be combined with -Encoder nvenc.'
        }
        if (-not $PSBoundParameters.ContainsKey('Crf')) {
            $Crf = 38
        }
        Write-Host 'Small-file mode: fit within 1280x720, allow AV1 re-encoding, copy audio unchanged.'
    }

    $ffmpeg = Resolve-ToolPath -ToolName 'ffmpeg'
    if ([string]::IsNullOrWhiteSpace($ffmpeg)) {
        throw 'FFmpeg was not found. Put ffmpeg.exe in the project root .\bin folder or install FFmpeg so it is available on PATH.'
    }

    $ffprobe = Resolve-ToolPath -ToolName 'ffprobe'
    if ([string]::IsNullOrWhiteSpace($ffprobe)) {
        Write-Host 'Warning: ffprobe was not found. Codec detection and AV1 skipping may be unavailable.' -ForegroundColor Yellow
    }

    $capabilities = Get-ToolCapabilities -FfmpegPath $ffmpeg -FfprobePath $ffprobe

    if ($Diagnostics) {
        Write-Host ("FFmpeg:  {0}" -f $ffmpeg)
        if (-not [string]::IsNullOrWhiteSpace($ffprobe)) {
            Write-Host ("FFprobe: {0}" -f $ffprobe)
        }
        Write-CapabilitySummary -Capabilities $capabilities
        Write-Host ''
        Write-Host 'Diagnostics complete. No input files were processed.'
        return
    }

    if ($null -eq $InputPath -or $InputPath.Count -eq 0) {
        throw 'No input files were provided. Use the Windows Send To menu, pass one or more file paths, or run -Diagnostics.'
    }

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
        $fileNumber++
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Section ("Skipping missing path: {0}" -f $path)
            Write-Host 'Skipped: path does not exist or is not a file.' -ForegroundColor Yellow
            $Script:SkippedCount++
            continue
        }

        try {
            Convert-VideoToAv1 -FfmpegPath $ffmpeg -FfprobePath $ffprobe -EncoderConfiguration $encoderConfiguration -Container $OutputContainer -DryRun:$DryRun -Small:$Small -KeepLog:$KeepLog -FileNumber $fileNumber -FileCount $InputPath.Count -Path $path
        }
        catch {
            Write-Host ''
            Write-Host ('Failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
            $Script:FailedCount++
        }
    }

    Write-Section 'Summary'
    Write-Host ("Encoder:   {0}" -f $encoderConfiguration.DisplayName)
    Write-Host ("Container: {0}" -f $OutputContainer.ToUpperInvariant())
    if ($DryRun) {
        Write-Host ("Planned:   {0}" -f $Script:PlannedCount)
    }
    Write-Host ("Processed: {0}" -f $Script:ProcessedCount)
    Write-Host ("Skipped:   {0}" -f $Script:SkippedCount)
    Write-Host ("Failed:    {0}" -f $Script:FailedCount)

    if ($Script:ProcessedCount -gt 0) {
        $totalSaved = $Script:TotalInputBytes - $Script:TotalOutputBytes
        $totalPercent = 0
        if ($Script:TotalInputBytes -gt 0) {
            $totalPercent = ($totalSaved / [double]$Script:TotalInputBytes) * 100
        }

        Write-Host ("Input total:  {0}" -f (Format-ByteSize $Script:TotalInputBytes))
        Write-Host ("Output total: {0}" -f (Format-ByteSize $Script:TotalOutputBytes))
        Write-Host ("Total saved:  {0:N1}% ({1})" -f $totalPercent, (Format-ByteSize $totalSaved))
    }
}
catch {
    Write-Host ''
    Write-Host 'Fatal error:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    $Script:FailedCount++
}
finally {
    if (-not $NoPause) {
        Write-Host ''
        Read-Host 'Press Enter to close'
    }
}

if ($Script:FailedCount -gt 0) {
    exit 1
}

exit 0
