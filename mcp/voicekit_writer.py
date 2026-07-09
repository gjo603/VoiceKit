"""VoiceKit write-side port.

Reproduces, in pure Python, exactly what VoiceKit's AutoHotkey generators
(`macros\\NewAutomation.ahk`, `macros\\WorkflowStudio.ahk`) write to disk, so
an MCP server can create the same automations non-interactively.

This module has NO MCP dependency on purpose: the conformance test imports it
directly and feeds its output through the real AutoHotkey engine to prove the
bytes match. Keep every format function in sync with its AHK source (named in
the docstrings); the conformance test is what enforces that.
"""

from __future__ import annotations

import os
import re
import subprocess
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# Locations (self-locating; overridable by env for tests / odd installs)
# ---------------------------------------------------------------------------
REPO_ROOT = Path(os.environ.get("VOICEKIT_ROOT", Path(__file__).resolve().parent.parent))
AHK_EXE = os.environ.get(
    "VOICEKIT_AHK",
    os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"),
                 "AutoHotkey", "v2", "AutoHotkey64.exe"),
)
VOICEKIT_AHK = REPO_ROOT / "VoiceKit.ahk"
VOICE_MACROS = Path(os.environ.get(
    "VOICEKIT_STARTMENU",
    os.path.join(os.environ.get("APPDATA", ""), "Microsoft", "Windows",
                 "Start Menu", "Programs", "Voice Macros"),
))

# Bridge-key pool from NewAutomation.ahk AllocateBridgeKey — E,N,R,X excluded.
BRIDGE_POOL = "ABCDFGHIJKLMOPQSTUVWYZ0123456789"

# Step types from lib\Workflow.ahk WfRunStep.
STEP_TYPES = ("run", "focus", "waitwin", "wait", "text", "keys",
              "click", "dblclick", "rclick", "move", "close",
              # Optional branching (engine executes these; recorder never emits them).
              # if|<window>|<element>|<condType> where condType is one of
              # winexists / winnotexists / elementexists / elementnotexists;
              # paired with "else" (optional) and "endif".
              "if", "else", "endif")

# Marker string that identifies a generated workflow stub (lib guards check it).
STUDIO_MARKER = "Workflow Studio"


class VoiceKitError(Exception):
    """A user-facing problem (bad name, collision, validation failure)."""


# ---------------------------------------------------------------------------
# Naming / encoding — byte-for-byte ports of the AHK helpers
# ---------------------------------------------------------------------------
def _title(s: str) -> str:
    """AHK StrTitle: capitalize the first letter of each SPACE-separated word,
    lowercase the rest. Word boundary is space only (NOT digits) — verified:
    'open2tabs' -> 'Open2tabs'. (Python str.title() differs on digits.)"""
    return " ".join(w[:1].upper() + w[1:].lower() for w in s.split(" "))


def clean_phrase(raw: str) -> str:
    """lib\\_Common.ahk CleanPhrase: strip all but [A-Za-z0-9 ], collapse
    whitespace, Title Case."""
    p = re.sub(r"[^A-Za-z0-9 ]", "", raw.strip())
    p = re.sub(r"\s+", " ", p)
    return _title(p)


def to_base(phrase: str) -> str:
    """Filename base = phrase with spaces removed (NewAutomation / SaveWorkflow)."""
    return phrase.replace(" ", "")


def is_reserved(base: str) -> bool:
    """lib\\_Common.ahk IsReservedName — Windows device names (case-insensitive)."""
    return bool(re.match(r"(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", base))


def space_out(base: str) -> str:
    """SpaceOut: re-insert a space between a lowercase/digit and a following
    uppercase. 'OpenPublicUserFolder' -> 'Open Public User Folder'."""
    return re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", base).strip()


def wf_encode(s: str) -> str:
    """lib\\Workflow.ahk WfEncode — order-sensitive: % first, then | CR LF."""
    s = s.replace("%", "%25")
    s = s.replace("|", "%7C")
    s = s.replace("\r", "%0D")
    s = s.replace("\n", "%0A")
    return s


def wf_decode(s: str) -> str:
    """lib\\Workflow.ahk WfDecode — reverse order: LF CR | then % last."""
    s = s.replace("%0A", "\n")
    s = s.replace("%0D", "\r")
    s = s.replace("%7C", "|")
    s = s.replace("%25", "%")
    return s


def allocate_bridge_key() -> str | None:
    """NewAutomation.ahk AllocateBridgeKey: first pool key whose literal
    'Ctrl+Alt+Shift+<K>|' is absent from bridge-map.txt. None if exhausted."""
    mapfile = REPO_ROOT / "bridge-map.txt"
    used = mapfile.read_text(encoding="utf-8-sig", errors="replace") if mapfile.exists() else ""
    for k in BRIDGE_POOL:
        if f"Ctrl+Alt+Shift+{k}|" not in used:
            return k
    return None


# ---------------------------------------------------------------------------
# File I/O — reproduce AHK's exact bytes (BOM on create, LF endings)
# ---------------------------------------------------------------------------
def _write_new(path: Path, content: str) -> None:
    """Create a file the way AHK FileOpen(.., 'w', 'UTF-8') does: UTF-8 BOM,
    LF line endings (newline='' stops Python translating \\n to \\r\\n)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        f.write(content)


def _append(path: Path, text: str) -> None:
    """Append like AHK FileAppend to an existing file: no BOM, LF preserved."""
    with open(path, "a", encoding="utf-8", newline="") as f:
        f.write(text)


def _today() -> str:
    return datetime.now().strftime("%Y-%m-%d")


def log(text: str) -> None:
    """lib\\_Common.ahk Log — append 'YYYY-MM-DD HH:mm | <text>' to
    logs\\created.log (BOM only when the file is first created)."""
    logs = REPO_ROOT / "logs"
    logs.mkdir(exist_ok=True)
    line = datetime.now().strftime("%Y-%m-%d %H:%M") + " | " + text + "\n"
    p = logs / "created.log"
    if p.exists():
        _append(p, line)
    else:
        _write_new(p, line)


def _read_template(name: str) -> str:
    """Read a template, normalizing to LF regardless of the checkout's endings
    (.gitattributes may make it CRLF on a fresh clone)."""
    p = REPO_ROOT / "templates" / name
    return p.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")


# ---------------------------------------------------------------------------
# Windows shortcut + AHK process helpers (PowerShell/subprocess, no pywin32)
# ---------------------------------------------------------------------------
def _ps_quote(s: str) -> str:
    return "'" + str(s).replace("'", "''") + "'"


def _run_powershell(command: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
        capture_output=True, text=True, check=check,
    )


def make_shortcut(link: str, ahk_file: str, workdir: str | None = None,
                  args: str | None = None) -> None:
    """lib\\_Common.ahk MakeAhkShortcut: a .lnk whose Target is the interpreter
    and whose Arguments is the quoted script path (association-proof). Extra
    `args` are appended after the script path (already quoted by the caller)."""
    if workdir is None:
        workdir = os.path.dirname(ahk_file)
    arguments = chr(34) + ahk_file + chr(34)
    if args:
        arguments += " " + args
    Path(link).parent.mkdir(parents=True, exist_ok=True)
    cmd = (
        "$ws=New-Object -ComObject WScript.Shell;"
        f"$s=$ws.CreateShortcut({_ps_quote(link)});"
        f"$s.TargetPath={_ps_quote(AHK_EXE)};"
        f"$s.Arguments={_ps_quote(arguments)};"
        f"$s.WorkingDirectory={_ps_quote(workdir)};"
        "$s.Save()"
    )
    _run_powershell(cmd)


def make_loop_shortcut(base: str, disp: str) -> str:
    """lib\\_Common.ahk MakeLoopShortcut: a 'loop <disp>' entry that runs the
    workflow <base> repeatedly via lib\\LoopRunner.ahk. Voice: 'open loop <disp>'."""
    _ensure_voice_dir()
    loop_runner = REPO_ROOT / "lib" / "LoopRunner.ahk"
    link = VOICE_MACROS / f"loop {disp}.lnk"
    make_shortcut(str(link), str(loop_runner), str(REPO_ROOT), chr(34) + base + chr(34))
    return str(link)


def validate_ahk(path: str) -> tuple[bool, str]:
    """Load-check a script with AutoHotkey /validate. Returns (ok, error_text)."""
    r = subprocess.run(
        [AHK_EXE, "/ErrorStdOut", "/validate", path],
        capture_output=True, text=True, timeout=30,
    )
    return r.returncode == 0, (r.stdout or r.stderr or "").strip()


def voicekit_running() -> bool:
    """True if the resident VoiceKit master is running (matched by its command
    line, so unrelated AutoHotkey scripts are ignored)."""
    cmd = ("Get-CimInstance Win32_Process | Where-Object { "
           "$_.Name -eq 'AutoHotkey64.exe' -and $_.CommandLine -like '*VoiceKit.ahk*' "
           "} | Select-Object -First 1 | ForEach-Object { $_.ProcessId }")
    try:
        r = _run_powershell(cmd, check=False)
        return bool(r.stdout.strip())
    except Exception:
        return False


def reload_voicekit() -> bool:
    """Reload the master (so a new snippet/hotkey goes live) by launching it
    again — #SingleInstance Force replaces the running instance. Only acts if
    VoiceKit is already running, to avoid unexpectedly starting the tray app."""
    if not voicekit_running():
        return False
    subprocess.Popen([AHK_EXE, str(VOICEKIT_AHK)])
    return True


def _ensure_voice_dir() -> None:
    VOICE_MACROS.mkdir(parents=True, exist_ok=True)


def _require_name(name: str) -> tuple[str, str]:
    phrase = clean_phrase(name)
    base = to_base(phrase)
    if not base or is_reserved(base):
        raise VoiceKitError(
            f"'{name}' isn't a usable name (empty after cleanup, or a reserved "
            f"Windows device name). Pick another.")
    return phrase, base


# ---------------------------------------------------------------------------
# Content builders
# ---------------------------------------------------------------------------
def _launch_content(phrase: str, ahk_body: str | None) -> str:
    if ahk_body is None:
        tpl = _read_template("launch-template.ahk")
        return tpl.replace("{{PHRASE}}", phrase).replace("{{DATE}}", _today())
    return (
        "#Requires AutoHotkey v2.0\n"
        "#SingleInstance Force\n"
        "; ============================================================\n"
        f";  {phrase}   (created {_today()}, via MCP)\n"
        f';  Trigger by voice:  "open {phrase}"\n'
        ";  Runs top to bottom, then exits.\n"
        "; ============================================================\n"
        '#Include "%A_ScriptDir%\\..\\lib\\_Common.ahk"\n'
        "\n"
        + ahk_body.strip("\n") + "\n"
    )


def _indent_body(ahk_body: str) -> str:
    lines = ahk_body.strip("\n").split("\n")
    return "\n".join(("    " + ln) if ln.strip() else "" for ln in lines)


def _hotkey_content(phrase: str, key: str, ahk_body: str | None) -> str:
    if ahk_body is None:
        tpl = _read_template("hotkey-template.ahk")
        return (tpl.replace("{{PHRASE}}", phrase)
                   .replace("{{KEY}}", key)
                   .replace("{{DATE}}", _today()))
    return (
        "#Requires AutoHotkey v2.0\n"
        "; ============================================================\n"
        f";  {phrase}   (created {_today()}, via MCP)\n"
        ";  Loaded by VoiceKit.ahk — do not run this file directly.\n"
        f";  Trigger key:  Ctrl+Alt+Shift+{key}\n"
        f';  Voice pairing: say "show voice shortcuts" -> new shortcut ->\n'
        f";    When I say: {phrase}  ->  Press keys  ->  Ctrl+Alt+Shift+{key}\n"
        "; ============================================================\n"
        "\n"
        f"^!+{key}:: {{\n"
        f"{_indent_body(ahk_body)}\n"
        "}\n"
    )


def workflow_stub(phrase: str, base: str, date: str | None = None) -> str:
    """The generated macros\\<Base>.ahk stub. Mirrors WorkflowStudio.ahk
    SaveWorkflow verbatim, including the 'Workflow Studio' marker that the
    overwrite/delete guards look for."""
    d = date or _today()
    return (
        "#Requires AutoHotkey v2.0\n"
        "#SingleInstance Force\n"
        "; ============================================================\n"
        f";  {phrase}   (workflow, saved {d})\n"
        f';  Trigger by voice:  "open {phrase}"\n'
        ";\n"
        f";  Generated by {STUDIO_MARKER} — don't edit steps here.\n"
        f';  Edit by voice:  "open workflow studio"  ->  pick "{phrase}"\n'
        f";  Steps live in:  workflows\\{base}.steps.txt\n"
        "; ============================================================\n"
        '#Include "%A_ScriptDir%\\..\\lib\\_Common.ahk"\n'
        '#Include "%A_ScriptDir%\\..\\lib\\Workflow.ahk"\n'
        f'RunWorkflow(A_ScriptDir "\\..\\workflows\\{base}.steps.txt")\n'
    )


def steps_to_text(phrase: str, steps: list) -> str:
    """Serialize steps to the .steps.txt format (header + type|encA|encB|encC)."""
    out = f"; {phrase} — VoiceKit workflow. Edit it by saying: open workflow studio\n"
    for s in steps:
        t = s[0]
        a = wf_encode(s[1] if len(s) > 1 and s[1] is not None else "")
        b = wf_encode(s[2] if len(s) > 2 and s[2] is not None else "")
        c = wf_encode(s[3] if len(s) > 3 and s[3] is not None else "")
        out += f"{t}|{a}|{b}|{c}\n"
    return out


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------
def create_launch_macro(name: str, ahk_body: str | None = None) -> dict:
    phrase, base = _require_name(name)
    macro = REPO_ROOT / "macros" / f"{base}.ahk"
    if macro.exists():
        raise VoiceKitError(f"A macro named '{base}' already exists. Pick another name.")
    _write_new(macro, _launch_content(phrase, ahk_body))
    ok, err = validate_ahk(str(macro))
    if not ok:
        macro.unlink(missing_ok=True)
        raise VoiceKitError(f"The generated macro failed to load, so nothing was kept:\n{err}")
    _ensure_voice_dir()
    link = VOICE_MACROS / f"{phrase}.lnk"
    make_shortcut(str(link), str(macro))
    log(f"launch | {phrase} | macros\\{base}.ahk")
    return {"type": "launch_macro", "phrase": phrase, "file": str(macro),
            "shortcut": str(link), "voice_phrase": f"open {phrase}", "reloaded": False}


def create_hotkey_module(name: str, ahk_body: str | None = None) -> dict:
    phrase, base = _require_name(name)
    module = REPO_ROOT / "hotkeys" / f"{base}.ahk"
    if module.exists():
        raise VoiceKitError(f"A module named '{base}' already exists. Pick another name.")
    key = allocate_bridge_key()
    if key is None:
        raise VoiceKitError("No free bridge keys left (all 32 used). "
                            "Retire one in bridge-map.txt first.")
    _write_new(module, _hotkey_content(phrase, key, ahk_body))
    ok, err = validate_ahk(str(module))
    if not ok:
        module.unlink(missing_ok=True)
        raise VoiceKitError(f"The generated module failed to load, so nothing was kept:\n{err}")
    # Wire it in (leading \n, no trailing NL) and register the pairing.
    _append(REPO_ROOT / "hotkeys" / "_index.ahk",
            f'\n#Include "%A_ScriptDir%\\hotkeys\\{base}.ahk"')
    _append(REPO_ROOT / "bridge-map.txt",
            f"Ctrl+Alt+Shift+{key}|{phrase}|hotkeys\\{base}.ahk|{_today()}\n")
    reloaded = reload_voicekit()
    log(f"hotkey | {phrase} | Ctrl+Alt+Shift+{key} | hotkeys\\{base}.ahk")
    return {
        "type": "hotkey_module", "phrase": phrase, "file": str(module),
        "bridge_key": f"Ctrl+Alt+Shift+{key}", "reloaded": reloaded,
        "voice_pairing": [
            'Say: "show voice shortcuts"',
            "Create a new shortcut -> When I say: " + phrase,
            f"Action: Press keys -> Ctrl + Alt + Shift + {key}",
        ],
        "note": ("The hotkey is live now."
                 if reloaded else
                 "VoiceKit isn't running — start it (Setup.bat / VoiceKit.ahk) to activate the hotkey."),
    }


def create_snippet(abbrev: str, expansion: str) -> dict:
    abbrev = re.sub(r"\s", "", abbrev.strip())
    if not abbrev or ":" in abbrev:
        raise VoiceKitError("The abbreviation can't be empty or contain a colon (:) — "
                            "a colon breaks the hotstring format and would disable every snippet.")
    snip = REPO_ROOT / "hotkeys" / "Snippets.ahk"
    existing = snip.read_text(encoding="utf-8-sig", errors="replace") if snip.exists() else ""
    if f":{abbrev}::" in existing:
        raise VoiceKitError(f"A snippet for '{abbrev}' already exists. Delete it first to change it.")
    exp = expansion.replace("`", "``")          # escape literal backticks (AHK escape char)
    exp = exp.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "`n")  # multi-line -> `n
    orig_size = snip.stat().st_size if snip.exists() else 0
    _append(snip, f"\n:*:{abbrev}::{exp}")
    ok, err = validate_ahk(str(snip))
    if not ok:
        os.truncate(snip, orig_size)            # roll back the appended line
        raise VoiceKitError(f"That snippet would break Snippets.ahk, so it was not kept:\n{err}")
    reloaded = reload_voicekit()
    log(f"snippet | {abbrev}")
    return {"type": "snippet", "abbrev": abbrev, "file": str(snip), "reloaded": reloaded,
            "note": ("Loaded now." if reloaded else
                     "VoiceKit isn't running — start it to activate the snippet.")}


def create_workflow(name: str, steps: list) -> dict:
    phrase, base = _require_name(name)
    if not steps:
        raise VoiceKitError("A workflow needs at least one step.")
    valid_conds = ("winexists", "winnotexists", "elementexists", "elementnotexists")
    depth = 0
    for i, s in enumerate(steps):
        if not s or s[0] not in STEP_TYPES:
            raise VoiceKitError(f"Step {i + 1}: unknown type '{s[0] if s else ''}'. "
                                f"Valid types: {', '.join(STEP_TYPES)}.")
        # if|window|element|condType — reject a blank window or bad condType at
        # create time (the engine would otherwise mis-branch or stop mid-run).
        if s[0] == "if":
            if not (len(s) >= 2 and str(s[1]).strip()):
                raise VoiceKitError(f"Step {i + 1}: an 'if' step needs a window to check.")
            cond = s[3] if len(s) >= 4 else ""
            if cond not in valid_conds:
                raise VoiceKitError(f"Step {i + 1}: 'if' condition must be one of "
                                    f"{', '.join(valid_conds)} (got '{cond}').")
            depth += 1
        elif s[0] == "else":
            if depth == 0:
                raise VoiceKitError(f"Step {i + 1}: 'else' has no matching 'if' above it.")
        elif s[0] == "endif":
            if depth == 0:
                raise VoiceKitError(f"Step {i + 1}: 'endif' has no matching 'if' above it.")
            depth -= 1
    if depth > 0:
        raise VoiceKitError(f"{depth} 'if' step(s) are missing a matching 'endif'.")
    macro = REPO_ROOT / "macros" / f"{base}.ahk"
    if macro.exists():
        txt = macro.read_text(encoding="utf-8-sig", errors="replace")
        if STUDIO_MARKER not in txt:
            raise VoiceKitError(f"A hand-written macro named '{base}' already exists. "
                                f"Pick another name.")
    steps_file = REPO_ROOT / "workflows" / f"{base}.steps.txt"
    _write_new(steps_file, steps_to_text(phrase, steps))
    _write_new(macro, workflow_stub(phrase, base))
    ok, err = validate_ahk(str(macro))
    if not ok:
        macro.unlink(missing_ok=True)
        steps_file.unlink(missing_ok=True)
        raise VoiceKitError(f"The generated workflow stub failed to load, so nothing was kept:\n{err}")
    _ensure_voice_dir()
    disp = space_out(base)
    link = VOICE_MACROS / f"{disp}.lnk"
    if not link.exists():
        make_shortcut(str(link), str(macro))
    loop_link = make_loop_shortcut(base, disp)   # companion 'loop <disp>' entry (repeats until stopped)
    log(f"workflow | {phrase} | workflows\\{base}.steps.txt")
    return {"type": "workflow", "phrase": disp, "steps_file": str(steps_file),
            "stub": str(macro), "shortcut": str(link), "loop_shortcut": loop_link,
            "step_count": len(steps), "voice_phrase": f"open {disp}",
            "loop_voice_phrase": f"open loop {disp}", "reloaded": False}


# ---------------------------------------------------------------------------
# Read / list
# ---------------------------------------------------------------------------
_BUILTINS = {"NewAutomation", "WorkflowStudio", "VoiceKitHelp"}


def list_automations() -> dict:
    macros_dir = REPO_ROOT / "macros"
    launch, workflows = [], []
    for f in sorted(macros_dir.glob("*.ahk")):
        base = f.stem
        txt = f.read_text(encoding="utf-8-sig", errors="replace")
        entry = {"name": space_out(base), "base": base, "file": str(f),
                 "builtin": base in _BUILTINS}
        if STUDIO_MARKER in txt:
            workflows.append(entry)
        else:
            launch.append(entry)

    hotkeys = []
    for f in sorted((REPO_ROOT / "hotkeys").glob("*.ahk")):
        if f.stem in ("_index", "Snippets"):
            continue
        hotkeys.append({"name": space_out(f.stem), "base": f.stem, "file": str(f)})

    snippets = []
    snip = REPO_ROOT / "hotkeys" / "Snippets.ahk"
    if snip.exists():
        for line in snip.read_text(encoding="utf-8-sig", errors="replace").splitlines():
            m = re.match(r"^:[^:]*:([^:]+)::", line.strip())
            if m:
                snippets.append(m.group(1))

    return {"launch_macros": launch, "workflows": workflows,
            "hotkey_modules": hotkeys, "snippets": snippets}


def read_workflow(name: str) -> dict:
    base = to_base(clean_phrase(name))
    steps_file = REPO_ROOT / "workflows" / f"{base}.steps.txt"
    if not steps_file.exists():
        raise VoiceKitError(f"No workflow named '{base}' (looked for {steps_file.name}).")
    steps = []
    for line in steps_file.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        parts = line.split("|")
        while len(parts) < 4:
            parts.append("")
        steps.append({"type": parts[0],
                      "a": wf_decode(parts[1]),
                      "b": wf_decode(parts[2]),
                      "c": wf_decode(parts[3])})
    return {"base": base, "name": space_out(base), "steps": steps}


def get_bridge_map() -> dict:
    mapfile = REPO_ROOT / "bridge-map.txt"
    entries = []
    if mapfile.exists():
        for line in mapfile.read_text(encoding="utf-8-sig", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith(";"):
                continue
            parts = line.split("|")
            if len(parts) >= 3:
                entries.append({"combo": parts[0], "phrase": parts[1], "file": parts[2],
                                "created": parts[3] if len(parts) > 3 else ""})
    used = {e["combo"].rsplit("+", 1)[-1] for e in entries}
    free = [k for k in BRIDGE_POOL if k not in used]
    return {"entries": entries, "free_keys": free, "reserved_keys": ["E", "N", "R", "X"]}


# ---------------------------------------------------------------------------
# Run / delete
# ---------------------------------------------------------------------------
def run_workflow(name: str) -> dict:
    base = to_base(clean_phrase(name))
    macro = REPO_ROOT / "macros" / f"{base}.ahk"
    if not macro.exists():
        raise VoiceKitError(f"No macro named '{base}' to run.")
    subprocess.Popen([AHK_EXE, str(macro)])
    return {"launched": space_out(base), "file": str(macro),
            "note": "Running on the desktop now; a failing step shows a popup naming it."}


def _remove_matching_lines(path: Path, predicate) -> int:
    """Rewrite a file (no BOM, LF) dropping lines for which predicate(line) is
    True. Returns the number removed."""
    if not path.exists():
        return 0
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    kept, removed = [], 0
    for line in text.split("\n"):
        if predicate(line):
            removed += 1
        else:
            kept.append(line)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(kept))
    return removed


def delete_automation(name: str, type: str) -> dict:
    """Remove an automation and its artifacts. `type` is one of
    launch_macro | workflow | hotkey_module | snippet."""
    result = {"type": type, "removed": []}

    if type == "snippet":
        abbrev = re.sub(r"\s", "", name.strip())
        snip = REPO_ROOT / "hotkeys" / "Snippets.ahk"
        n = _remove_matching_lines(snip, lambda ln: re.match(rf"^:[^:]*:{re.escape(abbrev)}::", ln.strip()) is not None)
        if not n:
            raise VoiceKitError(f"No snippet '{abbrev}' found.")
        result["removed"].append(f"snippet {abbrev}")
        result["reloaded"] = reload_voicekit()
        log(f"deleted snippet | {abbrev}")
        return result

    base = to_base(clean_phrase(name))

    if type == "hotkey_module":
        module = REPO_ROOT / "hotkeys" / f"{base}.ahk"
        if module.exists():
            module.unlink()
            result["removed"].append(str(module))
        _remove_matching_lines(REPO_ROOT / "hotkeys" / "_index.ahk",
                               lambda ln: f"hotkeys\\{base}.ahk" in ln)
        _remove_matching_lines(REPO_ROOT / "bridge-map.txt",
                               lambda ln: f"|hotkeys\\{base}.ahk|" in ln)
        result["reloaded"] = reload_voicekit()
        log(f"deleted hotkey | {base}")
        return result

    if type == "workflow":
        steps_file = REPO_ROOT / "workflows" / f"{base}.steps.txt"
        if steps_file.exists():
            steps_file.unlink()
            result["removed"].append(str(steps_file))
        macro = REPO_ROOT / "macros" / f"{base}.ahk"
        if macro.exists() and STUDIO_MARKER in macro.read_text(encoding="utf-8-sig", errors="replace"):
            macro.unlink()
            result["removed"].append(str(macro))
        disp = space_out(base)
        _delete_lnk(disp, result)
        _delete_lnk(f"loop {disp}", result)      # companion loop entry
        log(f"deleted workflow | {disp}")
        return result

    if type == "launch_macro":
        macro = REPO_ROOT / "macros" / f"{base}.ahk"
        if not macro.exists():
            raise VoiceKitError(f"No launch macro '{base}' found.")
        if STUDIO_MARKER in macro.read_text(encoding="utf-8-sig", errors="replace"):
            raise VoiceKitError(f"'{base}' is a workflow, not a launch macro — "
                                f"delete it with type='workflow'.")
        macro.unlink()
        result["removed"].append(str(macro))
        # Launch shortcut may be named by phrase or SpaceOut(base); try both.
        for nm in {clean_phrase(name), space_out(base)}:
            _delete_lnk(nm, result)
        log(f"deleted launch | {base}")
        return result

    raise VoiceKitError(f"Unknown automation type '{type}'.")


def _delete_lnk(display_name: str, result: dict) -> None:
    lnk = VOICE_MACROS / f"{display_name}.lnk"
    if lnk.exists():
        lnk.unlink()
        result["removed"].append(str(lnk))
