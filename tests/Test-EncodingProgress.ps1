<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Exercise progress calculations, native encoding, and diagnostic log cleanup.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$optimizer = Join-Path $repoRoot 'src/Optimize-AV1.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($optimizer, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Optimizer failed to parse.' }
$definitions = ($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false) | ForEach-Object { $_.Extent.Text }) -join "`n"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('send-to-av1-progress-test-' + [Guid]::NewGuid().ToString('N'))
$originalTemp = $env:TEMP
$originalTmp = $env:TMP
$originalTmpdir = $env:TMPDIR
$script:checks = 0
$script:interruptOnProgress = $false
$script:lockDiagnosticLog = $false
$script:updates = New-Object 'Collections.Generic.List[object]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Find-TestTool {
    param([string]$Name, [string]$ProjectRoot = $repoRoot)

    # Imported helpers live in a temp directory, so use the actual checkout root.
    $localTool = Join-Path $ProjectRoot ("bin/{0}.exe" -f $Name)
    if (Test-Path -LiteralPath $localTool -PathType Leaf) {
        return (Resolve-Path -LiteralPath $localTool).Path
    }
    return (Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}

# Inject only the cleanup failure under test; normal test cleanup uses the cmdlet.
function Remove-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [switch]$Force, [switch]$Recurse)

    if ($script:lockDiagnosticLog -and $LiteralPath -like '*.log') {
        throw 'simulated diagnostic file lock'
    }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}

# Capture the real progress records even when the test host is noninteractive.
function Write-Progress {
    param($Id, $Activity, $Status, $PercentComplete, $SecondsRemaining, [switch]$Completed)
    if ($script:interruptOnProgress -and -not $Completed -and $PercentComplete -gt 0) { throw 'simulated progress interruption' }
    $script:updates.Add([PSCustomObject]@{
        Activity = $Activity; Status = $Status; Percent = $PercentComplete; Completed = [bool]$Completed
    })
}

function Invoke-CapturedEncode {
    param([string]$Executable, [string[]]$Options, [double]$Duration = 1, [switch]$KeepLog)
    $script:updates.Clear()
    $script:result = $null
    $text = & {
        $script:result = Invoke-FfmpegEncode -FfmpegPath $Executable -Arguments $Options -Activity 'Encoding file 1 of 1: test' -DurationSeconds $Duration -KeepLog:$KeepLog
    } 6>&1 | Out-String
    return [PSCustomObject]@{ ExitCode = $script:result; Text = $text; Updates = $script:updates.ToArray() }
}

function Invoke-OptimizerCli {
    param([string[]]$Options)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = & $shell -NoProfile -File $optimizer -NoPause @Options 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    return [PSCustomObject]@{ ExitCode = $code; Text = $text }
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $helpers = Join-Path $tempRoot 'helpers.ps1'
    Set-Content -LiteralPath $helpers -Value $definitions
    . $helpers
    $env:TEMP = $tempRoot
    $env:TMP = $tempRoot
    $env:TMPDIR = $tempRoot
    $ffmpeg = Find-TestTool 'ffmpeg'
    $ffprobe = Find-TestTool 'ffprobe'
    if (-not $ffmpeg -or -not $ffprobe) { throw 'FFmpeg/SVT-AV1 and FFprobe are required.' }

    # Portable-only installations must not depend on the imported helpers' location.
    $portableRoot = Join-Path $tempRoot 'portable checkout'
    New-Item -ItemType Directory -Path (Join-Path $portableRoot 'bin') -Force | Out-Null
    $shell = (Get-Process -Id $PID).Path
    foreach ($name in @('ffmpeg', 'ffprobe')) {
        Copy-Item -LiteralPath $shell -Destination (Join-Path $portableRoot ("bin/{0}.exe" -f $name))
    }
    $originalPath = $env:PATH
    try {
        $env:PATH = Join-Path $tempRoot 'empty-path'
        foreach ($name in @('ffmpeg', 'ffprobe')) {
            Assert-True ((Find-TestTool -Name $name -ProjectRoot $portableRoot) -eq (Join-Path $portableRoot ("bin/{0}.exe" -f $name))) 'Portable tool discovery used the wrong project root.'
        }
    }
    finally { $env:PATH = $originalPath }

    $progress = Get-EncodingProgress -DurationSeconds 120 -ProcessedSeconds 30 -ElapsedSeconds 10
    Assert-True ($progress.Percent -eq 25 -and $progress.SecondsRemaining -eq 30) 'Incorrect percentage or ETA.'
    Assert-True ($progress.Status -match '00:00:30 / 00:02:00' -and $progress.Status -match 'Elapsed: 00:00:10') 'Progress times are incorrect.'
    $progress = Get-EncodingProgress -DurationSeconds 0 -ProcessedSeconds 30 -ElapsedSeconds 10
    Assert-True ($progress.Percent -eq -1 -and $progress.SecondsRemaining -eq -1 -and $progress.Status -match 'Duration unavailable') 'Unknown duration must use indeterminate progress.'
    $progress = Get-EncodingProgress -DurationSeconds 120 -ProcessedSeconds 0 -ElapsedSeconds 0
    Assert-True ($progress.Percent -eq 0 -and $progress.SecondsRemaining -eq -1) 'Startup must not invent an ETA.'
    $progress = Get-EncodingProgress -DurationSeconds 120 -ProcessedSeconds 125 -ElapsedSeconds 10 -Finalizing
    Assert-True ($progress.Percent -eq 99 -and $progress.Status -match 'Finalizing') 'Progress must not report completion before finalization.'
    Assert-True ((Format-ProgressTime 97205) -eq '27:00:05') 'Long videos must not wrap at 24 hours.'
    Assert-True ((Get-MediaDuration -FfprobePath '' -Path 'unused') -eq 0) 'Missing FFprobe must return unknown duration.'

    $output = Join-Path $tempRoot ('clip [test] caf' + [char]0xe9 + '.mkv')
    $arguments = @('-hide_banner', '-nostdin', '-nostats', '-progress', 'pipe:1', '-stats_period', '0.05',
        '-f', 'lavfi', '-i', 'testsrc2=size=128x128:rate=10', '-t', '1', '-c:v', 'libsvtav1',
        '-preset', '12', '-svtav1-params', 'lp=2', '-y', $output)
    $run = Invoke-CapturedEncode $ffmpeg $arguments
    Assert-True ($run.ExitCode -is [int] -and $run.ExitCode -eq 0 -and (Test-Path -LiteralPath $output)) 'Real FFmpeg encode failed.'
    Assert-True ($run.Text -notmatch 'Svt\[|Stream mapping|frame=|out_time|Diagnostic log:') 'Normal output leaked encoder diagnostics.'
    $active = @($run.Updates | Where-Object { -not $_.Completed })
    Assert-True (@($active | Where-Object { $_.Percent -gt 0 }).Count -gt 0) 'Real structured timestamps did not advance progress.'
    Assert-True (@($active | Where-Object { $_.Percent -gt 99 }).Count -eq 0) 'Running encoder reported 100%.'
    Assert-True ($run.Updates[-1].Completed) 'Progress bar was not cleared.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter 'send-to-av1-*.log').Count -eq 0) 'Successful encode left a diagnostic log.'
    $duration = Get-MediaDuration -FfprobePath $ffprobe -Path $output
    Assert-True ([Math]::Abs($duration - 1.0) -lt 0.1) 'MKV duration probe did not match the encoded clip.'
    Assert-True ((Get-MediaDuration -FfprobePath $ffprobe -Path (Join-Path $tempRoot 'missing.mkv')) -eq 0) 'Probe failures must return unknown duration.'

    # A diagnostic-log lock after successful encoding must preserve the video.
    $Script:ProcessedCount = 0; $Script:PlannedCount = 0
    $Script:SkippedCount = 0; $Script:FailedCount = 0
    $Script:TotalInputBytes = 0; $Script:TotalOutputBytes = 0
    $expectedOutput = New-UniqueOutputPath -InputFile $output -Container 'mkv'
    $inputHash = (Get-FileHash -LiteralPath $output).Hash
    $configuration = [PSCustomObject]@{
        Encoder = 'svt'; Summary = 'cleanup regression'; FfmpegVideoArgs = @('-c:v', 'libsvtav1', '-preset', '12', '-svtav1-params', 'lp=2')
    }
    $script:lockDiagnosticLog = $true
    try {
        $text = & {
            Convert-VideoToAv1 -FfmpegPath $ffmpeg -FfprobePath $ffprobe -EncoderConfiguration $configuration -Container 'mkv' -Small -Path $output
        } 6>&1 | Out-String
    }
    finally { $script:lockDiagnosticLog = $false }
    Assert-True ($Script:ProcessedCount -eq 1 -and $text -match 'Completed\.') 'Log cleanup failure invalidated a successful encode.'
    Assert-True ((Test-Path -LiteralPath $expectedOutput) -and (Get-MediaDuration -FfprobePath $ffprobe -Path $expectedOutput) -gt 0) 'Log cleanup failure discarded the encoded video.'
    Assert-True ($text -match 'Warning: Could not delete temporary diagnostic log:' -and $text -match 'simulated diagnostic file lock') 'Log cleanup failure was not explained.'
    Assert-True ((Get-FileHash -LiteralPath $output).Hash -eq $inputHash) 'Log cleanup failure modified the source.'
    Get-ChildItem -LiteralPath $tempRoot -Filter 'send-to-av1-*.log' | ForEach-Object { Remove-Item -LiteralPath $_.FullName }

    $run = Invoke-CapturedEncode $ffmpeg $arguments -Duration 0 -KeepLog
    Assert-True ($run.ExitCode -eq 0) 'Encode with unknown duration failed.'
    Assert-True (@($run.Updates | Where-Object { -not $_.Completed -and $_.Percent -ne -1 }).Count -eq 0) 'Unknown duration displayed a percentage.'
    $match = [regex]::Match($run.Text, '(?m)^Diagnostic log: (.+)\r?$')
    Assert-True ($match.Success -and (Test-Path -LiteralPath $match.Groups[1].Value.Trim())) 'KeepLog did not retain a successful diagnostic log.'
    Remove-Item -LiteralPath $match.Groups[1].Value.Trim()

    $badArguments = @($arguments | ForEach-Object { if ($_ -eq 'libsvtav1') { 'nonexistent-av1-encoder' } else { $_ } })
    $run = Invoke-CapturedEncode $ffmpeg $badArguments
    Assert-True ($run.ExitCode -ne 0 -and $run.Text -match 'Unknown encoder') 'Real encoder failure did not display its error.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter 'send-to-av1-*.log').Count -eq 0) 'Failed encode left a diagnostic log.'

    # More than a pipe buffer of stderr must be drained without blocking stdout.
    $fake = Join-Path $tempRoot 'verbose failure.ps1'
    @'
[Console]::Error.WriteLine(('diagnostic padding ' * 10000))
[Console]::Error.WriteLine('simulated encoder failure')
[Console]::Out.WriteLine('out_time_us=30000000')
[Console]::Out.WriteLine('progress=end')
exit 9
'@ | Set-Content -LiteralPath $fake
    $shell = (Get-Process -Id $PID).Path
    $run = Invoke-CapturedEncode $shell @('-NoProfile', '-File', $fake) -Duration 120 -KeepLog
    Assert-True ($run.ExitCode -eq 9 -and $run.Text -match 'simulated encoder failure') 'Verbose failure was not captured.'
    $match = [regex]::Match($run.Text, '(?m)^Diagnostic log: (.+)\r?$')
    Assert-True ($match.Success -and (Get-Item -LiteralPath $match.Groups[1].Value.Trim()).Length -gt 65536) 'KeepLog did not retain full diagnostics.'
    Assert-True (@($run.Updates | Where-Object { $_.Percent -eq 25 }).Count -gt 0) 'Microsecond progress timestamps were parsed incorrectly.'
    Remove-Item -LiteralPath $match.Groups[1].Value.Trim()

    # Decoder errors are important even when FFmpeg recovers and exits zero.
    $recovered = Join-Path $tempRoot 'recovered decoder.ps1'
    @'
[Console]::Error.WriteLine('[h264 @ decoder] [error] Invalid NAL unit size')
[Console]::Error.WriteLine('Svt[error]: decoder regression')
1..30 | ForEach-Object { [Console]::Error.WriteLine('[info] ordinary trailing diagnostic') }
[Console]::Out.WriteLine('out_time_us=1000000')
[Console]::Out.WriteLine('progress=end')
exit 0
'@ | Set-Content -LiteralPath $recovered
    $run = Invoke-CapturedEncode $shell @('-NoProfile', '-File', $recovered)
    Assert-True ($run.ExitCode -eq 0) 'Recovered decoder errors changed the native exit status.'
    Assert-True ($run.Text -match 'Warning: FFmpeg reported errors despite exiting successfully' -and $run.Text -match 'Invalid NAL unit size' -and $run.Text -match 'decoder regression') 'Recovered decoder errors were hidden.'
    Assert-True ($run.Text -notmatch 'ordinary trailing diagnostic') 'Successful error reporting flooded the console with info messages.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter 'send-to-av1-*.log').Count -eq 0) 'Recovered errors left a diagnostic log.'

    $informational = Join-Path $tempRoot 'ordinary diagnostics.ps1'
    @'
[Console]::Error.WriteLine('[info] Input file: [error] recording.mkv')
[Console]::Error.WriteLine('Svt[info]: no error, fatal, or panic occurred')
[Console]::Out.WriteLine('progress=end')
exit 0
'@ | Set-Content -LiteralPath $informational
    $run = Invoke-CapturedEncode $shell @('-NoProfile', '-File', $informational)
    Assert-True ($run.ExitCode -eq 0 -and $run.Text -notmatch 'Warning:|reported errors') 'Normal info messages were mistaken for encoder errors.'

    # Exercise the CLI switch and complete error path, including partial-output cleanup.
    $cli = Invoke-OptimizerCli @('-Small', '-Preset', '12', '-KeepLog', $output)
    $match = [regex]::Match($cli.Text, '(?m)^Diagnostic log: (.+)\r?$')
    Assert-True ($cli.ExitCode -eq 0 -and $cli.Text -match 'Completed\.' -and $match.Success) 'CLI KeepLog encode failed.'
    Assert-True (Test-Path -LiteralPath $match.Groups[1].Value.Trim()) 'CLI did not retain its diagnostic log.'
    Remove-Item -LiteralPath $match.Groups[1].Value.Trim()

    $attachment = Join-Path $tempRoot 'notes.txt'
    Set-Content -LiteralPath $attachment -Value 'attachment unsupported by MP4'
    $attached = Join-Path $tempRoot 'attached recording.mkv'
    $run = Invoke-CapturedEncode $ffmpeg @('-hide_banner', '-nostdin', '-nostats', '-progress', 'pipe:1',
        '-i', $output, '-map', '0', '-c', 'copy', '-attach', $attachment, '-metadata:s:t', 'mimetype=text/plain', $attached)
    Assert-True ($run.ExitCode -eq 0) 'Could not prepare incompatible-stream fixture.'
    $cli = Invoke-OptimizerCli @('-Small', '-Preset', '12', '-OutputContainer', 'mp4', $attached)
    Assert-True ($cli.ExitCode -eq 1 -and $cli.Text -match 'FFmpeg error details:' -and $cli.Text -match 'Failed:\s+1') 'CLI failed encode did not report failure.'
    Assert-True ($cli.Text -notmatch 'Completed\.') 'Failed CLI encode reported completion.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'attached recording_AV1.mp4'))) 'Failed CLI encode published a final output.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*.tmp.*').Count -eq 0) 'Failed CLI encode left a partial output.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter 'send-to-av1-*.log').Count -eq 0) 'Failed CLI encode left a diagnostic log.'

    # A consumer interruption must stop the encoder and release its log handles.
    $sleeper = Join-Path $tempRoot 'interrupted encoder.ps1'
    $pidFile = Join-Path $tempRoot 'encoder.pid'
    @'
param([string]$PidFile)
[IO.File]::WriteAllText($PidFile, [string]$PID)
[Console]::Out.WriteLine('out_time_us=1000000')
[Console]::Out.Flush()
Start-Sleep -Seconds 30
'@ | Set-Content -LiteralPath $sleeper
    $script:interruptOnProgress = $true
    $interrupted = $false
    try { Invoke-CapturedEncode $shell @('-NoProfile', '-File', $sleeper, $pidFile) -Duration 120 | Out-Null }
    catch { $interrupted = $_.Exception.Message -match 'simulated progress interruption' }
    finally { $script:interruptOnProgress = $false }
    Assert-True $interrupted 'Progress interruption was not propagated.'
    Assert-True (Test-Path -LiteralPath $pidFile) 'Interrupted encoder did not start.'
    $encoderPid = [int](Get-Content -LiteralPath $pidFile)
    Assert-True ($null -eq (Get-Process -Id $encoderPid -ErrorAction SilentlyContinue)) 'Interrupted encoder was left running.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter 'send-to-av1-*.log').Count -eq 0) 'Interrupted encode left a diagnostic log.'

    # Exercise the legacy Windows-compatible quoting through an actual argv parser.
    $echoArguments = Join-Path $tempRoot 'echo arguments.ps1'
    'param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Values); ConvertTo-Json -InputObject $Values -Compress' | Set-Content -LiteralPath $echoArguments
    $values = @('C:\folder with spaces\', 'a"quoted"value', 'trailing\\', '')
    $process = New-Object Diagnostics.Process
    try {
        $process.StartInfo.FileName = $shell
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.Arguments = (@('-NoProfile', '-File', $echoArguments) + $values | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
        $process.Start() | Out-Null
        $received = @($process.StandardOutput.ReadToEnd() | ConvertFrom-Json)
        $process.WaitForExit()
        Assert-True ($process.ExitCode -eq 0 -and $received.Count -eq $values.Count) 'Argument quoting lost arguments.'
        for ($index = 0; $index -lt $values.Count; $index++) {
            Assert-True ($received[$index] -ceq $values[$index]) 'Argument quoting changed a value.'
        }
    }
    finally { $process.Dispose() }

    $threw = $false
    try {
        Invoke-FfmpegEncode -FfmpegPath (Join-Path $tempRoot 'missing-ffmpeg') -Arguments @() -Activity 'test' -DurationSeconds 1 | Out-Null
    }
    catch { $threw = $true }
    Assert-True $threw 'Process launch failure must be reported.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter 'send-to-av1-*.log').Count -eq 0) 'Launch failure left a diagnostic log.'
    Write-Host ("Encoding-progress checks passed: {0}." -f $script:checks)
}
finally {
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
    $env:TMPDIR = $originalTmpdir
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
