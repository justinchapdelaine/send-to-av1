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
    # in the codec/duration fallbacks and the optional NVENC capability check.
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
    $purposes = @('FFmpeg encoder check', 'Video codec inspection', 'Video duration inspection', 'Source verification inspection')
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
    Assert-True ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'Inspection cancellation modified the source.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*_AV1*').Count -eq 0) 'Inspection cancellation created an output.'
    Write-Host ('Inspection checks passed: {0}.' -f $script:checks)
}
finally {
    Remove-Module $core.Name -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
