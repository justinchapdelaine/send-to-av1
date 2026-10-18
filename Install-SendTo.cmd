@rem SPDX-License-Identifier: GPL-3.0-or-later
@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "OPTIMIZER=%SCRIPT_DIR%src\Optimize-AV1.ps1"
set "DOWNLOADER=%SCRIPT_DIR%src\Download-FFmpeg.ps1"

if not exist "%OPTIMIZER%" (
    echo Error: Optimize-AV1.ps1 was not found in the src folder.
    echo Expected: %OPTIMIZER%
    echo.
    pause
    exit /b 1
)

if not exist "%DOWNLOADER%" (
    echo Error: Download-FFmpeg.ps1 was not found in the src folder.
    echo Expected: %DOWNLOADER%
    echo.
    pause
    exit /b 1
)

echo Checking portable FFmpeg tools...
where pwsh.exe >nul 2>nul
if not errorlevel 1 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%DOWNLOADER%" -Ensure
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DOWNLOADER%" -Ensure
)

if errorlevel 1 (
    echo.
    echo Warning: FFmpeg setup did not complete.
    rem Keep installing launchers so users can add FFmpeg later or use PATH tools.
    echo Send To launchers can still be installed, but conversions require ffmpeg.exe.
    echo You can run src\Download-FFmpeg.ps1 later or place ffmpeg.exe and ffprobe.exe in bin.
    echo.
    pause
)

where pwsh.exe >nul 2>nul
if not errorlevel 1 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%src\Install-SendTo.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%src\Install-SendTo.ps1"
)
if errorlevel 1 (
    echo.
    echo Error: failed to install Send To shortcuts.
    pause
    exit /b 1
)

echo.
echo Installed Send to AV1. Select videos in Explorer and choose a Send to AV1 entry.
echo Encoding progress will appear in a separate window.
echo Run this installer again if you move the project folder.
echo.
pause
exit /b 0
