<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Exercise setup orchestration and its actual background worker without WPF or downloads.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/AV1.Setup.psm1') -Force
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('av1-setup-' + [Guid]::NewGuid().ToString('N'))
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Invoke-TestSetup {
    param([string]$Operation = 'Install', [bool]$DownloadTools = $true)
    $worker = Start-AV1SetupWorker -Options @{ Operation = $Operation; DownloadTools = $DownloadTools; ProjectRoot = $tempRoot; SendToDirectory = $tempRoot }
    try {
        $events = [Collections.Generic.List[object]]::new()
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not $worker.Handle.IsCompleted) {
            $update = $null
            while ($worker.Updates.TryDequeue([ref]$update)) { $events.Add($update) }
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Setup worker timed out.' }
            Start-Sleep -Milliseconds 20
        }
        while ($worker.Updates.TryDequeue([ref]$update)) { $events.Add($update) }
        $output = @($events | Where-Object Type -eq Result)
        Assert-True ($output.Count -eq 1) 'The setup worker did not emit exactly one result.'
        if ($output[0].Data.Status -ne 'Failed') {
            Assert-True (@($events | Where-Object Type -eq Phase).Count -gt 0) 'Setup did not report its phase.'
        }
        return [PSCustomObject]@{ Result = $output[0].Data; Events = $events }
    }
    finally {
        if (-not $worker.Handle.IsCompleted) { $worker.Pipeline.Stop() }
        Complete-AV1SetupWorker $worker
    }
}
try {
    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'src') -Force | Out-Null
    @'
param([switch]$Ensure, [switch]$NoPrompt)
if (-not $Ensure -or -not $NoPrompt) { throw 'The GUI would have prompted or skipped update checking.' }
Write-Host 'Downloading FFmpeg...'
Write-Host 'SHA256 verification passed.'
Write-Host 'FFmpeg installed successfully.'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $tempRoot 'src/Download-FFmpeg.ps1') -Encoding Ascii
    @'
param([switch]$Uninstall, [string]$SendToDirectory)
if (-not $SendToDirectory) { throw 'The test could modify real Send to entries.' }
$name = 'installed.txt'
if ($Uninstall) { $name = 'removed.txt' }
Set-Content -LiteralPath (Join-Path $SendToDirectory $name) -Value 'fixture'
Write-Host 'Shortcut setup finished.'
'@ | Set-Content -LiteralPath (Join-Path $tempRoot 'src/Install-SendTo.ps1') -Encoding Ascii

    $test = Invoke-TestSetup
    Assert-True ($test.Result.Status -eq 'Completed' -and (Test-Path -LiteralPath (Join-Path $tempRoot 'installed.txt'))) 'Setup did not finish after a downloader exit 0.'
    Assert-True (@($test.Events | Where-Object { $_.Type -eq 'Detail' -and $_.Message -eq 'FFmpeg installed successfully.' }).Count -eq 1) 'Downloader information output was lost.'
    Assert-True (@($test.Events | Where-Object { $_.Type -eq 'Phase' -and $_.Message -eq 'Downloading FFmpeg...' }).Count -eq 1) 'Download progress was not forwarded.'

    "throw 'Network unavailable'" | Set-Content -LiteralPath (Join-Path $tempRoot 'src/Download-FFmpeg.ps1') -Encoding Ascii
    $test = Invoke-TestSetup
    Assert-True ($test.Result.Status -eq 'Warning') 'A failed download hid the warning or prevented shortcut installation.'
    Assert-True (@($test.Events | Where-Object { $_.Type -eq 'Detail' -and $_.Message -match 'Network unavailable' }).Count -gt 0) 'The download failure was not available in Details.'

    "Write-Host 'Download failed'; exit 1" | Set-Content -LiteralPath (Join-Path $tempRoot 'src/Download-FFmpeg.ps1') -Encoding Ascii
    $test = Invoke-TestSetup
    Assert-True ($test.Result.Status -eq 'Warning') 'A downloader exit 1 was treated as success.'
    $test = Invoke-TestSetup -DownloadTools $false
    Assert-True ($test.Result.Status -eq 'Completed' -and $test.Result.Message -match 'PATH') 'Opting out of the download still invoked it or hid the tool requirement.'

    $test = Invoke-TestSetup -Operation Uninstall
    Assert-True ($test.Result.Status -eq 'Completed' -and (Test-Path -LiteralPath (Join-Path $tempRoot 'removed.txt'))) 'Uninstall used the downloader or lost its operation.'
    Assert-True (Test-Path -LiteralPath (Join-Path $tempRoot 'installed.txt')) 'Uninstall removed unrelated fixture files.'

    "throw 'Shortcut access denied'" | Set-Content -LiteralPath (Join-Path $tempRoot 'src/Install-SendTo.ps1') -Encoding Ascii
    $test = Invoke-TestSetup -DownloadTools $false
    Assert-True ($test.Result.Status -eq 'Failed' -and $test.Result.Message -match 'Shortcut access denied') 'Shortcut failure was reported as success.'
    $test = Invoke-TestSetup -Operation Uninstall
    Assert-True ($test.Result.Status -eq 'Failed') 'Uninstall failure was reported as success.'
    "exit 1" | Set-Content -LiteralPath (Join-Path $tempRoot 'src/Install-SendTo.ps1') -Encoding Ascii
    $test = Invoke-TestSetup -DownloadTools $false
    Assert-True ($test.Result.Status -eq 'Failed') 'A shortcut script exit 1 was treated as success.'

    # Hold a real worker inside a fixture setup script, then start a second one.
    @'
param([switch]$Uninstall, [string]$SendToDirectory)
Set-Content -LiteralPath (Join-Path $SendToDirectory 'lock-held.txt') -Value 'ready'
while (-not (Test-Path -LiteralPath (Join-Path $SendToDirectory 'release-lock.txt'))) { Start-Sleep -Milliseconds 20 }
'@ | Set-Content -LiteralPath (Join-Path $tempRoot 'src/Install-SendTo.ps1') -Encoding Ascii
    $first = Start-AV1SetupWorker -Options @{ DownloadTools = $false; ProjectRoot = $tempRoot; SendToDirectory = $tempRoot }
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'lock-held.txt'))) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'The first setup worker never acquired its lock.' }
            Start-Sleep -Milliseconds 20
        }
        $test = Invoke-TestSetup -DownloadTools $false
        Assert-True ($test.Result.Status -eq 'Failed' -and $test.Result.Message -match 'Another Send to AV1 setup') 'Concurrent setup was allowed to modify the same installation.'
    }
    finally {
        Set-Content -LiteralPath (Join-Path $tempRoot 'release-lock.txt') -Value 'ready'
        if (-not $first.Handle.AsyncWaitHandle.WaitOne(10000)) { $first.Pipeline.Stop() }
        Complete-AV1SetupWorker $first
    }
    $test = Invoke-TestSetup -DownloadTools $false
    Assert-True ($test.Result.Status -eq 'Completed') 'The setup lock was not released after completion.'
    Write-Host ('Setup worker checks passed: {0}.' -f $script:checks)
}
finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }
