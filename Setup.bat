@echo off
setlocal

echo.
echo  VoiceKit Setup
echo  ==============
echo.

:: Check for AutoHotkey v2
if exist "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe" (
    echo  AutoHotkey v2 found.
) else (
    echo  AutoHotkey v2 not found. Installing via winget...
    echo.
    winget install AutoHotkey.AutoHotkey --accept-package-agreements --accept-source-agreements
    if not exist "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe" (
        echo.
        echo  Installation failed. Please install AutoHotkey v2 manually:
        echo  https://www.autohotkey.com
        echo.
        pause
        exit /b 1
    )
    echo.
    echo  AutoHotkey v2 installed.
)

:: Remove first-run flag so shortcuts are created fresh on this machine
if exist "%~dp0logs\installed.flag" del "%~dp0logs\installed.flag"

:: Launch VoiceKit
echo  Starting VoiceKit...
start "" "%~dp0VoiceKit.ahk"

echo.
echo  Done! VoiceKit is running.
echo  Try saying "open new automation" (give Windows a few seconds to index).
echo.
pause
