<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Show Windows encoding progress for files selected through the Send to menu.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputPath,
    [ValidateSet('svt', 'nvenc')]
    [string]$Encoder = 'svt',
    [switch]$Small,
    [switch]$KeepLog
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$window = $null
$timer = $null
$state = @{ Worker = $null }

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The progress window requires Windows. Use Optimize-AV1.ps1 for console encoding.'
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'The progress window requires STA mode. Start PowerShell with -STA, or reinstall the Send to entries.'
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $PSScriptRoot 'AV1.Worker.psm1') -Force -ErrorAction Stop

    [xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Send to AV1" Width="640" MinWidth="500" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" Background="#F5F6F8" FontFamily="Segoe UI" FontSize="13">
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0" Margin="0,0,0,16">
            <TextBlock Name="ModeLabel" DockPanel.Dock="Right" Foreground="#536174" VerticalAlignment="Center"/>
            <TextBlock Text="Send to AV1" FontSize="24" FontWeight="SemiBold"/>
        </DockPanel>
        <TextBlock Name="StatusLabel" Grid.Row="1" Text="Preparing..." FontSize="16" FontWeight="SemiBold"/>
        <TextBlock Name="FileLabel" Grid.Row="2" Margin="0,6,0,12" TextTrimming="CharacterEllipsis"/>
        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <ProgressBar Name="Progress" Height="14" Minimum="0" Maximum="100" IsIndeterminate="True"/>
            <TextBlock Name="PercentLabel" Grid.Column="1" Width="50" TextAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <TextBlock Name="TimeLabel" Grid.Row="4" Margin="0,10,0,0" Foreground="#536174" TextWrapping="Wrap"/>
        <ListBox Name="Results" Grid.Row="5" BorderThickness="1" BorderBrush="#D4D9E0" MaxHeight="180" Margin="0,12,0,0"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListBox.Style>
                <Style TargetType="ListBox">
                    <Style.Triggers>
                        <Trigger Property="HasItems" Value="False">
                            <Setter Property="Visibility" Value="Collapsed"/>
                        </Trigger>
                    </Style.Triggers>
                </Style>
            </ListBox.Style>
            <ListBox.ItemTemplate>
                <DataTemplate><TextBlock Text="{Binding}" Margin="6" TextWrapping="Wrap"/></DataTemplate>
            </ListBox.ItemTemplate>
        </ListBox>
        <Expander Header="Details" Grid.Row="6" Margin="0,12,0,0">
            <TextBox Name="Details" IsReadOnly="True" TextWrapping="Wrap" Height="110"
                     VerticalScrollBarVisibility="Auto"/>
        </Expander>
        <DockPanel Grid.Row="7" Margin="0,16,0,0">
            <Button Name="ActionButton" DockPanel.Dock="Right" Content="Cancel" MinWidth="90" Padding="12,6"/>
            <Button Name="FolderButton" DockPanel.Dock="Right" Content="Open output folder" Margin="0,0,10,0"
                    Padding="12,6" IsEnabled="False"/>
            <TextBlock Name="SummaryLabel" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0"/>
        </DockPanel>
    </Grid>
    </ScrollViewer>
</Window>
'@
    $reader = New-Object Xml.XmlNodeReader $layout
    try { $window = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
    $window.MaxHeight = [Math]::Max(300, [Windows.SystemParameters]::WorkArea.Height - 32)
    $controls = @{}
    foreach ($name in @('ModeLabel', 'StatusLabel', 'FileLabel', 'Progress', 'PercentLabel',
            'TimeLabel', 'Results', 'Details', 'ActionButton', 'FolderButton', 'SummaryLabel')) {
        $controls[$name] = $window.FindName($name)
    }
    $mode = 'CPU'
    if ($Small) { $mode = 'Small' }
    elseif ($Encoder -eq 'nvenc') { $mode = 'NVIDIA' }
    $controls.ModeLabel.Text = $mode
    $state = @{ Worker = $null; Running = $true; Started = $false; Summary = $null; Fatal = $false
        HasWarnings = $false; OutputPath = $null; CurrentPath = $null; CurrentFinished = $true }

    function Add-Detail {
        param([string]$Message)
        if ([string]::IsNullOrWhiteSpace($Message)) { return }
        # Bound the display for large batches; -KeepLog retains full encoder diagnostics.
        $controls.Details.AppendText($Message + [Environment]::NewLine)
        if ($controls.Details.Text.Length -gt 40000) {
            $controls.Details.Text = $controls.Details.Text.Substring($controls.Details.Text.Length - 30000)
        }
        $controls.Details.ScrollToEnd()
    }

    function Request-Cancellation {
        if ($state.Running -and $null -ne $state.Worker -and -not $state.Worker.Cancellation.IsCancellationRequested) {
            $state.Worker.Cancellation.Cancel()
            $controls.ActionButton.IsEnabled = $false
            $controls.StatusLabel.Text = 'Cancelling...'
            $controls.TimeLabel.Text = 'Stopping the encoder and cleaning up incomplete output.'
        }
    }

    function Update-Window {
        param($Update)
        $data = $Update.Data
        switch ($Update.Type) {
            'Message' {
                Add-Detail $data.Message
                if ($data.Color -eq 'Yellow') { $state.HasWarnings = $true }
            }
            'FileStarted' {
                $state.CurrentPath = $data.Path
                $state.CurrentFinished = $false
                if (-not $state.Worker.Cancellation.IsCancellationRequested) {
                    $controls.StatusLabel.Text = 'File {0} of {1}' -f $data.FileNumber, $data.FileCount
                    $controls.TimeLabel.Text = 'Inspecting video...'
                }
                $controls.FileLabel.Text = [IO.Path]::GetFileName($data.Path)
                $controls.FileLabel.ToolTip = $data.Path
                $controls.Progress.IsIndeterminate = $true
                $controls.Progress.Value = 0
                $controls.PercentLabel.Text = ''
            }
            'Progress' {
                if ($state.Worker.Cancellation.IsCancellationRequested) { return }
                $progress = $data.Progress
                $controls.Progress.IsIndeterminate = $progress.Percent -lt 0
                if ($progress.Percent -ge 0) {
                    $controls.Progress.Value = $progress.Percent
                    $controls.PercentLabel.Text = '{0}%' -f $progress.Percent
                }
                $controls.TimeLabel.Text = $progress.Status
            }
            'FileResult' {
                $state.CurrentFinished = $true
                $entry = '{0}: {1} - {2}' -f $data.Status, [IO.Path]::GetFileName($data.Path), $data.Message
                if ($data.Status -eq 'Completed') { $entry += [Environment]::NewLine + $data.OutputPath }
                $controls.Results.Items.Add($entry) | Out-Null
                $controls.Results.ScrollIntoView($entry)
                $controls.Progress.IsIndeterminate = $false
                if ($data.Status -eq 'Completed') {
                    $state.OutputPath = $data.OutputPath
                    $controls.FolderButton.IsEnabled = $true
                    $controls.FolderButton.ToolTip = 'Open the folder containing the most recently completed output.'
                    $controls.Progress.Value = 100
                    $controls.PercentLabel.Text = '100%'
                }
            }
            'Summary' { $state.Summary = $data.Summary }
            'Fatal' { $state.Fatal = $true; Add-Detail $data.Message }
        }
    }

    function Finish-Window {
        $state.Running = $false
        $controls.Progress.IsIndeterminate = $false
        $controls.ActionButton.Content = 'Close'
        $controls.ActionButton.IsEnabled = $true
        $summary = $state.Summary
        if ($state.Fatal -or $null -eq $summary) {
            $controls.StatusLabel.Text = 'Could not complete encoding'
            $controls.TimeLabel.Text = 'See Details for the error.'
        }
        else {
            if ($summary.Cancelled) {
                $controls.StatusLabel.Text = 'Cancelled'
                if (-not $state.CurrentFinished) {
                    $controls.Results.Items.Add(('Cancelled: {0}' -f [IO.Path]::GetFileName($state.CurrentPath))) | Out-Null
                }
            }
            elseif ($summary.Failed -gt 0) { $controls.StatusLabel.Text = 'Finished with errors' }
            elseif ($state.HasWarnings) { $controls.StatusLabel.Text = 'Finished with warnings' }
            else { $controls.StatusLabel.Text = 'Finished' }
            $controls.SummaryLabel.Text = '{0} completed | {1} skipped | {2} failed' -f $summary.Processed, $summary.Skipped, $summary.Failed
            if ($summary.Processed -gt 0) {
                if ($summary.SavedBytes -ge 0) { $controls.TimeLabel.Text = '{0} saved across completed files.' -f $summary.SavedText }
                else { $controls.TimeLabel.Text = 'Completed outputs are larger overall. See individual results.' }
            }
            else { $controls.TimeLabel.Text = 'No completed output files.' }
            if ($summary.Failed -gt 0 -or $state.HasWarnings) {
                $controls.TimeLabel.Text += ' See Details for errors or warnings.'
            }
        }
    }

    $controls.ActionButton.Add_Click({
        if ($state.Running) { Request-Cancellation }
        else { $window.Close() }
    })
    $controls.FolderButton.Add_Click({
        if ($null -ne $state.OutputPath) {
            try {
                $folder = Split-Path -Parent $state.OutputPath
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder) -ErrorAction Stop | Out-Null
            }
            catch { Add-Detail ('Could not open output folder: {0}' -f $_.Exception.Message) }
        }
    })
    $window.Add_Closing({
        param($sender, $eventArgs)
        if ($state.Running) {
            $eventArgs.Cancel = $true
            $answer = [Windows.MessageBox]::Show($window, 'Cancel the remaining encodes? Completed files will be kept.',
                'Send to AV1', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
            if ($answer -eq [Windows.MessageBoxResult]::Yes) { Request-Cancellation }
        }
    })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        try {
            $update = $null
            while ($state.Worker.Updates.TryDequeue([ref]$update)) { Update-Window $update }
            if ($state.Worker.Handle.IsCompleted) {
                # Drain again after completion so the final summary cannot be missed.
                while ($state.Worker.Updates.TryDequeue([ref]$update)) { Update-Window $update }
                $timer.Stop()
                try { Complete-AV1Worker $state.Worker }
                catch { $state.Fatal = $true; Add-Detail $_.Exception.Message }
                $state.Worker = $null
                Finish-Window
            }
        }
        catch {
            Add-Detail ('Progress display error: {0}' -f $_.Exception.Message)
            $state.Fatal = $true
            Request-Cancellation
        }
    })
    $window.Add_ContentRendered({
        if ($state.Started) { return }
        $state.Started = $true
        try {
            $options = @{ InputPath = $InputPath; Encoder = $Encoder; Small = [bool]$Small; KeepLog = [bool]$KeepLog }
            $state.Worker = Start-AV1Worker -Options $options
            $timer.Start()
        }
        catch {
            $state.Fatal = $true
            Add-Detail $_.Exception.Message
            Finish-Window
        }
    })
    $window.ShowDialog() | Out-Null
}
catch {
    # This also surfaces initialization failures when the PowerShell console is hidden.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Send to AV1', 'OK', 'Error') | Out-Null
    }
    else { Write-Error $_.Exception.Message }
    exit 1
}
finally {
    if ($null -ne $timer) { $timer.Stop() }
    if ($null -ne $state.Worker) {
        $state.Worker.Cancellation.Cancel()
        Complete-AV1Worker $state.Worker
    }
}
