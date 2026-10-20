<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Compile the launcher source and verify windowless startup options and native arguments.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $repoRoot 'src/SendToAv1Launcher.cs')
$script:checks = 0
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('send-to-av1-launcher-' + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $gui = Join-Path $tempRoot 'fixture GUI.ps1'
    $shell = (Get-Process -Id $PID).Path
    foreach ($mode in @('cpu', 'small', 'nvidia')) {
        $start = [SendToAv1Launcher]::CreateStartInfo($shell, $gui, $mode, @('first.mkv', 'second.mkv'))
        Assert-True ($start.CreateNoWindow -and -not $start.UseShellExecute) 'Launcher could create a console.'
        Assert-True ($start.Arguments -match '"-STA"' -and $start.Arguments -match '"-File"') 'Launcher lost its STA script invocation.'
        Assert-True ($start.Arguments.Contains([SendToAv1Launcher]::QuoteArgument($gui))) 'GUI path was not quoted.'
        if ($mode -eq 'small') { Assert-True ($start.Arguments -match '"-Small"') 'Small mode was not forwarded.' }
        elseif ($mode -eq 'nvidia') { Assert-True ($start.Arguments -match '"-Encoder" "nvenc"') 'NVIDIA mode was not forwarded.' }
        else { Assert-True ($start.Arguments -notmatch '"-Small"|"-Encoder"') 'CPU mode unexpectedly changed encoders.' }
    }
    $rejected = $false
    try { [SendToAv1Launcher]::CreateStartInfo($shell, $gui, 'invalid', @()) | Out-Null }
    catch { $rejected = $true }
    Assert-True $rejected 'An invalid mode was silently accepted.'

    # Round-trip the actual quoting through a native executable, including values
    # that a cmd.exe or PowerShell expression hop would reinterpret.
    'param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Values); ConvertTo-Json -InputObject $Values -Compress' |
        Set-Content -LiteralPath $gui -Encoding Ascii
    $values = @('C:\folder with spaces\', 'a"quoted"value', 'trailing\\', '',
        'literal & %PATH% (test) [brackets]', ('caf' + [char]0xe9 + '.mkv'))
    $process = New-Object Diagnostics.Process
    $started = $false
    try {
        $process.StartInfo.FileName = $shell
        $process.StartInfo.Arguments = (@('-NoProfile', '-File', $gui) + $values |
            ForEach-Object { [SendToAv1Launcher]::QuoteArgument($_) }) -join ' '
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $started = $process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { throw 'Argument round-trip timed out.' }
        $received = @($output.GetAwaiter().GetResult() | ConvertFrom-Json)
        Assert-True ($process.ExitCode -eq 0 -and $received.Count -eq $values.Count) 'Native invocation lost arguments.'
        for ($index = 0; $index -lt $values.Count; $index++) {
            Assert-True ($received[$index] -ceq $values[$index]) 'Native invocation changed an argument.'
        }
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    Write-Host ('Launcher checks passed: {0}.' -f $script:checks)
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
