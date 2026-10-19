<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Run the existing setup scripts off the UI thread and report structured results.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-AV1Setup {
    param(
        [ValidateSet('Install', 'Uninstall')][string]$Operation = 'Install',
        [bool]$DownloadTools = $true,
        [string]$ProjectRoot,
        [string]$SendToDirectory,
        [scriptblock]$EventSink
    )
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
    $warnings = [Collections.Generic.List[string]]::new()
    $setupMutex = $null
    $ownsMutex = $false
    function Send-SetupEvent {
        param([string]$Type, [string]$Message)
        if ($null -ne $EventSink) { & $EventSink ([PSCustomObject]@{ Type = $Type; Message = $Message }) | Out-Null }
    }
    function Write-SetupDetail {
        param($Record)
        $message = [string]$Record
        if ([string]::IsNullOrWhiteSpace($message)) { return }
        Send-SetupEvent 'Detail' $message
        if ($message -match '^Warning:') { $warnings.Add($message) }
        # Show meaningful download stages without exposing verbose tool output.
        if ($message -match '^(Downloading FFmpeg|Installing ffmpeg.exe|SHA256 verification passed)') {
            Send-SetupEvent 'Phase' $message
        }
    }
    try {
        # All project copies manage the same user's Send to entries. Serialize
        # setup so simultaneous windows cannot replace the same tools/shortcuts.
        $identity = [Environment]::UserName
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { $identity = $windowsIdentity.User.Value }
            finally { $windowsIdentity.Dispose() }
        }
        $setupMutex = [Threading.Mutex]::new($false, ('Local\SendToAV1.Setup.' + $identity))
        try { $ownsMutex = $setupMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'Another Send to AV1 setup is running. Let it finish, then try again.' }
        if ($Operation -eq 'Install' -and $DownloadTools) {
            Send-SetupEvent 'Phase' 'Checking portable FFmpeg tools...'
            try {
                $global:LASTEXITCODE = 0
                & (Join-Path $ProjectRoot 'src/Download-FFmpeg.ps1') -Ensure -NoPrompt *>&1 |
                    ForEach-Object { Write-SetupDetail $_ }
                if ($LASTEXITCODE -ne 0) { throw 'Portable FFmpeg setup did not complete. See Details for the download error.' }
            }
            catch {
                $warnings.Add($_.Exception.Message)
                Send-SetupEvent 'Detail' $_.Exception.Message
                # As in the console installer, users can supply their own tools later.
            }
        }
        $arguments = @{}
        if (-not [string]::IsNullOrWhiteSpace($SendToDirectory)) { $arguments.SendToDirectory = $SendToDirectory }
        if ($Operation -eq 'Uninstall') {
            $arguments.Uninstall = $true
            Send-SetupEvent 'Phase' 'Removing Send to entries...'
        }
        else { Send-SetupEvent 'Phase' 'Creating Send to entries...' }
        $global:LASTEXITCODE = 0
        & (Join-Path $ProjectRoot 'src/Install-SendTo.ps1') @arguments *>&1 |
            ForEach-Object { Write-SetupDetail $_ }
        if ($LASTEXITCODE -ne 0) { throw 'Send to shortcut setup failed. See Details for more information.' }
        $status = 'Completed'
        $message = 'The CPU, NVIDIA, and Small entries are installed. Select videos in Explorer and use the Send to menu.'
        if ($Operation -eq 'Uninstall') {
            $message = 'The Send to entries have been removed. Your project folder, portable tools, and videos have been kept.'
        }
        elseif ($warnings.Count -gt 0) {
            $status = 'Warning'
            $message = 'The Send to entries are installed, but FFmpeg needs attention. Review Details, then retry setup or provide your own tools.'
        }
        elseif (-not $DownloadTools) {
            $message += ' Make sure FFmpeg and FFprobe are available in bin or on PATH.'
        }
        return [PSCustomObject]@{ Status = $status; Message = $message }
    }
    catch {
        Send-SetupEvent 'Detail' $_.Exception.Message
        return [PSCustomObject]@{ Status = 'Failed'; Message = $_.Exception.Message }
    }
    finally {
        if ($ownsMutex) { $setupMutex.ReleaseMutex() }
        if ($null -ne $setupMutex) { $setupMutex.Dispose() }
    }
}

function Start-AV1SetupWorker {
    param([hashtable]$Options)
    $queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $pipeline = [PowerShell]::Create()
    try {
        $runspace.ApartmentState = 'STA'
        $runspace.Open()
        $pipeline.Runspace = $runspace
        $work = {
            param($ModulePath, $Options, $Updates)
            $ErrorActionPreference = 'Stop'
            try {
                Import-Module $ModulePath -Force -ErrorAction Stop
                $sink = { param($update) $Updates.Enqueue($update) }.GetNewClosure()
                $result = Invoke-AV1Setup @Options -EventSink $sink
                $Updates.Enqueue([PSCustomObject]@{ Type = 'Result'; Data = $result })
            }
            catch {
                $Updates.Enqueue([PSCustomObject]@{ Type = 'Result'; Data = [PSCustomObject]@{
                    Status = 'Failed'; Message = $_.Exception.Message
                } })
            }
        }
        $pipeline.AddScript($work.ToString()).AddArgument((Join-Path $PSScriptRoot 'AV1.Setup.psm1')).AddArgument($Options).AddArgument($queue) | Out-Null
        $handle = $pipeline.BeginInvoke()
        return [PSCustomObject]@{ Pipeline = $pipeline; Runspace = $runspace; Handle = $handle; Updates = $queue }
    }
    catch {
        $pipeline.Dispose()
        $runspace.Dispose()
        throw
    }
}

function Complete-AV1SetupWorker {
    param([Parameter(Mandatory = $true)]$Worker)
    try { $Worker.Pipeline.EndInvoke($Worker.Handle) | Out-Null }
    finally { $Worker.Pipeline.Dispose(); $Worker.Runspace.Dispose() }
}

Export-ModuleMember -Function Invoke-AV1Setup, Start-AV1SetupWorker, Complete-AV1SetupWorker
