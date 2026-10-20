<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Verify cancellation, timeout cleanup, and output capture during tool inspection.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$core = Import-Module (Join-Path $repoRoot 'src/AV1.Core.psm1') -Force -PassThru
$shell = (Get-Process -Id $PID).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('send-to-av1-inspection-' + [Guid]::NewGuid().ToString('N'))
$script:checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Invoke-TestQuery {
    param([hashtable]$Options, [scriptblock]$Sink, [Threading.CancellationTokenSource]$Cancellation)
    & $core {
        param($Options, $Sink, $Cancellation)
        $script:EventSink = $Sink
        $script:Cancellation = $Cancellation
        try { Invoke-AV1ToolQuery @Options }
        finally { $script:EventSink = $null; $script:Cancellation = $null }
    } $Options $Sink $Cancellation
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $fake = Join-Path $tempRoot 'query fixture.ps1'
    @'
param([switch]$Hang)
if ($Hang) { Start-Sleep -Seconds 30; exit 0 }
[Console]::Out.WriteLine(('stdout padding ' * 10000) + 'stdout end')
[Console]::Error.WriteLine(('stderr padding ' * 10000) + 'stderr end')
exit 7
'@ | Set-Content -LiteralPath $fake
    $queryOptions = @{ Executable = $shell; Arguments = @('-NoProfile', '-File', $fake); Purpose = 'Fixture inspection' }
    $result = Invoke-TestQuery $queryOptions
    Assert-True ($result.ExitCode -eq 7) 'Query lost its native exit status.'
    Assert-True ($result.StandardOutput.Length -gt 65536 -and $result.StandardOutput -match 'stdout end') 'Large stdout was truncated or blocked.'
    Assert-True ($result.StandardError.Length -gt 65536 -and $result.StandardError -match 'stderr end') 'Large stderr was truncated or blocked.'

    $queryOptions.Arguments += '-Hang'
    $events = New-Object 'Collections.Generic.List[object]'
    $sink = { param($update) $events.Add($update) }.GetNewClosure()
    $queryOptions.TimeoutSeconds = 1
    $timedOut = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try { Invoke-TestQuery $queryOptions $sink | Out-Null }
    catch [TimeoutException] { $timedOut = $true }
    Assert-True $timedOut 'A stalled query did not time out.'
    Assert-True ($clock.Elapsed.TotalSeconds -lt 5) 'Query timeout did not promptly return control.'
    $started = @($events | Where-Object { $_.Type -eq 'InspectionStarted' })
    Assert-True ($started.Count -eq 1) 'Timeout fixture did not start a child process.'
    Assert-True ($null -eq (Get-Process -Id $started[0].Data.ProcessId -ErrorAction SilentlyContinue)) 'Timeout left its query process running.'

    $queryOptions.TimeoutSeconds = 30
    $events.Clear()
    $cancellation = New-Object Threading.CancellationTokenSource
    try {
        $cancellation.CancelAfter(500)
        $cancelled = $false
        $clock.Restart()
        try { Invoke-TestQuery $queryOptions $sink $cancellation | Out-Null }
        catch [OperationCanceledException] { $cancelled = $true }
        Assert-True $cancelled 'A stalled query ignored cancellation.'
        Assert-True ($clock.Elapsed.TotalSeconds -lt 5) 'Cancellation waited for the query timeout.'
        $started = @($events | Where-Object { $_.Type -eq 'InspectionStarted' })
        Assert-True ($started.Count -eq 1) 'Cancellation fixture did not start a child process.'
        Assert-True ($null -eq (Get-Process -Id $started[0].Data.ProcessId -ErrorAction SilentlyContinue)) 'Cancellation left its query process running.'
    }
    finally { $cancellation.Dispose() }

    # Cancel each actual batch inspection stage to catch swallowed cancellation
    # in the source metadata fallback and the optional NVENC capability check.
    $ffmpeg = Join-Path $repoRoot 'bin/ffmpeg.exe'
    if (-not (Test-Path -LiteralPath $ffmpeg)) {
        $ffmpeg = (Get-Command ffmpeg -CommandType Application | Select-Object -First 1).Source
    }
    $source = Join-Path $tempRoot 'source.mkv'
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $ffmpeg -v error -f lavfi -i 'testsrc2=size=128x128:rate=25' -t 0.2 -c:v ffv1 $source
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw 'Could not create the inspection fixture.' }
    $sourceHash = (Get-FileHash -LiteralPath $source).Hash
    $purposes = @('FFmpeg encoder check', 'Source media inspection')
    $encoderOutput = & $core { param($Tool) Get-FfmpegEncoderOutput -FfmpegPath $Tool } $ffmpeg
    if ($encoderOutput -match '(?m)^\s*[A-Z\.]+\s+av1_nvenc\s') { $purposes += 'NVIDIA capability check' }
    foreach ($purpose in $purposes) {
        $events = New-Object 'Collections.Generic.List[object]'
        $cancellation = New-Object Threading.CancellationTokenSource
        try {
            $sink = {
                param($update)
                $events.Add($update)
                if ($update.Type -eq 'InspectionStarted' -and $update.Data.Purpose -eq $purpose) { $cancellation.Cancel() }
            }.GetNewClosure()
            $summary = Invoke-AV1Batch -InputPath @($source, $source) -EventSink $sink -Cancellation $cancellation
            Assert-True ($summary.Cancelled -and $summary.Failed -eq 0 -and $summary.Skipped -eq 0) ('Cancellation was swallowed during: ' + $purpose)
            Assert-True (@($events | Where-Object { $_.Type -eq 'EncoderStarted' }).Count -eq 0) ('Encoding started after inspection cancellation: ' + $purpose)
            Assert-True (@($events | Where-Object { $_.Type -eq 'FileStarted' }).Count -le 1) 'Inspection cancellation did not stop the remaining batch.'
            foreach ($started in @($events | Where-Object { $_.Type -eq 'InspectionStarted' })) {
                Assert-True ($null -eq (Get-Process -Id $started.Data.ProcessId -ErrorAction SilentlyContinue)) 'Batch cancellation left an inspection process running.'
            }
        }
        finally { $cancellation.Dispose() }
    }
    # Dry runs and skipped inputs must also use only one source probe, without
    # running output verification or accidentally sharing metadata between files.
    $audioOnly = Join-Path $tempRoot 'audio-only.mkv'
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $ffmpeg -v error -f lavfi -i 'sine=frequency=440' -t 0.2 -c:a aac $audioOnly
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw 'Could not create the audio-only inspection fixture.' }
    $invalid = Join-Path $tempRoot 'unreadable.mkv'
    'Not a media file.' | Set-Content -LiteralPath $invalid
    $events = New-Object 'Collections.Generic.List[object]'
    $sink = { param($update) $events.Add($update) }.GetNewClosure()
    $summary = Invoke-AV1Batch -InputPath @($source, $audioOnly, $invalid, $source) -DryRun -EventSink $sink
    Assert-True ($summary.Planned -eq 2 -and $summary.Skipped -eq 2 -and $summary.Failed -eq 0) 'Source inspection did not preserve dry runs or skipping unsupported inputs.'
    Assert-True (@($events | Where-Object { $_.Type -eq 'InspectionStarted' -and $_.Data.Purpose -eq 'Source media inspection' }).Count -eq 4) 'Source metadata was probed repeatedly or reused across inputs.'
    Assert-True (@($events | Where-Object { $_.Type -eq 'EncoderStarted' -or $_.Type -eq 'VerificationStarted' }).Count -eq 0) 'A dry run started encoding or verification.'

    # The single source query retains the old skip-on-timeout behavior, and a
    # failed query must not prevent the next file in the batch from being read.
    $originalQuery = & $core { (Get-Item Function:Invoke-AV1ToolQuery).ScriptBlock }
    try {
        & $core {
            param($Query, $Shell)
            $script:InspectionQuery = $Query
            $script:InspectionShell = $Shell
            $script:TimeoutFirstSource = $true
            function script:Invoke-AV1ToolQuery {
                param($Executable, $Arguments, $Purpose, $TimeoutSeconds = 30)
                if ($Purpose -eq 'Source media inspection' -and $script:TimeoutFirstSource) {
                    $script:TimeoutFirstSource = $false
                    $Executable = $script:InspectionShell
                    $Arguments = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
                    $TimeoutSeconds = 1
                }
                & $script:InspectionQuery -Executable $Executable -Arguments $Arguments -Purpose $Purpose -TimeoutSeconds $TimeoutSeconds
            }
        } $originalQuery $shell
        $events.Clear()
        $clock.Restart()
        $summary = Invoke-AV1Batch -InputPath @($source, $source) -DryRun -EventSink $sink
        Assert-True ($summary.Skipped -eq 1 -and $summary.Planned -eq 1 -and $summary.Failed -eq 0 -and
            -not $summary.Cancelled -and $clock.Elapsed.TotalSeconds -lt 10) 'A source timeout did not promptly skip the file and continue the batch.'
        Assert-True (@($events | Where-Object { $_.Type -eq 'Message' -and $_.Data.Color -eq 'Yellow' -and
            $_.Data.Message -match 'Source media inspection timed out.*file will be skipped' }).Count -eq 1) 'The source timeout was not explained.'
        Assert-True (@($events | Where-Object { $_.Type -eq 'InspectionStarted' -and $_.Data.Purpose -eq 'Source media inspection' }).Count -eq 2) 'The source timeout triggered redundant probes or reused invalid metadata.'
        foreach ($started in @($events | Where-Object Type -eq InspectionStarted)) {
            Assert-True ($null -eq (Get-Process -Id $started.Data.ProcessId -ErrorAction SilentlyContinue)) 'A source timeout left an inspection process running.'
        }

        & $core {
            function script:Invoke-AV1ToolQuery {
                param($Executable, $Arguments, $Purpose, $TimeoutSeconds = 30)
                if ($Purpose -eq 'Source media inspection') {
                    return [PSCustomObject]@{ ExitCode = 0; StandardOutput = 'invalid JSON'; StandardError = '' }
                }
                & $script:InspectionQuery -Executable $Executable -Arguments $Arguments -Purpose $Purpose -TimeoutSeconds $TimeoutSeconds
            }
        }
        $events.Clear()
        $summary = Invoke-AV1Batch -InputPath @($source) -DryRun -EventSink $sink
        Assert-True ($summary.Skipped -eq 1 -and $summary.Planned -eq 0 -and $summary.Failed -eq 0) 'Malformed source metadata was not skipped safely.'
    }
    finally { & $core { param($Query) Set-Item Function:script:Invoke-AV1ToolQuery $Query } $originalQuery }
    Assert-True ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'Inspection checks modified the source.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*_AV1*').Count -eq 0) 'Inspection cancellation created an output.'
    Write-Host ('Inspection checks passed: {0}.' -f $script:checks)
}
finally {
    Remove-Module $core.Name -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
