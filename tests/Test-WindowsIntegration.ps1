<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Validate WPF layout and real shortcut installation in an isolated Windows folder.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Run this integration test on Windows.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this integration test with PowerShell -STA.'
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$shellPath = (Get-Process -Id $PID).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('send-to-av1-windows-' + [Guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $tempRoot 'Project with spaces'
$installer = Join-Path $projectRoot 'src/Install-SendTo.ps1'
$script:checks = 0
$shell = $null
$window = $null
$launcherPath = Join-Path $projectRoot 'bin/SendToAV1.Launcher.exe'
$originalRecord = $env:SEND_TO_AV1_LAUNCHER_TEST_RECORD

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Invoke-Installer {
    param([switch]$Uninstall)
    # Omit LauncherPath to exercise the same default as Install-SendTo.cmd.
    $options = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-SendToDirectory', $tempRoot)
    if ($Uninstall) { $options += '-Uninstall' }
    & $shellPath @options
    if ($LASTEXITCODE -ne 0) { throw 'Shortcut installer failed.' }
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    & (Join-Path $PSScriptRoot 'Test-WpfApi.ps1')
    Import-Module (Join-Path $repoRoot 'src/AV1.ViewModel.psm1') -Force
    Import-Module (Join-Path $repoRoot 'src/AV1.Theme.psm1') -Force
    # Read resource values inside CLR code: PowerShell's property adapter can
    # unwrap PSObject values and conceal the type that WPF actually receives.
    if (-not ('Av1ThemeResourceInspector' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;
public static class Av1ThemeResourceInspector {
    public static bool HasType(IDictionary resources, object key, Type expectedType) {
        return expectedType.IsInstanceOfType(resources[key]);
    }
}
'@
    }
    # Use a real Window before native initialization; a fake window can hide
    # accidental references to properties that WPF does not actually expose.
    $resourceProbe = [Windows.Window]::new()
    $probeInterop = [Windows.Interop.WindowInteropHelper]::new($resourceProbe)
    try {
        Assert-True ($probeInterop.Handle -eq [IntPtr]::Zero) 'The theme probe already has a native handle.'
        foreach ($theme in @('Light', 'Dark', 'HighContrast')) {
            Set-AV1WindowTheme -Window $resourceProbe -Theme $theme
            foreach ($key in (Get-AV1ThemePalette $theme).Keys) {
                Assert-True ([Av1ThemeResourceInspector]::HasType($resourceProbe.Resources, $key, [Windows.Media.Brush])) ('WPF received a wrapped or invalid resource: ' + $theme + '/' + $key)
            }
            foreach ($key in @([Windows.SystemColors]::ControlBrushKey, [Windows.SystemColors]::ControlTextBrushKey,
                    [Windows.SystemColors]::WindowBrushKey, [Windows.SystemColors]::WindowTextBrushKey,
                    [Windows.SystemColors]::HighlightBrushKey, [Windows.SystemColors]::HighlightTextBrushKey,
                    [Windows.SystemColors]::GrayTextBrushKey)) {
                Assert-True ([Av1ThemeResourceInspector]::HasType($resourceProbe.Resources, $key, [Windows.Media.Brush])) 'A system-color resource alias retained a PowerShell wrapper.'
            }
            Assert-True ($probeInterop.Handle -eq [IntPtr]::Zero) 'Applying a theme created a native window before startup.'
        }
    }
    finally { $resourceProbe.Close() }
    $source = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src/Show-AV1Progress.ps1')
    $match = [regex]::Match($source, '(?s)\[xml\]\$layout = @''\r?\n(.*?)\r?\n''@')
    Assert-True $match.Success 'Could not find the actual progress-window layout.'
    [xml]$layout = $match.Groups[1].Value
    Import-Module (Join-Path $repoRoot 'src/AV1.Xaml.psm1') -Force
    Add-AV1WindowResources -Layout $layout
    $reader = New-Object Xml.XmlNodeReader $layout
    try { $window = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
    Set-AV1WindowTheme -Window $window -Theme Light
    foreach ($name in @('FileLabel', 'Progress', 'PercentLabel',
            'TimeLabel', 'Results', 'Details', 'ActionButton', 'FolderButton', 'SummaryLabel',
            'BatchLabel', 'RemainingValue', 'ElapsedValue', 'ProcessedValue', 'DetailsExpander',
            'ProgressPanel', 'TimingPanel')) {
        Assert-True ($null -ne $window.FindName($name)) ('Missing WPF control: ' + $name)
    }
    Assert-True ($window.SizeToContent -eq 'Height') 'The window reserves a fixed height.'
    $fileLabel = $window.FindName('FileLabel')
    $percentLabel = $window.FindName('PercentLabel')
    $progressPanel = $window.FindName('ProgressPanel')
    Assert-True ($percentLabel.Parent -eq $fileLabel.Parent -and [Windows.Controls.Grid]::GetColumn($percentLabel) -eq 1) 'The percentage is not beside the filename.'
    Assert-True ($progressPanel.ColumnDefinitions.Count -eq 0 -and $progressPanel.Children.Count -eq 1 -and
        $window.FindName('Progress').Parent -eq $progressPanel) 'The progress bar still shares its width with another element.'
    Assert-True ($null -eq $window.FindName('ModeLabel') -and $null -eq $window.FindName('StatusLabel') -and
        $null -eq $window.FindName('StatusDot')) 'The header retains separate mode or status decorations.'
    $results = $window.FindName('Results')
    $results.ApplyTemplate() | Out-Null
    Assert-True ($results -is [Windows.Controls.ItemsControl] -and $results -isnot [Windows.Controls.Primitives.Selector]) 'Result cards still support selection.'
    $resultsScroll = $results.Template.FindName('ResultsScroll', $results)
    Assert-True ($resultsScroll -is [Windows.Controls.ScrollViewer] -and $resultsScroll.Focusable -and $resultsScroll.IsTabStop -and
        $resultsScroll.VerticalScrollBarVisibility -eq 'Auto' -and $resultsScroll.HorizontalScrollBarVisibility -eq 'Disabled') 'Informational result cards lost their scrolling behavior.'
    Assert-True ($results.Visibility -eq 'Collapsed') 'The empty results area is visible.'
    $results.Items.Add((Get-AV1ResultView ([PSCustomObject]@{
        Path = 'fixture.mkv'; Status = 'Completed'; Message = ''; InputBytes = 100; OutputBytes = 50; OutputPath = 'fixture_AV1.mkv'
    }))) | Out-Null
    Assert-True ($results.Visibility -eq 'Visible') 'Results did not appear after an item was added.'
    # Fill the actual result template beyond its viewport and exercise the
    # keyboard scrolling commands without showing a window or selecting cards.
    for ($index = 1; $index -le 7; $index++) {
        $results.Items.Add((Get-AV1ResultView ([PSCustomObject]@{
            Path = ('fixture-{0}.mkv' -f $index); Status = 'Completed'; Message = ''
            InputBytes = 100; OutputBytes = 50; OutputPath = ('fixture-{0}_AV1.mkv' -f $index)
        }))) | Out-Null
    }
    $results.Measure([Windows.Size]::new(600, 220))
    $results.Arrange([Windows.Rect]::new(0, 0, 600, 220))
    $results.UpdateLayout()
    Assert-True ($resultsScroll.ScrollableHeight -gt 0) 'The batch fixture has no scrollable results.'
    [Windows.Input.ComponentCommands]::ScrollPageDown.Execute($null, $resultsScroll)
    $results.UpdateLayout()
    Assert-True ($resultsScroll.VerticalOffset -gt 0) 'The keyboard page-down command did not scroll the results.'
    [Windows.Input.ComponentCommands]::ScrollPageUp.Execute($null, $resultsScroll)
    $results.UpdateLayout()
    Assert-True ($resultsScroll.VerticalOffset -eq 0) 'The keyboard page-up command did not return to the first result.'
    $results.Items.Clear()
    Assert-True ($results.Visibility -eq 'Collapsed') 'The empty results area did not collapse again.'
    # Drive the actual GUI event handlers against the real WPF controls without
    # launching an encode, so binding/template and error-display failures surface.
    $controls = @{}
    foreach ($name in @('FileLabel', 'Progress', 'PercentLabel',
            'TimeLabel', 'Results', 'Details', 'ActionButton', 'FolderButton', 'SummaryLabel',
            'BatchLabel', 'RemainingValue', 'ElapsedValue', 'ProcessedValue', 'DetailsExpander',
            'ProgressPanel', 'TimingPanel')) {
        $controls[$name] = $window.FindName($name)
    }
    Assert-True ($controls.ActionButton.Style -eq $window.FindResource('CancelButton')) 'The running action did not use the outlined cancel style.'
    Assert-True ($null -eq $window.FindName('OutcomeIcon') -and
        $controls.FileLabel.Style -eq $window.FindResource('HeadingText') -and
        $controls.Progress.Style -eq $window.FindResource('SharedProgressBar') -and
        $controls.Details.Style -eq $window.FindResource('DetailsLog')) 'Encoding bypasses shared styling or retains a duplicate heading icon.'
    $controls.Details.ApplyTemplate() | Out-Null
    $logHost = $controls.Details.Template.FindName('PART_ContentHost', $controls.Details)
    Assert-True ($null -ne $logHost -and $null -ne $logHost.Content) 'The encoding Details log lost its native text host.'
    Assert-True ($controls.FolderButton.Background.Color.ToString() -eq '#FFF1F5F9') 'The disabled folder button did not use its disabled palette.'
    $controls.ActionButton.ApplyTemplate() | Out-Null
    Assert-True ($null -ne $controls.ActionButton.Template.FindName('FocusRing', $controls.ActionButton)) 'The button template lost its keyboard focus indicator.'
    $expander = $controls.DetailsExpander
    $expander.ApplyTemplate() | Out-Null
    $detailsToggle = $expander.Template.FindName('HeaderSite', $expander)
    $detailsContent = $expander.Template.FindName('DetailsContent', $expander)
    Assert-True ($null -ne $detailsToggle -and $null -ne $detailsContent) 'Encoding does not use the shared Details template.'
    $detailsToggle.ApplyTemplate() | Out-Null
    $chevron = $detailsToggle.Template.FindName('DetailsChevron', $detailsToggle)
    Assert-True ($detailsToggle.Focusable -and $detailsToggle.IsTabStop -and
        $null -ne $detailsToggle.Template.FindName('DetailsFocusRing', $detailsToggle)) 'Encoding Details lost keyboard access or focus styling.'
    foreach ($theme in @('Light', 'Dark', 'HighContrast')) {
        Set-AV1WindowTheme -Window $window -Theme $theme
        $expander.IsExpanded = $false
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::DataBind)
        Assert-True (-not $detailsToggle.IsChecked -and $detailsContent.Visibility -eq 'Collapsed' -and
            $chevron.Data.Bounds.Height -gt $chevron.Data.Bounds.Width) 'Collapsed encoding Details lost its right chevron or exposes content.'
        Assert-True ($chevron.Stroke.Color -eq $window.Resources['MutedBrush'].Color) ('Encoding Details ignored its theme: ' + $theme)
        $detailsToggle.IsChecked = $true
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::DataBind)
        Assert-True ($expander.IsExpanded -and $detailsContent.Visibility -eq 'Visible' -and
            $chevron.Data.Bounds.Width -gt $chevron.Data.Bounds.Height) 'The encoding Details toggle did not expand content with a down chevron.'
        $expander.IsExpanded = $false
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::DataBind)
        Assert-True (-not $detailsToggle.IsChecked -and $detailsContent.Visibility -eq 'Collapsed') 'Programmatic encoding Details changes lost their binding.'
    }
    # Drive the actual result-color style on the window's logical tree.
    $statusProbe = New-Object Windows.Controls.TextBlock
    $statusProbe.Style = $window.FindResource('ResultColor')
    $statusProbe.DataContext = Get-AV1ResultView ([PSCustomObject]@{
        Path = 'fixture.mkv'; Status = 'Completed'; Message = ''; InputBytes = 10MB; OutputBytes = 5MB; OutputPath = 'fixture_AV1.mkv'
    })
    $controls.Results.Parent.Children.Add($statusProbe) | Out-Null
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::DataBind)
    foreach ($theme in @('Light', 'Dark', 'HighContrast')) {
        Set-AV1WindowTheme -Window $window -Theme $theme
        Assert-True ($statusProbe.Foreground.Color -eq $window.Resources['SuccessBrush'].Color) 'An existing result did not follow its theme status color.'
    }
    $controls.Results.Parent.Children.Remove($statusProbe)
    Set-AV1WindowTheme -Window $window -Theme Light
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    $definitions = ($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false) | ForEach-Object { $_.Extent.Text }) -join "`n"
    . ([scriptblock]::Create($definitions))
    $cancellation = New-Object Threading.CancellationTokenSource
    try {
        $state = @{ Worker = [PSCustomObject]@{ Cancellation = $cancellation }; LastProgress = $null; HasWarnings = $false
            Clock = [Diagnostics.Stopwatch]::StartNew(); Running = $true; Summary = $null; Fatal = $false
            FileCount = 1; Mode = 'Small'; BatchPosition = 'Selected videos'; CurrentPath = 'fixture.mkv'; CurrentFinished = $true }
        Update-Window ([PSCustomObject]@{ Type = 'FileStarted'; Data = [PSCustomObject]@{ Path = 'fixture.mkv'; FileNumber = 1; FileCount = 1 } })
        Assert-True ($controls.BatchLabel.Text -eq ('File 1 of 1 {0} Small {0} Inspecting video' -f [char]0xb7)) 'The subtitle lost the file position, mode, or inspection phase.'
        $progress = [PSCustomObject]@{
            Percent = 25; SecondsRemaining = 480; Finalizing = $false
            DurationSeconds = 1200; ProcessedSeconds = 300; ElapsedSeconds = 160; Status = 'Precise progress'
        }
        Update-Window ([PSCustomObject]@{ Type = 'Progress'; Data = [PSCustomObject]@{ Progress = $progress } })
        Assert-True ($controls.RemainingValue.Text -eq 'About 8 minutes' -and $controls.PercentLabel.Text -eq '25%') 'The timing and percentage controls did not update.'
        Assert-True ($controls.Progress.Foreground.Color.ToString() -eq '#FF2563EB') 'Encoding progress did not use the blue accent.'
        Assert-True ($controls.BatchLabel.Text -eq ('File 1 of 1 {0} Small {0} Encoding' -f [char]0xb7) -and
            $controls.BatchLabel.Foreground.Color -eq $window.Resources['MutedBrush'].Color) 'The processing context is missing or visually competes with progress.'
        foreach ($mode in @('CPU', 'NVIDIA', 'Small')) {
            $state.Mode = $mode
            Set-Phase 'Finalizing output'
            Assert-True ($controls.BatchLabel.Text -eq ('File 1 of 1 {0} {1} {0} Finalizing output' -f [char]0xb7, $mode)) 'A mode or finalization phase was lost in the subtitle.'
        }
        Set-AV1WindowTheme -Window $window -Theme Dark
        Assert-True ($window.Background.Color.ToString() -eq '#FF111827' -and $controls.Details.Background.Color.ToString() -eq '#FF1F2937') 'Dark mode left the window or details panel light.'
        Assert-True ($controls.Progress.Foreground.Color.ToString() -eq '#FF93B4FF' -and $controls.PercentLabel.Text -eq '25%' -and $controls.RemainingValue.Text -eq 'About 8 minutes') 'Switching themes lost progress or its semantic color.'
        Set-AV1WindowTheme -Window $window -Theme Light
        $controls.Progress.ApplyTemplate() | Out-Null
        Assert-True ($null -ne $controls.Progress.Template.FindName('PART_Indicator', $controls.Progress)) 'The progress template has no indicator.'
        Update-Window ([PSCustomObject]@{ Type = 'VerificationStarted'; Data = [PSCustomObject]@{} })
        Assert-True ($controls.BatchLabel.Text -match 'Small.*Verifying output$' -and $controls.Progress.IsIndeterminate -and
            $controls.RemainingValue.Text -eq 'Checking output...' -and $controls.PercentLabel.Text -ne '100%' -and
            $controls.ActionButton.IsEnabled) 'Verification reports completion early or prevents cancellation.'
        Update-Window ([PSCustomObject]@{ Type = 'Message'; Data = [PSCustomObject]@{ Message = 'A normal update'; Color = 'Gray' } })
        Assert-True (-not $controls.DetailsExpander.IsExpanded) 'Normal operation opened troubleshooting details.'
        Update-Window ([PSCustomObject]@{ Type = 'FileResult'; Data = [PSCustomObject]@{
            Status = 'Failed'; Path = 'fixture.mkv'; Message = 'Test failure'
        } })
        Assert-True ($controls.DetailsExpander.IsExpanded -and $controls.BatchLabel.Text -match 'Small.*Failed$') 'A failed file did not reveal its error details.'
        Assert-True ($controls.Progress.Foreground.Color.ToString() -eq '#FFB91C1C') 'A failure did not use the error color.'
        $results.Items.Clear()
        $controls.DetailsExpander.IsExpanded = $false
        Update-Window ([PSCustomObject]@{ Type = 'FileResult'; Data = [PSCustomObject]@{
            Path = 'fixture.mkv'; Status = 'Completed'; Message = ''; InputBytes = 10MB; OutputBytes = 5MB; OutputPath = 'fixture_AV1.mkv'
        } })
        $state.Summary = [PSCustomObject]@{ Processed = 1; Skipped = 0; Failed = 0; SavedBytes = 5MB; Cancelled = $false }
        Finish-Window
        Assert-True ($controls.ProgressPanel.Visibility -eq 'Collapsed' -and $controls.TimingPanel.Visibility -eq 'Collapsed') 'Finished encoding still shows progress or timing panels.'
        Assert-True ($controls.PercentLabel.Visibility -eq 'Collapsed' -and $controls.BatchLabel.Text -notmatch 'Completed|Encoding$') 'Finished encoding repeats the percentage or processing phase.'
        Assert-True ($controls.FileLabel.Text -eq 'Encoding complete' -and $controls.BatchLabel.Text -match '^Finished in .*Small$') 'Completion did not replace the filename heading and batch position.'
        Assert-True ($controls.FileLabel.Foreground.Color -eq $window.Resources['SuccessBrush'].Color) 'Encoding completion lost its SuccessBrush heading color.'
        Assert-True ($controls.SummaryLabel.Text -eq '' -and $controls.TimeLabel.Text -eq '' -and -not $results.Items[0].ShowStatus) 'Single-file success repeats counts, savings, or status.'
        Assert-True (-not $state.Clock.IsRunning -and $controls.ActionButton.Content -eq 'Close') 'Completion did not stop timing or enable closing.'
        Assert-True ($controls.ActionButton.Style -eq $window.FindResource('PrimaryButton') -and $controls.ActionButton.Background.Color.ToString() -eq '#FF2563EB') 'Close did not use the primary button style.'
        Set-AV1WindowTheme -Window $window -Theme Dark
        Assert-True ($controls.FileLabel.Foreground.Color.ToString() -eq '#FF86EFAC' -and $controls.ProgressPanel.Visibility -eq 'Collapsed') 'Switching themes after completion lost the outcome color or layout.'
        $controls.ActionButton.IsEnabled = $false
        Assert-True ($controls.ActionButton.Background.Color.ToString() -eq '#FF263141') 'The disabled primary button did not use the dark palette.'
        $controls.ActionButton.IsEnabled = $true
        Set-AV1WindowTheme -Window $window -Theme Light
        Assert-True ([Windows.Controls.Grid]::GetRow($controls.SummaryLabel.Parent) -lt [Windows.Controls.Grid]::GetRow($results)) 'Batch summary is not above the result cards.'

        $state.FileCount = 3
        $state.Summary.Processed = 2; $state.Summary.Skipped = 1
        $state.HasWarnings = $true
        Finish-Window
        Assert-True ($controls.SummaryLabel.Text -match '2 completed.*1 skipped.*0 failed.*saved') 'Batch completion lost its counts or total savings.'
        Assert-True ($controls.FileLabel.Foreground.Color -eq $window.Resources['WarningBrush'].Color) 'Encoding completion lost its WarningBrush heading color.'
        $state.Summary.Cancelled = $true; $state.CurrentFinished = $false
        Finish-Window
        Assert-True ($controls.FileLabel.Text -eq 'Encoding cancelled' -and $results.Items[$results.Items.Count - 1].Status -eq 'Cancelled') 'Cancellation lost its heading or unfinished-file result.'
        Assert-True ($controls.FileLabel.Foreground.Color -eq $window.Resources['MutedBrush'].Color) 'Encoding completion lost its MutedBrush heading color.'
        $state.Fatal = $true
        Finish-Window
        Assert-True ($controls.DetailsExpander.IsExpanded -and $controls.FileLabel.Text -eq 'Could not complete encoding') 'Fatal completion hid error details.'
        Assert-True ($controls.FileLabel.Foreground.Color -eq $window.Resources['ErrorBrush'].Color) 'Encoding completion lost its ErrorBrush heading color.'
        $results.Items.Clear()
        # Queued progress and inspection events must not replace a cancellation request.
        $state.Running = $true
        $controls.ActionButton.IsEnabled = $true
        Request-Cancellation
        Update-Window ([PSCustomObject]@{ Type = 'FileStarted'; Data = [PSCustomObject]@{ Path = 'next.mkv'; FileNumber = 2; FileCount = 3 } })
        Update-Window ([PSCustomObject]@{ Type = 'Progress'; Data = [PSCustomObject]@{ Progress = $progress } })
        Update-Window ([PSCustomObject]@{ Type = 'VerificationStarted'; Data = [PSCustomObject]@{} })
        Assert-True ($controls.BatchLabel.Text -eq ('File 2 of 3 {0} Small {0} Cancelling' -f [char]0xb7) -and
            -not $controls.ActionButton.IsEnabled) 'Queued events replaced the cancellation phase or enabled a second cancellation.'
    }
    finally { $cancellation.Dispose() }
    $iconStream = [IO.File]::OpenRead((Join-Path $repoRoot 'resources/SendToAV1.ico'))
    try {
        $icon = [Windows.Media.Imaging.BitmapFrame]::Create($iconStream,
            [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        Assert-True ($icon.PixelWidth -gt 0) 'The AV1 icon could not be decoded by WPF.'
        $window.Icon = $icon
    }
    finally { $iconStream.Dispose() }
    (New-Object Windows.Interop.WindowInteropHelper $window).EnsureHandle() | Out-Null
    Set-AV1WindowTheme -Window $window -Theme Dark
    Assert-True ($null -ne ('SendToAv1Theme.NativeMethods' -as [type])) 'The native title-bar theme helper did not compile.'
    $window.Close()
    $window = $null

    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    New-Item -ItemType Directory -Path $projectRoot | Out-Null
    foreach ($directory in @('src', 'resources')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $directory) -Destination $projectRoot -Recurse
    }
    # Also exercise the standalone builder's default output path. All generated
    # files stay in the temporary project, away from the installed launcher.
    & $shellPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'src/Build-Launcher.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Launcher build with the default output path failed.' }
    Assert-True (Test-Path -LiteralPath $launcherPath -PathType Leaf) 'Default launcher output is not relative to the project.'
    Remove-Item -LiteralPath $launcherPath
    $names = @('Send to AV1', 'Send to AV1 - NVIDIA', 'Send to AV1 - Small')
    foreach ($name in $names) { Set-Content -LiteralPath (Join-Path $tempRoot ($name + '.cmd')) -Value 'legacy launcher' }
    Set-Content -LiteralPath (Join-Path $tempRoot 'unrelated.txt') -Value 'keep this file'
    Invoke-Installer
    $reader = New-Object IO.BinaryReader ([IO.File]::OpenRead($launcherPath))
    try {
        $reader.BaseStream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $reader.BaseStream.Position = $peOffset + 24 + 68
        Assert-True ($reader.ReadUInt16() -eq 2) 'Launcher is a console executable rather than a Windows GUI executable.'
    }
    finally { $reader.Dispose() }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($name in $names) {
        $shortcutPath = Join-Path $tempRoot ($name + '.lnk')
        Assert-True (Test-Path -LiteralPath $shortcutPath) ('Missing shortcut: ' + $name)
        $shortcut = $shell.CreateShortcut($shortcutPath)
        try {
            Assert-True ($shortcut.TargetPath -eq $launcherPath) 'Shortcut does not target the windowless launcher.'
            Assert-True ($shortcut.IconLocation -eq ($launcherPath + ',0')) 'Shortcut does not use the AV1 application icon.'
            Assert-True ($shortcut.Arguments.Contains(('"{0}"' -f (Join-Path $projectRoot 'src/Show-AV1Progress.ps1')))) 'GUI path was not quoted correctly.'
            if ($name -like '*NVIDIA') { Assert-True ($shortcut.Arguments -match '--mode nvidia') 'NVIDIA shortcut lost its mode.' }
            elseif ($name -like '*Small') { Assert-True ($shortcut.Arguments -match '--mode small') 'Small shortcut lost its mode.' }
            else { Assert-True ($shortcut.Arguments -match '--mode cpu') 'CPU shortcut lost its mode.' }
        }
        finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot ($name + '.cmd')))) 'Upgrade left a duplicate legacy launcher.'
    }

    # Invoke the real GUI-subsystem executable with a recording script, checking
    # all modes, multi-file arguments, and the child's lack of a console window.
    $fixture = Join-Path $tempRoot 'record GUI arguments.ps1'
    @'
param(
    [Parameter(Position=0,ValueFromRemainingArguments=$true)][string[]]$InputPath,
    [string]$Encoder='svt', [switch]$Small
)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
$record = @{ Files=$InputPath; Encoder=$Encoder; Small=[bool]$Small; HasConsole=([ConsoleProbe]::GetConsoleWindow() -ne [IntPtr]::Zero) }
$temporary = $env:SEND_TO_AV1_LAUNCHER_TEST_RECORD + '.tmp'
[IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json))
[IO.File]::Move($temporary, $env:SEND_TO_AV1_LAUNCHER_TEST_RECORD)
'@ | Set-Content -LiteralPath $fixture -Encoding Ascii
    $files = @((Join-Path $tempRoot 'a & (test) [1].mkv'), (Join-Path $tempRoot ('caf' + [char]0xe9 + ' %PATH%.mkv')))
    foreach ($mode in @('cpu', 'small', 'nvidia')) {
        $env:SEND_TO_AV1_LAUNCHER_TEST_RECORD = Join-Path $tempRoot ($mode + '.json')
        $nativeArguments = '--gui "{0}" --mode {1} "{2}" "{3}"' -f $fixture, $mode, $files[0], $files[1]
        $launched = Start-Process -FilePath $launcherPath -ArgumentList $nativeArguments -PassThru
        try {
            if (-not $launched.WaitForExit(10000)) { throw 'The windowless launcher did not exit.' }
            Assert-True ($launched.ExitCode -eq 0) 'The windowless launcher failed.'
        }
        finally {
            if (-not $launched.HasExited) { $launched.Kill(); $launched.WaitForExit() }
            $launched.Dispose()
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath $env:SEND_TO_AV1_LAUNCHER_TEST_RECORD)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw ('Launcher did not start the recording script: ' + $mode) }
            Start-Sleep -Milliseconds 50
        }
        $record = Get-Content -Raw -LiteralPath $env:SEND_TO_AV1_LAUNCHER_TEST_RECORD | ConvertFrom-Json
        Assert-True (-not $record.HasConsole) 'The PowerShell child has a console window.'
        Assert-True ($record.Files.Count -eq 2 -and $record.Files[0] -ceq $files[0] -and $record.Files[1] -ceq $files[1]) 'Launcher changed selected file paths.'
        Assert-True ($record.Small -eq ($mode -eq 'small')) 'Small mode was forwarded incorrectly.'
        $expectedEncoder = 'svt'
        if ($mode -eq 'nvidia') { $expectedEncoder = 'nvenc' }
        Assert-True ($record.Encoder -eq $expectedEncoder) 'Encoder mode was forwarded incorrectly.'
    }
    Invoke-Installer
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*.lnk').Count -eq 3) 'Reinstall duplicated shortcuts.'
    foreach ($name in $names) { Set-Content -LiteralPath (Join-Path $tempRoot ($name + '.cmd')) -Value 'legacy launcher' }
    Invoke-Installer -Uninstall
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*.lnk').Count -eq 0) 'Uninstall left GUI shortcuts.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*.cmd').Count -eq 0) 'Uninstall left legacy launchers.'
    Assert-True (Test-Path -LiteralPath (Join-Path $tempRoot 'unrelated.txt')) 'Uninstall deleted an unrelated file.'
    Write-Host ('Windows integration checks passed: {0}.' -f $script:checks)
}
finally {
    $env:SEND_TO_AV1_LAUNCHER_TEST_RECORD = $originalRecord
    if ($null -ne $window) { $window.Close() }
    if ($null -ne $shell) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
