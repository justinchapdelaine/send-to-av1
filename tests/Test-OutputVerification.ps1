<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Verify real media metadata and publication/cleanup after failed or cancelled checks.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$core = Import-Module (Join-Path $repoRoot 'src/AV1.Core.psm1') -Force -PassThru
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('av1-verification-' + [Guid]::NewGuid().ToString('N'))
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Invoke-Tool {
    param([string[]]$Arguments)
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = & $ffmpeg @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw $text }
}
function Get-Info {
    param([string]$Path)
    & $core { param($Tool, $Path) Get-MediaVerificationInfo -FfprobePath $Tool -Path $Path -Purpose 'Test inspection' } $ffprobe $Path
}
function Assert-Rejected {
    param([string]$Path, $Expected, [string]$Pattern)
    $errorText = ''
    try { & $core { param($Tool, $Path, $Expected) Assert-AV1Output -FfprobePath $Tool -Path $Path -Expected $Expected } $ffprobe $Path $Expected }
    catch { $errorText = $_.Exception.Message }
    Assert-True ($errorText -match $Pattern) ('Verification did not reject the fixture: ' + $errorText)
}
function Invoke-Case {
    param([Threading.CancellationTokenSource]$Cancellation, [switch]$CancelVerification)
    $events = [Collections.Generic.List[object]]::new()
    $sink = {
        param($update)
        $events.Add($update)
        if ($CancelVerification -and $update.Type -eq 'InspectionStarted' -and $update.Data.Purpose -eq 'Output verification') { $Cancellation.Cancel() }
    }.GetNewClosure()
    $inputs = @($source)
    if ($CancelVerification) { $inputs += $source }
    $summary = Invoke-AV1Batch -InputPath $inputs -Small -Preset 12 -EventSink $sink -Cancellation $Cancellation
    return [PSCustomObject]@{ Summary = $summary; Events = $events.ToArray() }
}
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $ffmpeg = & $core { Resolve-ToolPath ffmpeg }
    $ffprobe = & $core { Resolve-ToolPath ffprobe }
    if (-not $ffmpeg -or -not $ffprobe) { throw 'FFmpeg/SVT-AV1 and FFprobe are required.' }
    $source = Join-Path $tempRoot ('source [test] caf' + [char]0xe9 + '.mkv')
    $subtitles = Join-Path $tempRoot 'subtitle.srt'
    "1`r`n00:00:00,000 --> 00:00:05,000`r`nVerification fixture`r`n" | Set-Content -LiteralPath $subtitles -Encoding UTF8
    Invoke-Tool @('-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=128x128:rate=10', '-f', 'lavfi', '-i', 'sine=frequency=400',
        '-i', $subtitles, '-map', '0:v', '-map', '1:a', '-map', '1:a', '-map', '2:s', '-t', '6', '-c:v', 'ffv1', '-c:a', 'aac', '-c:s', 'srt', $source)
    $sourceHash = (Get-FileHash -LiteralPath $source).Hash
    $expected = Get-Info $source
    Assert-True ($expected.VideoCount -eq 1 -and $expected.AudioCount -eq 2 -and $expected.SubtitleCount -eq 1) 'The multi-stream source fixture is invalid.'
    $run = Invoke-Case
    Assert-True ($run.Summary.Processed -eq 1 -and $run.Summary.Failed -eq 0) 'A valid real encode failed verification.'
    $completed = @($run.Events | Where-Object { $_.Type -eq 'FileResult' -and $_.Data.Status -eq 'Completed' })
    $good = $completed[0].Data.OutputPath
    $goodHash = (Get-FileHash -LiteralPath $good).Hash
    $verificationIndex = -1; $completionIndex = -1
    for ($i = 0; $i -lt $run.Events.Count; $i++) {
        if ($run.Events[$i].Type -eq 'VerificationStarted') { $verificationIndex = $i }
        if ($run.Events[$i].Type -eq 'FileResult') { $completionIndex = $i }
    }
    Assert-True ($verificationIndex -ge 0 -and $completionIndex -gt $verificationIndex) 'Completion was reported before verification.'
    Assert-True (@($run.Events | Where-Object { $_.Type -eq 'Message' -and $_.Data.Message -eq 'Output verification passed.' }).Count -eq 1) 'Successful verification was not reported.'

    Assert-Rejected $source $expected 'only AV1'
    $audioOnly = Join-Path $tempRoot 'audio-only.mkv'
    Invoke-Tool @('-v', 'error', '-i', $good, '-map', '0:a', '-c', 'copy', $audioOnly)
    Assert-Rejected $audioOnly $expected 'only AV1'
    $missingAudio = Join-Path $tempRoot 'missing-audio.mkv'
    Invoke-Tool @('-v', 'error', '-i', $good, '-map', '0:v', '-map', '0:a:0', '-map', '0:s', '-c', 'copy', $missingAudio)
    Assert-Rejected $missingAudio $expected 'expected 2 audio stream\(s\), found 1'
    $missingSubtitle = Join-Path $tempRoot 'missing-subtitle.mkv'
    Invoke-Tool @('-v', 'error', '-i', $good, '-map', '0:v', '-map', '0:a', '-c', 'copy', $missingSubtitle)
    Assert-Rejected $missingSubtitle $expected 'expected 1 subtitle stream\(s\), found 0'
    $short = Join-Path $tempRoot 'truncated.mkv'
    Invoke-Tool @('-v', 'error', '-i', $good, '-map', '0:v', '-map', '0:a', '-c', 'copy', '-t', '1', $short)
    $withoutSubtitle = $expected.PSObject.Copy(); $withoutSubtitle.SubtitleCount = 0
    Assert-Rejected $short $withoutSubtitle 'duration changed'
    $unreadable = Join-Path $tempRoot 'unreadable.mkv'
    'This is not a video.' | Set-Content -LiteralPath $unreadable
    Assert-Rejected $unreadable $expected 'Output verification failed'

    # Valid shifted timelines must not look like truncated outputs. Matroska
    # and MP4 duration fields differ from MPEG-TS when start timestamps are nonzero.
    $offset = Join-Path $tempRoot 'offset.mkv'
    Invoke-Tool @('-v', 'error', '-i', $source, '-map', '0', '-c', 'copy', '-output_ts_offset', '5', $offset)
    $offsetInfo = Get-Info $offset
    Assert-True ([Math]::Abs($offsetInfo.DurationSeconds - $expected.DurationSeconds) -lt 0.2) 'Shifted Matroska timestamps inflated the expected duration.'
    & $core { param($Tool, $Path, $Expected) Assert-AV1Output -FfprobePath $Tool -Path $Path -Expected $Expected } $ffprobe $good $offsetInfo
    $offsetMp4 = Join-Path $tempRoot 'offset.mp4'
    Invoke-Tool @('-v', 'error', '-i', $good, '-map', '0:v', '-map', '0:a', '-c', 'copy', '-output_ts_offset', '5', $offsetMp4)
    Assert-True ([Math]::Abs((Get-Info $offsetMp4).DurationSeconds - $expected.DurationSeconds) -lt 0.2) 'Shifted MP4 timestamps inflated the expected duration.'
    $offsetTs = Join-Path $tempRoot 'offset.ts'
    Invoke-Tool @('-v', 'error', '-i', $source, '-map', '0:v', '-c:v', 'mpeg2video', '-output_ts_offset', '5', $offsetTs)
    Assert-True ([Math]::Abs((Get-Info $offsetTs).DurationSeconds - 6) -lt 0.2) 'MPEG-TS duration was incorrectly shortened by its start timestamp.'
    $unknownDuration = $expected.PSObject.Copy(); $unknownDuration.DurationSeconds = 0
    $warnings = [Collections.Generic.List[object]]::new()
    & $core {
        param($Tool, $Path, $Expected, $Events)
        $script:EventSink = { param($update) $Events.Add($update) }.GetNewClosure()
        try { Assert-AV1Output -FfprobePath $Tool -Path $Path -Expected $Expected }
        finally { $script:EventSink = $null }
    } $ffprobe $good $unknownDuration $warnings
    Assert-True (@($warnings | Where-Object { $_.Type -eq 'Message' -and $_.Data.Color -eq 'Yellow' -and $_.Data.Message -match 'duration was unavailable' }).Count -eq 1) 'An unavailable duration was silently treated as fully verified.'

    # Simulate an encoder returning success with a faulty file, while retaining
    # the real source/output probes and the actual batch publication logic.
    $originalEncode = & $core { (Get-Item Function:Invoke-FfmpegEncode).ScriptBlock }
    $originalResolve = & $core { (Get-Item Function:Resolve-ToolPath).ScriptBlock }
    $originalQuery = & $core { (Get-Item Function:Invoke-AV1ToolQuery).ScriptBlock }
    try {
        & $core {
            param($Fixture)
            $script:VerificationFixture = $Fixture
            function script:Invoke-FfmpegEncode {
                param($FfmpegPath, $Arguments, $Activity, $DurationSeconds, [switch]$KeepLog)
                Copy-Item -LiteralPath $script:VerificationFixture -Destination $Arguments[-1]
                return 0
            }
        } $missingAudio
        $run = Invoke-Case
        Assert-True ($run.Summary.Failed -eq 1 -and $run.Summary.Processed -eq 0) 'A verification failure was counted as a completed encode.'
        Assert-True (@($run.Events | Where-Object { $_.Type -eq 'FileResult' -and $_.Data.Status -eq 'Failed' -and $_.Data.Message -match 'audio' }).Count -eq 1) 'Verification failure details were lost.'
        Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*_AV1*.mkv').Count -eq 1 -and
            @(Get-ChildItem -LiteralPath $tempRoot -Filter '*.tmp.*').Count -eq 0) 'Failed verification published or retained a temporary encode.'
        & $core { param($Fixture) $script:VerificationFixture = $Fixture } $good
        $cancellation = [Threading.CancellationTokenSource]::new()
        try {
            $run = Invoke-Case -Cancellation $cancellation -CancelVerification
            Assert-True ($run.Summary.Cancelled -and $run.Summary.Failed -eq 0 -and $run.Summary.Processed -eq 0) 'Verification cancellation was swallowed or counted as failure.'
            Assert-True (@($run.Events | Where-Object Type -eq FileStarted).Count -eq 1) 'Verification cancellation started the next file.'
            foreach ($inspection in @($run.Events | Where-Object Type -eq InspectionStarted)) {
                Assert-True ($null -eq (Get-Process -Id $inspection.Data.ProcessId -ErrorAction SilentlyContinue)) 'Cancellation left an inspection process running.'
            }
            Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*_AV1*.mkv').Count -eq 1 -and
                @(Get-ChildItem -LiteralPath $tempRoot -Filter '*.tmp.*').Count -eq 0) 'Verification cancellation published or retained a temporary encode.'
        }
        finally { $cancellation.Dispose() }

        & $core {
            param($Query, $Shell)
            $script:VerificationQuery = $Query
            $script:VerificationShell = $Shell
            function script:Invoke-AV1ToolQuery {
                param($Executable, $Arguments, $Purpose, $TimeoutSeconds = 30)
                if ($Purpose -eq 'Output verification') {
                    $Executable = $script:VerificationShell
                    $Arguments = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
                    $TimeoutSeconds = 1
                }
                & $script:VerificationQuery -Executable $Executable -Arguments $Arguments -Purpose $Purpose -TimeoutSeconds $TimeoutSeconds
            }
        } $originalQuery (Get-Process -Id $PID).Path
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-Case
        Assert-True ($run.Summary.Failed -eq 1 -and $run.Summary.Processed -eq 0 -and $clock.Elapsed.TotalSeconds -lt 10) 'A verification timeout did not promptly fail the file.'
        Assert-True (@($run.Events | Where-Object { $_.Type -eq 'FileResult' -and $_.Data.Message -match 'Output verification timed out' }).Count -eq 1) 'The verification timeout was not explained.'
        foreach ($inspection in @($run.Events | Where-Object Type -eq InspectionStarted)) {
            Assert-True ($null -eq (Get-Process -Id $inspection.Data.ProcessId -ErrorAction SilentlyContinue)) 'Timeout left an inspection process running.'
        }
        Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*_AV1*.mkv').Count -eq 1 -and
            @(Get-ChildItem -LiteralPath $tempRoot -Filter '*.tmp.*').Count -eq 0) 'Verification timeout published or retained a temporary encode.'

        & $core {
            param($Tool)
            $script:VerificationFfmpeg = $Tool
            function script:Resolve-ToolPath {
                param($ToolName)
                if ($ToolName -eq 'ffprobe') { return $null }
                return $script:VerificationFfmpeg
            }
        } $ffmpeg
        $run = Invoke-Case
        Assert-True ($run.Summary.Processed -eq 1 -and $run.Summary.Failed -eq 0) 'Missing FFprobe broke the existing fallback.'
        Assert-True (@($run.Events | Where-Object { $_.Type -eq 'Message' -and $_.Data.Color -eq 'Yellow' -and $_.Data.Message -match 'verification was skipped' }).Count -eq 1) 'Unverified output was not explained.'
    }
    finally {
        & $core { param($Encode, $Resolve, $Query) Set-Item Function:script:Invoke-FfmpegEncode $Encode; Set-Item Function:script:Resolve-ToolPath $Resolve; Set-Item Function:script:Invoke-AV1ToolQuery $Query } $originalEncode $originalResolve $originalQuery
    }
    Assert-True ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash -and (Get-FileHash -LiteralPath $good).Hash -eq $goodHash) 'Verification modified an original or existing completed output.'
    Write-Host ('Output verification checks passed: {0}.' -f $script:checks)
}
finally {
    Remove-Module $core.Name -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
