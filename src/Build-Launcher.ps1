<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Build the windowless Send to launcher using the Windows .NET Framework compiler.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/SendToAV1.Launcher.exe')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Building the Send to launcher requires Windows.'
}
$compiler = $null
foreach ($framework in @('Framework64', 'Framework')) {
    $candidate = Join-Path $env:WINDIR ('Microsoft.NET/{0}/v4.0.30319/csc.exe' -f $framework)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $compiler = $candidate; break }
}
if ($null -eq $compiler) { throw 'The Windows .NET Framework C# compiler was not found. The launcher could not be built.' }
$source = Join-Path $PSScriptRoot 'SendToAv1Launcher.cs'
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$directory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$temporary = Join-Path $directory ([Guid]::NewGuid().ToString('N') + '.tmp.exe')
try {
    $compilerArguments = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/debug-', ('/out:{0}' -f $temporary), $source)
    & $compiler @compilerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
        throw 'The windowless launcher could not be compiled. Existing shortcuts have been kept.'
    }
    Copy-Item -LiteralPath $temporary -Destination $OutputPath -Force
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
