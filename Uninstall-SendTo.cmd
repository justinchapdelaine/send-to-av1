@rem SPDX-License-Identifier: GPL-3.0-or-later
@echo off
setlocal
if /i "%~1"=="--console" goto console
wscript.exe //nologo "%~dp0Uninstall-SendTo.vbs"
exit /b %errorlevel%

:console
set "INSTALLER=%~dp0src\Install-SendTo.ps1"
if not exist "%INSTALLER%" (
    echo Error: src\Install-SendTo.ps1 was not found.
    pause
    exit /b 1
)
where pwsh.exe >nul 2>nul
if not errorlevel 1 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Uninstall
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Uninstall
)
if errorlevel 1 (
    pause
    exit /b 1
)
echo.
pause
exit /b 0
