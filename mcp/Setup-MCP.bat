@echo off
setlocal enableextensions
cd /d "%~dp0"

echo.
echo  Connect VoiceKit to Claude
echo  ==========================
echo.
echo  This lets Claude (Desktop or Claude Code) build and run VoiceKit
echo  automations for you. It needs Python 3.10 or newer.
echo.

rem Find a real Python 3.10+: "python" first, then the "py" launcher. (The
rem Microsoft Store stub answers to "python" but fails the version test.)
set "PY="
python -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" >nul 2>nul
if not errorlevel 1 set "PY=python"
if defined PY goto :havepy
py -3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" >nul 2>nul
if not errorlevel 1 set "PY=py -3"
if defined PY goto :havepy

echo  Python 3.10+ was not found on this PC.
where winget >nul 2>nul
if errorlevel 1 goto :nopy
choice /C YN /M "  Install Python now (through winget)"
if errorlevel 2 goto :nopy
winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
echo.
echo  Python is installed. Close this window and run Setup-MCP.bat again
echo  (a new window is needed for Windows to see it).
pause
exit /b 1

:nopy
echo  Install it from https://www.python.org/downloads/ (tick "Add python.exe
echo  to PATH" in its installer), then run this again.
pause
exit /b 1

:havepy
if exist ".venv\Scripts\python.exe" goto :install
echo  Setting up (one time)...
%PY% -m venv .venv
if not exist ".venv\Scripts\python.exe" ( echo  Could not create the Python environment. & pause & exit /b 1 )

:install
echo  Installing what the server needs...
".venv\Scripts\python.exe" -m pip install --quiet --disable-pip-version-check -r requirements.txt
if errorlevel 1 ( echo  The install failed - check your internet connection and run this again. & pause & exit /b 1 )
".venv\Scripts\python.exe" -c "import fastmcp, openpyxl, voicekit_writer"
if errorlevel 1 ( echo  The server did not pass its self-check. & pause & exit /b 1 )

echo.
echo  Connecting to Claude...
echo.
".venv\Scripts\python.exe" connect_claude.py

echo.
echo  Done. Then just ask Claude, for example:
echo    "Make a VoiceKit workflow that opens Notepad and types my address."
echo.
echo  Using another MCP client? Point it at:
echo    command : %~dp0.venv\Scripts\python.exe
echo    args    : %~dp0server.py
echo.
pause
