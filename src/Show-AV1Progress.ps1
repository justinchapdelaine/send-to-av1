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

    [xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Send to AV1" Width="660" MinWidth="520" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource WindowBrush}" Foreground="{DynamicResource TextBrush}"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="Caption" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11"/><Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
        </Style>
        <Style x:Key="Metric" TargetType="TextBlock">
            <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Margin" Value="0,6,10,0"/><Setter Property="TextWrapping" Value="Wrap"/>
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
        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="MinWidth" Value="90"/>
            <Setter Property="MinHeight" Value="38"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Name="FocusRing" CornerRadius="9" BorderThickness="2" BorderBrush="Transparent"/>
                            <Border Margin="3" CornerRadius="6" Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
                                <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"
                                                  RecognizesAccessKey="True" TextElement.Foreground="{TemplateBinding Foreground}"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="FocusRing" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{DynamicResource HoverBrush}"/>
                    <Setter Property="Foreground" Value="{DynamicResource HoverTextBrush}"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="{DynamicResource PressedBrush}"/>
                    <Setter Property="Foreground" Value="{DynamicResource HoverTextBrush}"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="{DynamicResource DisabledBrush}"/>
                    <Setter Property="Foreground" Value="{DynamicResource DisabledTextBrush}"/>
                    <Setter Property="Cursor" Value="Arrow"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
            <Setter Property="Background" Value="{DynamicResource PrimaryBrush}"/>
            <Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource PrimaryBrush}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{DynamicResource PrimaryHoverBrush}"/>
                    <Setter Property="BorderBrush" Value="{DynamicResource PrimaryHoverBrush}"/>
                    <Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="{DynamicResource PrimaryPressedBrush}"/>
                    <Setter Property="BorderBrush" Value="{DynamicResource PrimaryPressedBrush}"/>
                    <Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="{DynamicResource DisabledBrush}"/>
                    <Setter Property="Foreground" Value="{DynamicResource DisabledTextBrush}"/>
                    <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="CancelButton" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{DynamicResource DangerHoverBrush}"/>
                    <Setter Property="Foreground" Value="{DynamicResource DangerTextBrush}"/>
                    <Setter Property="BorderBrush" Value="{DynamicResource DangerTextBrush}"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="{DynamicResource DangerPressedBrush}"/>
                    <Setter Property="Foreground" Value="{DynamicResource DangerTextBrush}"/>
                    <Setter Property="BorderBrush" Value="{DynamicResource DangerTextBrush}"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="{DynamicResource DisabledBrush}"/>
                    <Setter Property="Foreground" Value="{DynamicResource DisabledTextBrush}"/>
                    <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="EncodingProgress" TargetType="ProgressBar">
            <Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid Name="PART_Track" ClipToBounds="True">
                            <Border Background="{DynamicResource TrackBrush}" CornerRadius="4"/>
                            <Border Name="PART_Indicator" HorizontalAlignment="Left"
                                    Background="{TemplateBinding Foreground}" CornerRadius="4"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsIndeterminate" Value="True">
                                <Trigger.EnterActions>
                                    <BeginStoryboard Name="BusyPulse">
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="PART_Indicator" Storyboard.TargetProperty="Opacity"
                                                             From="0.25" To="1" Duration="0:0:0.8" AutoReverse="True" RepeatBehavior="Forever"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions><StopStoryboard BeginStoryboardName="BusyPulse"/></Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
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
            <TextBlock Name="FileLabel" Text="Preparing your videos..." FontSize="20" FontWeight="SemiBold"
                       TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,16,0"/>
            <Border Grid.Column="1" Background="{DynamicResource BadgeBrush}" CornerRadius="10" Padding="10,5" VerticalAlignment="Center">
                <TextBlock Name="ModeLabel" Foreground="{DynamicResource BadgeTextBrush}" FontSize="12" FontWeight="SemiBold"/>
            </Border>
        </Grid>
        <Grid Grid.Row="1" Margin="0,10,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Name="BatchLabel" Text="Selected videos" Foreground="{DynamicResource MutedBrush}"/>
            <Ellipse Name="StatusDot" Grid.Column="1" Width="7" Height="7" Fill="{DynamicResource AccentBrush}" Margin="0,0,7,0"/>
            <TextBlock Name="StatusLabel" Grid.Column="2" Text="Preparing" Foreground="{DynamicResource AccentBrush}" FontWeight="SemiBold"/>
        </Grid>
        <Grid Name="ProgressPanel" Grid.Row="2" Margin="0,16,0,16">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <ProgressBar Name="Progress" Height="8" Minimum="0" Maximum="100" IsIndeterminate="True"
                         VerticalAlignment="Center" Style="{StaticResource EncodingProgress}"/>
            <TextBlock Name="PercentLabel" Grid.Column="1" MinWidth="64" Text="..." FontSize="22" FontWeight="SemiBold"
                       Foreground="{DynamicResource AccentBrush}" TextAlignment="Right" VerticalAlignment="Center" Margin="12,0,0,0"/>
        </Grid>
        <Border Name="TimingPanel" Grid.Row="3" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="14">
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="1.2*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="1.3*"/></Grid.ColumnDefinitions>
                <StackPanel>
                    <TextBlock Text="TIME REMAINING" Style="{StaticResource Caption}"/>
                    <TextBlock Name="RemainingValue" Text="Calculating..." Style="{StaticResource Metric}" Foreground="{DynamicResource AccentBrush}"/>
                </StackPanel>
                <StackPanel Grid.Column="1">
                    <TextBlock Text="ELAPSED" Style="{StaticResource Caption}"/>
                    <TextBlock Name="ElapsedValue" Text="00:00:00" Style="{StaticResource Metric}"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                    <TextBlock Text="VIDEO PROCESSED" Style="{StaticResource Caption}"/>
                    <TextBlock Name="ProcessedValue" Text="&#x2014;" Style="{StaticResource Metric}" FontSize="12"/>
                </StackPanel>
            </Grid>
        </Border>
        <StackPanel Grid.Row="4">
            <TextBlock Name="SummaryLabel" Style="{StaticResource OptionalText}" Margin="0,14,0,0"
                       Foreground="{DynamicResource TextBrush}" FontSize="12" TextWrapping="Wrap"/>
            <TextBlock Name="TimeLabel" Style="{StaticResource OptionalText}" Margin="0,8,0,0"
                       Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap"/>
        </StackPanel>
        <ListBox Foreground="{DynamicResource TextBrush}" Name="Results" Grid.Row="5" BorderThickness="0" Background="Transparent" MaxHeight="220" Margin="0,16,0,0"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListBox.Style>
                <Style TargetType="ListBox"><Style.Triggers>
                    <Trigger Property="HasItems" Value="False"><Setter Property="Visibility" Value="Collapsed"/></Trigger>
                </Style.Triggers></Style>
            </ListBox.Style>
            <ListBox.ItemContainerStyle>
                <Style TargetType="ListBoxItem">
                    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                    <Setter Property="Padding" Value="0"/><Setter Property="Margin" Value="0"/>
                </Style>
            </ListBox.ItemContainerStyle>
            <ListBox.ItemTemplate>
                <DataTemplate>
                    <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,8">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <TextBlock Text="{Binding Glyph}" Style="{StaticResource ResultColor}" FontFamily="Segoe UI Symbol" FontSize="18"/>
                            <StackPanel Grid.Column="1">
                                <DockPanel>
                                    <TextBlock Text="{Binding Status}" DockPanel.Dock="Right" FontSize="11" Margin="12,0,0,0">
                                        <TextBlock.Style>
                                            <Style TargetType="TextBlock" BasedOn="{StaticResource ResultColor}"><Style.Triggers>
                                                <DataTrigger Binding="{Binding ShowStatus}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
                                            </Style.Triggers></Style>
                                        </TextBlock.Style>
                                    </TextBlock>
                                    <TextBlock Text="{Binding Name}" Foreground="{DynamicResource TextBrush}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                                </DockPanel>
                                <TextBlock Text="{Binding Description}" Foreground="{DynamicResource TextBrush}" Margin="0,4,0,0" TextWrapping="Wrap"/>
                                <TextBlock Text="{Binding PathText}" ToolTip="{Binding PathText}" Foreground="{DynamicResource MutedBrush}" FontSize="11"
                                           Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                        </Grid>
                    </Border>
                </DataTemplate>
            </ListBox.ItemTemplate>
        </ListBox>
        <Expander Name="DetailsExpander" Header="Details" Grid.Row="6" Margin="0,14,0,0" Foreground="{DynamicResource MutedBrush}">
            <TextBox Name="Details" IsReadOnly="True" TextWrapping="Wrap" Height="110" FontFamily="Consolas" FontSize="11"
                     Foreground="{DynamicResource TextBrush}" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}"
                     Margin="0,8,0,0" VerticalScrollBarVisibility="Auto"/>
        </Expander>
        <DockPanel Grid.Row="7" Margin="0,18,0,0" LastChildFill="False">
            <Button Name="ActionButton" DockPanel.Dock="Right" Content="Cancel" Style="{StaticResource CancelButton}"/>
            <Button Name="FolderButton" DockPanel.Dock="Right" Content="Open output folder" Margin="0,0,10,0" Style="{StaticResource SecondaryButton}" IsEnabled="False"/>
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
            'TimeLabel', 'Results', 'Details', 'ActionButton', 'FolderButton', 'SummaryLabel',
            'BatchLabel', 'StatusDot', 'RemainingValue', 'ElapsedValue', 'ProcessedValue', 'DetailsExpander',
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
    $controls.ModeLabel.Text = $mode
    $state = @{ Worker = $null; Running = $true; Started = $false; Summary = $null; Fatal = $false
        HasWarnings = $false; OutputPath = $null; CurrentPath = $null; CurrentFinished = $true; LastProgress = $null
        FileCount = 0; Clock = (New-Object Diagnostics.Stopwatch) }
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
        $controls.StatusLabel.Text = $Text
        $key = Get-AV1StatusBrushKey $Color
        foreach ($name in @('StatusLabel', 'Progress', 'PercentLabel', 'RemainingValue')) {
            $controls[$name].SetResourceReference([Windows.Controls.Control]::ForegroundProperty, $key)
        }
        $controls.StatusDot.SetResourceReference([Windows.Shapes.Shape]::FillProperty, $key)
    }

    function Add-Result {
        param($Data)
        $view = Get-AV1ResultView $Data
        $controls.Results.Items.Add($view) | Out-Null
        $controls.Results.ScrollIntoView($view)
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
                $controls.BatchLabel.Text = 'File {0} of {1}' -f $data.FileNumber, $data.FileCount
                if (-not $state.Worker.Cancellation.IsCancellationRequested) {
                    Set-Phase 'Inspecting video'
                    $controls.TimeLabel.Text = ''
                    $controls.RemainingValue.Text = 'Calculating...'
                }
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
        $controls.StatusDot.Visibility = 'Collapsed'
        $controls.StatusLabel.Visibility = 'Collapsed'
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
        $controls.BatchLabel.Text = $view.Subtitle
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
