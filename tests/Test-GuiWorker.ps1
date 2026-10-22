<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Exercise the GUI's actual background worker, progress events, and cancellation.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src/AV1.Worker.psm1') -Force
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('send-to-av1-worker-' + [Guid]::NewGuid().ToString('N'))
$script:checks = 0
$worker = $null
$originalTemp = $env:TEMP
$originalTmp = $env:TMP
$originalTmpdir = $env:TMPDIR

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Invoke-TestTool {
    param([string]$Executable, [string[]]$Options)
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = & $Executable @Options 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw $text }
    return $text
}

function Wait-Worker {
    param($Worker, [scriptblock]$OnUpdate)
    $events = New-Object 'Collections.Generic.List[object]'
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $update = $null
        while ($Worker.Updates.TryDequeue([ref]$update)) {
            $events.Add($update)
            if ($null -ne $OnUpdate) { & $OnUpdate $update | Out-Null }
        }
        if ([DateTime]::UtcNow -gt $deadline) {
            $Worker.Cancellation.Cancel()
            throw 'Background worker exceeded its test deadline.'
        }
        Start-Sleep -Milliseconds 20
    } while (-not $Worker.Handle.IsCompleted)
    while ($Worker.Updates.TryDequeue([ref]$update)) {
        $events.Add($update)
        if ($null -ne $OnUpdate) { & $OnUpdate $update | Out-Null }
    }
    return $events.ToArray()
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $env:TEMP = $tempRoot
    $env:TMP = $tempRoot
    $env:TMPDIR = $tempRoot
    $ffmpeg = Join-Path $repoRoot 'bin/ffmpeg.exe'
    if (-not (Test-Path -LiteralPath $ffmpeg)) {
        $ffmpeg = (Get-Command ffmpeg -CommandType Application | Select-Object -First 1).Source
    }
    $short = Join-Path $tempRoot ('short [test] caf' + [char]0xe9 + '.mkv')
    $long = Join-Path $tempRoot 'long.mkv'
    Invoke-TestTool $ffmpeg @('-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=128x128:rate=25',
        '-t', '0.4', '-c:v', 'ffv1', $short) | Out-Null
    Invoke-TestTool $ffmpeg @('-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=25',
        '-t', '4', '-c:v', 'ffv1', $long) | Out-Null

    $worker = Start-AV1Worker @{ InputPath = @($short); Preset = 12; Small = $true }
    $events = @(Wait-Worker $worker)
    Complete-AV1Worker $worker
    $worker = $null
    $summaries = @($events | Where-Object { $_.Type -eq 'Summary' })
    Assert-True ($summaries.Count -eq 1 -and $summaries[0].Data.Summary.Processed -eq 1) 'Worker did not complete its real encode.'
    Assert-True (@($events | Where-Object { $_.Type -eq 'Fatal' }).Count -eq 0) 'Worker emitted an unexpected fatal error.'
    $progress = @($events | Where-Object { $_.Type -eq 'Progress' })
    Assert-True ($progress.Count -gt 0) 'GUI worker did not deliver progress objects.'
    Assert-True (@($progress | Where-Object { $_.Data.Progress.Percent -gt 99 }).Count -eq 0) 'Encoder progress reached 100% before finalization.'
    $results = @($events | Where-Object { $_.Type -eq 'FileResult' })
    Assert-True ($results.Count -eq 1 -and $results[0].Data.Status -eq 'Completed') 'GUI worker did not deliver a completed-file result.'
    Assert-True (Test-Path -LiteralPath $results[0].Data.OutputPath) 'GUI received a nonexistent completed output.'
    Assert-True (@($events | Where-Object { $_.Type -eq 'VerificationStarted' }).Count -eq 1 -and
        @($events | Where-Object { $_.Type -eq 'InspectionStarted' -and $_.Data.Purpose -eq 'Output verification' }).Count -eq 1) 'The GUI worker lost the output verification stage.'

    # Already-AV1 and missing files must be explained without encoder activity.
    $worker = Start-AV1Worker @{ InputPath = @($results[0].Data.OutputPath, (Join-Path $tempRoot 'missing.mkv')) }
    $events = @(Wait-Worker $worker)
    Complete-AV1Worker $worker
    $worker = $null
    $summary = @($events | Where-Object { $_.Type -eq 'Summary' })[0].Data.Summary
    Assert-True ($summary.Skipped -eq 2 -and $summary.Failed -eq 0) 'Skipped files were counted incorrectly.'
    Assert-True (@($events | Where-Object { $_.Type -eq 'FileResult' -and $_.Data.Status -eq 'Skipped' }).Count -eq 2) 'GUI did not receive both skipped-file results.'
    Assert-True (@($events | Where-Object { $_.Type -eq 'EncoderStarted' }).Count -eq 0) 'Skipped files started an encoder.'

    # Cancellation of the second encode must retain the first and stop the third.
    $sourceHash = (Get-FileHash -LiteralPath $long).Hash
    $worker = Start-AV1Worker @{ InputPath = @($short, $long, $short); Preset = 5 }
    $script:startedEncoders = 0
    $events = @(Wait-Worker $worker {
        param($update)
        if ($update.Type -eq 'EncoderStarted') {
            $script:startedEncoders++
            if ($script:startedEncoders -eq 2) { $worker.Cancellation.Cancel() }
        }
    })
    Complete-AV1Worker $worker
    $worker = $null
    $summary = @($events | Where-Object { $_.Type -eq 'Summary' })[0].Data.Summary
    Assert-True ($summary.Cancelled -and $summary.Processed -eq 1 -and $summary.Failed -eq 0) 'Cancellation was counted as failure or lost completed work.'
    Assert-True (@($events | Where-Object { $_.Type -eq 'FileStarted' }).Count -eq 2) 'Cancellation did not stop the remaining batch.'
    $completed = @($events | Where-Object { $_.Type -eq 'FileResult' -and $_.Data.Status -eq 'Completed' })
    Assert-True ($completed.Count -eq 1 -and (Test-Path -LiteralPath $completed[0].Data.OutputPath)) 'Cancellation removed an earlier completed output.'
    foreach ($started in @($events | Where-Object { $_.Type -eq 'EncoderStarted' })) {
        Assert-True ($null -eq (Get-Process -Id $started.Data.ProcessId -ErrorAction SilentlyContinue)) 'Cancellation left a child encoder running.'
    }
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*.tmp.*').Count -eq 0) 'Cancellation left an incomplete output.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'long_AV1.mkv'))) 'Cancellation published an incomplete output.'
    Assert-True ((Get-FileHash -LiteralPath $long).Hash -eq $sourceHash) 'Cancellation modified the original.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter 'send-to-av1-*.log').Count -eq 0) 'Cancellation left a diagnostic log.'

    # A startup failure must reach the GUI even when no file has started.
    $worker = Start-AV1Worker @{ Small = $true; Encoder = 'nvenc'; InputPath = @($short) }
    $events = @(Wait-Worker $worker)
    Complete-AV1Worker $worker
    $worker = $null
    $summary = @($events | Where-Object { $_.Type -eq 'Summary' })[0].Data.Summary
    Assert-True ($summary.Fatal -and $summary.Failed -eq 0 -and $summary.Processed -eq 0) 'Startup failure did not reach the summary as a batch error.'
    Assert-True (@($events | Where-Object { $_.Type -eq 'Message' -and $_.Data.Message -match 'cannot be combined' }).Count -gt 0) 'Startup failure details were lost.'
    Write-Host ('GUI worker checks passed: {0}.' -f $script:checks)
}
finally {
    if ($null -ne $worker) {
        $worker.Cancellation.Cancel()
        Complete-AV1Worker $worker
    }
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
    $env:TMPDIR = $originalTmpdir
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
