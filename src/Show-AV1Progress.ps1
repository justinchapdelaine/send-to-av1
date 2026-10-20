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
$themeTimer = $null
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
    Import-Module (Join-Path $PSScriptRoot 'AV1.ViewModel.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'AV1.Theme.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'AV1.Xaml.psm1') -Force -ErrorAction Stop

    [xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Send to AV1" Width="660" MinWidth="520" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource WindowBrush}" Foreground="{DynamicResource TextBrush}"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="Metric" TargetType="TextBlock">
            <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Margin" Value="0,8,8,0"/><Setter Property="TextWrapping" Value="Wrap"/>
        </Style>
        <Style x:Key="OptionalText" TargetType="TextBlock">
            <Style.Triggers>
                <Trigger Property="Text" Value=""><Setter Property="Visibility" Value="Collapsed"/></Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="ResultColor" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding Color}" Value="#15803D"><Setter Property="Foreground" Value="{DynamicResource SuccessBrush}"/></DataTrigger>
                <DataTrigger Binding="{Binding Color}" Value="#B45309"><Setter Property="Foreground" Value="{DynamicResource WarningBrush}"/></DataTrigger>
                <DataTrigger Binding="{Binding Color}" Value="#B91C1C"><Setter Property="Foreground" Value="{DynamicResource ErrorBrush}"/></DataTrigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="ResultIcon" TargetType="Path">
            <Setter Property="Width" Value="16"/><Setter Property="Height" Value="16"/>
            <Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Stretch" Value="None"/>
            <Setter Property="Stroke" Value="{DynamicResource MutedBrush}"/><Setter Property="StrokeThickness" Value="1.7"/>
            <Setter Property="StrokeStartLineCap" Value="Round"/><Setter Property="StrokeEndLineCap" Value="Round"/>
            <Setter Property="StrokeLineJoin" Value="Round"/>
            <Setter Property="IsHitTestVisible" Value="False"/>
            <Setter Property="Data" Value="M 2,8 L 14,8 M 10,4 L 14,8 L 10,12"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding Glyph}" Value="&#x2713;"><Setter Property="Data" Value="M 2,8 L 6,12 L 14,4"/></DataTrigger>
                <DataTrigger Binding="{Binding Glyph}" Value="!"><Setter Property="Data" Value="M 8,3 L 8,9 M 8,12 L 8,13"/></DataTrigger>
                <DataTrigger Binding="{Binding Glyph}" Value="&#x2715;"><Setter Property="Data" Value="M 4,4 L 12,12 M 12,4 L 4,12"/></DataTrigger>
                <DataTrigger Binding="{Binding Glyph}" Value="&#x2014;"><Setter Property="Data" Value="M 2,8 L 14,8"/></DataTrigger>
                <DataTrigger Binding="{Binding Color}" Value="#15803D"><Setter Property="Stroke" Value="{DynamicResource SuccessBrush}"/></DataTrigger>
                <DataTrigger Binding="{Binding Color}" Value="#B45309"><Setter Property="Stroke" Value="{DynamicResource WarningBrush}"/></DataTrigger>
                <DataTrigger Binding="{Binding Color}" Value="#B91C1C"><Setter Property="Stroke" Value="{DynamicResource ErrorBrush}"/></DataTrigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Name="FileLabel" Text="Preparing your videos..." Style="{StaticResource HeadingText}" TextWrapping="NoWrap"
                       TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,16,0"/>
            <TextBlock Name="PercentLabel" Grid.Column="1" MinWidth="64" Text="..." FontSize="22" FontWeight="SemiBold"
                       Foreground="{DynamicResource AccentBrush}" TextAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <TextBlock Name="BatchLabel" Grid.Row="1" Margin="0,8,0,0" Style="{StaticResource SecondaryText}"/>
        <Grid Name="ProgressPanel" Grid.Row="2" Margin="0,16,0,16">
            <ProgressBar Name="Progress" Minimum="0" Maximum="100" IsIndeterminate="True"
                         Style="{StaticResource SharedProgressBar}"/>
        </Grid>
        <Border Name="TimingPanel" Grid.Row="3" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="16">
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="1.2*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="1.3*"/></Grid.ColumnDefinitions>
                <StackPanel>
                    <TextBlock Text="TIME REMAINING" Style="{StaticResource CaptionText}"/>
                    <TextBlock Name="RemainingValue" Text="Calculating..." Style="{StaticResource Metric}" Foreground="{DynamicResource AccentBrush}"/>
                </StackPanel>
                <StackPanel Grid.Column="1">
                    <TextBlock Text="ELAPSED" Style="{StaticResource CaptionText}"/>
                    <TextBlock Name="ElapsedValue" Text="00:00:00" Style="{StaticResource Metric}"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                    <TextBlock Text="VIDEO PROCESSED" Style="{StaticResource CaptionText}"/>
                    <TextBlock Name="ProcessedValue" Text="&#x2014;" Style="{StaticResource Metric}" FontSize="12"/>
                </StackPanel>
            </Grid>
        </Border>
        <StackPanel Grid.Row="4">
            <TextBlock Name="SummaryLabel" Style="{StaticResource OptionalText}" Margin="0,16,0,0"
                       Foreground="{DynamicResource TextBrush}" FontSize="12" TextWrapping="Wrap"/>
            <TextBlock Name="TimeLabel" Style="{StaticResource OptionalText}" Margin="0,8,0,0"
                       Foreground="{DynamicResource MutedBrush}" FontSize="12" TextWrapping="Wrap"/>
        </StackPanel>
        <ItemsControl Foreground="{DynamicResource TextBrush}" Name="Results" Grid.Row="5" BorderThickness="0" Background="Transparent" MaxHeight="220" Margin="0,16,0,0">
            <ItemsControl.Style>
                <Style TargetType="ItemsControl"><Style.Triggers>
                    <Trigger Property="HasItems" Value="False"><Setter Property="Visibility" Value="Collapsed"/></Trigger>
                </Style.Triggers></Style>
            </ItemsControl.Style>
            <ItemsControl.Template>
                <ControlTemplate TargetType="ItemsControl">
                    <ScrollViewer Name="ResultsScroll" Focusable="True" IsTabStop="True"
                                  VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <ItemsPresenter/>
                    </ScrollViewer>
                </ControlTemplate>
            </ItemsControl.Template>
            <ItemsControl.ItemTemplate>
                <DataTemplate>
                    <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="16" Margin="0,0,0,8">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="24"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <!-- Keep the icon centered on the filename row, independent of wrapped details below. -->
                            <Path Name="ResultIcon" Style="{StaticResource ResultIcon}"/>
                            <DockPanel Grid.Column="1" VerticalAlignment="Center">
                                <TextBlock Text="{Binding Status}" DockPanel.Dock="Right" FontSize="11" Margin="16,0,0,0" VerticalAlignment="Center">
                                    <TextBlock.Style>
                                        <Style TargetType="TextBlock" BasedOn="{StaticResource ResultColor}"><Style.Triggers>
                                            <DataTrigger Binding="{Binding ShowStatus}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
                                        </Style.Triggers></Style>
                                    </TextBlock.Style>
                                </TextBlock>
                                <TextBlock Text="{Binding Name}" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                            </DockPanel>
                            <TextBlock Grid.Column="1" Grid.Row="1" Text="{Binding Description}" Foreground="{DynamicResource TextBrush}" Margin="0,4,0,0" TextWrapping="Wrap"/>
                            <TextBlock Grid.Column="1" Grid.Row="2" Text="{Binding PathText}" ToolTip="{Binding PathText}" Style="{StaticResource SecondaryText}"
                                       Margin="0,4,0,0" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
                        </Grid>
                    </Border>
                </DataTemplate>
            </ItemsControl.ItemTemplate>
        </ItemsControl>
        <Expander Name="DetailsExpander" Header="Details" Style="{StaticResource DetailsExpander}" Grid.Row="6" Margin="0,16,0,0">
            <TextBox Name="Details" Style="{StaticResource DetailsLog}" Margin="0,8,0,0"/>
        </Expander>
        <DockPanel Grid.Row="7" Margin="0,24,0,0" LastChildFill="False">
            <Button Name="ActionButton" DockPanel.Dock="Right" Content="Cancel" Style="{StaticResource CancelButton}"/>
            <Button Name="FolderButton" DockPanel.Dock="Right" Content="Open output folder" Margin="0,0,8,0" Style="{StaticResource SecondaryButton}" IsEnabled="False"/>
        </DockPanel>
    </Grid>
    </ScrollViewer>
</Window>
'@
    Add-AV1WindowResources -Layout $layout
    $reader = New-Object Xml.XmlNodeReader $layout
    try { $window = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
    $window.MaxHeight = [Math]::Max(300, [Windows.SystemParameters]::WorkArea.Height - 32)
    $controls = @{}
    foreach ($name in @('FileLabel', 'Progress', 'PercentLabel',
            'TimeLabel', 'Results', 'Details', 'ActionButton', 'FolderButton', 'SummaryLabel',
            'BatchLabel', 'RemainingValue', 'ElapsedValue', 'ProcessedValue', 'DetailsExpander',
            'ProgressPanel', 'TimingPanel')) {
        $controls[$name] = $window.FindName($name)
    }
    $iconPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'resources/SendToAV1.ico'
    if (Test-Path -LiteralPath $iconPath) {
        $iconStream = [IO.File]::OpenRead($iconPath)
        try {
            $icon = [Windows.Media.Imaging.BitmapFrame]::Create($iconStream,
                [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $icon.Freeze()
            $window.Icon = $icon
        }
        finally { $iconStream.Dispose() }
    }
    $mode = 'CPU'
    if ($Small) { $mode = 'Small' }
    elseif ($Encoder -eq 'nvenc') { $mode = 'NVIDIA' }
    $state = @{ Worker = $null; Running = $true; Started = $false; Summary = $null; Fatal = $false
        HasWarnings = $false; OutputPath = $null; CurrentPath = $null; CurrentFinished = $true; LastProgress = $null
        FileCount = 0; Mode = $mode; BatchPosition = 'Selected videos'; Clock = (New-Object Diagnostics.Stopwatch) }
    if ($null -ne $InputPath) { $state.FileCount = $InputPath.Count }

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

    function Set-Phase {
        param([string]$Text, [string]$Color = '#2563EB')
        $controls.BatchLabel.Text = '{0} {3} {1} {3} {2}' -f $state.BatchPosition, $state.Mode, $Text, [char]0xb7
        $key = Get-AV1StatusBrushKey $Color
        foreach ($name in @('Progress', 'PercentLabel', 'RemainingValue')) {
            $controls[$name].SetResourceReference([Windows.Controls.Control]::ForegroundProperty, $key)
        }
    }
    Set-Phase 'Preparing'

    function Add-Result {
        param($Data)
        $view = Get-AV1ResultView $Data
        $controls.Results.Items.Add($view) | Out-Null
        # Update the scroll extent before revealing the newest informational card.
        $controls.Results.UpdateLayout()
        $resultsScroll = $controls.Results.Template.FindName('ResultsScroll', $controls.Results)
        if ($null -ne $resultsScroll) { $resultsScroll.ScrollToEnd() }
        if ($null -ne $state.LastProgress) {
            Add-Detail ('Last progress: ' + $state.LastProgress.Status)
            $state.LastProgress = $null
        }
    }

    function Request-Cancellation {
        if ($state.Running -and $null -ne $state.Worker -and -not $state.Worker.Cancellation.IsCancellationRequested) {
            $state.Worker.Cancellation.Cancel()
            $controls.ActionButton.IsEnabled = $false
            Set-Phase 'Cancelling' '#64748B'
            $controls.RemainingValue.Text = 'Stopping...'
            $controls.RemainingValue.ToolTip = $null
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
                if ($data.Color -eq 'Red') { $controls.DetailsExpander.IsExpanded = $true }
            }
            'FileStarted' {
                $state.CurrentPath = $data.Path
                $state.CurrentFinished = $false
                $state.FileCount = $data.FileCount
                $state.LastProgress = $null
                $state.BatchPosition = 'File {0} of {1}' -f $data.FileNumber, $data.FileCount
                if (-not $state.Worker.Cancellation.IsCancellationRequested) {
                    Set-Phase 'Inspecting video'
                    $controls.TimeLabel.Text = ''
                    $controls.RemainingValue.Text = 'Calculating...'
                }
                else { Set-Phase 'Cancelling' '#64748B' }
                $controls.FileLabel.Text = [IO.Path]::GetFileName($data.Path)
                $controls.FileLabel.ToolTip = $data.Path
                $controls.Progress.IsIndeterminate = $true
                $controls.Progress.Value = 0
                $controls.PercentLabel.Text = '...'
                $controls.ElapsedValue.Text = '00:00:00'
                $controls.ProcessedValue.Text = [string][char]0x2014
                $controls.RemainingValue.ToolTip = $null
            }
            'Progress' {
                if ($state.Worker.Cancellation.IsCancellationRequested) { return }
                $progress = $data.Progress
                $state.LastProgress = $progress
                $view = Get-AV1ProgressView $progress
                $controls.Progress.IsIndeterminate = $progress.Percent -lt 0
                if ($progress.Percent -ge 0) {
                    $controls.Progress.Value = $progress.Percent
                    $controls.PercentLabel.Text = '{0}%' -f $progress.Percent
                }
                $controls.RemainingValue.Text = $view.Remaining
                $controls.RemainingValue.ToolTip = $view.RemainingDetail
                $controls.ElapsedValue.Text = $view.Elapsed
                $controls.ProcessedValue.Text = $view.Processed
                if ($progress.Finalizing) { Set-Phase 'Finalizing output' }
                else { Set-Phase 'Encoding' }
            }
            'VerificationStarted' {
                if ($state.Worker.Cancellation.IsCancellationRequested) { return }
                Set-Phase 'Verifying output'
                $controls.Progress.IsIndeterminate = $true
                $controls.PercentLabel.Text = '...'
                $controls.RemainingValue.Text = 'Checking output...'
                $controls.RemainingValue.ToolTip = $null
            }
            'FileResult' {
                $state.CurrentFinished = $true
                Add-Result $data
                $controls.Progress.IsIndeterminate = $false
                if ($data.Status -eq 'Completed') {
                    $state.OutputPath = $data.OutputPath
                    $controls.FolderButton.IsEnabled = $true
                    $controls.FolderButton.ToolTip = 'Open the folder containing the most recently completed output.'
                    $controls.Progress.Value = 100
                    $controls.PercentLabel.Text = '100%'
                    Set-Phase 'Completed' '#15803D'
                }
                else {
                    $controls.Progress.Value = 0
                    $controls.PercentLabel.Text = [string][char]0x2014
                    if ($data.Status -eq 'Failed') {
                        Set-Phase 'Failed' '#B91C1C'
                        $controls.DetailsExpander.IsExpanded = $true
                    }
                    else { Set-Phase $data.Status '#64748B' }
                }
            }
            'Summary' { $state.Summary = $data.Summary }
            'Fatal' {
                $state.Fatal = $true
                Add-Detail $data.Message
                $controls.DetailsExpander.IsExpanded = $true
            }
        }
    }

    function Finish-Window {
        $state.Running = $false
        $state.Clock.Stop()
        $controls.Progress.IsIndeterminate = $false
        $controls.ProgressPanel.Visibility = 'Collapsed'
        $controls.TimingPanel.Visibility = 'Collapsed'
        $controls.PercentLabel.Visibility = 'Collapsed'
        $controls.ActionButton.Content = 'Close'
        $controls.ActionButton.Style = $window.FindResource('PrimaryButton')
        $controls.ActionButton.IsEnabled = $true
        $controls.RemainingValue.Text = [string][char]0x2014
        $controls.RemainingValue.ToolTip = $null
        if ($null -ne $state.LastProgress) {
            Add-Detail ('Last progress: ' + $state.LastProgress.Status)
            $state.LastProgress = $null
        }
        $summary = $state.Summary
        if ($null -ne $summary -and $summary.Cancelled -and -not $state.CurrentFinished) {
            Add-Result ([PSCustomObject]@{ Path = $state.CurrentPath; Status = 'Cancelled'; Message = 'Remaining encodes stopped.' })
        }
        $view = Get-AV1CompletionView -Summary $summary -FileCount $state.FileCount `
            -ElapsedSeconds $state.Clock.Elapsed.TotalSeconds -HasWarnings $state.HasWarnings -Fatal $state.Fatal
        $controls.FileLabel.Text = $view.Title
        $controls.FileLabel.ToolTip = $null
        $controls.FileLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, (Get-AV1StatusBrushKey $view.Color))
        $controls.BatchLabel.Text = '{0} {2} {1}' -f $view.Subtitle, $state.Mode, [char]0xb7
        $controls.SummaryLabel.Text = $view.BatchSummary
        $controls.TimeLabel.Text = $view.Notice
        if ($view.ShowDetails) { $controls.DetailsExpander.IsExpanded = $true }
        if ($view.HideResultStatus -and $controls.Results.Items.Count -eq 1) {
            $controls.Results.Items[0].ShowStatus = $false
            $controls.Results.Items.Refresh()
        }
    }

    $themeState = @{ Name = '' }
    function Update-WindowTheme {
        param([switch]$Force)
        $name = Get-AV1WindowsTheme
        if (-not $Force -and $name -eq $themeState.Name -and $name -ne 'HighContrast') { return }
        Set-AV1WindowTheme -Window $window -Theme $name
        $themeState.Name = $name
    }
    Update-WindowTheme
    $window.Add_SourceInitialized({ Update-WindowTheme -Force })
    # Poll on the UI dispatcher: registry notifications and SystemEvents callbacks
    # can arrive on threads without a PowerShell runspace. Keep checking after encoding.
    $themeTimer = New-Object Windows.Threading.DispatcherTimer
    $themeTimer.Interval = [TimeSpan]::FromSeconds(2)
    $themeTimer.Add_Tick({
        try { Update-WindowTheme }
        catch {
            $themeTimer.Stop()
            Add-Detail ('Could not update the window theme: {0}' -f $_.Exception.Message)
        }
    })
    $themeTimer.Start()

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
            $state.Clock.Start()
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
    if ($null -ne $themeTimer) { $themeTimer.Stop() }
    if ($null -ne $timer) { $timer.Stop() }
    if ($null -ne $state.Worker) {
        $state.Worker.Cancellation.Cancel()
        Complete-AV1Worker $state.Worker
    }
}
