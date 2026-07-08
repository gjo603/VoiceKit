@echo off
setlocal
cd /d "%~dp0"

echo.
echo  VoiceKit MCP server setup
echo  =========================
echo.

python --version >nul 2>nul
if errorlevel 1 (
    echo  Python is not on PATH. Install Python 3.10+ from https://python.org
    echo  (tick "Add python.exe to PATH"), then run this again.
    pause
    exit /b 1
)

echo  Creating a virtual environment in .venv ...
python -m venv .venv
call ".venv\Scripts\activate.bat"
echo  Installing FastMCP ...
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r requirements.txt
if errorlevel 1 ( echo  pip install failed. & pause & exit /b 1 )

echo  Verifying ...
python -c "import fastmcp, voicekit_writer; print('  fastmcp', fastmcp.__version__, 'OK')"

echo.
echo  Done. Register the server with your client(s):
echo.
echo  --- Claude Code (run this in a terminal) ---
echo     claude mcp add voicekit -- "%~dp0.venv\Scripts\python.exe" "%~dp0server.py"
echo.
echo  --- Claude Desktop ---
echo     Edit  %%APPDATA%%\Claude\claude_desktop_config.json  and add the
echo     "voicekit" block shown in mcp\README.md (use the paths printed above).
echo.
echo     command : %~dp0.venv\Scripts\python.exe
echo     args    : %~dp0server.py
echo.
pause
