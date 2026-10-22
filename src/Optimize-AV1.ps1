<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Optimize one or more videos for storage by converting video streams to AV1.

.DESCRIPTION
    Send to AV1 is designed to be launched from the Windows Send To menu.
    It preserves original files, writes AV1 outputs next to the source files,
    and copies non-video streams where possible.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputPath,

    [switch]$NoPause,

    [switch]$Diagnostics,

    [switch]$DryRun,

    [switch]$Small,

    [switch]$KeepLog,

    [ValidateSet('svt', 'nvenc')]
    [string]$Encoder = 'svt',

    [ValidateSet('mkv', 'mp4')]
    [string]$OutputContainer = 'mkv',

    [ValidateRange(0, 63)]
    [int]$Crf = 34,

    [ValidateRange(0, 13)]
    [int]$Preset = 5,

    [ValidateRange(0, 63)]
    [int]$NvencCq = 32,

    [ValidateSet('p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7')]
    [string]$NvencPreset = 'p7',

    [ValidateSet('auto', 'hq', 'uhq')]
    [string]$NvencTune = 'auto'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$exitCode = 0
try {
    Import-Module (Join-Path $PSScriptRoot 'AV1.Core.psm1') -Force -ErrorAction Stop
    $options = @{} + $PSBoundParameters
    $options.Remove('NoPause')
    $result = Invoke-AV1Batch @options
    if ($null -ne $result -and ($result.Failed -gt 0 -or $result.Fatal)) { $exitCode = 1 }
}
catch {
    Write-Host ('Failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    $exitCode = 1
}
finally {
    if (-not $NoPause) {
        Write-Host ''
        Read-Host 'Press Enter to close' | Out-Null
    }
}
exit $exitCode
