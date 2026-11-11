@echo off
setlocal enableextensions
rem ============================================================
rem  bootstrap.cmd — the command the self-extracting VoiceKit-Setup.exe
rem  runs after it unpacks. It expands the bundled ZIP payload to a temp
rem  folder and hands off to the same Install-VoiceKit.cmd the ZIP uses,
rem  so both delivery paths share one tested installer.
rem ============================================================
set "TMPX=%TEMP%\VoiceKitExtract"
rmdir /s /q "%TMPX%" 2>nul
mkdir "%TMPX%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath '%~dp0VoiceKit-Setup.zip' -DestinationPath '%TMPX%' -Force -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 goto :xfail
if not exist "%TMPX%\Install-VoiceKit.cmd" goto :xfail
call "%TMPX%\Install-VoiceKit.cmd"
set "RC=%ERRORLEVEL%"
rem VoiceKit now runs from its installed folder, so the unpacked copy is spare.
rmdir /s /q "%TMPX%" 2>nul
exit /b %RC%

:xfail
echo   Install FAILED while extracting the payload.
pause
exit /b 1
