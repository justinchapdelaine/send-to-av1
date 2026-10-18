@rem SPDX-License-Identifier: GPL-3.0-or-later
@echo off
setlocal

set "SENDTO=%APPDATA%\Microsoft\Windows\SendTo"
set "CPU_LAUNCHER=%SENDTO%\Send to AV1.cmd"
set "NVIDIA_LAUNCHER=%SENDTO%\Send to AV1 - NVIDIA.cmd"
set "SMALL_LAUNCHER=%SENDTO%\Send to AV1 - Small.cmd"
set "REMOVED=0"
set "FAILED=0"

if exist "%CPU_LAUNCHER%" (
    del /f /q "%CPU_LAUNCHER%"
    if errorlevel 1 (
        echo Error: failed to remove Send to AV1 launcher.
        echo Target: %CPU_LAUNCHER%
        set "FAILED=1"
    ) else (
        echo Removed: %CPU_LAUNCHER%
        set "REMOVED=1"
    )
)

if exist "%NVIDIA_LAUNCHER%" (
    del /f /q "%NVIDIA_LAUNCHER%"
    if errorlevel 1 (
        echo Error: failed to remove Send to AV1 - NVIDIA launcher.
        echo Target: %NVIDIA_LAUNCHER%
        set "FAILED=1"
    ) else (
        echo Removed: %NVIDIA_LAUNCHER%
        set "REMOVED=1"
    )
)

if exist "%SMALL_LAUNCHER%" (
    del /f /q "%SMALL_LAUNCHER%"
    if errorlevel 1 (
        echo Error: failed to remove Send to AV1 - Small launcher.
        echo Target: %SMALL_LAUNCHER%
        set "FAILED=1"
    ) else (
        echo Removed: %SMALL_LAUNCHER%
        set "REMOVED=1"
    )
)

if "%FAILED%"=="1" (
    echo.
    pause
    exit /b 1
)

if "%REMOVED%"=="1" (
    echo Uninstalled Send to AV1.
) else (
    echo Send to AV1 was not installed for the current user.
    echo No launchers found in: %SENDTO%
)

echo.
pause
exit /b 0
