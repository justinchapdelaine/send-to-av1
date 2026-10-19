<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Check the actual setup window, shared styles, and hidden Windows Script Host launchers.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'These checks require Windows.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run this test with PowerShell -STA.' }
$repoRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('av1 setup & (test) %PATH% ' + [char]0xe9 + ' ' + [Guid]::NewGuid().ToString('N'))
$originalRecord = $env:SEND_TO_AV1_SETUP_TEST_RECORD
$window = $null
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $repoRoot 'src/AV1.Theme.psm1') -Force
    Import-Module (Join-Path $repoRoot 'src/AV1.Xaml.psm1') -Force
    $source = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src/Show-AV1Setup.ps1')
    $match = [regex]::Match($source, '(?s)\[xml\]\$layout = @''\r?\n(.*?)\r?\n''@')
    Assert-True $match.Success 'The actual setup layout was not found.'
    [xml]$layout = $match.Groups[1].Value
    Add-AV1WindowResources -Layout $layout
    $reader = [Xml.XmlNodeReader]::new($layout)
    try { $window = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
    $controls = @{}
    foreach ($name in @('Heading', 'Description', 'Location', 'LocationHint', 'DownloadOptions', 'DownloadTools',
            'ProgressPanel', 'Phase', 'Progress', 'Notice', 'DetailsExpander', 'Details', 'ActionButton', 'CloseButton')) {
        $controls[$name] = $window.FindName($name)
        Assert-True ($null -ne $controls[$name]) ('Missing setup control: ' + $name)
    }
    Assert-True ($controls.ProgressPanel.Visibility -eq 'Collapsed' -and $controls.DetailsExpander.Visibility -eq 'Collapsed') 'Idle setup exposes empty progress or details.'
    Assert-True ($controls.DownloadTools.IsChecked -and $controls.ActionButton.IsEnabled) 'The initial installation choices are unavailable.'
    $controls.ActionButton.ApplyTemplate() | Out-Null
    Assert-True ($null -ne $controls.ActionButton.Template.FindName('FocusRing', $controls.ActionButton)) 'Setup does not use the shared button template.'
    $checkBox = $controls.DownloadTools
    $checkBox.ApplyTemplate() | Out-Null
    $checkSurface = $checkBox.Template.FindName('CheckSurface', $checkBox)
    $checkGlyph = $checkBox.Template.FindName('CheckGlyph', $checkBox)
    $checkFocusRing = $checkBox.Template.FindName('CheckFocusRing', $checkBox)
    Assert-True ($null -ne $checkSurface -and $null -ne $checkGlyph -and $null -ne $checkFocusRing) 'Setup still uses the stock checkbox template.'
    Assert-True ($checkBox.Focusable -and $checkBox.IsTabStop) 'The download choice cannot receive keyboard focus.'
    $expander = $controls.DetailsExpander
    $expander.ApplyTemplate() | Out-Null
    $detailsToggle = $expander.Template.FindName('HeaderSite', $expander)
    $detailsContent = $expander.Template.FindName('DetailsContent', $expander)
    Assert-True ($null -ne $detailsToggle -and $null -ne $detailsContent) 'Setup does not use the shared Details template.'
    $detailsToggle.ApplyTemplate() | Out-Null
    $chevron = $detailsToggle.Template.FindName('DetailsChevron', $detailsToggle)
    Assert-True ($detailsToggle.Focusable -and $detailsToggle.IsTabStop -and
        $null -ne $detailsToggle.Template.FindName('DetailsFocusRing', $detailsToggle)) 'Setup Details lost keyboard access or focus styling.'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'The setup window script does not parse.'
    $definitions = ($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        ForEach-Object { $_.Extent.Text }) -join "`n"
    . ([scriptblock]::Create($definitions))
    foreach ($theme in @('Light', 'Dark', 'HighContrast')) {
        Set-AV1WindowTheme -Window $window -Theme $theme
        $palette = Get-AV1ThemePalette $theme
        Assert-True ($window.Background.Color.ToString() -eq [Windows.Media.ColorConverter]::ConvertFromString($palette.WindowBrush).ToString()) 'Setup ignored its window palette.'
        Assert-True ($controls.ActionButton.Background.Color -eq $window.Resources['PrimaryBrush'].Color) 'The setup action did not follow the theme.'
        $controls.ActionButton.IsEnabled = $false
        Assert-True ($controls.ActionButton.Background.Color -eq $window.Resources['DisabledBrush'].Color) 'Disabled setup buttons did not follow the theme.'
        $controls.ActionButton.IsEnabled = $true

        $expander.IsExpanded = $false
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::DataBind)
        Assert-True (-not $detailsToggle.IsChecked -and $detailsContent.Visibility -eq 'Collapsed' -and
            $chevron.Data.Bounds.Height -gt $chevron.Data.Bounds.Width) 'Collapsed setup Details lost its right chevron or exposes content.'
        Assert-True ($chevron.Stroke.Color -eq $window.Resources['MutedBrush'].Color) ('Setup Details ignored its theme: ' + $theme)
        $detailsToggle.IsChecked = $true
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::DataBind)
        Assert-True ($expander.IsExpanded -and $detailsContent.Visibility -eq 'Visible' -and
            $chevron.Data.Bounds.Width -gt $chevron.Data.Bounds.Height) 'The setup Details toggle did not expand content with a down chevron.'
        $expander.IsExpanded = $false
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::DataBind)
        Assert-True (-not $detailsToggle.IsChecked -and $detailsContent.Visibility -eq 'Collapsed') 'Programmatic setup Details changes lost their binding.'

        # The selected state must be visible before any mouse hover. Exercise
        # the actual template, including disabled states used while setup runs.
        $checkBox.IsChecked = $true
        Assert-True (-not $checkBox.IsMouseOver) 'The checkbox regression check unexpectedly has mouse hover.'
        Assert-True ($checkSurface.Background.Color -eq $window.Resources['PrimaryBrush'].Color -and
            $checkGlyph.Visibility -eq 'Visible' -and $checkGlyph.Stroke.Color -eq $window.Resources['PrimaryTextBrush'].Color) ('The checked option lacks its contrasting fill/checkmark: ' + $theme)
        Assert-True ($checkSurface.BorderBrush.Color -eq $window.Resources['AccentBrush'].Color) ('The checked option lost its visible border: ' + $theme)
        $checkBox.IsChecked = $false
        Assert-True ($checkGlyph.Visibility -eq 'Collapsed' -and $checkSurface.Background.Color -eq $window.Resources['SurfaceBrush'].Color -and
            $checkSurface.BorderBrush.Color -eq $window.Resources['MutedBrush'].Color) ('The unchecked option is ambiguous: ' + $theme)
        $checkBox.IsChecked = $true
        $checkBox.IsEnabled = $false
        Assert-True ($checkGlyph.Visibility -eq 'Visible' -and $checkGlyph.Stroke.Color -eq $window.Resources['DisabledTextBrush'].Color -and
            $checkSurface.Background.Color -eq $window.Resources['DisabledBrush'].Color -and
            $checkBox.Foreground.Color -eq $window.Resources['DisabledTextBrush'].Color) ('The disabled option lost its selected state or theme: ' + $theme)
        $checkBox.IsChecked = $false
        Assert-True ($checkGlyph.Visibility -eq 'Collapsed') ('The disabled unchecked option still displays a checkmark: ' + $theme)
        $checkBox.IsEnabled = $true
        $checkBox.IsChecked = $true
        Assert-True ($checkGlyph.Stroke.Color -eq $window.Resources['PrimaryTextBrush'].Color -and
            $checkBox.Foreground.Color -eq $window.Resources['TextBrush'].Color) ('Re-enabling the option did not restore its theme: ' + $theme)
    }
    $Uninstall = $false
    $state = @{ Running = $true; Finished = $false; Result = $null }
    Update-SetupWindow ([PSCustomObject]@{ Type = 'Phase'; Message = 'Downloading FFmpeg...' })
    Update-SetupWindow ([PSCustomObject]@{ Type = 'Detail'; Message = 'Download diagnostic' })
    Assert-True ($controls.Phase.Text -eq 'Downloading FFmpeg...' -and $controls.Details.Text -match 'Download diagnostic') 'Setup lost background progress or diagnostics.'
    Update-SetupWindow ([PSCustomObject]@{ Type = 'Result'; Data = [PSCustomObject]@{ Status = 'Warning'; Message = 'Download unavailable; shortcuts installed.' } })
    Finish-SetupWindow
    Assert-True (-not $state.Running -and -not $state.Finished -and $controls.ActionButton.Content -eq 'Try again') 'A warning cannot be retried.'
    Assert-True ($controls.DetailsExpander.IsExpanded -and $controls.Heading.Foreground.Color -eq $window.Resources['WarningBrush'].Color) 'Setup hid a warning or lost its semantic color.'
    $state.Result = [PSCustomObject]@{ Status = 'Failed'; Message = 'Test setup failure' }
    Finish-SetupWindow
    Assert-True ($controls.Description.Text -eq 'Test setup failure' -and $controls.Heading.Foreground.Color -eq $window.Resources['ErrorBrush'].Color) 'Setup failure was hidden.'
    $state.Result = [PSCustomObject]@{ Status = 'Completed'; Message = 'Installed.' }
    Finish-SetupWindow
    Assert-True ($state.Finished -and $controls.Heading.Text -eq 'Installation complete' -and $controls.ActionButton.Content -eq 'Close') 'Install completion did not enable closing.'
    Assert-True ($controls.ProgressPanel.Visibility -eq 'Collapsed' -and $controls.DownloadOptions.Visibility -eq 'Collapsed') 'Completed setup still shows progress or setup choices.'
    Set-AV1WindowTheme -Window $window -Theme Dark
    Assert-True ($controls.Heading.Foreground.Color -eq $window.Resources['SuccessBrush'].Color) 'Changing themes lost the completion color.'
    $Uninstall = $true
    Finish-SetupWindow
    Assert-True ($controls.Heading.Text -eq 'Uninstall complete') 'Uninstall uses the install completion heading.'
    $window.Close()
    $window = $null

    # Test both real launchers against a recording script in a temporary project.
    # No setup scripts run and no user Send to entries are changed.
    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'src') -Force | Out-Null
    foreach ($name in @('Install-SendTo.vbs', 'Uninstall-SendTo.vbs')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $name) -Destination $tempRoot
    }
    @'
param([switch]$Uninstall)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class SetupConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window); }'
$record = @{ Uninstall=[bool]$Uninstall; VisibleConsole=[SetupConsoleProbe]::IsWindowVisible([SetupConsoleProbe]::GetConsoleWindow()); Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString() }
$path = $env:SEND_TO_AV1_SETUP_TEST_RECORD
[IO.File]::WriteAllText($path + '.tmp', ($record | ConvertTo-Json))
[IO.File]::Move($path + '.tmp', $path)
'@ | Set-Content -LiteralPath (Join-Path $tempRoot 'src/Show-AV1Setup.ps1') -Encoding Ascii
    foreach ($name in @('Install-SendTo', 'Uninstall-SendTo')) {
        $env:SEND_TO_AV1_SETUP_TEST_RECORD = Join-Path $tempRoot ($name + '.json')
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $env:WINDIR 'System32/wscript.exe'
        $start.Arguments = '//nologo "' + (Join-Path $tempRoot ($name + '.vbs')) + '"'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $process = [Diagnostics.Process]::Start($start)
        try {
            if (-not $process.WaitForExit(10000)) { throw 'The setup launcher did not exit.' }
            Assert-True ($process.ExitCode -eq 0) 'The setup launcher failed.'
        }
        finally { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $env:SEND_TO_AV1_SETUP_TEST_RECORD)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw ('The setup launcher did not reach the recording script: ' + $name) }
            Start-Sleep -Milliseconds 50
        }
        $record = Get-Content -Raw -Encoding UTF8 -LiteralPath $env:SEND_TO_AV1_SETUP_TEST_RECORD | ConvertFrom-Json
        Assert-True (-not $record.VisibleConsole -and $record.Apartment -eq 'STA') 'Setup launched with a visible console or without STA.'
        Assert-True ($record.Uninstall -eq ($name -eq 'Uninstall-SendTo')) 'The setup launcher changed the operation.'
    }
    Write-Host ('Windows setup checks passed: {0}.' -f $script:checks)
}
finally {
    $env:SEND_TO_AV1_SETUP_TEST_RECORD = $originalRecord
    if ($null -ne $window) { $window.Close() }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
