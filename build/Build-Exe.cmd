@echo off
rem Double-click to rebuild the ZIP and ALSO wrap it into a single
rem dist\VoiceKit-Setup.exe (self-extractor). Needs an interactive desktop.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Installer.ps1" -Exe
echo.
pause
