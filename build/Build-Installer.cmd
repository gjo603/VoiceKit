@echo off
rem Double-click to rebuild dist\VoiceKit-Setup.zip (the installer to send).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Installer.ps1"
echo.
pause
