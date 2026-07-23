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

# Bridge-key pool from lib\_Common.ahk BridgeKeyPool — E,N,R,X,H excluded
# (H is Workflow Studio's mark-hover key while recording).
# (Companion hotkeys — hotkeys\<Base>.hotkey.ahk, assigned in the Voice Kit
# home window — draw from the same pool via bridge-map.txt registration.)
BRIDGE_POOL = "ABCDFGIJKLMOPQSTUVWYZ0123456789"

# Step types from lib\Workflow.ahk WfRunStep.
STEP_TYPES = ("run", "focus", "waitwin", "wait", "text", "keys",
              "click", "dblclick", "rclick", "hover", "move", "close",
              # Optional branching (engine executes these; recorder never emits them).
              # if|<window>|<element>|<condType> where condType is one of
              # winexists / winnotexists / elementexists / elementnotexists;
              # paired with "else" (optional) and "endif".
              "if", "else", "endif")

# Marker string that identifies a generated workflow stub (lib guards check it).
STUDIO_MARKER = "Workflow Studio"

# Companion-hotkey module suffix from lib\_Common.ahk HotkeyCompanionRel:
# hotkeys\<Base>.hotkey.ahk is a keyboard trigger for macros\<Base>.ahk,
# assigned in the home window. The suffix doubles as the marker (scaffolded
# module names come from CleanPhrase and can never contain a dot).
COMPANION_SUFFIX = ".hotkey.ahk"


def _companion_rel(base: str) -> str:
    """Repo-relative bridge-map FILE field of <base>'s companion module."""
    return f"hotkeys\\{base}{COMPANION_SUFFIX}"


def _companion_parent(relfile: str) -> str:
    """Parent automation base for a bridge-map FILE field, or "" when the
    file isn't a companion module (mirrors _Common.ahk HotkeyCompanionParent)."""
    m = re.match(rf"(?i)^hotkeys\\(.+){re.escape(COMPANION_SUFFIX)}$", relfile)
    return m.group(1) if m else ""


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


def ahk_str_lit(s: str) -> str:
    """macros\\NewAutomation.ahk AhkStrLit: render a value as an AutoHotkey v2
    double-quoted string literal (backtick doubled, quote escaped, CR dropped,
    LF -> `n)."""
    s = s.replace("`", "``")
    s = s.replace('"', '`"')
    s = s.replace("\r", "")
    s = s.replace("\n", "`n")
    return '"' + s + '"'


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
    """Read a template PRESERVING its on-disk line endings. The AHK generators
    fill templates with FileRead + StrReplace + FileAppend (no EOL translation),
    so they emit whatever endings the template has on disk (CRLF on a normal
    .gitattributes checkout). To stay byte-identical the writer must do the same
    — do NOT normalize here. (An earlier version normalized to LF, so MCP-created
    template macros came out LF while GUI-created ones were CRLF.) Content built
    from Python string literals stays LF, matching AHK's backtick-n literals."""
    p = REPO_ROOT / "templates" / name
    with open(p, encoding="utf-8-sig", newline="") as f:
        return f.read()


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


def _ahk_script_running(script_name: str) -> bool:
    """True if OUR interpreter (basename of AHK_EXE — honors the VOICEKIT_AHK
    override, e.g. a UIA build) is running a script whose command line contains
    `\\<script_name>`. The pattern is anchored on the path separator so a user
    macro whose base merely ENDS in the name (RestartVoicekit.ahk vs
    \\VoiceKit.ahk) never matches. `script_name` is a fixed literal from our own
    code — never user input — so embedding it in the -like pattern is safe."""
    exe = os.path.basename(AHK_EXE).replace("'", "''")
    cmd = ("Get-CimInstance Win32_Process | Where-Object { "
           "$_.Name -eq '" + exe + "' -and $_.CommandLine -like '*\\" + script_name + "*' "
           "} | Select-Object -First 1 | ForEach-Object { $_.ProcessId }")
    try:
        r = _run_powershell(cmd, check=False)
        return bool(r.stdout.strip())
    except Exception:
        return False


def voicekit_running() -> bool:
    """True if the resident VoiceKit master is running."""
    return _ahk_script_running("VoiceKit.ahk")


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


def _opens_content(phrase: str, target: str) -> str:
    """NewAutomation.ahk NewOpenSomething: the no-code 'Open Something' macro.
    Keep the ';  Opens:  <target>' header line — the Voice Kit home window
    parses it for the row's detail text."""
    run_arg = f'"{target}"' if (" " in target and Path(target).exists()) else target
    return (
        "#Requires AutoHotkey v2.0\n"
        "#SingleInstance Force\n"
        "; ============================================================\n"
        f";  {phrase}   (created {_today()})\n"
        f';  Trigger by voice:  "open {phrase}"\n'
        f";  Opens:  {target}\n"
        ";\n"
        ";  Created by New Automation — no code needed. To add steps,\n"
        ";  edit below (building blocks: templates\\launch-template.ahk).\n"
        "; ============================================================\n"
        '#Include "%A_ScriptDir%\\..\\lib\\_Common.ahk"\n'
        f"Run({ahk_str_lit(run_arg)})\n"
    )


def _ai_action_content(phrase: str, base: str) -> str:
    """NewAutomation.ahk NewAIAction: fill templates\\ai-template.ahk."""
    tpl = _read_template("ai-template.ahk")
    return (tpl.replace("{{PHRASE}}", phrase)
               .replace("{{BASE}}", base)
               .replace("{{DATE}}", _today()))


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
def _require_free_lnk(disp: str) -> Path:
    """Refuse a voice phrase whose Start Menu entry already exists — creating it
    would silently hijack another automation's phrase (NewAutomation checks the
    same thing since the production review)."""
    _ensure_voice_dir()
    link = VOICE_MACROS / f"{disp}.lnk"
    if link.exists():
        raise VoiceKitError(
            f'The voice phrase "open {disp}" is already taken by another Start Menu '
            f"entry. Pick another name.")
    return link


def create_launch_macro(name: str, ahk_body: str | None = None,
                        opens: str | None = None) -> dict:
    """A standalone macro + Start Menu entry. Exactly one content source:
    `opens` (the no-code 'Open Something' generator — app/file/folder/URL) or
    `ahk_body` (custom AHK v2 code), or neither (placeholder template).
    The .lnk is named SpaceOut(base) — the same name listing, Delete, and
    first-run reinstall reconstruct — so they never drift (phrases with digits
    don't round-trip otherwise)."""
    if ahk_body and opens:
        raise VoiceKitError("Give either 'opens' or 'ahk_body', not both.")
    if opens is not None:
        opens = opens.strip()
        if not opens:
            raise VoiceKitError("'opens' is empty — give an app, file, folder, or https:// URL "
                                "(or use 'ahk_body' for custom code).")
        # 'opens' is a single target, advertised as no-code data — a line break
        # would escape the ';  Opens:' comment header and inject executable AHK.
        if "\n" in opens or "\r" in opens:
            raise VoiceKitError("'opens' can't contain line breaks — it names one thing to open. "
                                "For multi-line code use 'ahk_body'.")
    phrase, base = _require_name(name)
    macro = REPO_ROOT / "macros" / f"{base}.ahk"
    if macro.exists():
        raise VoiceKitError(f"A macro named '{base}' already exists. Pick another name.")
    disp = space_out(base)
    link = _require_free_lnk(disp)
    content = _opens_content(phrase, opens) if opens else _launch_content(phrase, ahk_body)
    _write_new(macro, content)
    ok, err = validate_ahk(str(macro))
    if not ok:
        macro.unlink(missing_ok=True)
        raise VoiceKitError(f"The generated macro failed to load, so nothing was kept:\n{err}")
    make_shortcut(str(link), str(macro))
    log(f"launch | {disp} | macros\\{base}.ahk" + (f" | opens {opens}" if opens else ""))
    return {"type": "launch_macro", "phrase": disp, "file": str(macro),
            "shortcut": str(link), "voice_phrase": f"open {disp}", "reloaded": False}


def create_ai_action(name: str, prompt: str) -> dict:
    """An AI text action (mirrors NewAutomation.ahk NewAIAction): the prompt is
    saved to prompts\\<Base>.prompt.txt and the macro is templates\\ai-template.ahk
    filled in. Select text anywhere, say 'open <name>' — the AI's answer replaces
    it. Needs the user's OpenRouter key (AI Settings); creating the action never
    calls the network."""
    phrase, base = _require_name(name)
    prompt = prompt.strip()
    if not prompt:
        raise VoiceKitError("The AI action needs a prompt — what should the AI do "
                            "with the selected text?")
    macro = REPO_ROOT / "macros" / f"{base}.ahk"
    if macro.exists():
        raise VoiceKitError(f"A macro named '{base}' already exists. Pick another name.")
    disp = space_out(base)
    link = _require_free_lnk(disp)
    prompt_file = REPO_ROOT / "prompts" / f"{base}.prompt.txt"
    _write_new(prompt_file, prompt + "\n")
    _write_new(macro, _ai_action_content(phrase, base))
    ok, err = validate_ahk(str(macro))
    if not ok:
        macro.unlink(missing_ok=True)
        prompt_file.unlink(missing_ok=True)
        raise VoiceKitError(f"The generated AI action failed to load, so nothing was kept:\n{err}")
    make_shortcut(str(link), str(macro))
    log(f"ai-action | {disp} | macros\\{base}.ahk")
    return {"type": "ai_action", "phrase": disp, "file": str(macro),
            "prompt_file": str(prompt_file), "shortcut": str(link),
            "voice_phrase": f"open {disp}",
            "note": "Runs on the user's selected text; needs their OpenRouter key "
                    "(home window -> AI Settings) the first time."}


def read_ai_prompt(name: str) -> dict:
    """The full current prompt of an AI action (list_automations only previews
    the first 120 characters — read before rewriting)."""
    base = to_base(clean_phrase(name))
    prompt_file = REPO_ROOT / "prompts" / f"{base}.prompt.txt"
    if not prompt_file.exists():
        raise VoiceKitError(f"No AI action named '{base}' (looked for {prompt_file.name}).")
    return {"type": "ai_action", "base": base, "name": space_out(base),
            "prompt_file": str(prompt_file),
            "prompt": prompt_file.read_text(encoding="utf-8-sig", errors="replace").strip()}


def update_ai_prompt(name: str, prompt: str) -> dict:
    """Rewrite an existing AI action's prompt (the macro itself is untouched).
    Returns the previous prompt so an unwanted overwrite can be undone."""
    prev = read_ai_prompt(name)          # same resolution + not-found error
    prompt = prompt.strip()
    if not prompt:
        raise VoiceKitError("The new prompt can't be empty.")
    _write_new(Path(prev["prompt_file"]), prompt + "\n")
    log(f"ai-prompt updated | {prev['base']}")
    return {"type": "ai_action", "base": prev["base"], "prompt_file": prev["prompt_file"],
            "previous_prompt": prev["prompt"],
            "note": "Applies the next time the action runs."}


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
    if expansion.strip() == "{":
        raise VoiceKitError("The expansion can't be just '{' — that's code-block syntax "
                            "in the snippets file (it would break loading entirely).")
    snip = REPO_ROOT / "hotkeys" / "Snippets.ahk"
    existing = snip.read_text(encoding="utf-8-sig", errors="replace") if snip.exists() else ""
    # Case-insensitive like the GUI (and like AHK hotstring firing itself):
    # a case-differing duplicate would load fine but never fire (shadowed).
    if re.search(rf"^:[^:]*:{re.escape(abbrev)}::", existing, re.MULTILINE | re.IGNORECASE):
        raise VoiceKitError(f"A snippet for '{abbrev}' already exists. Delete it first to change it.")
    exp = expansion.replace("`", "``")          # escape literal backticks (AHK escape char)
    exp = exp.replace(";", "`;")                # a bare ; would start a comment mid-line
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
# VoiceKit's own tools: listed separately, never deletable through MCP.
_BUILTINS = {"NewAutomation", "WorkflowStudio", "VoiceKitHelp", "VoiceKitHome", "AskAI"}
# Deletion guard compares case-insensitively: spoken names round-trip through
# CleanPhrase's Title Case ("Ask AI" -> base "AskAi"), and NTFS would happily
# match AskAi.ahk to AskAI.ahk — an exact-case check would not protect it.
_BUILTINS_LOWER = {b.lower() for b in _BUILTINS}


def list_automations() -> dict:
    """Everything sayable/typable, in the same categories the Voice Kit home
    window shows: workflows (+ loop phrase), launch macros (+ what they open),
    AI actions (+ prompt preview), hotkey modules (+ combo), snippets
    (+ expansion), and VoiceKit's own tools. An automation the user gave a
    companion hotkey (the home window's Hotkey button) carries it as
    "hotkey" on its own entry — the companion module isn't listed twice."""
    combos = {e["file"]: e for e in get_bridge_map()["entries"]}
    # Companion hotkeys fold into their automation's entry (mirrors the
    # home window) instead of listing as modules of their own.
    companion_combo = {}
    for file, e in combos.items():
        parent = _companion_parent(file)
        if parent:
            companion_combo[parent.lower()] = e["combo"]

    def _with_hotkey(entry: dict) -> dict:
        combo = companion_combo.get(entry["base"].lower())
        if combo:
            entry["hotkey"] = combo
        return entry

    macros_dir = REPO_ROOT / "macros"
    launch, workflows, ai_actions, tools = [], [], [], []
    for f in sorted(macros_dir.glob("*.ahk")):
        base = f.stem
        disp = space_out(base)
        txt = f.read_text(encoding="utf-8-sig", errors="replace")
        if base in _BUILTINS:
            say = "open voice kit" if base == "VoiceKitHome" else f"open {disp}"
            tools.append(_with_hotkey(
                {"name": disp, "base": base, "voice_phrase": say, "file": str(f)}))
            continue
        if STUDIO_MARKER in txt:
            workflows.append(_with_hotkey(
                {"name": disp, "base": base, "file": str(f),
                 "voice_phrase": f"open {disp}",
                 "loop_voice_phrase": f"open loop {disp}"}))
            continue
        prompt_file = REPO_ROOT / "prompts" / f"{base}.prompt.txt"
        if prompt_file.exists():
            preview = prompt_file.read_text(encoding="utf-8-sig", errors="replace").strip()
            ai_actions.append(_with_hotkey(
                {"name": disp, "base": base, "file": str(f),
                 "voice_phrase": f"open {disp}",
                 "prompt_preview": preview[:120]}))
            continue
        entry = {"name": disp, "base": base, "file": str(f),
                 "voice_phrase": f"open {disp}"}
        m = re.search(r"^;\s+Opens:\s+(.+)$", txt, re.MULTILINE)
        if m:
            entry["opens"] = m.group(1).strip()
        launch.append(_with_hotkey(entry))

    hotkeys = []
    for f in sorted((REPO_ROOT / "hotkeys").glob("*.ahk")):
        if f.stem in ("_index", "Snippets"):
            continue
        if f.name.lower().endswith(COMPANION_SUFFIX):
            continue    # a companion — already folded into its automation above
        entry = {"name": space_out(f.stem), "base": f.stem, "file": str(f)}
        bm = combos.get(f"hotkeys\\{f.stem}.ahk")
        if bm:
            entry["combo"] = bm["combo"]
            entry["voice_phrase"] = bm["phrase"]
        hotkeys.append(entry)

    snippets = []
    snip = REPO_ROOT / "hotkeys" / "Snippets.ahk"
    if snip.exists():
        for line in snip.read_text(encoding="utf-8-sig", errors="replace").splitlines():
            m = re.match(r"^:\*?[^:]*:(.+?)::(.*)$", line.strip())
            if m:
                exp = m.group(2).strip()
                snippets.append({"abbrev": m.group(1),
                                 "dynamic": exp in ("{", ""),
                                 "expansion_preview": "" if exp in ("{", "") else exp[:80]})

    return {"workflows": workflows, "launch_macros": launch, "ai_actions": ai_actions,
            "hotkey_modules": hotkeys, "snippets": snippets, "voicekit_tools": tools}


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
            # Trim each field like the GUI does (VoiceKitHome.ahk) — the file is
            # the user's hand-maintained recreate list, so padded fields happen.
            parts = [p.strip() for p in line.split("|")]
            if len(parts) >= 3:
                entries.append({"combo": parts[0], "phrase": parts[1], "file": parts[2],
                                "created": parts[3] if len(parts) > 3 else ""})
    used = {e["combo"].rsplit("+", 1)[-1] for e in entries}
    free = [k for k in BRIDGE_POOL if k not in used]
    return {"entries": entries, "free_keys": free, "reserved_keys": ["E", "N", "R", "X", "H"]}


# ---------------------------------------------------------------------------
# Run / trigger / delete
# ---------------------------------------------------------------------------
def run_automation(name: str, wait_seconds: int = 0) -> dict:
    """Trigger any spoken automation (workflow, launch macro, AI action, or
    VoiceKit tool) by launching its macro — the same thing Voice Access does
    when the user says 'open <name>'. A 'loop <name>' phrase starts a workflow's
    loop companion (repeats until stopped — the floating Stop Looping button,
    Ctrl+Alt+Shift+X, or a failing step). With wait_seconds > 0, waits that long
    for the script to finish and reports how it went; otherwise fire-and-forget."""
    phrase = clean_phrase(name)
    base = to_base(phrase)
    macro = REPO_ROOT / "macros" / f"{base}.ahk"
    if macro.exists():
        # Workflow Studio is #SingleInstance Force: relaunching it would kill an
        # open session and lose unsaved recorded steps (the GUI's OpenStudioSafely
        # guards this; do the same headlessly by refusing rather than clobbering).
        if base.lower() == "workflowstudio" and _ahk_script_running("WorkflowStudio.ahk"):
            raise VoiceKitError("Workflow Studio is already open — launching it again would discard "
                                "any unsaved recorded steps. Ask the user to save or close it first.")
        return _launch_and_report([AHK_EXE, str(macro)], space_out(base), str(macro), wait_seconds)
    # 'loop <name>': the workflow's loop companion (same target as its
    # 'loop <name>.lnk' — lib\LoopRunner.ahk resolves the steps file itself).
    if phrase.lower().startswith("loop "):
        wf_base = to_base(phrase[5:])
        if (REPO_ROOT / "workflows" / f"{wf_base}.steps.txt").exists():
            r = _launch_and_report(
                [AHK_EXE, str(REPO_ROOT / "lib" / "LoopRunner.ahk"), wf_base],
                f"loop {space_out(wf_base)}", str(REPO_ROOT / "lib" / "LoopRunner.ahk"),
                wait_seconds)
            if not r.get("finished"):
                r["note"] = ("Looping until stopped — the floating Stop Looping button, "
                             "saying 'click stop looping', or Ctrl+Alt+Shift+X ends it; "
                             "it also stops itself if a step fails.")
            return r
        raise VoiceKitError(f"No workflow named '{wf_base}' to loop — "
                            f"list_automations shows what exists.")
    raise VoiceKitError(f"No automation named '{base}' to run — "
                        f"list_automations shows what exists.")


def _launch_and_report(cmd: list, launched: str, file: str, wait_seconds: int) -> dict:
    proc = subprocess.Popen(cmd)
    result = {"launched": launched, "file": file}
    if wait_seconds > 0:
        try:
            rc = proc.wait(timeout=wait_seconds)
            result["finished"] = True
            result["exit_code"] = rc
            result["note"] = ("Finished cleanly." if rc == 0 else
                              f"Exited with code {rc} — something in it failed.")
        except subprocess.TimeoutExpired:
            result["finished"] = False
            result["note"] = (f"Still running after {wait_seconds}s — a long automation, "
                              "a window it's waiting for, or a failing step showing its popup.")
    else:
        result["finished"] = False
        result["note"] = "Running on the desktop now; a failing step shows a popup naming it."
    return result


def _run_inline_ahk(script: str, timeout: int = 15) -> None:
    """Run a short throwaway AHK v2 script via stdin (AutoHotkey's `*` mode) —
    no temp files."""
    subprocess.run([AHK_EXE, "/ErrorStdOut", "*"], input=script,
                   capture_output=True, text=True, timeout=timeout, check=True)


def resolve_bridge(name_or_key: str) -> dict:
    """Find a bridge-map entry by voice phrase, module name, or bare key
    (e.g. 'Toggle Timer', 'ToggleTimer', or 'A'). Raises if there's no match.

    Matches in PRECEDENCE order — exact phrase, then module base, then bare key
    letter — across all entries, so a coincidental single-letter key match never
    beats an entry whose actual phrase/name equals the input."""
    entries = get_bridge_map()["entries"]
    want = name_or_key.strip()
    want_base = to_base(clean_phrase(want))

    def rows():
        for e in entries:
            key = e["combo"].rsplit("+", 1)[-1]
            mod_base = re.sub(r"^hotkeys\\|\.ahk$", "", e["file"])
            yield e, key, mod_base

    for match in (
        lambda e, key, mb: want.lower() == e["phrase"].lower(),
        lambda e, key, mb: want_base and want_base.lower() == mb.lower(),
        lambda e, key, mb: len(want) == 1 and want.upper() == key.upper(),
    ):
        for e, key, mb in rows():
            if match(e, key, mb):
                return {"combo": e["combo"], "phrase": e["phrase"], "key": key, "module": e["file"]}
    raise VoiceKitError(f"No hotkey module matches '{name_or_key}' — "
                        f"get_bridge_map shows what exists.")


def press_hotkey(name_or_key: str) -> dict:
    """Trigger an always-on hotkey module by synthesizing its Ctrl+Alt+Shift
    combo (SendLevel 1, so VoiceKit's hook hotkeys hear it — the same way the
    home window's Run button does it). Only combos registered in bridge-map.txt
    can be pressed. Requires the resident VoiceKit master to be running."""
    hit = resolve_bridge(name_or_key)
    # The key comes from bridge-map.txt (rsplit on '+'). Even though the file is
    # ours, constrain it to a single alphanumeric before it enters an executed
    # Send string — a tampered/garbled combo field must never inject keystrokes.
    if not re.fullmatch(r"[A-Za-z0-9]", hit["key"]):
        raise VoiceKitError(f"Refusing to press a malformed bridge key '{hit['key']}' "
                            f"(from {hit['combo']}). Check bridge-map.txt.")
    if not voicekit_running():
        raise VoiceKitError(
            "VoiceKit isn't running, so its hotkeys aren't registered — pressing "
            f"{hit['combo']} would do nothing. Start VoiceKit first (VoiceKit.ahk).")
    _run_inline_ahk(
        "#Requires AutoHotkey v2.0\n"
        "SendLevel 1\n"
        f'Send "^!+{hit["key"].lower()}"\n'
        "Sleep 150\n"
        "ExitApp\n")
    return {"pressed": hit["combo"], "phrase": hit["phrase"], "module": hit["module"],
            "note": "The combo was sent; the module's action ran in the resident VoiceKit."}


def _remove_matching_lines(path: Path, predicate) -> int:
    """Rewrite a file (no BOM, LF) dropping lines for which predicate(line) is
    True. Returns the number removed; the file is left untouched when nothing
    matched (no churn on unrelated deletes)."""
    if not path.exists():
        return 0
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    kept, removed = [], 0
    for line in text.split("\n"):
        if predicate(line):
            removed += 1
        else:
            kept.append(line)
    if removed:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(kept))
    return removed


def _remove_companion_hotkey(base: str, result: dict) -> None:
    """The home window's Hotkey button can give any automation a companion
    Ctrl+Alt+Shift key: hotkeys\\<Base>.hotkey.ahk, registered in _index.ahk and
    bridge-map.txt. Deleting the automation must retire all three (mirroring the
    GUI's delete parity), or a live key keeps pointing at a ghost and its bridge
    key stays allocated forever."""
    module = REPO_ROOT / _companion_rel(base)
    existed = module.exists()
    if existed:
        module.unlink()
        result["removed"].append(str(module))
    rel = _companion_rel(base)
    n = _remove_matching_lines(REPO_ROOT / "hotkeys" / "_index.ahk",
                               lambda ln: rel in ln)
    n += _remove_matching_lines(REPO_ROOT / "bridge-map.txt",
                                lambda ln: f"|{rel}|" in ln)
    if existed or n:
        result["reloaded"] = reload_voicekit()   # so the key stops working now


def delete_automation(name: str, type: str) -> dict:
    """Remove an automation and its artifacts (including a companion hotkey
    assigned in the home window). `type` is one of
    launch_macro | workflow | hotkey_module | snippet | ai_action."""
    result = {"type": type, "removed": []}

    if type == "snippet":
        abbrev = re.sub(r"\s", "", name.strip())
        snip = REPO_ROOT / "hotkeys" / "Snippets.ahk"
        text = snip.read_text(encoding="utf-8-sig", errors="replace") if snip.exists() else ""
        # Case-insensitive like the GUI (hotstrings themselves fire caselessly).
        pat = re.compile(rf"^:[^:]*:{re.escape(abbrev)}::(.*)$", re.IGNORECASE)
        matches = [m for m in (pat.match(ln.strip()) for ln in text.split("\n")) if m]
        if not matches:
            raise VoiceKitError(f"No snippet '{abbrev}' found.")
        # A code-block snippet's line is ':*:abbrev:: {' — removing just that
        # line orphans the block, Snippets.ahk stops loading, and the reload
        # below would take down EVERY hotkey and snippet. Refuse, like Home does.
        if any(m.group(1).strip() in ("{", "") for m in matches):
            raise VoiceKitError(
                f"'{abbrev}' is a code-block (dynamic) snippet — deleting its line would break "
                f"Snippets.ahk and every hotkey with it. Edit hotkeys\\Snippets.ahk by hand "
                f"and remove the whole block instead.")
        orig_bytes = snip.read_bytes()
        _remove_matching_lines(snip, lambda ln: pat.match(ln.strip()) is not None)
        ok, err = validate_ahk(str(snip))
        if not ok:
            snip.write_bytes(orig_bytes)        # roll back — never reload a broken file
            raise VoiceKitError(f"Removing '{abbrev}' would break Snippets.ahk, so it was "
                                f"rolled back:\n{err}")
        result["removed"].append(f"snippet {abbrev}")
        result["reloaded"] = reload_voicekit()
        log(f"deleted snippet | {abbrev}")
        return result

    base = to_base(clean_phrase(name))
    if base.lower() in _BUILTINS_LOWER:
        raise VoiceKitError(f"'{base}' is part of VoiceKit itself and can't be deleted.")

    if type == "hotkey_module":
        module = REPO_ROOT / "hotkeys" / f"{base}.ahk"
        existed = module.exists()
        if existed:
            module.unlink()
            result["removed"].append(str(module))
        n = _remove_matching_lines(REPO_ROOT / "hotkeys" / "_index.ahk",
                                   lambda ln: f"hotkeys\\{base}.ahk" in ln)
        n += _remove_matching_lines(REPO_ROOT / "bridge-map.txt",
                                    lambda ln: f"|hotkeys\\{base}.ahk|" in ln)
        if not existed and n == 0:
            raise VoiceKitError(f"No hotkey module '{base}' found — nothing was deleted.")
        result["reloaded"] = reload_voicekit()
        log(f"deleted hotkey | {base}")
        return result

    if type == "workflow":
        steps_file = REPO_ROOT / "workflows" / f"{base}.steps.txt"
        macro = REPO_ROOT / "macros" / f"{base}.ahk"
        is_stub = macro.exists() and STUDIO_MARKER in macro.read_text(encoding="utf-8-sig",
                                                                      errors="replace")
        # Cross-guard BEFORE touching anything: a same-named launch macro / AI
        # action must not lose its Start Menu shortcut to a mistyped `type`.
        if macro.exists() and not is_stub:
            hint = ("ai_action" if (REPO_ROOT / "prompts" / f"{base}.prompt.txt").exists()
                    else "launch_macro")
            raise VoiceKitError(f"'{base}' isn't a workflow — delete it with type='{hint}'.")
        if not steps_file.exists() and not is_stub:
            raise VoiceKitError(f"No workflow named '{base}' found — nothing was deleted.")
        if steps_file.exists():
            steps_file.unlink()
            result["removed"].append(str(steps_file))
        if is_stub:
            macro.unlink()
            result["removed"].append(str(macro))
        disp = space_out(base)
        _delete_lnk(disp, result)
        _delete_lnk(f"loop {disp}", result)      # companion loop entry
        _remove_companion_hotkey(base, result)   # companion hotkey, if assigned
        log(f"deleted workflow | {disp}")
        return result

    if type == "ai_action":
        macro = REPO_ROOT / "macros" / f"{base}.ahk"
        prompt_file = REPO_ROOT / "prompts" / f"{base}.prompt.txt"
        if not macro.exists() and not prompt_file.exists():
            raise VoiceKitError(f"No AI action '{base}' found.")
        if macro.exists():
            macro.unlink()
            result["removed"].append(str(macro))
        if prompt_file.exists():
            prompt_file.unlink()
            result["removed"].append(str(prompt_file))
        for nm in {clean_phrase(name), space_out(base)}:
            _delete_lnk(nm, result)
        _remove_companion_hotkey(base, result)
        log(f"deleted ai-action | {base}")
        return result

    if type == "launch_macro":
        macro = REPO_ROOT / "macros" / f"{base}.ahk"
        if not macro.exists():
            raise VoiceKitError(f"No launch macro '{base}' found.")
        if STUDIO_MARKER in macro.read_text(encoding="utf-8-sig", errors="replace"):
            raise VoiceKitError(f"'{base}' is a workflow, not a launch macro — "
                                f"delete it with type='workflow'.")
        if (REPO_ROOT / "prompts" / f"{base}.prompt.txt").exists():
            raise VoiceKitError(f"'{base}' is an AI action — delete it with "
                                f"type='ai_action' so its prompt file goes too.")
        macro.unlink()
        result["removed"].append(str(macro))
        # Launch shortcut may be named by phrase or SpaceOut(base); try both.
        for nm in {clean_phrase(name), space_out(base)}:
            _delete_lnk(nm, result)
        _remove_companion_hotkey(base, result)
        log(f"deleted launch | {base}")
        return result

    raise VoiceKitError(f"Unknown automation type '{type}'.")


def _delete_lnk(display_name: str, result: dict) -> None:
    lnk = VOICE_MACROS / f"{display_name}.lnk"
    if lnk.exists():
        lnk.unlink()
        result["removed"].append(str(lnk))
