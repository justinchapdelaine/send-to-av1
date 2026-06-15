@rem SPDX-License-Identifier: GPL-3.0-or-later
@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "OPTIMIZER=%SCRIPT_DIR%src\Optimize-AV1.ps1"
set "DOWNLOADER=%SCRIPT_DIR%src\Download-FFmpeg.ps1"
set "SENDTO=%APPDATA%\Microsoft\Windows\SendTo"
set "CPU_LAUNCHER=%SENDTO%\Send to AV1.cmd"
set "NVIDIA_LAUNCHER=%SENDTO%\Send to AV1 - NVIDIA.cmd"

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

if not exist "%SENDTO%" (
    mkdir "%SENDTO%"
    if errorlevel 1 (
        echo Error: Send To folder was not found and could not be created.
        echo Expected: %SENDTO%
        echo.
        pause
        exit /b 1
    )
)

> "%CPU_LAUNCHER%" echo @echo off
>> "%CPU_LAUNCHER%" echo setlocal
>> "%CPU_LAUNCHER%" echo where pwsh.exe ^>nul 2^>nul
>> "%CPU_LAUNCHER%" echo if not errorlevel 1 ^(
>> "%CPU_LAUNCHER%" echo     pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%OPTIMIZER%" %%*
>> "%CPU_LAUNCHER%" echo ^) else ^(
>> "%CPU_LAUNCHER%" echo     powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%OPTIMIZER%" %%*
>> "%CPU_LAUNCHER%" echo ^)
>> "%CPU_LAUNCHER%" echo exit /b %%ERRORLEVEL%%

if errorlevel 1 (
    echo Error: failed to create CPU Send To launcher.
    echo Target: %CPU_LAUNCHER%
    echo.
    pause
    exit /b 1
)

> "%NVIDIA_LAUNCHER%" echo @echo off
>> "%NVIDIA_LAUNCHER%" echo setlocal
>> "%NVIDIA_LAUNCHER%" echo where pwsh.exe ^>nul 2^>nul
>> "%NVIDIA_LAUNCHER%" echo if not errorlevel 1 ^(
>> "%NVIDIA_LAUNCHER%" echo     pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%OPTIMIZER%" -Encoder nvenc %%*
>> "%NVIDIA_LAUNCHER%" echo ^) else ^(
>> "%NVIDIA_LAUNCHER%" echo     powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%OPTIMIZER%" -Encoder nvenc %%*
>> "%NVIDIA_LAUNCHER%" echo ^)
>> "%NVIDIA_LAUNCHER%" echo exit /b %%ERRORLEVEL%%

if errorlevel 1 (
    echo Error: failed to create NVIDIA Send To launcher.
    echo Target: %NVIDIA_LAUNCHER%
    echo.
    pause
    exit /b 1
)

echo Installed Send to AV1.
echo Launchers:
echo   %CPU_LAUNCHER%
echo   %NVIDIA_LAUNCHER%
echo.
echo Use it from File Explorer:
echo Right-click one or more videos ^> Send to ^> Send to AV1
echo Right-click one or more videos ^> Send to ^> Send to AV1 - NVIDIA
echo.
echo Note: the launchers point to this folder. If you move this folder, run Install-SendTo.cmd again.
echo.
pause
exit /b 0
