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
$installer = Join-Path $repoRoot 'src/Install-SendTo.ps1'
$shellPath = (Get-Process -Id $PID).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('send-to-av1-windows-' + [Guid]::NewGuid().ToString('N'))
$script:checks = 0
$shell = $null
$window = $null
$launcherPath = Join-Path $tempRoot 'bin/SendToAV1.Launcher.exe'
$originalRecord = $env:SEND_TO_AV1_LAUNCHER_TEST_RECORD

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Invoke-Installer {
    param([switch]$Uninstall)
    $options = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-SendToDirectory', $tempRoot, '-LauncherPath', $launcherPath)
    if ($Uninstall) { $options += '-Uninstall' }
    & $shellPath @options
    if ($LASTEXITCODE -ne 0) { throw 'Shortcut installer failed.' }
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $source = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'src/Show-AV1Progress.ps1')
    $match = [regex]::Match($source, '(?s)\[xml\]\$layout = @''\r?\n(.*?)\r?\n''@')
    Assert-True $match.Success 'Could not find the actual progress-window layout.'
    [xml]$layout = $match.Groups[1].Value
    $reader = New-Object Xml.XmlNodeReader $layout
    try { $window = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
    foreach ($name in @('ModeLabel', 'StatusLabel', 'FileLabel', 'Progress', 'PercentLabel',
            'TimeLabel', 'Results', 'Details', 'ActionButton', 'FolderButton', 'SummaryLabel')) {
        Assert-True ($null -ne $window.FindName($name)) ('Missing WPF control: ' + $name)
    }
    Assert-True ($window.SizeToContent -eq 'Height') 'The window reserves a fixed height.'
    $results = $window.FindName('Results')
    $results.ApplyTemplate() | Out-Null
    Assert-True ($results.Visibility -eq 'Collapsed') 'The empty results area is visible.'
    $results.Items.Add('Completed: fixture') | Out-Null
    Assert-True ($results.Visibility -eq 'Visible') 'Results did not appear after an item was added.'
    $results.Items.Clear()
    Assert-True ($results.Visibility -eq 'Collapsed') 'The empty results area did not collapse again.'
    $window.Close()
    $window = $null

    New-Item -ItemType Directory -Path $tempRoot | Out-Null
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
            Assert-True ($shortcut.Arguments.Contains(('"{0}"' -f (Join-Path $repoRoot 'src/Show-AV1Progress.ps1')))) 'GUI path was not quoted correctly.'
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
