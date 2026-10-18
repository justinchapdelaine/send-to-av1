<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Run the shared encoder off the UI thread, passing objects without serialization.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Start-AV1Worker {
    param([hashtable]$Options)

    $queue = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
    $cancellation = New-Object Threading.CancellationTokenSource
    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $pipeline = [PowerShell]::Create()
    try {
        $runspace.ApartmentState = 'MTA'
        $runspace.Open()
        $pipeline.Runspace = $runspace
        $work = {
            param($ModulePath, $Options, $Updates, $Cancellation)
            $ErrorActionPreference = 'Stop'
            try {
                Import-Module $ModulePath -Force -ErrorAction Stop
                $sink = { param($update) $Updates.Enqueue($update) }.GetNewClosure()
                Invoke-AV1Batch @Options -EventSink $sink -Cancellation $Cancellation | Out-Null
            }
            catch {
                $Updates.Enqueue([PSCustomObject]@{
                    Type = 'Fatal'; Data = [PSCustomObject]@{ Message = $_.Exception.Message }
                })
            }
        }
        $pipeline.AddScript($work.ToString()) | Out-Null
        $pipeline.AddArgument((Join-Path $PSScriptRoot 'AV1.Core.psm1')) | Out-Null
        $pipeline.AddArgument($Options).AddArgument($queue).AddArgument($cancellation) | Out-Null
        $handle = $pipeline.BeginInvoke()
        return [PSCustomObject]@{
            Pipeline = $pipeline; Runspace = $runspace; Handle = $handle
            Updates = $queue; Cancellation = $cancellation
        }
    }
    catch {
        $pipeline.Dispose()
        $runspace.Dispose()
        $cancellation.Dispose()
        throw
    }
}

function Complete-AV1Worker {
    param([Parameter(Mandatory = $true)]$Worker)

    try { $Worker.Pipeline.EndInvoke($Worker.Handle) | Out-Null }
    finally {
        $Worker.Pipeline.Dispose()
        $Worker.Runspace.Dispose()
        $Worker.Cancellation.Dispose()
    }
}

Export-ModuleMember -Function Start-AV1Worker, Complete-AV1Worker
