@echo off
setlocal

echo.
echo  VoiceKit Uninstaller
echo  ====================
echo.
echo  This removes VoiceKit's Start Menu entries and login shortcut, and
echo  stops the running VoiceKit tray app. It does NOT delete this folder
echo  or uninstall AutoHotkey - delete the folder yourself when you're done,
echo  and remove AutoHotkey from Settings if nothing else uses it.
echo.
choice /C YN /M "Continue"
if errorlevel 2 goto :cancel

echo.
echo  Stopping VoiceKit (if running)...
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'AutoHotkey64.exe' -and $_.CommandLine -like '*VoiceKit.ahk*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"

set "VM=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Voice Macros"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\VoiceKit.lnk"

if exist "%VM%" (
    echo  Removing Start Menu "Voice Macros" group...
    rmdir /s /q "%VM%"
)
if exist "%STARTUP%" (
    echo  Removing the login shortcut...
    del /q "%STARTUP%"
)
if exist "%~dp0logs\installed.flag" (
    echo  Resetting the first-run flag...
    del /q "%~dp0logs\installed.flag"
)

echo.
echo  Done. VoiceKit has been unregistered from this machine.
echo  You can delete this folder now. To reinstall later, run your installer
echo  again (Install-VoiceKit.cmd for the bundled package, or Setup.bat from source).
echo.
pause
goto :eof

:cancel
echo.
echo  Cancelled - nothing was changed.
pause
