<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Test duplicate PATH entries and concurrent output finalization without FFmpeg.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$optimizer = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Optimize-AV1.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($optimizer, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Optimizer failed to parse.' }
$names = @('Resolve-ToolPath', 'New-UniqueOutputPath', 'Complete-OutputFile')
$functions = $ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names
}, $false)
if ($functions.Count -ne $names.Count) { throw 'Missing optimizer functions.' }
# Load the actual helpers without running the optimizer's command-line entry point.
$definitions = ($functions | ForEach-Object { $_.Extent.Text }) -join "`n"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('send-to-av1-safety-' + [Guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
$jobs = @()
$script:checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $helpers = Join-Path $tempRoot 'helpers.ps1'
    Set-Content -LiteralPath $helpers -Value $definitions
    . $helpers
    $firstDirectory = New-Item -ItemType Directory -Path (Join-Path $tempRoot 'first')
    $secondDirectory = New-Item -ItemType Directory -Path (Join-Path $tempRoot 'second')
    $toolName = 'av1-test-' + [Guid]::NewGuid().ToString('N')
    $executableName = $toolName
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $executableName += '.exe' }
    $shell = (Get-Process -Id $PID).Path
    foreach ($directory in @($firstDirectory, $secondDirectory)) {
        Copy-Item -LiteralPath $shell -Destination (Join-Path $directory.FullName $executableName)
    }
    $env:PATH = $firstDirectory.FullName + [IO.Path]::PathSeparator + $secondDirectory.FullName + [IO.Path]::PathSeparator + $originalPath
    Assert-True (@(Get-Command $toolName -CommandType Application -All).Count -eq 2) 'Duplicate tool fixture was not discoverable.'
    $resolved = Resolve-ToolPath $toolName
    Assert-True ($resolved -is [string] -and $resolved -eq (Join-Path $firstDirectory.FullName $executableName)) 'Tool discovery must return only the first PATH match.'
    Assert-True ($null -eq (Resolve-ToolPath ($toolName + '-missing'))) 'Missing tools must return null.'
    $env:PATH = $originalPath

    $inputFile = Join-Path $tempRoot 'recording.mp4'
    Set-Content -LiteralPath $inputFile -Value 'original input'
    $originalHash = (Get-FileHash -LiteralPath $inputFile).Hash
    $output = New-UniqueOutputPath -InputFile $inputFile -Container 'mkv'
    foreach ($index in 1..2) {
        $temporary = Join-Path $tempRoot ("job-{0}.tmp.mkv" -f $index)
        Set-Content -LiteralPath $temporary -Value ("encoded job {0}" -f $index)
        $jobs += Start-Job -ScriptBlock {
            param($Definitions, $Temporary, $Output, $InputFile, $Root, $Index)
            $ErrorActionPreference = 'Stop'
            Invoke-Expression $Definitions
            New-Item -ItemType File -Path (Join-Path $Root ("ready-{0}" -f $Index)) | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while (@(Get-ChildItem -LiteralPath $Root -Filter 'ready-*').Count -lt 2) {
                if ([DateTime]::UtcNow -gt $deadline) { throw 'Concurrent worker did not arrive.' }
                Start-Sleep -Milliseconds 20
            }
            Complete-OutputFile -TemporaryPath $Temporary -OutputPath $Output -InputFile $InputFile -Container 'mkv'
        } -ArgumentList $definitions, $temporary, $output, $inputFile, $tempRoot, $index
    }
    $jobs | Wait-Job -Timeout 30 | Out-Null
    foreach ($job in $jobs) {
        Assert-True ($job.State -eq 'Completed') ("Concurrent finalization failed: {0}" -f $job.ChildJobs[0].JobStateInfo.Reason)
    }
    $outputs = @($jobs | Receive-Job -ErrorAction Stop)
    Assert-True ($outputs.Count -eq 2 -and @($outputs | Select-Object -Unique).Count -eq 2) 'Both conversions must retain distinct outputs.'
    for ($index = 0; $index -lt 2; $index++) {
        Assert-True ((Get-Content -Raw -LiteralPath $outputs[$index]).Trim() -eq ("encoded job {0}" -f ($index + 1))) 'A completed encode was overwritten.'
    }
    Assert-True ((Test-Path -LiteralPath $output) -and
        (Test-Path -LiteralPath (Join-Path $tempRoot 'recording_AV1_2.mkv'))) 'Concurrent outputs must use the normal numbered names.'
    Assert-True ((Get-FileHash -LiteralPath $inputFile).Hash -eq $originalHash) 'Source input was modified.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*.tmp.mkv').Count -eq 0) 'Successful moves left temporary files.'

    # Unrelated I/O failures must fail rather than loop or replace an output.
    $before = (Get-FileHash -LiteralPath $output).Hash
    $failed = $false
    try {
        Complete-OutputFile -TemporaryPath (Join-Path $tempRoot 'missing.tmp.mkv') -OutputPath $output -InputFile $inputFile -Container 'mkv' | Out-Null
    }
    catch [IO.IOException] { $failed = $true }
    Assert-True $failed 'Missing temporary output must raise an I/O error.'
    Assert-True ((Get-FileHash -LiteralPath $output).Hash -eq $before) 'Failed finalization modified an existing output.'
    Write-Host ("Output-safety checks passed: {0}." -f $script:checks)
}
finally {
    $env:PATH = $originalPath
    if ($jobs.Count -gt 0) {
        $jobs | Stop-Job -ErrorAction SilentlyContinue
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
