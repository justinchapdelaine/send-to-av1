<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Install or remove Send to entries in a themed Windows setup window.
#>
[CmdletBinding()]
param([switch]$Uninstall)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$window = $null
$timer = $null
$themeTimer = $null
$state = @{ Worker = $null; Running = $false; Finished = $false; Result = $null }

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Send to AV1 setup requires Windows.' }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start setup with PowerShell -STA.' }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $PSScriptRoot 'AV1.Setup.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'AV1.Theme.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'AV1.Xaml.psm1') -Force

    [xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Send to AV1 setup" Width="600" MinWidth="480" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource WindowBrush}" Foreground="{DynamicResource TextBrush}"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
    <Window.Resources/>
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="24">
            <TextBlock Name="Heading" Text="Install Send to AV1" Style="{StaticResource HeadingText}"/>
            <TextBlock Name="Description" Margin="0,8,0,0" TextWrapping="Wrap"
                       Text="Add CPU, NVIDIA, and Small encoding to your Send to menu. No administrator rights are needed."/>
            <TextBlock Name="CompactLocation" Visibility="Collapsed" Margin="0,8,0,0" Style="{StaticResource SecondaryText}"/>
            <Border Name="LocationCard" Margin="0,24,0,0" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="16">
                <StackPanel>
                    <TextBlock Text="PROJECT FOLDER" Style="{StaticResource CaptionText}"/>
                    <TextBlock Name="Location" Margin="0,8,0,0" TextWrapping="Wrap"/>
                    <TextBlock Name="LocationHint" Margin="0,8,0,0" Style="{StaticResource SecondaryText}"
                               Text="Keep this folder here. The Send to entries will use its scripts and tools."/>
                </StackPanel>
            </Border>
            <StackPanel Name="DownloadOptions" Margin="0,16,0,0">
                <CheckBox Name="DownloadTools" IsChecked="True" Style="{StaticResource ThemedCheckBox}">
                    <TextBlock Text="Download or update portable FFmpeg" TextWrapping="Wrap"/>
                </CheckBox>
                <TextBlock Margin="32,8,0,0" Style="{StaticResource SecondaryText}"
                           Text="Uses BtbN's GPL Windows builds and checks for updates. Clear this option if you provide your own FFmpeg and FFprobe."/>
            </StackPanel>
            <StackPanel Name="ProgressPanel" Visibility="Collapsed" Margin="0,24,0,0">
                <TextBlock Name="Phase" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource AccentBrush}" TextWrapping="Wrap"/>
                <ProgressBar Name="Progress" Margin="0,8,0,0" IsIndeterminate="True" Style="{StaticResource SharedProgressBar}"/>
            </StackPanel>
            <Expander Name="DetailsExpander" Header="Details" Style="{StaticResource DetailsExpander}" Visibility="Collapsed" Margin="0,16,0,0">
                <TextBox Name="Details" Style="{StaticResource DetailsLog}" Margin="0,8,0,0"/>
            </Expander>
            <TextBlock Name="Notice" Visibility="Collapsed" Margin="0,16,0,0" Style="{StaticResource SecondaryText}"/>
            <DockPanel Name="ActionsPanel" Margin="0,24,0,0" LastChildFill="False">
                <Button Name="ActionButton" DockPanel.Dock="Right" Content="Install" Style="{StaticResource PrimaryButton}"/>
                <Button Name="CloseButton" DockPanel.Dock="Right" Content="Cancel" Margin="0,0,8,0" Style="{StaticResource SecondaryButton}"/>
            </DockPanel>
        </StackPanel>
    </ScrollViewer>
</Window>
'@
    Add-AV1WindowResources -Layout $layout
    $reader = [Xml.XmlNodeReader]::new($layout)
    try { $window = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
    $window.MaxHeight = [Math]::Max(300, [Windows.SystemParameters]::WorkArea.Height - 32)
    $controls = @{}
    foreach ($name in @('Heading', 'Description', 'Location', 'LocationHint', 'LocationCard', 'CompactLocation', 'DownloadOptions', 'DownloadTools',
            'ProgressPanel', 'Phase', 'Progress', 'Notice', 'DetailsExpander', 'Details', 'ActionsPanel', 'ActionButton', 'CloseButton')) {
        $controls[$name] = $window.FindName($name)
    }
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $controls.Location.Text = $projectRoot
    $controls.CompactLocation.Text = $projectRoot
    $iconPath = Join-Path $projectRoot 'resources/SendToAV1.ico'
    if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
        $iconStream = [IO.File]::OpenRead($iconPath)
        try {
            $icon = [Windows.Media.Imaging.BitmapFrame]::Create($iconStream,
                [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $icon.Freeze()
            $window.Icon = $icon
        }
        finally { $iconStream.Dispose() }
    }
    $operation = 'Install'
    if ($Uninstall) {
        $operation = 'Uninstall'
        $window.Title = 'Uninstall Send to AV1'
        $controls.Heading.Text = 'Uninstall Send to AV1?'
        $controls.Description.Text = 'Remove the CPU, NVIDIA, and Small entries from your Send to menu? Your videos, portable tools, and project files will be kept.'
        $controls.LocationHint.Text = 'Only the Send to entries for your Windows account will be removed.'
        $controls.DownloadOptions.Visibility = 'Collapsed'
        $controls.ActionButton.Content = 'Uninstall'
    }

    function Add-SetupDetail {
        param([string]$Message)
        if ([string]::IsNullOrWhiteSpace($Message)) { return }
        $controls.DetailsExpander.Visibility = 'Visible'
        $controls.Details.AppendText($Message + [Environment]::NewLine)
        if ($controls.Details.Text.Length -gt 40000) { $controls.Details.Text = $controls.Details.Text.Substring($controls.Details.Text.Length - 30000) }
        $controls.Details.ScrollToEnd()
    }
    function Update-SetupWindow {
        param($Update)
        switch ($Update.Type) {
            'Detail' { Add-SetupDetail $Update.Message }
            'Phase' { $controls.Phase.Text = $Update.Message }
            'Result' { $state.Result = $Update.Data }
        }
    }
    function Finish-SetupWindow {
        $state.Running = $false
        $state.Finished = $false
        $controls.Progress.IsIndeterminate = $false
        $controls.ProgressPanel.Visibility = 'Collapsed'
        $controls.DownloadTools.IsEnabled = $true
        $controls.ActionButton.IsEnabled = $true
        $controls.CloseButton.IsEnabled = $true
        $controls.ActionsPanel.Visibility = 'Visible'
        $controls.CloseButton.Visibility = 'Visible'
        $controls.Description.Visibility = 'Visible'
        $controls.Notice.Visibility = 'Collapsed'
        if ($null -eq $state.Result) {
            $state.Result = [PSCustomObject]@{ Status = 'Failed'; Message = 'Setup ended without a result. Please try again.' }
        }
        $controls.Description.Text = $state.Result.Message
        $color = 'SuccessBrush'
        switch ($state.Result.Status) {
            'Completed' {
                $state.Finished = $true
                $controls.Heading.Text = 'Installation complete'
                if ($Uninstall) { $controls.Heading.Text = 'Uninstall complete' }
                $controls.DownloadOptions.Visibility = 'Collapsed'
                $controls.LocationCard.Visibility = 'Collapsed'
                $controls.CompactLocation.Visibility = 'Collapsed'
                $controls.ActionButton.Content = 'Close'
                $controls.CloseButton.Visibility = 'Collapsed'
            }
            'Warning' {
                $controls.Heading.Text = 'Installed with a warning'
                $color = 'WarningBrush'
            }
            default {
                $controls.Heading.Text = 'Setup could not complete'
                $color = 'ErrorBrush'
            }
        }
        $controls.Heading.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $color)
        if (-not $state.Finished) {
            $controls.DownloadOptions.Visibility = 'Collapsed'
            if (-not $Uninstall) { $controls.DownloadOptions.Visibility = 'Visible' }
            Add-SetupDetail $state.Result.Message
            $controls.DetailsExpander.IsExpanded = $true
            $controls.ActionButton.Content = 'Try again'
            $controls.CloseButton.Content = 'Close'
        }
    }
    function Start-Setup {
        if ($state.Running) { return }
        $state.Running = $true
        $state.Finished = $false
        $state.Result = $null
        $controls.ActionButton.IsEnabled = $false
        $controls.CloseButton.IsEnabled = $false
        $controls.DownloadTools.IsEnabled = $false
        $controls.ActionsPanel.Visibility = 'Collapsed'
        $controls.DownloadOptions.Visibility = 'Collapsed'
        $controls.LocationCard.Visibility = 'Collapsed'
        $controls.CompactLocation.Visibility = 'Visible'
        $controls.Heading.Text = 'Installing Send to AV1'
        if ($Uninstall) { $controls.Heading.Text = 'Removing Send to entries' }
        $controls.Heading.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
        $controls.Description.Visibility = 'Collapsed'
        $controls.Notice.Text = 'Please wait while setup finishes.'
        $controls.Notice.Visibility = 'Visible'
        $controls.Details.Clear()
        $controls.DetailsExpander.IsExpanded = $false
        $controls.DetailsExpander.Visibility = 'Visible'
        $controls.ProgressPanel.Visibility = 'Visible'
        $controls.Progress.IsIndeterminate = $true
        $controls.Phase.Text = 'Starting setup...'
        try {
            $state.Worker = Start-AV1SetupWorker -Options @{
                Operation = $operation; DownloadTools = [bool]$controls.DownloadTools.IsChecked; ProjectRoot = $projectRoot
            }
            $timer.Start()
        }
        catch {
            $state.Result = [PSCustomObject]@{ Status = 'Failed'; Message = $_.Exception.Message }
            Finish-SetupWindow
        }
    }
    $themeState = @{ Name = '' }
    function Update-SetupTheme {
        param([switch]$Force)
        $name = Get-AV1WindowsTheme
        if (-not $Force -and $name -eq $themeState.Name -and $name -ne 'HighContrast') { return }
        Set-AV1WindowTheme -Window $window -Theme $name
        $themeState.Name = $name
    }
    Update-SetupTheme
    $window.Add_SourceInitialized({ Update-SetupTheme -Force })
    $themeTimer = [Windows.Threading.DispatcherTimer]::new()
    $themeTimer.Interval = [TimeSpan]::FromSeconds(2)
    $themeTimer.Add_Tick({
        try { Update-SetupTheme }
        catch { $themeTimer.Stop(); Add-SetupDetail $_.Exception.Message }
    })
    $themeTimer.Start()
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        try {
            $update = $null
            while ($state.Worker.Updates.TryDequeue([ref]$update)) { Update-SetupWindow $update }
            if ($state.Worker.Handle.IsCompleted) {
                while ($state.Worker.Updates.TryDequeue([ref]$update)) { Update-SetupWindow $update }
                $timer.Stop()
                try { Complete-AV1SetupWorker $state.Worker }
                catch { $state.Result = [PSCustomObject]@{ Status = 'Failed'; Message = $_.Exception.Message } }
                $state.Worker = $null
                Finish-SetupWindow
            }
        }
        catch { Add-SetupDetail ('Setup display error: ' + $_.Exception.Message) }
    })
    $controls.ActionButton.Add_Click({
        if ($state.Finished) { $window.Close() }
        else { Start-Setup }
    })
    $controls.CloseButton.Add_Click({ $window.Close() })
    $window.Add_Closing({
        param($sender, $eventArgs)
        if ($state.Running) {
            # Do not interrupt executable replacement or leave half-written shortcuts.
            $eventArgs.Cancel = $true
            $controls.Notice.Text = 'Setup is still running. This window can be closed when it finishes.'
            $controls.Notice.Visibility = 'Visible'
        }
    })
    $window.ShowDialog() | Out-Null
}
catch {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Send to AV1 setup', 'OK', 'Error') | Out-Null
    }
    else { Write-Error $_.Exception.Message }
    exit 1
}
finally {
    if ($null -ne $timer) { $timer.Stop() }
    if ($null -ne $themeTimer) { $themeTimer.Stop() }
    if ($null -ne $state.Worker) { Complete-AV1SetupWorker $state.Worker }
}
