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

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Invoke-Installer {
    param([switch]$Uninstall)
    $options = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-SendToDirectory', $tempRoot)
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
    $window.Close()
    $window = $null

    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $names = @('Send to AV1', 'Send to AV1 - NVIDIA', 'Send to AV1 - Small')
    foreach ($name in $names) { Set-Content -LiteralPath (Join-Path $tempRoot ($name + '.cmd')) -Value 'legacy launcher' }
    Set-Content -LiteralPath (Join-Path $tempRoot 'unrelated.txt') -Value 'keep this file'
    Invoke-Installer
    $shell = New-Object -ComObject WScript.Shell
    foreach ($name in $names) {
        $shortcutPath = Join-Path $tempRoot ($name + '.lnk')
        Assert-True (Test-Path -LiteralPath $shortcutPath) ('Missing shortcut: ' + $name)
        $shortcut = $shell.CreateShortcut($shortcutPath)
        try {
            Assert-True ($shortcut.TargetPath -eq $shellPath) 'Shortcut targets the wrong PowerShell host.'
            Assert-True ($shortcut.Arguments -match '-STA' -and $shortcut.Arguments -match '-WindowStyle Hidden') 'Shortcut does not request hidden STA startup.'
            Assert-True ($shortcut.Arguments.Contains(('"{0}"' -f (Join-Path $repoRoot 'src/Show-AV1Progress.ps1')))) 'GUI path was not quoted correctly.'
            if ($name -like '*NVIDIA') { Assert-True ($shortcut.Arguments -match '-Encoder nvenc') 'NVIDIA shortcut lost its mode.' }
            if ($name -like '*Small') { Assert-True ($shortcut.Arguments -match '-Small') 'Small shortcut lost its mode.' }
        }
        finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot ($name + '.cmd')))) 'Upgrade left a duplicate legacy launcher.'
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
    if ($null -ne $window) { $window.Close() }
    if ($null -ne $shell) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
