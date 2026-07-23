"""Conformance test: prove voicekit_writer's output is byte-compatible with the
real AutoHotkey engine, and that the naming/encoding ports match AHK exactly.

Non-invasive: it only writes temp files and reads existing committed artifacts —
it never creates automations in macros\\, hotkeys\\, or the Start Menu.

Run:  python test_conformance.py     (prints PASS/FAIL, exit 1 on failure)
Also collectable by pytest (test_* functions).
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import voicekit_writer as vk

HARNESS = vk.REPO_ROOT / "mcp" / "_conformance" / "roundtrip.ahk"

# Adversarial params: pipe, percent, newline, tab, quotes, backslashes, GUID path.
STEPS = [
    ("focus", "Notepad ahk_exe notepad.exe", "notepad.exe", ""),
    ("text", "a|b%c\nsecond\tline & 100%", "", ""),
    ("click", "Untitled - Notepad", "File | Save As...", "120,44"),
    ("hover", "Untitled - Notepad", "Format", ""),          # hover by element name
    ("hover", "ahk_exe notepad.exe", "", "50,60"),          # hover by position only
    ("run", 'explorer.exe "::{20D04FE0-3AEA-1069-A2D8-08002B30309D}"', "", ""),
    ("run", r'C:\Program Files\App "x".exe', "", ""),
    ("keys", "^s", "", ""),
    ("wait", "800", "", ""),
    # if/else/endif branching (condType in paramC): must round-trip too.
    ("if", "ahk_exe notepad.exe", "", "winexists"),
    ("text", "then branch", "", ""),
    ("else", "", "", ""),
    ("text", "else branch", "", ""),
    ("endif", "", "", ""),
    ("if", "Untitled - Notepad", "File | Save", "elementexists"),
    ("endif", "", "", ""),
]


def _expected_line(step) -> str:
    t, a, b, c = (list(step) + ["", "", ""])[:4]
    return f"{t}|{vk.wf_encode(a)}|{vk.wf_encode(b)}|{vk.wf_encode(c)}\n"


def test_workflow_roundtrip_through_real_engine():
    """Python emits .steps.txt -> real WorkflowLoad parses it -> re-emit -> match."""
    with tempfile.TemporaryDirectory() as d:
        in_file = Path(d) / "in.steps.txt"
        out_file = Path(d) / "out.txt"
        vk._write_new(in_file, vk.steps_to_text("Round Trip", STEPS))  # BOM+LF, as create_workflow writes

        r = subprocess.run(
            [vk.AHK_EXE, "/ErrorStdOut", str(HARNESS), str(in_file), str(out_file)],
            capture_output=True, text=True, timeout=30,
        )
        assert r.returncode == 0, f"harness failed: {r.stdout}{r.stderr}"

        got = out_file.read_text(encoding="utf-8-sig").replace("\r\n", "\n")
        want = "".join(_expected_line(s) for s in STEPS)
        assert got == want, f"round-trip mismatch:\n--- got ---\n{got}\n--- want ---\n{want}"


def test_created_files_have_bom_and_lf():
    """AHK writes newly-created files with a UTF-8 BOM and LF endings."""
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "x.txt"
        vk._write_new(p, "line1\nline2\n")
        raw = p.read_bytes()
        assert raw.startswith(b"\xef\xbb\xbf"), "missing UTF-8 BOM on created file"
        assert b"\r\n" not in raw, "created file must use LF, not CRLF"


def test_stub_matches_real_generated_stub():
    """workflow_stub() reproduces a real Studio-generated stub byte-for-byte
    (compared against the committed macros\\OpenPublicUserFolder.ahk)."""
    real = vk.REPO_ROOT / "macros" / "OpenPublicUserFolder.ahk"
    if not real.exists():
        return  # optional reference artifact
    real_txt = real.read_text(encoding="utf-8-sig").replace("\r\n", "\n")
    mine = vk.workflow_stub("Open Public User Folder", "OpenPublicUserFolder", date="2026-07-07")
    assert vk.STUDIO_MARKER in mine
    assert mine.strip("\n") == real_txt.strip("\n"), (
        f"stub differs from real generated stub:\n--- mine ---\n{mine}\n--- real ---\n{real_txt}")


def test_generated_stub_and_launch_macro_validate():
    """The engine load-checks a real generated workflow stub and launch macro."""
    for rel in ("macros/OpenPublicUserFolder.ahk", "macros/MeetingNotes.ahk"):
        f = vk.REPO_ROOT / rel
        if f.exists():
            ok, err = vk.validate_ahk(str(f))
            assert ok, f"{rel} failed /validate: {err}"


def test_naming_and_encoding_parity():
    assert vk.clean_phrase("meeting notes") == "Meeting Notes"
    assert vk.clean_phrase("MEETING NOTES") == "Meeting Notes"
    assert vk.clean_phrase("open2tabs") == "Open2tabs"          # StrTitle: no cap after digit
    assert vk.clean_phrase("meeting-notes!!") == "Meetingnotes"  # punctuation deleted, not spaced
    assert vk.to_base("Meeting Notes") == "MeetingNotes"
    assert vk.space_out("OpenPublicUserFolder") == "Open Public User Folder"
    for r in ("CON", "prn", "Nul", "COM1", "LPT9"):
        assert vk.is_reserved(r), r
    for ok in ("Notes", "Com", "Con1", ""):
        assert not vk.is_reserved(ok) or ok == "", ok
    # WfEncode/WfDecode inverse on nasty input
    for s in ("a|b%c\r\nx", "100% | done", "plain", "%25%7C%0A"):
        assert vk.wf_decode(vk.wf_encode(s)) == s


def test_allocate_bridge_key_is_free_and_in_pool():
    k = vk.allocate_bridge_key()
    assert k in vk.BRIDGE_POOL
    mapfile = vk.REPO_ROOT / "bridge-map.txt"
    used = mapfile.read_text(encoding="utf-8-sig") if mapfile.exists() else ""
    assert f"Ctrl+Alt+Shift+{k}|" not in used, "allocator returned an in-use key"


def test_ai_template_validates_and_fills():
    """The committed AI-action template must load-check as-is (placeholders live
    only in comments/strings), and the fill must leave no {{...}} behind."""
    tpl = vk.REPO_ROOT / "templates" / "ai-template.ahk"
    ok, err = vk.validate_ahk(str(tpl))
    assert ok, f"ai-template.ahk failed /validate: {err}"
    filled = vk._ai_action_content("Fix Grammar", "FixGrammar")
    assert "{{" not in filled and "}}" not in filled, "unfilled placeholder left in AI action"
    assert '"open Fix Grammar"' in filled
    assert "FixGrammar.prompt.txt" in filled


def test_template_fill_preserves_line_endings():
    """Template-filled macros (AI action + placeholder launch/hotkey) must carry
    the SAME line endings the template has on disk — the AHK generators fill via
    FileRead+FileAppend with no EOL translation, so byte parity requires it."""
    def tpl_is_crlf(name):
        return b"\r\n" in (vk.REPO_ROOT / "templates" / name).read_bytes()

    ai = vk._ai_action_content("Fix Grammar", "FixGrammar")
    assert ("\r\n" in ai) == tpl_is_crlf("ai-template.ahk"), \
        "AI-action macro endings diverge from the template AHK reads"
    launch = vk._launch_content("Test Ping", None)          # None => template path
    assert ("\r\n" in launch) == tpl_is_crlf("launch-template.ahk"), \
        "launch placeholder endings diverge from its template"
    hotkey = vk._hotkey_content("Test Bridge", "A", None)   # None => template path
    assert ("\r\n" in hotkey) == tpl_is_crlf("hotkey-template.ahk"), \
        "hotkey placeholder endings diverge from its template"


def test_opens_guards():
    """opens rejects line breaks / empties (injection + dead-macro guards).
    (press_hotkey's malformed-key guard is exercised for real in
    test_fix_regressions_via_monkeypatch.)"""
    for bad in ("", "   ", "https://x\nMsgBox(1)", "a\rb"):
        try:
            vk.create_launch_macro("Guard Probe", opens=bad)
            assert False, f"opens={bad!r} should be rejected"
        except vk.VoiceKitError:
            pass


def test_ahk_str_lit_and_opens_content():
    """ahk_str_lit mirrors NewAutomation.ahk AhkStrLit; _opens_content keeps the
    ';  Opens:' header line the home window parses."""
    assert vk.ahk_str_lit('say "hi"') == '"say `"hi`""'
    assert vk.ahk_str_lit("tick`mark") == '"tick``mark"'
    assert vk.ahk_str_lit("a\r\nb") == '"a`nb"'
    c = vk._opens_content("Team Board", "https://example.com/x")
    assert ";  Opens:  https://example.com/x\n" in c
    assert 'Run("https://example.com/x")\n' in c
    # An existing path containing a space gets embedded quotes (Run needs them).
    spaced = r"C:\Program Files"
    if Path(spaced).exists():
        c2 = vk._opens_content("Progs", spaced)
        assert f'Run("`"{spaced}`"")' in c2


def test_snippet_guards_reject_before_writing():
    """The brace-block and duplicate guards fire before any file is touched
    (so these calls are safe in a conformance run)."""
    snip = vk.REPO_ROOT / "hotkeys" / "Snippets.ahk"
    before = snip.read_bytes() if snip.exists() else b""
    try:
        vk.create_snippet("/conformance_probe", "{")
        assert False, "a lone '{' expansion must be rejected"
    except vk.VoiceKitError:
        pass
    existing = vk.list_automations()["snippets"]
    if existing:
        for variant in (existing[0]["abbrev"], existing[0]["abbrev"].upper()):
            try:
                vk.create_snippet(variant, "dup")
                assert False, f"duplicate abbreviation must be rejected ({variant})"
            except vk.VoiceKitError:
                pass  # caseless like the GUI — hotstrings fire caselessly
    after = snip.read_bytes() if snip.exists() else b""
    assert before == after, "guards must not modify Snippets.ahk"


def test_list_and_bridge_resolution():
    """list_automations categories exist; VoiceKit's tools are separated out;
    bridge entries resolve by phrase and by key letter."""
    listing = vk.list_automations()
    for k in ("workflows", "launch_macros", "ai_actions", "hotkey_modules",
              "snippets", "voicekit_tools"):
        assert k in listing, f"missing category {k}"
    tool_bases = {t["base"] for t in listing["voicekit_tools"]}
    if (vk.REPO_ROOT / "macros" / "VoiceKitHome.ahk").exists():
        assert "VoiceKitHome" in tool_bases
        home = next(t for t in listing["voicekit_tools"] if t["base"] == "VoiceKitHome")
        assert home["voice_phrase"] == "open voice kit"
    entries = vk.get_bridge_map()["entries"]
    if entries:
        e = entries[0]
        key = e["combo"].rsplit("+", 1)[-1]
        assert vk.resolve_bridge(e["phrase"])["combo"] == e["combo"]
        assert vk.resolve_bridge(key)["combo"] == e["combo"]
    try:
        vk.resolve_bridge("No Such Hotkey Exists Xyz")
        assert False, "unknown hotkey must raise"
    except vk.VoiceKitError:
        pass


def test_builtins_protected_from_delete():
    try:
        vk.delete_automation("Voice Kit Home", "launch_macro")
        assert False, "deleting a builtin must be refused"
    except vk.VoiceKitError as e:
        assert "part of VoiceKit" in str(e)


def test_delete_guards_are_nondestructive():
    """Every guard that protects against a bad delete fires BEFORE any file is
    touched (safe to exercise against the real repo)."""
    # Dynamic code-block snippet (/date ships in the repo): refuse, don't corrupt.
    snip = vk.REPO_ROOT / "hotkeys" / "Snippets.ahk"
    if snip.exists() and ":/date::" in snip.read_text(encoding="utf-8-sig"):
        before = snip.read_bytes()
        try:
            vk.delete_automation("/date", "snippet")
            assert False, "dynamic snippet delete must be refused"
        except vk.VoiceKitError as e:
            assert "code-block" in str(e)
        assert snip.read_bytes() == before, "guard must not modify Snippets.ahk"
    # Nonexistent names raise instead of reporting success.
    for typ in ("workflow", "hotkey_module"):
        try:
            vk.delete_automation("Never Existed Xyz Q", typ)
            assert False, f"{typ} delete of a nonexistent name must raise"
        except vk.VoiceKitError as e:
            assert "No " in str(e)
    # A non-workflow macro must not lose its .lnk to type='workflow'.
    listing = vk.list_automations()
    guardable = listing["launch_macros"] + listing["ai_actions"]
    if guardable:
        try:
            vk.delete_automation(guardable[0]["name"], "workflow")
            assert False, "workflow delete must cross-guard non-workflow macros"
        except vk.VoiceKitError as e:
            assert "isn't a workflow" in str(e)


def test_fix_regressions_via_monkeypatch():
    """Regression tests for the reviewed fixes, isolated by monkeypatching."""
    # 1. run_automation refuses to relaunch a running Workflow Studio.
    orig_running = vk._ahk_script_running
    vk._ahk_script_running = lambda s: True
    try:
        vk.run_automation("Workflow Studio")
        assert False, "must refuse to clobber a running Studio"
    except vk.VoiceKitError as e:
        assert "already open" in str(e)
    finally:
        vk._ahk_script_running = orig_running
    # 2. resolve_bridge precedence: exact phrase beats an earlier key-letter hit.
    orig_map = vk.get_bridge_map
    vk.get_bridge_map = lambda: {"entries": [
        {"combo": "Ctrl+Alt+Shift+A", "phrase": "Toggle Timer",
         "file": "hotkeys\\ToggleTimer.ahk", "created": ""},
        {"combo": "Ctrl+Alt+Shift+B", "phrase": "A", "file": "hotkeys\\A.ahk", "created": ""},
    ], "free_keys": [], "reserved_keys": []}
    try:
        assert vk.resolve_bridge("A")["combo"] == "Ctrl+Alt+Shift+B", \
            "exact phrase must beat a coincidental key-letter match"
        assert vk.resolve_bridge("Toggle Timer")["combo"] == "Ctrl+Alt+Shift+A"
    finally:
        vk.get_bridge_map = orig_map
    # 3. press_hotkey rejects a malformed key before anything runs.
    orig_resolve = vk.resolve_bridge
    vk.resolve_bridge = lambda n: {"combo": 'Ctrl+Alt+Shift+a" "^!+c', "phrase": "x",
                                   "key": 'a" "^!+c', "module": "hotkeys\\X.ahk"}
    try:
        vk.press_hotkey("x")
        assert False, "malformed bridge key must be refused"
    except vk.VoiceKitError as e:
        assert "malformed" in str(e)
    finally:
        vk.resolve_bridge = orig_resolve
    # 4. 'loop <name>' resolves through run_automation (unknown -> clean error).
    try:
        vk.run_automation("loop no such workflow zz")
        assert False, "unknown loop target must raise"
    except vk.VoiceKitError as e:
        assert "to loop" in str(e)


def test_companion_hotkey_folds_into_listing_and_delete_cleans_up():
    """A companion hotkey (hotkeys\\<Base>.hotkey.ahk + _index + bridge-map
    lines, written by the home window's Hotkey button) must (a) appear as the
    automation's own "hotkey" field — never as a separate hotkey module, (b)
    count its key as used, and (c) be retired when the automation is deleted."""
    orig_root, orig_reload = vk.REPO_ROOT, vk.reload_voicekit
    with tempfile.TemporaryDirectory() as d:
        vk.REPO_ROOT = Path(d)
        vk.reload_voicekit = lambda: False
        try:
            base = "CompanionProbeZz"
            for sub in ("macros", "workflows", "hotkeys"):
                (Path(d) / sub).mkdir()
            (Path(d) / "workflows" / f"{base}.steps.txt").write_text(
                "; probe\nwait|100||\n", encoding="utf-8")
            (Path(d) / "macros" / f"{base}.ahk").write_text(
                f"; generated by {vk.STUDIO_MARKER}\n", encoding="utf-8")
            (Path(d) / "hotkeys" / f"{base}.hotkey.ahk").write_text(
                "#Requires AutoHotkey v2.0\n^!+K:: {\n}\n", encoding="utf-8")
            (Path(d) / "hotkeys" / "_index.ahk").write_text(
                "#Requires AutoHotkey v2.0\n"
                f'#Include "%A_ScriptDir%\\hotkeys\\{base}.hotkey.ahk"',
                encoding="utf-8")
            (Path(d) / "bridge-map.txt").write_text(
                f"Ctrl+Alt+Shift+K|open companion probe zz|hotkeys\\{base}.hotkey.ahk|2026-07-15\n",
                encoding="utf-8")

            listing = vk.list_automations()
            wf = next(w for w in listing["workflows"] if w["base"] == base)
            assert wf.get("hotkey") == "Ctrl+Alt+Shift+K", "companion must fold into its automation"
            assert all(not h["base"].lower().endswith(".hotkey")
                       for h in listing["hotkey_modules"]), \
                "companion must not be listed as a hotkey module of its own"
            assert "K" not in vk.get_bridge_map()["free_keys"], "companion key must count as used"

            vk.delete_automation("Companion Probe Zz", "workflow")
            assert not (Path(d) / "hotkeys" / f"{base}.hotkey.ahk").exists(), \
                "delete must remove the companion module"
            assert f"{base}.hotkey.ahk" not in (Path(d) / "hotkeys" / "_index.ahk").read_text(
                encoding="utf-8-sig"), "delete must unwire the companion from _index.ahk"
            assert f"{base}.hotkey.ahk" not in (Path(d) / "bridge-map.txt").read_text(
                encoding="utf-8-sig"), "delete must free the companion's bridge key"
        finally:
            vk.REPO_ROOT, vk.reload_voicekit = orig_root, orig_reload


def test_get_bridge_map_strips_padded_fields():
    """Hand-padded bridge-map lines (the file is the user's recreate list) must
    parse like the GUI, which Trim()s every field."""
    orig_root = vk.REPO_ROOT
    with tempfile.TemporaryDirectory() as d:
        vk.REPO_ROOT = Path(d)
        try:
            (Path(d) / "bridge-map.txt").write_text(
                "Ctrl+Alt+Shift+B | Mute Mic | hotkeys\\MuteMic.ahk | 2026-01-02\n",
                encoding="utf-8")
            bm = vk.get_bridge_map()
            assert bm["entries"][0]["combo"] == "Ctrl+Alt+Shift+B"
            assert bm["entries"][0]["phrase"] == "Mute Mic"
            assert "B" not in bm["free_keys"], "padded key must count as used"
            assert vk.resolve_bridge("Mute Mic")["key"] == "B"
        finally:
            vk.REPO_ROOT = orig_root


def _run_all():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL  {t.__name__}\n      {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return failed


if __name__ == "__main__":
    import sys
    sys.exit(1 if _run_all() else 0)
