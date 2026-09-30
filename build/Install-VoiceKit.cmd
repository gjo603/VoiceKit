@echo off
setlocal enableextensions
rem ============================================================
rem  VoiceKit installer (ships INSIDE VoiceKit-Setup.zip).
rem  Copies VoiceKit to a permanent per-user folder and starts it.
rem  Self-contained: the bundled AutoHotkey64.exe means nothing
rem  needs to be preinstalled (no winget, no admin).
rem
rem  Advanced/testing env vars:
rem    VK_TARGET   install somewhere other than the default
rem    VK_NOLAUNCH install without starting VoiceKit
rem ============================================================
set "SRC=%~dp0"
if "%SRC:~-1%"=="\" set "SRC=%SRC:~0,-1%"
if defined VK_TARGET (set "TARGET=%VK_TARGET%") else set "TARGET=%LOCALAPPDATA%\Programs\VoiceKit"
rem Pass the path to PowerShell via the environment (not interpolated into the
rem script text) so a target containing a space OR an apostrophe (C:\Users\O'Brien)
rem can't break the quoting and silently no-op the hardening below.
set "VK_T=%TARGET%"

echo.
echo   VoiceKit installer
echo   From: %SRC%
echo   To:   %TARGET%
echo.

rem Release ONLY VoiceKit's own interpreter (the master, any running loop, and
rem Workflow Studio all run from %TARGET%\AutoHotkey64.exe) so unrelated
rem AutoHotkey scripts the user runs are left alone. A blanket
rem "taskkill /im AutoHotkey64.exe" would kill those too.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Process -Name AutoHotkey64 -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -like ($env:VK_T + '\*') } catch { $false } } | Stop-Process -Force -ErrorAction SilentlyContinue" >nul 2>&1

if not exist "%TARGET%" mkdir "%TARGET%" 2>nul
rem Additive copy (keeps any automations the user already made); never copies
rem this installer or the legacy Setup.bat into the install.
rem USER STATE: the snippet file, the hotkey include manifest and the
rem bridge-key registry are the user's own. The package ships only their
rem defaults (*.default.*); VoiceKit makes the live copies on first start
rem and adds any line a newer version ships (SeedUserFiles in _Common.ahk),
rem so an upgrade gets new shipped hotkeys without losing a snippet or a
rem registration. The live names are still excluded here (a package built
rem from an older tree carried them), and this copy never purges: no /MIR,
rem no /PURGE, so nothing the user made is ever removed.
set "XFILES="Install-VoiceKit.cmd" "Setup.bat" "Snippets.ahk" "_index.ahk" "bridge-map.txt""
robocopy "%SRC%" "%TARGET%" /E /XF %XFILES% /NFL /NDL /NJH /NJS /NP >nul
set "RC=%ERRORLEVEL%"
if %RC% GEQ 8 goto :copyfail
if not exist "%TARGET%\VoiceKit.ahk" goto :missing
if not exist "%TARGET%\VoiceKitLauncher.ahk" goto :missing
if not exist "%TARGET%\AutoHotkey64.exe" goto :missing

rem Strip Mark-of-the-Web. If the zip was emailed / downloaded, every extracted
rem file (including the unsigned bundled exe) carries an internet-zone tag; the
rem first launch and every voice-launched macro would then trip a Windows
rem security-warning prompt. Unblock-File clears it before anything runs.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:VK_T -Recurse -File | Unblock-File" >nul 2>&1

if defined VK_NOLAUNCH goto :nolaunch

rem Start through the launcher, never VoiceKit.ahk directly: it load-checks
rem first and parks any module that won't compile, so a bad module can't
rem leave the machine with no hotkeys and no snippets at all.
echo   Starting VoiceKit...
start "" "%TARGET%\AutoHotkey64.exe" "%TARGET%\VoiceKitLauncher.ahk"
echo.
echo   Done. Turn on Voice Access, then say:  open voice kit
echo   (Give Windows a few seconds to index the new Start Menu entries.)
echo.
exit /b 0

:nolaunch
echo   Installed. Launch skipped because VK_NOLAUNCH is set.
exit /b 0

:copyfail
echo   Install FAILED while copying files.
pause
exit /b 1

:missing
echo   Install FAILED: expected files are missing after the copy.
pause
exit /b 1
