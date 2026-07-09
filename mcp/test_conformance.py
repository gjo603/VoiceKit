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
