<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Run lightweight repository checks that do not require FFmpeg.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$optimizerPath = Join-Path $repoRoot 'src\Optimize-AV1.ps1'
$corePath = Join-Path $repoRoot 'src\AV1.Core.psm1'
$downloaderPath = Join-Path $repoRoot 'src\Download-FFmpeg.ps1'
$installerPath = Join-Path $repoRoot 'Install-SendTo.cmd'
$binReadmePath = Join-Path $repoRoot 'bin\README.md'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Assert-True (Test-Path -LiteralPath $optimizerPath -PathType Leaf) 'Missing src\Optimize-AV1.ps1.'
Assert-True (Test-Path -LiteralPath $downloaderPath -PathType Leaf) 'Missing src\Download-FFmpeg.ps1.'
Assert-True (Test-Path -LiteralPath $installerPath -PathType Leaf) 'Missing Install-SendTo.cmd.'
Assert-True (Test-Path -LiteralPath $binReadmePath -PathType Leaf) 'Missing bin\README.md.'
foreach ($name in @('AV1.Core.psm1', 'AV1.Worker.psm1', 'AV1.ViewModel.psm1', 'Show-AV1Progress.ps1', 'Install-SendTo.ps1', 'Build-Launcher.ps1', 'SendToAv1Launcher.cs')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot ('src/' + $name)) -PathType Leaf) ('Missing src/' + $name)
}
Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot 'resources/SendToAV1.ico') -PathType Leaf) 'Missing application icon.'

foreach ($scriptPath in (Get-ChildItem (Join-Path $repoRoot 'src') -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }).FullName) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) ('PowerShell parser found errors in {0}: {1}' -f (Resolve-Path -LiteralPath $scriptPath -Relative), (($errors | ForEach-Object { $_.Message }) -join '; '))
}

$optimizerText = (Get-Content -Raw -LiteralPath $optimizerPath) + (Get-Content -Raw -LiteralPath $corePath)
$downloaderText = Get-Content -Raw -LiteralPath $downloaderPath
$installerText = Get-Content -Raw -LiteralPath $installerPath

Assert-True ($installerText -match [Regex]::Escape('set "OPTIMIZER=%SCRIPT_DIR%src\Optimize-AV1.ps1"')) 'Installer does not point at src\Optimize-AV1.ps1.'
Assert-True ($installerText -match [Regex]::Escape('set "DOWNLOADER=%SCRIPT_DIR%src\Download-FFmpeg.ps1"')) 'Installer does not point at src\Download-FFmpeg.ps1.'
Assert-True ($installerText -match [Regex]::Escape('-File "%DOWNLOADER%" -Ensure')) 'Installer does not run the FFmpeg downloader in ensure mode.'
Assert-True ($optimizerText -match [Regex]::Escape("Join-Path `$projectRoot (Join-Path 'bin'")) 'Optimizer does not look for local FFmpeg tools in the root bin folder.'
Assert-True ($optimizerText -match [Regex]::Escape("[ValidateSet('mkv', 'mp4')]")) 'Optimizer is missing the output container validation set.'
Assert-True ($optimizerText -match [Regex]::Escape('[switch]$Diagnostics')) 'Optimizer is missing -Diagnostics.'
Assert-True ($optimizerText -match [Regex]::Escape('[switch]$DryRun')) 'Optimizer is missing -DryRun.'
Assert-True ($optimizerText -match [Regex]::Escape('[int]$Crf = 34')) 'Optimizer default CRF is not the balanced storage value.'
Assert-True ($optimizerText -match [Regex]::Escape('[int]$Preset = 5')) 'Optimizer default SVT preset is not the balanced storage value.'
Assert-True ($optimizerText -match [Regex]::Escape('[int]$NvencCq = 32')) 'Optimizer default NVENC CQ is not the balanced storage value.'
Assert-True ($optimizerText -match [Regex]::Escape("'-svtav1-params', 'keyint=10s:tune=0'")) 'Optimizer is missing the time-based SVT keyframe interval and visual quality tuning.'
Assert-True ($optimizerText -match [Regex]::Escape("ConvertFrom-Json")) 'Optimizer should parse ffprobe output as structured JSON.'
Assert-True ($downloaderText -match [Regex]::Escape('function Test-LocalToolExecutables')) 'Downloader is missing the local executable presence check.'
Assert-True ($downloaderText -match [Regex]::Escape('$localToolExecutablesAvailable = Test-LocalToolExecutables')) 'Downloader does not use the local executable presence check.'

Write-Host 'Repository checks passed.'
