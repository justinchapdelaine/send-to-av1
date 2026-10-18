<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Exercise Small mode with real FFmpeg/SVT-AV1 encodes and copied AAC tracks.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$optimizer = Join-Path $repoRoot 'src/Optimize-AV1.ps1'
$shell = (Get-Process -Id $PID).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('send-to-av1-tests-' + [Guid]::NewGuid().ToString('N'))
$script:checks = 0

function Find-Tool {
    param([string]$Name)
    $local = Join-Path $repoRoot "bin/$Name.exe"
    if (Test-Path -LiteralPath $local) { return $local }
    return (Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}

function Invoke-Tool {
    param([string]$Executable, [string[]]$Arguments, [int]$ExpectedExit = 0)
    # Windows PowerShell represents native stderr as error records.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Executable @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($code -ne $ExpectedExit) { throw "Unexpected exit code ${code}: $output" }
    return $output.Trim()
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Invoke-Optimizer {
    param([string[]]$Options, [int]$ExpectedExit = 0)
    return Invoke-Tool $shell (@('-NoProfile', '-File', $optimizer, '-NoPause') + $Options) $ExpectedExit
}

function Get-Video {
    param([string]$Path)
    $json = Invoke-Tool $ffprobe @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=codec_name,width,height,sample_aspect_ratio', '-of', 'json', $Path)
    return ($json | ConvertFrom-Json).streams[0]
}

try {
    $ffmpeg = Find-Tool 'ffmpeg'
    $ffprobe = Find-Tool 'ffprobe'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    # MOV timecode tracks are data streams that cannot be muxed into MKV.
    $timecodeSource = Join-Path $tempRoot 'timecode.mov'
    Invoke-Tool $ffmpeg @('-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=128x128:rate=25',
        '-f', 'lavfi', '-i', 'sine=frequency=440', '-f', 'lavfi', '-i', 'sine=frequency=660',
        '-t', '0.4', '-map', '0:v', '-map', '1:a', '-map', '2:a', '-c:v', 'mpeg4',
        '-c:a', 'aac', '-timecode', '01:00:00:00', $timecodeSource) | Out-Null
    $json = Invoke-Tool $ffprobe @('-v', 'error', '-show_streams', '-of', 'json', $timecodeSource)
    $streams = @(($json | ConvertFrom-Json).streams)
    Assert-True (@($streams | Where-Object { $_.codec_type -eq 'data' -and $_.codec_tag_string -eq 'tmcd' }).Count -eq 1) 'Fixture must contain a real MOV timecode data track.'
    $timecodeHash = (Get-FileHash -LiteralPath $timecodeSource).Hash
    $audioBefore = Invoke-Tool $ffmpeg @('-v', 'error', '-i', $timecodeSource, '-map', '0:a', '-c', 'copy', '-f', 'streamhash', '-hash', 'sha256', '-')
    foreach ($mode in @('cpu', 'small')) {
        $options = @('-Preset', '12', $timecodeSource)
        if ($mode -eq 'small') { $options = @('-Small') + $options }
        $log = Invoke-Optimizer $options
        Assert-True ($log -match 'Processed:\s+1' -and $log -match 'Failed:\s+0') ("MOV timecode conversion failed in {0} mode." -f $mode)
        $encoded = Join-Path $tempRoot 'timecode_AV1.mkv'
        if ($mode -eq 'small') { $encoded = Join-Path $tempRoot 'timecode_AV1_2.mkv' }
        $json = Invoke-Tool $ffprobe @('-v', 'error', '-show_streams', '-of', 'json', $encoded)
        $streams = @(($json | ConvertFrom-Json).streams)
        Assert-True (@($streams | Where-Object { $_.codec_type -eq 'data' -or $_.codec_type -eq 'unknown' }).Count -eq 0) 'Unsupported streams reached the output.'
        Assert-True ((Get-Video $encoded).codec_name -eq 'av1') 'Timecode fixture was not encoded to AV1.'
        $audioAfter = Invoke-Tool $ffmpeg @('-v', 'error', '-i', $encoded, '-map', '0:a', '-c', 'copy', '-f', 'streamhash', '-hash', 'sha256', '-')
        Assert-True (($audioBefore -split '\r?\n').Count -eq 2 -and $audioBefore -eq $audioAfter) 'Timecode conversion must preserve both AAC tracks byte-for-byte.'
    }
    Assert-True ((Get-FileHash -LiteralPath $timecodeSource).Hash -eq $timecodeHash) 'Timecode source was modified.'

    # Explicit stream selection must retain supported subtitles and attachments,
    # together with metadata and chapters, as well as every audio track.
    $subtitle = Join-Path $tempRoot 'captions.srt'
    $attachment = Join-Path $tempRoot 'note.txt'
    $metadata = Join-Path $tempRoot 'chapters.txt'
    Set-Content -LiteralPath $subtitle -Encoding Ascii -Value "1`n00:00:00,000 --> 00:00:00,300`nStream selection regression"
    Set-Content -LiteralPath $attachment -Encoding Ascii -Value 'Preserve this attachment.'
    Set-Content -LiteralPath $metadata -Encoding Ascii -Value ";FFMETADATA1`ntitle=Stream preservation`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=0`nEND=400`ntitle=Opening"
    $mediaSource = Join-Path $tempRoot 'supported-streams.mkv'
    Invoke-Tool $ffmpeg @('-v', 'error', '-i', $timecodeSource, '-i', $subtitle, '-f', 'ffmetadata', '-i', $metadata,
        '-map', '0:v', '-map', '0:a', '-map', '1:s', '-map_metadata', '2', '-map_chapters', '2',
        '-c', 'copy', '-attach', $attachment, '-metadata:s:t', 'mimetype=text/plain', $mediaSource) | Out-Null
    Invoke-Optimizer @('-Preset', '12', $mediaSource) | Out-Null
    $encoded = Join-Path $tempRoot 'supported-streams_AV1.mkv'
    $json = Invoke-Tool $ffprobe @('-v', 'error', '-show_streams', '-show_chapters', '-show_format', '-of', 'json', $encoded)
    $media = $json | ConvertFrom-Json
    Assert-True (@($media.streams | Where-Object { $_.codec_type -eq 'subtitle' -and $_.codec_name -eq 'subrip' }).Count -eq 1) 'Supported subtitle track was lost.'
    Assert-True (@($media.streams | Where-Object { $_.codec_type -eq 'attachment' -and $_.tags.filename -eq 'note.txt' }).Count -eq 1) 'Attachment was lost.'
    Assert-True ($media.format.tags.title -eq 'Stream preservation') 'Container metadata was lost.'
    Assert-True (@($media.chapters).Count -eq 1 -and $media.chapters[0].tags.title -eq 'Opening') 'Chapter metadata was lost.'
    $audioAfter = Invoke-Tool $ffmpeg @('-v', 'error', '-i', $encoded, '-map', '0:a', '-c', 'copy', '-f', 'streamhash', '-hash', 'sha256', '-')
    Assert-True ($audioBefore -eq $audioAfter) 'Supported-stream conversion must preserve both AAC tracks byte-for-byte.'
    $extracted = Join-Path $tempRoot 'extracted-note.txt'
    Invoke-Tool $ffmpeg @('-v', 'error', '-dump_attachment:t:0', $extracted, '-i', $encoded, '-map', '0:v:0', '-t', '0', '-f', 'null', '-') | Out-Null
    Assert-True ((Get-FileHash -LiteralPath $attachment).Hash -eq (Get-FileHash -LiteralPath $extracted).Hash) 'Attachment bytes were modified.'

    $source = Join-Path $tempRoot 'OBS recording.mkv'
    # Three independent AAC tracks mirror a common OBS recording setup.
    Invoke-Tool $ffmpeg @('-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1600x900:rate=5',
        '-f', 'lavfi', '-i', 'sine=frequency=440', '-f', 'lavfi', '-i', 'sine=frequency=660',
        '-f', 'lavfi', '-i', 'sine=frequency=880', '-t', '0.4', '-map', '0:v', '-map', '1:a',
        '-map', '2:a', '-map', '3:a', '-c:v', 'libsvtav1', '-preset', '12', '-threads', '2',
        '-svtav1-params', 'lp=2', '-c:a', 'aac', $source) | Out-Null
    $originalHash = (Get-FileHash -LiteralPath $source).Hash

    foreach ($options in @(@('-DryRun', $source), @('-Encoder', 'nvenc', '-DryRun', $source))) {
        $log = Invoke-Optimizer $options
        Assert-True ($log -match 'Skipped: source video codec is already AV1') 'Existing modes must still skip AV1.'
        Assert-True ($log -notmatch 'scale=') 'Existing modes must not apply Small scaling.'
    }
    $log = Invoke-Optimizer @('-Small', '-DryRun', $source)
    Assert-True ($log -match 'CRF 38, preset 5') 'Small defaults must be CRF 38 and preset 5.'
    Assert-True ($log -match 'Planned:\s+1') 'Small dry-run must accept an AV1 source.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'OBS recording_AV1.mkv'))) 'Dry-run created an output.'
    $log = Invoke-Optimizer @('-Small', '-Crf', '40', '-DryRun', $source)
    Assert-True ($log -match 'CRF 40') 'Explicit CRF override was ignored.'
    $log = Invoke-Optimizer @('-Small', '-Encoder', 'nvenc', '-DryRun', $source) 1
    Assert-True ($log -match 'cannot be combined') 'Incompatible encoder must be rejected.'

    $log = Invoke-Optimizer @('-Small', $source)
    Assert-True ($log -match 'Processed:\s+1' -and $log -match 'Failed:\s+0') 'Small AV1 encode failed.'
    $output = Join-Path $tempRoot 'OBS recording_AV1.mkv'
    $video = Get-Video $output
    Assert-True ($video.codec_name -eq 'av1' -and $video.width -eq 1280 -and $video.height -eq 720) 'AV1 source was not resized to 720p.'
    $audioBefore = Invoke-Tool $ffmpeg @('-v', 'error', '-i', $source, '-map', '0:a', '-c', 'copy', '-f', 'streamhash', '-hash', 'sha256', '-')
    $audioAfter = Invoke-Tool $ffmpeg @('-v', 'error', '-i', $output, '-map', '0:a', '-c', 'copy', '-f', 'streamhash', '-hash', 'sha256', '-')
    Assert-True (($audioBefore -split '\r?\n').Count -eq 3 -and $audioBefore -eq $audioAfter) 'All three AAC tracks must be copied byte-for-byte.'
    Assert-True ((Get-FileHash -LiteralPath $source).Hash -eq $originalHash) 'Source file was modified.'

    $outputHash = (Get-FileHash -LiteralPath $output).Hash
    Invoke-Optimizer @('-Small', '-Preset', '12', $source) | Out-Null
    Assert-True ((Test-Path -LiteralPath (Join-Path $tempRoot 'OBS recording_AV1_2.mkv')) -and
        (Get-FileHash -LiteralPath $output).Hash -eq $outputHash) 'Existing output was not preserved.'

    foreach ($case in @(@('small', '320x180', 320, 180), @('portrait', '900x1600', 405, 720), @('wide', '1600x600', 1280, 480), @('odd', '321x181', 320, 180))) {
        $inputFile = Join-Path $tempRoot ($case[0] + '.mkv')
        Invoke-Tool $ffmpeg @('-v', 'error', '-f', 'lavfi', '-i', ("testsrc=size={0}:rate=5,format=yuv444p" -f $case[1]),
            '-t', '0.2', '-c:v', 'ffv1', $inputFile) | Out-Null
        $log = Invoke-Optimizer @('-DryRun', $inputFile)
        Assert-True ($log -match 'CRF 34, preset 5' -and $log -notmatch 'scale=') 'Default CPU settings changed.'
        Invoke-Optimizer @('-Small', '-Preset', '12', $inputFile) | Out-Null
        $video = Get-Video (Join-Path $tempRoot ($case[0] + '_AV1.mkv'))
        # One-pixel tolerance before even rounding accommodates FFmpeg versions.
        Assert-True ([Math]::Abs($video.width - $case[2]) -le 1 -and $video.height -eq $case[3] -and
            $video.width % 2 -eq 0 -and $video.height % 2 -eq 0) ("Incorrect scaling for {0}: {1}x{2}." -f $case[0], $video.width, $video.height)
        $dimensions = $case[1] -split 'x'
        Assert-True ($video.width -le [int]$dimensions[0] -and $video.height -le [int]$dimensions[1]) 'Small mode upscaled an input.'
        $sar = $video.sample_aspect_ratio -split ':'
        $actualAspect = ($video.width / [double]$video.height) * ([double]$sar[0] / [double]$sar[1])
        Assert-True ([Math]::Abs($actualAspect - ([double]$dimensions[0] / [double]$dimensions[1])) -lt 0.001) 'Display aspect ratio changed.'
    }
    # Measure actual keyframes across frame rates for both CPU modes.
    foreach ($case in @(@('cpu-25', '25', 25.0, $false), @('small-60', '60', 60.0, $true))) {
        $inputFile = Join-Path $tempRoot ($case[0] + '.mkv')
        Invoke-Tool $ffmpeg @('-v', 'error', '-f', 'lavfi', '-i', ("testsrc2=size=128x128:rate={0}" -f $case[1]),
            '-t', '21', '-c:v', 'ffv1', $inputFile) | Out-Null
        $options = @('-Preset', '12', $inputFile)
        if ($case[3]) { $options = @('-Small') + $options }
        $log = Invoke-Optimizer $options
        Assert-True ($log -match 'Processed:\s+1' -and $log -match 'Failed:\s+0') 'Keyframe cadence encode failed.'
        $encoded = Join-Path $tempRoot ($case[0] + '_AV1.mkv')
        $json = Invoke-Tool $ffprobe @('-v', 'error', '-select_streams', 'v:0', '-show_frames',
            '-show_entries', 'frame=key_frame,best_effort_timestamp_time', '-of', 'json', $encoded)
        $keys = @(($json | ConvertFrom-Json).frames | Where-Object { $_.key_frame -eq 1 })
        Assert-True ($keys.Count -eq 3) ("Expected three keyframes in 21 seconds at {0} fps, found {1}." -f $case[1], $keys.Count)
        for ($index = 1; $index -lt $keys.Count; $index++) {
            $current = [double]::Parse($keys[$index].best_effort_timestamp_time, [Globalization.CultureInfo]::InvariantCulture)
            $previous = [double]::Parse($keys[$index - 1].best_effort_timestamp_time, [Globalization.CultureInfo]::InvariantCulture)
            $interval = $current - $previous
            Assert-True ([Math]::Abs($interval - 10.0) -lt (2.0 / $case[2])) ("Keyframe interval was {0} seconds at {1} fps." -f $interval, $case[1])
        }
    }
    Write-Host ("Small-mode integration checks passed: {0}." -f $script:checks)
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
