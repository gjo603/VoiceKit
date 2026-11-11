@echo off
setlocal enableextensions

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
rem Handed to PowerShell through the environment, never spliced into its
rem command text, so a folder with a space or an apostrophe can't break it.
set "VK_HERE=%HERE%"

echo.
echo  VoiceKit Uninstaller
echo  ====================
echo.
echo  This stops VoiceKit and removes its Start Menu entries, its login
echo  shortcut and its entry in Windows' installed-apps list.
echo.
choice /C YN /M "  Uninstall VoiceKit"
if errorlevel 2 goto :cancel

echo.
echo  Stopping VoiceKit...
rem Everything AutoHotkey is running out of THIS folder: the tray app, its
rem watchdog (which would otherwise start VoiceKit again within seconds),
rem any loop, hotkey body or open VoiceKit window. Other AutoHotkey scripts
rem on the machine are left alone.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$h = $env:VK_HERE.ToLower() + '\'; Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'AutoHotkey*.exe' -and $_.CommandLine -and $_.CommandLine.ToLower().Contains($h) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

set "VM=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Voice Macros"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\VoiceKit.lnk"

if exist "%VM%" (
    echo  Removing the Start Menu "Voice Macros" group...
    rmdir /s /q "%VM%"
)
if exist "%STARTUP%" (
    echo  Removing the login shortcut...
    del /q "%STARTUP%"
)
if exist "%HERE%\logs\installed.flag" del /q "%HERE%\logs\installed.flag"
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\VoiceKit" /f >nul 2>&1

echo.
echo  VoiceKit is uninstalled. Its folder is still here:
echo    %HERE%
echo  It holds the automations, snippets and settings you made.
echo.
rem A source checkout is somebody's working copy: never offer to delete it.
if exist "%HERE%\.git" goto :keep
choice /C YN /M "  Delete that folder and everything in it too"
if errorlevel 2 goto :keep

rem The folder's own Python helpers (the optional Claude connection, a
rem module's tools) would hold files open and leave the delete half done.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$h = $env:VK_HERE.ToLower() + '\'; Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'python*.exe' -and $_.ExecutablePath -and $_.ExecutablePath.ToLower().StartsWith($h) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
echo.
echo  Deleting the folder. This window will close.
rem A batch file can't delete the folder it is running from, so a detached
rem command does it a moment after this one has ended.
cd /d "%TEMP%"
start "" /min "%ComSpec%" /c "ping -n 3 127.0.0.1 >nul & rmdir /s /q "%HERE%""
exit /b 0

:keep
echo.
echo  Kept. Delete the folder yourself whenever you like; to reinstall,
echo  run the VoiceKit installer again - what you made will still be there.
echo  (Voice Access shortcuts you paired by hand are removed in Voice Access.)
echo.
pause
exit /b 0

:cancel
echo.
echo  Cancelled - nothing was changed.
pause
