<#
SPDX-License-Identifier: GPL-3.0-or-later

.SYNOPSIS
    Check GUI time estimates and result presentation without requiring WPF.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/AV1.ViewModel.psm1') -Force
$script:checks = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$progress = [PSCustomObject]@{
    SecondsRemaining = -1; Finalizing = $false; DurationSeconds = 3600
    ProcessedSeconds = 75; ElapsedSeconds = 10; Status = 'Detailed timestamps'
}
foreach ($case in @(@(-1, 'Calculating...'), @(0, 'Almost done'), @(30, 'Less than a minute'),
        @(60, 'About 1 minute'), @(480, 'About 8 minutes'), @(491, 'About 8 minutes'), @(3600, 'About 1 hour'),
        @(3900, 'About 1 hour 5 min'), @(7200, 'About 2 hours'))) {
    $progress.SecondsRemaining = $case[0]
    $view = Get-AV1ProgressView $progress
    Assert-True ($view.Remaining -eq $case[1]) ('Incorrect time estimate: ' + $view.Remaining)
}
$progress.SecondsRemaining = 480
$view = Get-AV1ProgressView $progress
Assert-True ($view.RemainingDetail -match '00:08:00') 'Precise remaining time was lost.'
Assert-True ($view.Elapsed -eq '00:00:10' -and $view.Processed -eq '00:01:15 / 01:00:00') 'Elapsed and processed times were confused.'
$progress.DurationSeconds = 0
$view = Get-AV1ProgressView $progress
Assert-True ($view.Remaining -eq 'Unavailable' -and $view.Processed -eq '00:01:15') 'Unknown duration invented an ETA or total.'
$progress.Finalizing = $true
$view = Get-AV1ProgressView $progress
Assert-True ($view.Remaining -eq 'Finalizing...' -and $view.RemainingDetail -eq $progress.Status) 'Finalization displayed an obsolete ETA.'
Assert-True ((Format-AV1Clock 97205) -eq '27:00:05') 'Long-running times wrapped at midnight.'

$data = [PSCustomObject]@{ Status = 'Completed'; Path = 'source.mkv'; Message = ''; InputBytes = 10MB; OutputBytes = 5MB; OutputPath = 'source_AV1_2.mkv' }
$view = Get-AV1ResultView $data
Assert-True ($view.Name -eq 'source.mkv' -and $view.PathText -eq 'source_AV1_2.mkv') 'Result displayed the wrong source or final output name.'
Assert-True ($view.Description -match '50[.,]0% smaller' -and $view.Description -match 'MB') 'Result did not show accurate size savings.'
Assert-True ($view.Color -eq '#15803D') 'Successful compression was not shown as success.'
$data.OutputBytes = 15MB
$view = Get-AV1ResultView $data
Assert-True ($view.Description -match '50[.,]0% larger' -and $view.Color -eq '#B45309') 'Larger outputs were presented as savings.'
$data.OutputBytes = $data.InputBytes
Assert-True ((Get-AV1ResultView $data).Description -match 'Same size') 'Equal sizes were presented as compression.'
$data.InputBytes = 0
$view = Get-AV1ResultView $data
Assert-True ($view.Description -notmatch '%' -and $view.Color -eq '#B45309') 'Zero-sized inputs caused an invalid percentage.'
foreach ($status in @('Skipped', 'Failed', 'Cancelled')) {
    # Non-completed results do not have output-size or output-path properties.
    $view = Get-AV1ResultView ([PSCustomObject]@{ Status = $status; Path = 'source.mkv'; Message = 'Reason for result' })
    Assert-True ($view.Status -eq $status -and $view.Description -eq 'Reason for result') ('Reason was lost for: ' + $status)
    if ($status -eq 'Failed') { Assert-True ($view.Color -eq '#B91C1C') 'Failure was not visually distinguished.' }
}
Write-Host ('GUI presentation checks passed: {0}.' -f $script:checks)
