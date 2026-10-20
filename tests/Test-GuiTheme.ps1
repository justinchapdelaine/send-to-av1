<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Check light/dark palette completeness and readable text without WPF.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/AV1.Theme.psm1') -Force
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Get-Luminance {
    param([string]$Color)
    $channels = foreach ($offset in @(1, 3, 5)) {
        $value = [Convert]::ToInt32($Color.Substring($offset, 2), 16) / 255.0
        if ($value -le 0.04045) { $value / 12.92 }
        else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
    }
    return 0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
}
function Assert-Contrast {
    param([hashtable]$Palette, [string]$Foreground, [string]$Background, [string]$Theme)
    $first = Get-Luminance $Palette[$Foreground]
    $second = Get-Luminance $Palette[$Background]
    $contrast = ([Math]::Max($first, $second) + 0.05) / ([Math]::Min($first, $second) + 0.05)
    Assert-True ($contrast -ge 4.5) ('Unreadable {0} text: {1} on {2} ({3:N2}:1).' -f $Theme, $Foreground, $Background, $contrast)
}

$light = Get-AV1ThemePalette Light
$dark = Get-AV1ThemePalette Dark
$lightKeys = ($light.Keys | Sort-Object) -join ','
$darkKeys = ($dark.Keys | Sort-Object) -join ','
Assert-True ($lightKeys -eq $darkKeys) 'Light and dark palettes expose different resources.'
Assert-True ($light.WindowBrush -ne $dark.WindowBrush -and $light.TextBrush -ne $dark.TextBrush) 'Dark mode did not change the background and text.'
foreach ($theme in @('Light', 'Dark')) {
    $palette = Get-AV1ThemePalette $theme
    foreach ($key in $palette.Keys) { Assert-True ($palette[$key] -match '^#[0-9A-Fa-f]{6}$') ('Invalid theme color: ' + $key) }
    foreach ($foreground in @('TextBrush', 'MutedBrush', 'AccentBrush', 'SuccessBrush', 'WarningBrush', 'ErrorBrush')) {
        foreach ($background in @('WindowBrush', 'SurfaceBrush')) { Assert-Contrast $palette $foreground $background $theme }
    }
    Assert-Contrast $palette 'BadgeTextBrush' 'BadgeBrush' $theme
    foreach ($background in @('PrimaryBrush', 'PrimaryHoverBrush', 'PrimaryPressedBrush')) { Assert-Contrast $palette 'PrimaryTextBrush' $background $theme }
    foreach ($background in @('HoverBrush', 'PressedBrush')) { Assert-Contrast $palette 'HoverTextBrush' $background $theme }
    foreach ($background in @('DangerHoverBrush', 'DangerPressedBrush')) { Assert-Contrast $palette 'DangerTextBrush' $background $theme }
    foreach ($case in @(@('#2563EB', 'AccentBrush'), @('#15803D', 'SuccessBrush'), @('#B45309', 'WarningBrush'), @('#B91C1C', 'ErrorBrush'), @('#64748B', 'MutedBrush'))) {
        Assert-True ((Get-AV1StatusBrushKey $case[0]) -eq $case[1] -and $palette.ContainsKey($case[1])) 'A status did not map to an available theme resource.'
    }
}
Write-Host ('GUI theme checks passed: {0}.' -f $script:checks)
