<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Interpret FFmpeg encoder queries for both encoding and setup.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-FfmpegEncoder {
    param(
        [string]$EncoderOutput,
        [string]$EncoderName
    )

    return ($EncoderOutput -match ("(?im)^\s*[A-Z\.]+\s+{0}\s" -f [Regex]::Escape($EncoderName)))
}

function Test-NvencTuneSupport {
    param(
        [string]$NvencHelpOutput,
        [string]$TuneName
    )

    return ($NvencHelpOutput -match ("(?im)^\s+{0}\s+" -f [Regex]::Escape($TuneName)))
}

function Format-CapabilityStatus {
    param([bool]$Available)

    if ($Available) {
        return 'Available'
    }

    return 'Unavailable'
}

function Format-NvencTuneStatus {
    param(
        [bool]$HasNvenc,
        [bool]$SupportsUhq,
        [bool]$SupportsHq
    )

    if (-not $HasNvenc) { return 'Unavailable' }
    if ($SupportsUhq) { return 'UHQ available' }
    if ($SupportsHq) { return 'HQ available; UHQ unavailable' }
    return 'Tune options unavailable'
}

Export-ModuleMember -Function Test-FfmpegEncoder, Test-NvencTuneSupport, Format-CapabilityStatus, Format-NvencTuneStatus
