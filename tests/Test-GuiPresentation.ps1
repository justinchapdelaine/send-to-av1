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
$summary = [PSCustomObject]@{ Processed = 1; Skipped = 0; Failed = 0; SavedBytes = 5MB; Cancelled = $false }
$view = Get-AV1CompletionView -Summary $summary -FileCount 1 -ElapsedSeconds 145.9
Assert-True ($view.Title -eq 'Encoding complete' -and $view.Subtitle -eq 'Finished in 2m 25s') 'Single-file completion lost its outcome or wall-clock duration.'
Assert-True ($view.BatchSummary -eq '' -and $view.Notice -eq '' -and $view.HideResultStatus) 'Single-file success repeated counts, savings, or status.'
Assert-True ($view.Color -eq '#15803D' -and -not $view.ShowDetails) 'Normal completion showed an error or opened details.'
Assert-True ((Get-AV1ResultView $data).ShowStatus) 'Result status was hidden before the batch finished.'
$view = Get-AV1CompletionView -Summary $summary -FileCount 2 -ElapsedSeconds 3905
Assert-True ($view.Title -eq 'Batch complete' -and $view.Subtitle -eq 'Finished in 1h 5m 5s') 'Batch completion lost its total duration.'
Assert-True ($view.BatchSummary -match '1 completed.*0 skipped.*0 failed.*5[.,]0 MB saved' -and -not $view.HideResultStatus) 'Batch completion lost counts, savings, or per-file status.'
$summary.SavedBytes = -5MB
$view = Get-AV1CompletionView -Summary $summary -FileCount 2 -ElapsedSeconds 145 -HasWarnings $true
Assert-True ($view.BatchSummary -match '5[.,]0 MB larger overall' -and $view.BatchSummary -notmatch 'saved') 'Larger batch outputs were presented as savings.'
Assert-True ($view.Title -eq 'Finished with warnings' -and $view.Color -eq '#B45309' -and $view.Notice -match 'Details') 'Completion hid a warning.'
$summary.Failed = 1
$view = Get-AV1CompletionView -Summary $summary -FileCount 2 -ElapsedSeconds 145 -HasWarnings $true
Assert-True ($view.Title -eq 'Finished with errors' -and $view.Color -eq '#B91C1C' -and $view.ShowDetails) 'A partial failure was presented as successful completion.'
$summary.Cancelled = $true
$view = Get-AV1CompletionView -Summary $summary -FileCount 3 -ElapsedSeconds 145
Assert-True ($view.Title -eq 'Encoding cancelled' -and $view.Subtitle -eq 'Stopped after 2m 25s' -and $view.Notice -match 'kept') 'Cancellation lost its outcome or retention notice.'
Assert-True ($view.BatchSummary -match '1 completed' -and -not $view.HideResultStatus) 'Cancellation hid completed outputs or result statuses.'
$summary.Processed = 0; $summary.Skipped = 1; $summary.Failed = 0
$view = Get-AV1CompletionView -Summary $summary -FileCount 1 -ElapsedSeconds 0
Assert-True ($view.Notice -eq 'No completed output files.' -and $view.BatchSummary -eq '') 'Cancellation without completed files claimed to retain an output.'
$summary.Cancelled = $false
$view = Get-AV1CompletionView -Summary $summary -FileCount 1 -ElapsedSeconds 0 -HasWarnings $true
Assert-True ($view.Title -eq 'No files encoded' -and -not $view.HideResultStatus) 'A skipped file was presented as encoded.'
Assert-True ($view.Color -eq '#B45309' -and $view.Notice -eq 'See Details for warnings.') 'An all-skipped file hid its warning notice.'
$summary.Skipped = 3
$view = Get-AV1CompletionView -Summary $summary -FileCount 3 -ElapsedSeconds 90 -HasWarnings $true
Assert-True ($view.Title -eq 'No files encoded' -and $view.Color -eq '#B45309' -and $view.Notice -match 'Details' -and $view.BatchSummary -match '0 completed.*3 skipped.*0 failed') 'An all-skipped batch lost its warning or counts.'
$view = Get-AV1CompletionView -Summary $summary -FileCount 3 -ElapsedSeconds 0
Assert-True ($view.Color -eq '#64748B' -and $view.Notice -eq '') 'A warning-free empty result invented a warning.'
$view = Get-AV1CompletionView -Summary $null -FileCount 1 -ElapsedSeconds 0
Assert-True ($view.Title -eq 'Could not complete encoding' -and $view.ShowDetails -and $view.Subtitle -eq 'Stopped after 0s') 'A missing worker summary was presented as success.'
$view = Get-AV1CompletionView -Summary $summary -FileCount 1 -ElapsedSeconds 10 -Fatal $true
Assert-True ($view.Color -eq '#B91C1C' -and $view.ShowDetails -and -not $view.HideResultStatus) 'A fatal display error was masked by the worker summary.'
$view = Get-AV1CompletionView -Summary $summary -FileCount 3 -ElapsedSeconds 1 -Fatal $true
Assert-True ($view.Title -eq 'Could not complete encoding' -and $view.BatchSummary -eq '') 'A batch-level error was presented as per-file counts.'
Assert-True ((Get-AV1CompletionView -Summary $summary -FileCount 1 -ElapsedSeconds 97205).Subtitle -eq 'Finished in 27h 0m 5s') 'Completion duration wrapped at midnight.'
Write-Host ('GUI presentation checks passed: {0}.' -f $script:checks)
