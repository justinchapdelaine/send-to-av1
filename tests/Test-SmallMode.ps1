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
    Write-Host ("Small-mode integration checks passed: {0}." -f $script:checks)
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
