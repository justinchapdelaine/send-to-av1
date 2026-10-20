<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Download portable FFmpeg tools for Send to AV1.

.DESCRIPTION
    Downloads BtbN GPL Windows builds, verifies the GitHub asset digest when
    available, and installs ffmpeg.exe and ffprobe.exe into the project bin
    folder.
#>

[CmdletBinding()]
param(
    [ValidateSet('auto', 'x64', 'arm64')]
    [string]$Architecture = 'auto',

    [switch]$Force,

    [switch]$Ensure,

    [switch]$NoPrompt,

    [switch]$CheckOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:Provider = 'BtbN'
$Script:ReleaseApiUrl = 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest'

function Resolve-NativeWindowsArchitecture {
    # IsWow64Process2 reports the actual Windows architecture even when this
    # script is running inside an x64 PowerShell process on ARM64 Windows.
    try {
        if (-not ('NativeArchitecture' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeArchitecture {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool IsWow64Process2(IntPtr hProcess, out ushort processMachine, out ushort nativeMachine);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();
}
'@
        }

        $processMachine = 0
        $nativeMachine = 0
        if ([NativeArchitecture]::IsWow64Process2([NativeArchitecture]::GetCurrentProcess(), [ref]$processMachine, [ref]$nativeMachine)) {
            if ($nativeMachine -eq 0xAA64) { return 'arm64' }
            if ($nativeMachine -eq 0x8664) { return 'x64' }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Write-Section {
    param([string]$Message)
    Write-Host ''
    Write-Host '============================================================'
    Write-Host $Message
    Write-Host '============================================================'
}

function Resolve-ProjectRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Resolve-Architecture {
    param([string]$RequestedArchitecture)

    if ($RequestedArchitecture -ne 'auto') {
        return $RequestedArchitecture
    }

    $nativeArchitecture = Resolve-NativeWindowsArchitecture
    if (-not [string]::IsNullOrWhiteSpace($nativeArchitecture)) {
        return $nativeArchitecture
    }

    $architectures = @(
        [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(),
        $env:PROCESSOR_ARCHITEW6432,
        $env:PROCESSOR_ARCHITECTURE
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($architectures -match 'ARM64') {
        return 'arm64'
    }

    if ($architectures -match 'X64|AMD64') {
        return 'x64'
    }

    throw 'Unsupported Windows architecture. BtbN provider support is limited to x64 and arm64.'
}

function Get-AssetName {
    param([string]$ResolvedArchitecture)

    if ($ResolvedArchitecture -eq 'arm64') {
        return 'ffmpeg-master-latest-winarm64-gpl.zip'
    }

    return 'ffmpeg-master-latest-win64-gpl.zip'
}

function Read-InstallManifest {
    param([string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json)
    }
    catch {
        Write-Host ('Warning: could not read existing FFmpeg manifest: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        return $null
    }
}

function Test-InstalledTools {
    param(
        [string]$BinDirectory,
        [string]$ResolvedArchitecture,
        [string]$AssetName,
        [object]$Manifest
    )

    $ffmpegPath = Join-Path $BinDirectory 'ffmpeg.exe'
    $ffprobePath = Join-Path $BinDirectory 'ffprobe.exe'

    # A managed install needs both executables plus a matching manifest so
    # update checks can tell whether the BtbN build is current for this CPU.
    if (-not (Test-Path -LiteralPath $ffmpegPath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $ffprobePath -PathType Leaf)) { return $false }
    if ($null -eq $Manifest) { return $false }
    if ($Manifest.provider -ne $Script:Provider) { return $false }
    if ($Manifest.architecture -ne $ResolvedArchitecture) { return $false }
    if ($Manifest.assetName -ne $AssetName) { return $false }

    return $true
}

function Test-LocalToolExecutables {
    param([string]$BinDirectory)

    $ffmpegPath = Join-Path $BinDirectory 'ffmpeg.exe'
    $ffprobePath = Join-Path $BinDirectory 'ffprobe.exe'

    # Manual installs are still usable without a manifest; they just cannot be
    # treated as up-to-date managed downloads.
    if (-not (Test-Path -LiteralPath $ffmpegPath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $ffprobePath -PathType Leaf)) { return $false }

    return $true
}

function Test-FfmpegEncoder {
    param(
        [string]$EncoderOutput,
        [string]$EncoderName
    )

    return ($EncoderOutput -match ("(?im)^\s*[A-Z\.]+\s+{0}\s" -f [Regex]::Escape($EncoderName)))
}

function Test-NvencTuneSupport {
    param(
        [string]$NvencHelpOutput,
        [string]$TuneName
    )

    return ($NvencHelpOutput -match ("(?im)^\s+{0}\s+" -f [Regex]::Escape($TuneName)))
}

function Write-ToolCapabilitySummary {
    param([string]$BinDirectory)

    $ffmpegPath = Join-Path $BinDirectory 'ffmpeg.exe'
    $ffprobePath = Join-Path $BinDirectory 'ffprobe.exe'

    if (-not (Test-Path -LiteralPath $ffmpegPath -PathType Leaf)) {
        Write-Host 'Capability summary skipped: ffmpeg.exe was not found.' -ForegroundColor Yellow
        return
    }

    $hasFfprobe = Test-Path -LiteralPath $ffprobePath -PathType Leaf
    $hasSvt = $false
    $hasNvenc = $false
    $nvencTuneStatus = 'Unavailable'

    try {
        $encoderOutput = & $ffmpegPath -hide_banner -encoders 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to query FFmpeg encoders.'
        }

        $hasSvt = Test-FfmpegEncoder -EncoderOutput $encoderOutput -EncoderName 'libsvtav1'
        $hasNvenc = Test-FfmpegEncoder -EncoderOutput $encoderOutput -EncoderName 'av1_nvenc'

        if ($hasNvenc) {
            $nvencHelpOutput = & $ffmpegPath -hide_banner -h encoder=av1_nvenc 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                if (Test-NvencTuneSupport -NvencHelpOutput $nvencHelpOutput -TuneName 'uhq') {
                    $nvencTuneStatus = 'UHQ available'
                }
                elseif (Test-NvencTuneSupport -NvencHelpOutput $nvencHelpOutput -TuneName 'hq') {
                    $nvencTuneStatus = 'HQ available; UHQ unavailable'
                }
                else {
                    $nvencTuneStatus = 'Tune options unavailable'
                }
            }
            else {
                $nvencTuneStatus = 'Options query failed'
            }
        }
    }
    catch {
        Write-Host ('Warning: installed FFmpeg could not be queried: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Installed FFmpeg capability summary:'
    Write-Host ('  FFprobe:           {0}' -f $(if ($hasFfprobe) { 'Available' } else { 'Unavailable' }))
    Write-Host ('  CPU/SVT-AV1:       {0}' -f $(if ($hasSvt) { 'Available' } else { 'Unavailable' }))
    Write-Host ('  NVIDIA AV1 NVENC:  {0}' -f $(if ($hasNvenc) { 'Available in FFmpeg' } else { 'Unavailable' }))
    Write-Host ('  NVIDIA tune:       {0}' -f $nvencTuneStatus)
    if ($hasNvenc) {
        Write-Host '  NVIDIA hardware:   Requires a GPU and driver with AV1 encode support'
    }
}

function Invoke-GitHubJsonRequest {
    param([string]$Uri)

    $headers = @{
        'User-Agent' = 'send-to-av1'
        'Accept' = 'application/vnd.github+json'
    }

    return Invoke-RestMethod -Uri $Uri -Headers $headers -TimeoutSec 30 -ErrorAction Stop
}

function Get-ReleaseAsset {
    param([string]$AssetName)

    $release = Invoke-GitHubJsonRequest -Uri $Script:ReleaseApiUrl
    $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if ($null -eq $asset) {
        throw ("BtbN latest release did not include expected asset '{0}'." -f $AssetName)
    }

    return [PSCustomObject]@{
        ReleaseTag = $release.tag_name
        Asset = $asset
    }
}

function Test-ManifestCurrent {
    param(
        [object]$Manifest,
        [string]$ResolvedArchitecture,
        [object]$ReleaseAsset
    )

    if ($null -eq $Manifest) { return $false }
    if ($Manifest.provider -ne $Script:Provider) { return $false }
    if ($Manifest.architecture -ne $ResolvedArchitecture) { return $false }
    if ($Manifest.assetName -ne $ReleaseAsset.Asset.name) { return $false }
    if ($Manifest.assetUpdatedAt -ne $ReleaseAsset.Asset.updated_at) { return $false }

    return $true
}

function Confirm-Download {
    param([string]$Prompt)

    if ($NoPrompt) {
        return $true
    }

    $answer = Read-Host $Prompt
    return ($answer -match '^(?i)(y|yes)$')
}

function Save-Download {
    param(
        [object]$ReleaseAsset,
        [string]$ArchivePath
    )

    $headers = @{
        'User-Agent' = 'send-to-av1'
    }

    $previousProgressPreference = $ProgressPreference
    try {
        # Windows PowerShell's download progress renderer is very slow for
        # large ZIP files, so suppress it while preserving the caller setting.
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ReleaseAsset.Asset.browser_download_url -Headers $headers -OutFile $ArchivePath -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
    }
    finally {
        $ProgressPreference = $previousProgressPreference
    }
}

function Test-AssetDigest {
    param(
        [object]$ReleaseAsset,
        [string]$ArchivePath
    )

    $digest = $null
    if ($ReleaseAsset.Asset.PSObject.Properties.Name -contains 'digest') {
        $digest = $ReleaseAsset.Asset.digest
    }
    if ([string]::IsNullOrWhiteSpace($digest)) {
        Write-Host 'Warning: GitHub did not provide an asset digest; skipping SHA256 verification.' -ForegroundColor Yellow
        return
    }

    if ($digest -notmatch '^sha256:(?<hash>[a-fA-F0-9]{64})$') {
        Write-Host ('Warning: unsupported asset digest format: {0}' -f $digest) -ForegroundColor Yellow
        return
    }

    $expectedHash = $Matches.hash.ToUpperInvariant()
    $actualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) {
        throw ('SHA256 verification failed. Expected {0}; got {1}.' -f $expectedHash, $actualHash)
    }

    Write-Host 'SHA256 verification passed.'
}

function Install-FFmpegArchive {
    param(
        [string]$ArchivePath,
        [string]$BinDirectory
    )

    $extractDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("send-to-av1-ffmpeg-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $extractDirectory | Out-Null

    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractDirectory -Force

        $ffmpegSource = Get-ChildItem -LiteralPath $extractDirectory -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
        $ffprobeSource = Get-ChildItem -LiteralPath $extractDirectory -Recurse -Filter 'ffprobe.exe' | Select-Object -First 1

        if ($null -eq $ffmpegSource -or $null -eq $ffprobeSource) {
            throw 'Downloaded archive did not contain both ffmpeg.exe and ffprobe.exe.'
        }

        New-Item -ItemType Directory -Force -Path $BinDirectory | Out-Null
        Copy-Item -LiteralPath $ffmpegSource.FullName -Destination (Join-Path $BinDirectory 'ffmpeg.exe') -Force
        Copy-Item -LiteralPath $ffprobeSource.FullName -Destination (Join-Path $BinDirectory 'ffprobe.exe') -Force
    }
    finally {
        if (Test-Path -LiteralPath $extractDirectory) {
            Remove-Item -LiteralPath $extractDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-Manifest {
    param(
        [string]$ManifestPath,
        [string]$ResolvedArchitecture,
        [object]$ReleaseAsset
    )

    $manifest = [PSCustomObject]@{
        provider = $Script:Provider
        architecture = $ResolvedArchitecture
        releaseTag = $ReleaseAsset.ReleaseTag
        assetName = $ReleaseAsset.Asset.name
        assetUpdatedAt = $ReleaseAsset.Asset.updated_at
        sourceUrl = $ReleaseAsset.Asset.browser_download_url
        installedAt = (Get-Date).ToString('o')
    }

    $manifest | ConvertTo-Json | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
}

try {
    Write-Section 'Download FFmpeg'

    $projectRoot = Resolve-ProjectRoot
    $binDirectory = Join-Path $projectRoot 'bin'
    $manifestPath = Join-Path $binDirectory 'ffmpeg-manifest.json'
    $resolvedArchitecture = Resolve-Architecture -RequestedArchitecture $Architecture
    $assetName = Get-AssetName -ResolvedArchitecture $resolvedArchitecture
    $manifest = Read-InstallManifest -ManifestPath $manifestPath

    Write-Host ('Provider:     {0}' -f $Script:Provider)
    Write-Host ('Architecture: {0}' -f $resolvedArchitecture)
    Write-Host ('Target:       {0}' -f $binDirectory)

    $localToolExecutablesAvailable = Test-LocalToolExecutables -BinDirectory $binDirectory
    $installedToolsAvailable = Test-InstalledTools -BinDirectory $binDirectory -ResolvedArchitecture $resolvedArchitecture -AssetName $assetName -Manifest $manifest

    if ($localToolExecutablesAvailable -and -not $Force) {
        Write-Host 'Local FFmpeg tools are installed. Checking latest BtbN asset...'
    }

    try {
        $releaseAsset = Get-ReleaseAsset -AssetName $assetName
    }
    catch {
        if ($Ensure -and $localToolExecutablesAvailable -and -not $Force) {
            Write-Host ('Warning: could not check BtbN for FFmpeg updates: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
            Write-Host 'Using the existing local FFmpeg tools.'
            Write-ToolCapabilitySummary -BinDirectory $binDirectory
            exit 0
        }

        throw
    }

    $installedCurrent = $installedToolsAvailable -and (Test-ManifestCurrent -Manifest $manifest -ResolvedArchitecture $resolvedArchitecture -ReleaseAsset $releaseAsset)

    if ($installedCurrent -and -not $Force) {
        Write-Host 'FFmpeg is already installed and current.'
        Write-ToolCapabilitySummary -BinDirectory $binDirectory
        exit 0
    }

    if ($CheckOnly) {
        Write-Host 'FFmpeg is missing or not current.'
        exit 1
    }

    $reason = 'FFmpeg is missing or not current.'
    if ($Force) {
        $reason = 'Forced download requested.'
    }

    Write-Host $reason -ForegroundColor Yellow
    Write-Host ('Asset:        {0}' -f $releaseAsset.Asset.name)
    Write-Host ('Updated:      {0}' -f $releaseAsset.Asset.updated_at)

    if (-not (Confirm-Download -Prompt 'Download and install portable FFmpeg now? [Y/N]')) {
        Write-Host 'Skipped FFmpeg download.'
        exit 0
    }

    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) $releaseAsset.Asset.name
    try {
        Write-Host 'Downloading FFmpeg...'
        Save-Download -ReleaseAsset $releaseAsset -ArchivePath $archivePath
        Test-AssetDigest -ReleaseAsset $releaseAsset -ArchivePath $archivePath

        Write-Host 'Installing ffmpeg.exe and ffprobe.exe...'
        Install-FFmpegArchive -ArchivePath $archivePath -BinDirectory $binDirectory
        Write-Manifest -ManifestPath $manifestPath -ResolvedArchitecture $resolvedArchitecture -ReleaseAsset $releaseAsset

        Write-Host 'FFmpeg installed successfully.' -ForegroundColor Green
        Write-ToolCapabilitySummary -BinDirectory $binDirectory
    }
    finally {
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Host ''
    Write-Host 'FFmpeg download failed:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
