<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Apply Windows app themes to the progress window without changing encoding state.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-AV1ThemePalette {
    param([ValidateSet('Light', 'Dark', 'HighContrast')][string]$Theme = 'Light')

    $palette = @{
        WindowBrush = '#F5F7FB'; SurfaceBrush = '#FFFFFF'; TextBrush = '#0F172A'; MutedBrush = '#5F6F85'
        BorderBrush = '#CBD5E1'; TrackBrush = '#E2E8F0'; AccentBrush = '#2563EB'; SuccessBrush = '#15803D'
        WarningBrush = '#B45309'; ErrorBrush = '#B91C1C'; BadgeBrush = '#E8EFFD'; BadgeTextBrush = '#1D4ED8'
        HoverBrush = '#F1F5F9'; PressedBrush = '#E2E8F0'; HoverTextBrush = '#0F172A'; FocusBrush = '#2563EB'
        PrimaryBrush = '#2563EB'; PrimaryHoverBrush = '#1D4ED8'; PrimaryPressedBrush = '#1E40AF'; PrimaryTextBrush = '#FFFFFF'
        DangerHoverBrush = '#FEF2F2'; DangerPressedBrush = '#FEE2E2'; DangerTextBrush = '#B91C1C'
        DisabledBrush = '#F1F5F9'; DisabledTextBrush = '#64748B'
    }
    if ($Theme -eq 'Dark') {
        $palette = @{
            WindowBrush = '#111827'; SurfaceBrush = '#1F2937'; TextBrush = '#F1F5F9'; MutedBrush = '#A8B5C8'
            BorderBrush = '#475569'; TrackBrush = '#374151'; AccentBrush = '#93B4FF'; SuccessBrush = '#86EFAC'
            WarningBrush = '#FCD34D'; ErrorBrush = '#FCA5A5'; BadgeBrush = '#25375C'; BadgeTextBrush = '#BFDBFE'
            HoverBrush = '#334155'; PressedBrush = '#475569'; HoverTextBrush = '#F1F5F9'; FocusBrush = '#93B4FF'
            PrimaryBrush = '#2563EB'; PrimaryHoverBrush = '#1D4ED8'; PrimaryPressedBrush = '#1E40AF'; PrimaryTextBrush = '#FFFFFF'
            DangerHoverBrush = '#452B34'; DangerPressedBrush = '#5D303B'; DangerTextBrush = '#FCA5A5'
            DisabledBrush = '#263141'; DisabledTextBrush = '#94A3B8'
        }
    }
    elseif ($Theme -eq 'HighContrast') {
        # Resolve these only on Windows after WPF has been loaded.
        $background = [Windows.SystemColors]::WindowColor.ToString()
        $text = [Windows.SystemColors]::WindowTextColor.ToString()
        $highlight = [Windows.SystemColors]::HighlightColor.ToString()
        $highlightText = [Windows.SystemColors]::HighlightTextColor.ToString()
        foreach ($key in @('WindowBrush', 'SurfaceBrush', 'TrackBrush', 'BadgeBrush', 'DisabledBrush')) { $palette[$key] = $background }
        foreach ($key in @('TextBrush', 'MutedBrush', 'BorderBrush', 'AccentBrush', 'SuccessBrush', 'WarningBrush', 'ErrorBrush', 'BadgeTextBrush')) { $palette[$key] = $text }
        foreach ($key in @('HoverBrush', 'PressedBrush', 'FocusBrush', 'PrimaryBrush', 'PrimaryHoverBrush', 'PrimaryPressedBrush', 'DangerHoverBrush', 'DangerPressedBrush')) { $palette[$key] = $highlight }
        foreach ($key in @('PrimaryTextBrush', 'HoverTextBrush', 'DangerTextBrush')) { $palette[$key] = $highlightText }
        $palette.DisabledTextBrush = [Windows.SystemColors]::GrayTextColor.ToString()
    }
    return $palette
}

function Get-AV1StatusBrushKey {
    param([string]$Color)
    switch ($Color) {
        '#2563EB' { return 'AccentBrush' }
        '#15803D' { return 'SuccessBrush' }
        '#B45309' { return 'WarningBrush' }
        '#B91C1C' { return 'ErrorBrush' }
        default { return 'MutedBrush' }
    }
}

function Get-AV1WindowsTheme {
    if ([Windows.SystemParameters]::HighContrast) { return 'HighContrast' }
    try {
        $preference = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ([int]$preference.AppsUseLightTheme -eq 0) { return 'Dark' }
    }
    catch { } # Older Windows installations may not have an app-theme preference.
    return 'Light'
}

function Get-AV1ThemeKey {
    param([ValidateSet('Light', 'Dark', 'HighContrast')][string]$Theme)

    # High Contrast colors can change without the theme name changing, so
    # include the resolved palette. Callers reapply only when this key changes.
    if ($Theme -ne 'HighContrast') { return $Theme }
    $palette = Get-AV1ThemePalette -Theme $Theme
    return $Theme + ':' + ((@($palette.Keys | Sort-Object) | ForEach-Object { $palette[$_] }) -join ',')
}

function Set-AV1WindowTheme {
    param([Parameter(Mandatory = $true)]$Window,
        [ValidateSet('Light', 'Dark', 'HighContrast')][string]$Theme)

    $palette = Get-AV1ThemePalette -Theme $Theme
    foreach ($key in $palette.Keys) {
        # New-Object can leave a PSObject wrapper in the object-valued resource
        # dictionary. WPF needs the actual Brush when resolving DynamicResource.
        $brush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($palette[$key]))
        $brush.Freeze()
        $Window.Resources[$key] = $brush
    }
    # Let built-in selection and expander styles use the same window palette.
    $Window.Resources[[Windows.SystemColors]::ControlBrushKey] = $Window.Resources['SurfaceBrush']
    $Window.Resources[[Windows.SystemColors]::ControlTextBrushKey] = $Window.Resources['TextBrush']
    $Window.Resources[[Windows.SystemColors]::WindowBrushKey] = $Window.Resources['SurfaceBrush']
    $Window.Resources[[Windows.SystemColors]::WindowTextBrushKey] = $Window.Resources['TextBrush']
    $Window.Resources[[Windows.SystemColors]::HighlightBrushKey] = $Window.Resources['PrimaryBrush']
    $Window.Resources[[Windows.SystemColors]::HighlightTextBrushKey] = $Window.Resources['PrimaryTextBrush']
    $Window.Resources[[Windows.SystemColors]::GrayTextBrushKey] = $Window.Resources['DisabledTextBrush']
    # Reading Handle does not create a native window. The SourceInitialized
    # handler reapplies the theme once the handle exists. Caption support is optional.
    try {
        $handle = [Windows.Interop.WindowInteropHelper]::new($Window).Handle
        if ($handle -eq [IntPtr]::Zero) { return }
        if (-not ('SendToAv1Theme.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SendToAv1Theme {
    public static class NativeMethods {
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    }
}
'@
        }
        $dark = [int]($Theme -eq 'Dark')
        $result = [SendToAv1Theme.NativeMethods]::DwmSetWindowAttribute($handle, 20, [ref]$dark, 4)
        if ($result -lt 0) { [SendToAv1Theme.NativeMethods]::DwmSetWindowAttribute($handle, 19, [ref]$dark, 4) | Out-Null }
    }
    catch { } # Keep the native caption when immersive dark mode is unavailable.
}

Export-ModuleMember -Function Get-AV1ThemePalette, Get-AV1StatusBrushKey, Get-AV1WindowsTheme, Get-AV1ThemeKey, Set-AV1WindowTheme
