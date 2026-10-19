<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Format structured encoder updates for the Windows progress window.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Format-AV1Clock {
    param([double]$Seconds)
    $value = [long][Math]::Max(0, [Math]::Floor($Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [long][Math]::Floor($value / 3600.0),
        [long][Math]::Floor(($value % 3600) / 60.0), ($value % 60))
}

function Format-AV1Size {
    param([double]$Bytes)
    foreach ($unit in @(@(1TB, 'TB'), @(1GB, 'GB'), @(1MB, 'MB'), @(1KB, 'KB'))) {
        if ([Math]::Abs($Bytes) -ge $unit[0]) { return ('{0:N1} {1}' -f ($Bytes / $unit[0]), $unit[1]) }
    }
    return ('{0:N0} B' -f $Bytes)
}

function Get-AV1ProgressView {
    param([Parameter(Mandatory = $true)]$Progress)

    $remaining = 'Calculating...'
    if ($Progress.Finalizing) { $remaining = 'Finalizing...' }
    elseif ($Progress.DurationSeconds -le 0) { $remaining = 'Unavailable' }
    elseif ($Progress.SecondsRemaining -eq 0) { $remaining = 'Almost done' }
    elseif ($Progress.SecondsRemaining -gt 0 -and $Progress.SecondsRemaining -lt 60) { $remaining = 'Less than a minute' }
    elseif ($Progress.SecondsRemaining -ge 60) {
        $minutes = [long][Math]::Round($Progress.SecondsRemaining / 60.0, [MidpointRounding]::AwayFromZero)
        if ($minutes -eq 1) { $remaining = 'About 1 minute' }
        elseif ($minutes -lt 60) { $remaining = 'About {0} minutes' -f $minutes }
        else {
            $hours = [long][Math]::Floor($minutes / 60.0)
            $minutePart = $minutes % 60
            $hourWord = 'hours'
            if ($hours -eq 1) { $hourWord = 'hour' }
            $remaining = 'About {0} {1}' -f $hours, $hourWord
            if ($minutePart -gt 0) { $remaining += (' {0} min' -f $minutePart) }
        }
    }
    $processed = Format-AV1Clock $Progress.ProcessedSeconds
    if ($Progress.DurationSeconds -gt 0) { $processed += ' / ' + (Format-AV1Clock $Progress.DurationSeconds) }
    $detail = [string]$Progress.Status
    if ($Progress.SecondsRemaining -ge 0 -and -not $Progress.Finalizing) {
        $detail = 'Estimated remaining: ' + (Format-AV1Clock $Progress.SecondsRemaining)
    }
    return [PSCustomObject]@{
        Remaining = $remaining; RemainingDetail = $detail
        Elapsed = (Format-AV1Clock $Progress.ElapsedSeconds); Processed = $processed
    }
}

function Get-AV1ResultView {
    param([Parameter(Mandatory = $true)]$Data)

    $color = '#64748B'
    $glyph = [string][char]0x2192
    $description = [string]$Data.Message
    $path = [string]$Data.Path
    if ($Data.Status -eq 'Completed') {
        $path = $Data.OutputPath
        $color = '#15803D'
        $glyph = [string][char]0x2713
        $description = '{0} {1} {2}' -f (Format-AV1Size $Data.InputBytes), [char]0x2192, (Format-AV1Size $Data.OutputBytes)
        if ($Data.InputBytes -gt 0) {
            $change = 100.0 * (1.0 - $Data.OutputBytes / [double]$Data.InputBytes)
            if ($change -gt 0) { $description += (' {0} {1:N1}% smaller' -f [char]0xb7, $change) }
            elseif ($change -lt 0) { $description += (' {0} {1:N1}% larger' -f [char]0xb7, (-$change)) }
            else { $description += (' {0} Same size' -f [char]0xb7) }
        }
        if ($Data.OutputBytes -gt $Data.InputBytes) { $color = '#B45309'; $glyph = '!' }
    }
    elseif ($Data.Status -eq 'Failed') { $color = '#B91C1C'; $glyph = [string][char]0x2715 }
    elseif ($Data.Status -eq 'Cancelled') { $glyph = [string][char]0x2014 }
    return [PSCustomObject]@{
        Name = [IO.Path]::GetFileName($Data.Path); Status = $Data.Status; Description = $description
        PathText = $path; Color = $color; Glyph = $glyph
    }
}

Export-ModuleMember -Function Format-AV1Clock, Format-AV1Size, Get-AV1ProgressView, Get-AV1ResultView
