<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Install per-user shortcuts that open the WPF progress window.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$SendToDirectory = [Environment]::GetFolderPath('SendTo'),
    [string]$LauncherPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/SendToAV1.Launcher.exe')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Send to shortcut installation requires Windows.'
}
$sendTo = $SendToDirectory
if ([string]::IsNullOrWhiteSpace($sendTo)) { throw 'The current user has no Send to folder.' }
$entries = @(
    @{ Name = 'Send to AV1'; Mode = 'cpu' },
    @{ Name = 'Send to AV1 - NVIDIA'; Mode = 'nvidia' },
    @{ Name = 'Send to AV1 - Small'; Mode = 'small' }
)
if ($Uninstall) {
    foreach ($entry in $entries) {
        foreach ($extension in @('.lnk', '.cmd')) {
            $path = Join-Path $sendTo ($entry.Name + $extension)
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
                Write-Host ('Removed: {0}' -f $path)
            }
        }
    }
    Write-Host 'Uninstalled Send to AV1.'
    return
}

$guiPath = Join-Path $PSScriptRoot 'Show-AV1Progress.ps1'
foreach ($name in @('Show-AV1Progress.ps1', 'AV1.Core.psm1', 'AV1.Worker.psm1', 'AV1.ViewModel.psm1', 'Build-Launcher.ps1', 'SendToAv1Launcher.cs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
        throw ('Missing required file: {0}' -f $name)
    }
}
New-Item -ItemType Directory -Path $sendTo -Force | Out-Null
$LauncherPath = [IO.Path]::GetFullPath($LauncherPath)
& (Join-Path $PSScriptRoot 'Build-Launcher.ps1') -OutputPath $LauncherPath
$shell = New-Object -ComObject WScript.Shell
try {
    foreach ($entry in $entries) {
        $shortcut = $shell.CreateShortcut((Join-Path $sendTo ($entry.Name + '.lnk')))
        try {
            $shortcut.TargetPath = $LauncherPath
            # Explorer appends selected files; the GUI executable creates no console.
            $shortcut.Arguments = '--gui "{0}" --mode {1}' -f $guiPath, $entry.Mode
            $shortcut.WorkingDirectory = Split-Path -Parent $PSScriptRoot
            $shortcut.Description = 'Convert selected videos to AV1 and show progress.'
            $shortcut.IconLocation = $LauncherPath + ',0'
            $shortcut.Save()
        }
        finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
        Write-Host ('Installed: {0}' -f $entry.Name)
    }
    # Upgrade existing installations only after all three shortcuts were written.
    foreach ($entry in $entries) {
        $legacy = Join-Path $sendTo ($entry.Name + '.cmd')
        if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Force }
    }
}
finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
