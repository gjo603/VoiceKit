"""Connect this VoiceKit install to Claude Desktop and Claude Code.

Run by Setup-MCP.bat after the virtual environment is ready (standard library
only, so it also runs on the base interpreter). It registers ONE server entry
named "voicekit" per client, pointing at this folder's .venv and server.py:

  * Claude Desktop: adds the entry to claude_desktop_config.json. The file is
    backed up beside itself first, every other setting in it is kept, and a
    file that isn't valid JSON is left untouched.
  * Claude Code: asks the `claude` command to add it for this user.

A client that already has this exact entry is left alone, so running the
setup again is safe. Exit code 0 = at least one client is connected.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PYTHON = HERE / ".venv" / "Scripts" / "python.exe"
SERVER = HERE / "server.py"
NAME = "voicekit"


def _same(a: str, b: Path) -> bool:
    try:
        return Path(a).resolve() == b.resolve()
    except (OSError, ValueError):
        return str(a).lower() == str(b).lower()


def _is_ours(spec) -> bool:
    """True when a server entry already runs this install's server.py with this venv."""
    if not isinstance(spec, dict):
        return False
    args = [a for a in (spec.get("args") or []) if isinstance(a, str)]
    return _same(str(spec.get("command") or ""), PYTHON) and any(_same(a, SERVER) for a in args)


def _read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def connect_desktop() -> str:
    """Returns 'connected', 'already', 'absent' (Claude Desktop isn't installed) or 'failed'."""
    appdata = os.environ.get("APPDATA", "")
    folder = Path(appdata) / "Claude" if appdata else None
    if not folder or not folder.is_dir():
        print("  Claude Desktop: not found on this PC - skipped.")
        return "absent"
    cfg = folder / "claude_desktop_config.json"
    data = {}
    if cfg.exists() and cfg.read_text(encoding="utf-8-sig").strip():
        try:
            data = _read_json(cfg)
        except (OSError, ValueError) as e:
            print(f"  Claude Desktop: couldn't read {cfg} ({e}).")
            print("                  Left it untouched - see mcp\\README.md to add VoiceKit by hand.")
            return "failed"
        if not isinstance(data, dict):
            print(f"  Claude Desktop: {cfg} isn't a settings object - left untouched.")
            return "failed"
    servers = data.get("mcpServers")
    if servers is None:
        servers = data["mcpServers"] = {}
    if not isinstance(servers, dict):
        print(f"  Claude Desktop: 'mcpServers' in {cfg} has an unexpected shape - left untouched.")
        return "failed"
    if _is_ours(servers.get(NAME)):
        print("  Claude Desktop: already connected.")
        return "already"
    try:
        if cfg.exists():
            backup = cfg.with_name(cfg.name + time.strftime(".before-voicekit-%Y%m%d-%H%M%S"))
            shutil.copy2(cfg, backup)
        servers[NAME] = {"command": str(PYTHON), "args": [str(SERVER)]}
        tmp = cfg.with_name(cfg.name + ".voicekit-tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, cfg)
    except OSError as e:
        print(f"  Claude Desktop: couldn't write {cfg} ({e}).")
        return "failed"
    print("  Claude Desktop: connected. Quit Claude Desktop completely (tray icon > Quit)")
    print("                  and open it again to see the VoiceKit tools.")
    return "connected"


def _code_already() -> bool:
    cfg = Path(os.environ.get("USERPROFILE", "") or Path.home()) / ".claude.json"
    try:
        data = _read_json(cfg)
    except (OSError, ValueError):
        return False
    servers = data.get("mcpServers") if isinstance(data, dict) else None
    return isinstance(servers, dict) and any(_is_ours(s) for s in servers.values())


def connect_code() -> str:
    """Returns 'connected', 'already', 'absent' (no `claude` command) or 'failed'."""
    if _code_already():
        print("  Claude Code:    already connected.")
        return "already"
    exe = shutil.which("claude")
    if not exe:
        print("  Claude Code:    not found on this PC - skipped.")
        return "absent"
    cmd = [exe, "mcp", "add", "--scope", "user", NAME, "--", str(PYTHON), str(SERVER)]
    try:
        # A .cmd shim (npm installs) needs the shell; the arguments are this
        # install's own paths, quoted by list2cmdline.
        shim = exe.lower().endswith((".cmd", ".bat"))
        r = subprocess.run(subprocess.list2cmdline(cmd) if shim else cmd, shell=shim,
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        print(f"  Claude Code:    couldn't run the claude command ({e}).")
        return "failed"
    if r.returncode != 0:
        why = (r.stderr or r.stdout or "").strip().splitlines()
        print("  Claude Code:    not connected" + (f" - {why[-1]}" if why else "."))
        print("                  To do it by hand, run:")
        print(f'                  claude mcp add {NAME} -- "{PYTHON}" "{SERVER}"')
        return "failed"
    print("  Claude Code:    connected. Start a new Claude Code session to use it.")
    return "connected"


def main() -> int:
    if not PYTHON.exists():
        print(f"  The virtual environment is missing ({PYTHON}). Run Setup-MCP.bat first.")
        return 1
    results = [connect_desktop(), connect_code()]
    if all(r == "absent" for r in results):
        print()
        print("  Neither Claude Desktop nor Claude Code was found. Install one, then run")
        print("  Setup-MCP.bat again - or see mcp\\README.md for other MCP clients.")
    return 0 if any(r in ("connected", "already") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
