"""VoiceKit MCP privacy masking (WP9 phase 2).

Tool results go to a cloud model, and on a PC that handles client files the names of files
and folders ARE client data (`Documents\\Clients\\Smith John\\2025 Invoice
Smith.pdf`). Phase 1 (voicekit_writer.normalize_paths, always on) already
turns the profile / temp prefixes into %USERPROFILE% / %TEMP%; this module is
phase 2, applied once, in server._guard, to every response and every error:

  * paths mode (the DEFAULT when settings.ini says nothing): every file and
    folder name under the user profile (and under each extra MaskRoot) becomes
    a stable token that keeps the extension — <dir#1c2e>, <file#3a9f>.pdf.
    Readable on purpose: the well-known profile folders (Desktop, Documents,
    AppData, OneDrive - <org>, ...), the VoiceKit root and everything under it
    (macro/workflow/module names are the user's automation names, and the agent
    needs them to work), the Voice Macros Start Menu folder, and Python /
    program folders. The same names are then masked where they appear BARE
    elsewhere in the same response (an Out() that prints just the file name).
  * strict mode = paths + SSN / EIN patterns -> <ssn#..> / <ein#..>, one-way.
  * off = phase 1 only.

The mode lives in logs\\settings.ini [Privacy] Mode=paths|strict|off, plus
MaskRoots=D:\\Clients;\\\\server\\share (semicolon list). No tool can change
it — only the file. Tokens are HMAC-SHA256 of the case-folded name under a
per-install random key (logs\\privacy.key); the token -> name map lives in
logs\\privacy-tokens.json so a token handed back as INPUT expands to the real
name locally (expand_tokens). reveal() is the audited way to read one.

What this is NOT: data-loss prevention. It stops INCIDENTAL leakage (paths in
listings, errors, logs, snippet output). A snippet that deliberately Out()s a
document's text sends that text, and a client name that never appears as part
of a masked path is not caught (strict mode adds the ID patterns only).

Deliberately free of any voicekit_writer import: the writer imports this
module (expand_user_paths), and the server uses both.
"""

from __future__ import annotations

import configparser
import hashlib
import hmac
import io
import json
import os
import re
import secrets
import sys
import tempfile
import threading
from urllib.parse import unquote
import time
from datetime import datetime
from pathlib import Path, PurePath

DEFAULT_ROOT = Path(os.environ.get("VOICEKIT_ROOT", Path(__file__).resolve().parent.parent))

# Test hooks: a fake profile / temp folder (None = the real ones). The
# conformance tests point these at a sandbox so they never depend on (or
# write tokens for) the real profile.
PROFILE_OVERRIDE: str | None = None
TEMP_OVERRIDE: str | None = None

MODES = ("off", "paths", "strict")
DEFAULT_MODE = "paths"
TOKEN_MIN_HEX = 6          # grows per name, only on a collision (6 hex: a
                           # collision is rare even at the map cap, which
                           # matters if the map is ever rebuilt — see _assign)
TOKEN_MAX_HEX = 12
ID_TOKEN_HEX = 6
MAP_CAP = 20000            # names kept in privacy-tokens.json (oldest dropped)
RETIRED_CAP = 100000       # trimmed token ids never handed out again
AUDIT_CAP_BYTES = 262144   # privacy-audit.log: past this, keep the newest half
REVEAL_MAX_CHARS = 4096

KEY_FILE = "privacy.key"
MAP_FILE = "privacy-tokens.json"
AUDIT_FILE = "privacy-audit.log"


class PrivacyError(ValueError):
    """A token that can't be used where it was passed (unknown, one-way, or
    baked into saved code). A ValueError, so server._guard turns it into a
    ToolError like every other bad input."""


# ---------------------------------------------------------------------------
# Where things are
# ---------------------------------------------------------------------------
def _clean_dir(p: str) -> str:
    p = (p or "").strip().strip('"')
    if len(p) > 3:
        p = p.rstrip("\\/")
    return p


def profile_dir() -> str:
    if PROFILE_OVERRIDE:
        return _clean_dir(PROFILE_OVERRIDE)
    return _clean_dir(os.environ.get("USERPROFILE", "") or str(Path.home()))


def temp_dir() -> str:
    if TEMP_OVERRIDE:
        return _clean_dir(TEMP_OVERRIDE)
    return _clean_dir(tempfile.gettempdir())


# Test hook: the shell folders' real locations (None = read the registry).
KNOWN_FOLDERS_OVERRIDE: list | None = None
_KNOWN_FOLDERS_CACHE: dict = {}
# HKCU ...\Explorer\User Shell Folders values for Desktop, Documents,
# Downloads, Pictures, Videos, Music.
_SHELL_FOLDER_VALUES = ("Desktop", "Personal", "{374DE290-123F-4565-9164-39C4925E467B}",
                        "My Pictures", "My Video", "My Music")


def redirected_folders(profile: str) -> list[str]:
    """The user's Desktop / Documents / Downloads / ... when they are NOT
    under the profile — folder redirection to a server share (common in
    offices on a domain) or to another drive. They hold the same client files
    as a local Documents would, so they are masked like an implicit MaskRoot.
    Read once per process (a redirection change needs a restart anyway)."""
    if KNOWN_FOLDERS_OVERRIDE is not None:
        found = list(KNOWN_FOLDERS_OVERRIDE)
    else:
        if "real" not in _KNOWN_FOLDERS_CACHE:
            got = []
            try:
                import winreg
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                    r"Software\Microsoft\Windows\CurrentVersion\Explorer"
                                    r"\User Shell Folders") as k:
                    for v in _SHELL_FOLDER_VALUES:
                        try:
                            val, _t = winreg.QueryValueEx(k, v)
                        except OSError:
                            continue
                        if isinstance(val, str) and val.strip():
                            got.append(_clean_dir(os.path.expandvars(val)))
            except (ImportError, OSError):
                pass
            _KNOWN_FOLDERS_CACHE["real"] = got
        found = _KNOWN_FOLDERS_CACHE["real"]
    pn = _norm(profile)
    return [f for f in found if f and not _under(_norm(f), pn)
            and (re.match(r"^[A-Za-z]:\\.", f) or f.startswith("\\\\"))]


def _logs(root) -> Path:
    return Path(root or DEFAULT_ROOT) / "logs"


def _norm(p: str) -> str:
    """Caseless, backslashed, no trailing separator — for prefix compares."""
    p = (p or "").replace("/", "\\")
    if len(p) > 3:
        p = p.rstrip("\\")
    return p.casefold()


def _under(p: str, q: str) -> bool:
    """p is q or inside it (both already _norm'd)."""
    return bool(q) and (p == q or p.startswith(q.rstrip("\\") + "\\"))


# ---------------------------------------------------------------------------
# Settings: logs\settings.ini [Privacy] — read at each call, mtime-cached
# ---------------------------------------------------------------------------
_SETTINGS_CACHE: dict = {}
_LOCK = threading.RLock()


def _decode_any(raw: bytes) -> str:
    """AutoHotkey's IniWrite creates settings.ini as UTF-16LE with a BOM; a
    hand edit in Notepad may leave UTF-8 or ANSI."""
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    if raw[:3] == b"\xef\xbb\xbf":
        return raw.decode("utf-8-sig")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def _expand_env(s: str) -> str:
    def sub(m):
        k = m.group(1).upper()
        if k == "USERPROFILE":
            return profile_dir()
        if k in ("TEMP", "TMP"):
            return temp_dir()
        return os.environ.get(m.group(1), m.group(0))
    return re.sub(r"%([A-Za-z_][A-Za-z0-9_]*)%", sub, s)


def settings(root=None) -> dict:
    """{'mode': off|paths|strict, 'mask_roots': [real paths], 'note': str}.
    A missing file / section / key means the default, paths. An unknown Mode
    value falls back to paths (the safe side) and says so in 'note'."""
    ini = _logs(root) / "settings.ini"
    try:
        st = ini.stat()
        stamp = (st.st_mtime_ns, st.st_size)
    except OSError:
        stamp = None
    key = (str(ini), stamp, PROFILE_OVERRIDE, TEMP_OVERRIDE)
    with _LOCK:
        hit = _SETTINGS_CACHE.get(str(ini))
        if hit and hit[0] == key:
            return hit[1]
    out = {"mode": DEFAULT_MODE, "mask_roots": [], "note": ""}
    if stamp is not None:
        try:
            cp = configparser.RawConfigParser(strict=False)
            cp.read_string(_decode_any(ini.read_bytes()))
            sect = next((s for s in cp.sections() if s.strip().lower() == "privacy"), None)
            if sect:
                raw_mode = (cp.get(sect, "mode", fallback="") or "").strip().strip('"').lower()
                if raw_mode in MODES:
                    out["mode"] = raw_mode
                elif raw_mode:
                    out["note"] = (f"settings.ini [Privacy] Mode='{raw_mode}' isn't one of "
                                   f"off / paths / strict — using paths.")
                roots = []
                for part in (cp.get(sect, "maskroots", fallback="") or "").split(";"):
                    r = _clean_dir(_expand_env(part.strip().strip('"')))
                    if not r:
                        continue
                    if not (re.match(r"^[A-Za-z]:[\\/]?", r) or r.startswith("\\\\")):
                        out["note"] = (out["note"] + " " if out["note"] else "") + \
                            f"MaskRoots entry '{part.strip()}' isn't a full path — ignored."
                        continue
                    if re.fullmatch(r"[A-Za-z]:[\\/]?", r):
                        r = r[:2]                   # a whole drive: 'D:'
                    roots.append(r.replace("/", "\\"))
                out["mask_roots"] = roots
        except (OSError, configparser.Error, UnicodeError):
            out["note"] = "settings.ini couldn't be read — using the default privacy mode (paths)."
    with _LOCK:
        _SETTINGS_CACHE[str(ini)] = (key, out)
    return out


def mode(root=None) -> str:
    return settings(root)["mode"]


# ---------------------------------------------------------------------------
# The key and the token map
# ---------------------------------------------------------------------------
_KEY_CACHE: dict = {}


def _key(root, create: bool = True) -> bytes | None:
    """The per-install HMAC key (logs\\privacy.key, 32 random bytes as hex).
    Created on first use — lazily, so a response with nothing to mask never
    writes it — with O_EXCL, so two servers starting together agree on one."""
    p = _logs(root) / KEY_FILE
    with _LOCK:
        if str(p) in _KEY_CACHE and p.exists():
            return _KEY_CACHE[str(p)]
        for _attempt in range(3):
            try:
                txt = p.read_text(encoding="ascii", errors="replace").strip()
                if txt:
                    k = bytes.fromhex(txt) if re.fullmatch(r"[0-9a-fA-F]{32,}", txt) \
                        else txt.encode("utf-8")
                    _KEY_CACHE[str(p)] = k
                    return k
            except FileNotFoundError:
                pass
            except OSError:
                time.sleep(0.05)
                continue
            if not create:
                return None
            try:
                p.parent.mkdir(parents=True, exist_ok=True)
                fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0))
                try:
                    os.write(fd, secrets.token_hex(32).encode("ascii") + b"\n")
                finally:
                    os.close(fd)
            except FileExistsError:
                time.sleep(0.05)          # the other writer is mid-write: read it next pass
            except OSError:
                return None
        return None


def _digest(key: bytes, text: str, salt: str = "") -> str:
    return hmac.new(key, (salt + text.casefold()).encode("utf-8"), hashlib.sha256).hexdigest()


class _TokenMap:
    """hex -> {'t': real name, 'p': [parents seen], 's': epoch}, plus the
    reverse index folded name -> hex. Loaded from disk when its stamp
    changes; written under a cross-process lock (merge-on-write) so two
    VoiceKit servers never hand out one token for two different names."""

    def __init__(self, path: Path):
        self.path = path
        self.stamp = None
        self.tokens: dict = {}
        self.rev: dict = {}
        self.retired: set = set()
        self.ok = True              # False: the file exists but couldn't be read

    def _file_stamp(self):
        try:
            st = self.path.stat()
            return (st.st_mtime_ns, st.st_size)
        except OSError:
            return None

    def load(self, force: bool = False):
        stamp = self._file_stamp()
        if not force and stamp == self.stamp:
            return
        tokens, retired = {}, []
        if stamp is not None:
            data, err = None, None
            for _ in range(5):
                try:
                    data = json.loads(self.path.read_text(encoding="utf-8"))
                    break
                except OSError as e:          # locked (AV, a writer mid-replace): retry
                    err = e
                    time.sleep(0.05)
                except ValueError as e:       # truncated / hand-edited
                    err = e
                    time.sleep(0.05)
            if data is None:
                # NEVER fall back to an empty map here: the next save would
                # overwrite every token issued so far, and a later name could
                # be handed an id an agent still holds for a different file.
                # Keep what's in memory and refuse to assign (_assign fails
                # closed) until the file reads again.
                self.ok = False
                self.err = err
                return
            if isinstance(data, dict):
                tokens = data.get("tokens", {}) if isinstance(data.get("tokens"), dict) else {}
                retired = data.get("retired", []) if isinstance(data.get("retired"), list) else []
        self.tokens = {h: v for h, v in tokens.items()
                       if isinstance(v, dict) and isinstance(v.get("t"), str)}
        self.rev = {v["t"].casefold(): h for h, v in self.tokens.items()}
        self.retired = {h for h in retired if isinstance(h, str)}
        self.ok = True
        self.stamp = stamp

    def save(self):
        if len(self.tokens) > MAP_CAP:
            keep = dict(sorted(self.tokens.items(), key=lambda kv: kv[1].get("s", 0),
                               reverse=True)[: int(MAP_CAP * 0.9)])
            # A trimmed id is RETIRED, never reissued: an agent may still hold
            # it, and handing it to a new name would expand it to the wrong
            # file. The retired id just reads as unknown/expired.
            self.retired |= {h for h in self.tokens if h not in keep}
            if len(self.retired) > RETIRED_CAP:
                self.retired = set(sorted(self.retired)[-RETIRED_CAP:])
            self.tokens = keep
            self.rev = {v["t"].casefold(): h for h, v in self.tokens.items()}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(f"{self.path.name}.tmp-{os.getpid()}-{threading.get_ident()}")
        tmp.write_text(json.dumps({"version": 1, "tokens": self.tokens,
                                   "retired": sorted(self.retired)}, ensure_ascii=False,
                                  separators=(",", ":")), encoding="utf-8")
        for i in range(20):
            try:
                os.replace(tmp, self.path)
                break
            except OSError:
                if i == 19:
                    try:
                        tmp.unlink()
                    except OSError:
                        pass
                    raise
                time.sleep(0.05)
        self.stamp = self._file_stamp()


_MAPS: dict = {}


def _map(root) -> _TokenMap:
    p = _logs(root) / MAP_FILE
    with _LOCK:
        m = _MAPS.get(str(p))
        if m is None:
            m = _MAPS[str(p)] = _TokenMap(p)
        m.load()
        return m


class _FileLock:
    """logs\\privacy-tokens.lock, O_EXCL — held only around assign+save."""

    def __init__(self, root):
        self.path = _logs(root) / "privacy-tokens.lock"
        self.held = False

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        deadline = time.time() + 5
        while True:
            try:
                fd = os.open(str(self.path), os.O_WRONLY | os.O_CREAT | os.O_EXCL)
                os.write(fd, str(os.getpid()).encode())
                os.close(fd)
                self.held = True
                return self
            except FileExistsError:
                try:
                    if time.time() - self.path.stat().st_mtime > 15:
                        self.path.unlink()          # a crashed holder's leftover
                        continue
                except OSError:
                    pass
                if time.time() > deadline:
                    return self                     # proceed unlocked rather than hang
                time.sleep(0.05)
            except OSError:
                return self

    def __exit__(self, *exc):
        if self.held:
            try:
                self.path.unlink()
            except OSError:
                pass


def _assign(root, names: dict) -> dict:
    """{folded: (real text, parent, kind)} -> {folded: hex}. New names are added
    under the file lock; a name already mapped keeps its token forever (until
    the map is trimmed or the key rotates)."""
    if not names:
        return {}
    m = _map(root)
    out = {f: m.rev[f] for f in names if f in m.rev}
    todo = {f: v for f, v in names.items() if f not in out}
    if not todo:
        return out
    key = _key(root)
    if key is None:
        raise PrivacyError("Couldn't create logs\\privacy.key, so names can't be masked.")
    with _LOCK, _FileLock(root):
        m.load(force=True)
        if not m.ok:
            raise PrivacyError(f"logs\\{MAP_FILE} exists but can't be read "
                               f"({type(getattr(m, 'err', None)).__name__}); nothing new is "
                               f"masked until it reads again (move it aside if it's damaged — "
                               f"old tokens then stop expanding, they never expand wrongly).")
        now = int(time.time())
        changed = False
        for f, (text, parent, *_rest) in todo.items():
            if f in m.rev:
                out[f] = m.rev[f]
                continue
            full = _digest(key, text)
            for n in range(TOKEN_MIN_HEX, TOKEN_MAX_HEX + 1):
                h = full[:n]
                if h in m.retired:
                    continue
                cur = m.tokens.get(h)
                if cur is None or cur["t"].casefold() == f:
                    break
            m.tokens[h] = {"t": text, "p": [parent] if parent else [], "s": now}
            m.rev[f] = h
            out[f] = h
            changed = True
        if changed:
            try:
                m.save()
            except OSError:
                pass            # tokens still correct in memory; the next save retries
    return out


# ---------------------------------------------------------------------------
# Tokens in text
# ---------------------------------------------------------------------------
# Anything TOKEN-SHAPED (any hex length) is recognized, so a truncated or
# hand-typed token is refused as unknown rather than silently passed through
# as literal text; only tokens this map issued (TOKEN_MIN_HEX..MAX) expand.
TOKEN_RE = re.compile(r"<(dir|file|ssn|ein)#([0-9a-f]{1,16})>")
# What the bare-name and ID passes must never rewrite.
_PROTECT_RE = re.compile(TOKEN_RE.pattern + r"|%(?:USERPROFILE|TEMP|TMP)%", re.IGNORECASE)


def find_tokens(s) -> list[str]:
    return [m.group(0) for m in TOKEN_RE.finditer(s)] if isinstance(s, str) else []


def _lookup(root, kind: str, hexpart: str) -> str:
    """The real name behind one path token — verified: the stored name must
    HMAC to the token, so a corrupted or edited map can never expand a token
    to somebody else's file."""
    tok = f"<{kind}#{hexpart}>"
    if kind in ("ssn", "ein"):
        raise PrivacyError(f"{tok} is a one-way ID mask (strict privacy mode) — the number "
                           f"never left this PC and no tool can turn it back. Have the "
                           f"automation read it where it lives (the sheet, the form).")
    m = _map(root)
    ent = m.tokens.get(hexpart)
    key = _key(root, create=False)
    if ent is None or key is None or not _digest(key, ent["t"]).startswith(hexpart):
        raise PrivacyError(f"Unknown privacy token {tok} — it isn't in this PC's token map "
                           f"(logs\\{MAP_FILE}). Tokens come only from this VoiceKit's own "
                           f"responses; re-read the listing or path that showed it and pass "
                           f"that token exactly.")
    _note_expanded(kind, ent["t"])
    return ent["t"]


# Names this call expanded from tokens in its INPUT (per thread: server._guard
# runs the writer call in its own thread). The answer is then masked for them
# too — a script handed '<file#..>.pdf' that echoes just the file name must
# not send the name straight back.
_CALL = threading.local()


def start_call() -> None:
    _CALL.seen = {}


def take_expanded() -> dict:
    """{folded name: (name, kind)} expanded since start_call(); resets."""
    seen = getattr(_CALL, "seen", None) or {}
    _CALL.seen = None
    return seen


def _note_expanded(kind: str, name: str) -> None:
    seen = getattr(_CALL, "seen", None)
    if seen is not None and isinstance(name, str):
        seen.setdefault(name.casefold(), (name, kind))


def expand_tokens(s, root=None):
    """Every <dir#..>/<file#..> in `s` replaced by the real name it stands
    for. An unknown token, or a one-way <ssn#..>/<ein#..>, raises."""
    if not isinstance(s, str) or "<" not in s:
        return s
    return TOKEN_RE.sub(lambda m: _lookup(root, m.group(1), m.group(2)), s)


def refuse_tokens(s, what: str) -> None:
    """Saved code and steps must not carry tokens: the read tools return
    authored source verbatim, and a macro that types '<file#3a9f>.pdf' is
    broken anyway."""
    toks = find_tokens(s)
    if toks:
        raise PrivacyError(
            f"{what} contains the privacy token {toks[0]}. Tokens stand for client file/folder "
            f"names that stay on this PC; they're expanded only where a tool ACTS on a path or "
            f"value (run_automation args, run_workflow_batch rows/source, create_launch_macro "
            f"opens, a workflow run target / focus launch / capture command, string literals "
            f"in run_ahk_snippet code) — never baked into saved code, steps or text. Have the "
            f"automation find the file itself (the File Explorer selection, A_Args), or ask "
            f"the user; reveal() returns a real name when you truly need it.")


# AHK string literals in run_ahk_snippet code ------------------------------
def _ahk_escape(text: str) -> str:
    """Literal-safe inside either quote style: backtick, ;, ', " escaped
    (all four are valid v2 escapes in both — measured)."""
    return (text.replace("`", "``").replace(";", "`;").replace("'", "`'")
            .replace('"', '`"'))


def _string_spans(line: str) -> tuple[list, int]:
    """[(start, end)] of the quoted string literals on one AHK line, and the
    index where a ; comment starts (len(line) when none)."""
    spans, i, n = [], 0, len(line)
    while i < n:
        ch = line[i]
        if ch == ";" and (i == 0 or line[i - 1] in " \t"):
            return spans, i
        if ch in "\"'":
            q, j = ch, i + 1
            while j < n:
                if line[j] == "`":
                    j += 2
                    continue
                if line[j] == q:
                    break
                j += 1
            spans.append((i + 1, min(j, n)))
            i = j + 1
            continue
        i += 1
    return spans, n


def expand_ahk_code(code: str, root=None) -> str:
    """Tokens in run_ahk_snippet code: expanded ONLY inside quoted string
    literals (escaped for AHK, and that literal's %USERPROFILE% / %TEMP%
    expanded too, so a masked path pasted back as a string just works) and
    inside continuation sections. A token anywhere else in code is refused —
    it can't mean anything there. Comments are left alone."""
    if not isinstance(code, str) or not TOKEN_RE.search(code):
        return code
    out, in_block, in_cont = [], False, False
    for ln_no, line in enumerate(code.split("\n"), 1):
        body = line.rstrip("\r")
        t = body.strip()
        if in_block:
            out.append(line)
            if "*/" in t:
                in_block = False
            continue
        if t.startswith("/*"):
            in_block = "*/" not in t[2:]
            out.append(line)
            continue
        if in_cont:
            if t.startswith(")"):
                in_cont = False
            else:
                line = _expand_literal(line, root)
            out.append(line)
            continue
        if t.startswith("(") and ")" not in t:
            in_cont = True
            out.append(line)
            continue
        spans, comment_at = _string_spans(body)
        pieces, pos = [], 0
        for a, b in spans:
            pieces.append(("code", body[pos:a]))
            pieces.append(("str", body[a:b]))
            pos = b
        pieces.append(("code", body[pos:]))
        rebuilt = []
        cursor = 0
        for kind, text in pieces:
            start = cursor
            cursor += len(text)
            if kind == "code":
                m = TOKEN_RE.search(text)
                if m and start + m.start() < comment_at:
                    raise PrivacyError(
                        f"Line {ln_no}: the privacy token {m.group(0)} is outside a string "
                        f"literal. Put the masked path in quotes (\"%USERPROFILE%\\...\\"
                        f"{m.group(0)}\") — it's expanded locally — or pass it as a "
                        f"run_automation argument.")
                rebuilt.append(text)
            else:
                rebuilt.append(_expand_literal(text, root))
        out.append("".join(rebuilt) + line[len(body):])
    return "\n".join(out)


def _expand_literal(text: str, root) -> str:
    """One piece of string-literal text holding a token: every token -> its
    real name, and the literal's %USERPROFILE% / %TEMP% -> the real folders,
    each escaped for AHK (a name may hold ' or ; or a backtick)."""
    if not TOKEN_RE.search(text):
        return text

    def one(m):
        if m.group("tok"):
            return _ahk_escape(_lookup(root, m.group("kind"), m.group("hex")))
        return _ahk_escape(profile_dir() if m.group("var").upper() == "USERPROFILE"
                           else temp_dir())
    return _LITERAL_RE.sub(one, text)


_LITERAL_RE = re.compile(r"(?P<tok><(?P<kind>dir|file|ssn|ein)#(?P<hex>[0-9a-f]{1,16})>)"
                         r"|%(?P<var>USERPROFILE|TEMP|TMP)%", re.IGNORECASE)


# ---------------------------------------------------------------------------
# Masking
# ---------------------------------------------------------------------------
_SEP = r"(?:\\\\|\\|/)"
# A segment char: a token, a URL %XX escape (file:///...%20...), or any
# character a Windows name may hold except '%' (which starts %VAR% text).
_SEGCH = r"(?:%s|%%[0-9A-Fa-f]{2}|[^\\/:*?\"<>|\r\n\t%%])" % TOKEN_RE.pattern.replace("(", "(?:")
_BOUNDARY = set(" \t.,;:)]'!?\"(")
_EXT_OK = re.compile(r"\.(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{1,8}")

# Well-known profile folders whose OWN name stays readable (their children
# are masked), relative to the profile, caseless full matches.
_READABLE_LEVELS = [re.compile(p, re.IGNORECASE) for p in (
    r"Desktop|Documents|Downloads|Pictures|Videos|Music|Favorites|Links|Contacts"
    r"|Saved Games|Searches|3D Objects|OneDrive(?: - [^\\]+)?",
    r"OneDrive(?: - [^\\]+)?\\(?:Desktop|Documents|Pictures|Downloads|Music|Videos)",
    r"AppData|AppData\\(?:Local|Roaming|LocalLow)",
    r"AppData\\Local\\(?:Temp|Programs|Microsoft|Packages)",
    r"AppData\\Roaming\\Microsoft(?:\\Windows(?:\\Start Menu(?:\\Programs)?)?)?",
)]
# Whole subtrees that stay readable (relative to the profile): program and
# Python folders, VoiceKit's own Start Menu folders, the MCP clients' configs.
_READABLE_TREES = (
    r"AppData\Local\Programs\Python", r"AppData\Roaming\Python",
    r"AppData\Local\Microsoft\WindowsApps",
    r"AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Voice Macros",
    r"AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup",
    r"AppData\Roaming\Microsoft\Windows\Start Menu\Programs\AutoHotkey",
    r"AppData\Roaming\Claude", r"AppData\Local\AnthropicClaude", r".claude", r".claude.json",
)
# Folder names a bare-name pass must never rewrite (they're readable above).
_KNOWN_WORDS = {w.casefold() for w in (
    "Desktop Documents Downloads Pictures Videos Music Favorites Links Contacts Searches "
    "OneDrive AppData Local Roaming LocalLow Temp Programs Microsoft Packages Windows "
    "Python Claude Startup").split()} | {"start menu", "saved games", "3d objects", "voice macros"}


class _Ctx:
    """One response's masking pass."""

    def __init__(self, root, cfg: dict, normalize):
        self.root = Path(root or DEFAULT_ROOT)
        self.cfg = cfg
        self.normalize = normalize
        self.profile = profile_dir()
        self.temp = temp_dir()
        self.found: dict = {}          # folded -> (real text, parent, kind)
        self.bare: dict = {}           # folded bare form -> (folded key, suffix, text)
        self._readable: dict = {}
        self.tokens: dict = {}         # folded -> hex (after _assign)
        self.listing: dict = {}
        pn = _norm(self.profile)
        tn = _norm(self.temp)
        trees = [_norm(str(self.root.resolve()) if self.root.exists() else str(self.root))]
        for p in {sys.prefix, sys.base_prefix, os.path.dirname(sys.executable)}:
            if p:
                trees.append(_norm(p))
        ahk = os.environ.get("VOICEKIT_AHK", "")
        if ahk:
            trees.append(_norm(os.path.dirname(ahk)))
        # A readable tree that CONTAINS the profile (a Python or VoiceKit
        # living directly in it, a drive root) would unmask everything.
        trees = [t for t in trees if t and not _under(pn, t) and not _under(tn, t)]
        trees += [_norm(os.path.join(self.profile, t)) for t in _READABLE_TREES]
        self.trees = trees
        self.pn = pn
        self.mask_roots = [_norm(r) for r in cfg.get("mask_roots", [])]
        # Anchors: the phase-1 forms, plus the other env-var spellings of
        # folders inside the profile (an AHK message or a script's own text may
        # say %APPDATA%\...), plus '~' starting a word.
        anchors = [(r"%USERPROFILE%", self.profile), (r"%TEMP%", self.temp),
                   (r"%TMP%", self.temp)]
        for var, dflt in (("APPDATA", "AppData\\Roaming"), ("LOCALAPPDATA", "AppData\\Local"),
                          ("ONEDRIVE", None), ("ONEDRIVECOMMERCIAL", None),
                          ("ONEDRIVECONSUMER", None)):
            real = None if PROFILE_OVERRIDE else os.environ.get(var)
            if not real and dflt:
                real = os.path.join(self.profile, dflt)
            if real and _under(_norm(real), pn):
                anchors.append((f"%{var}%", _clean_dir(real)))
        alts = [re.escape(a) for a, _ in anchors]
        self.anchor_base = {a.casefold(): b for a, b in anchors}
        self.anchor_base["~"] = self.profile
        root_alts = []
        for r in list(cfg.get("mask_roots", [])) + redirected_folders(self.profile):
            rn = _norm(r)
            if _under(rn, pn) or _under(rn, tn):
                continue           # inside the profile: masked by the profile rules already
            if rn not in self.mask_roots:
                self.mask_roots.append(rn)
            for spelled in {r, r.replace("\\", "/"), r.replace("\\", "\\\\")}:
                self.anchor_base[spelled.casefold()] = r
                root_alts.append(re.escape(spelled))
        alts.sort(key=len, reverse=True)
        root_alts.sort(key=len, reverse=True)
        # %VAR% anchors are unambiguous wherever they sit (phase 1 replaces
        # the profile prefix mid-word too); a MaskRoot like 'Q:\Clients' must
        # not match inside 'XQ:\Clients'; '~' only starts a word.
        anchor = "(?:%s)" % "|".join(alts)
        if root_alts:
            anchor += r"|(?<![A-Za-z0-9])(?:%s)" % "|".join(root_alts)
        anchor += r"""|(?<![^\s"'(=,\[])~(?=[\\/])"""
        self.rx = re.compile(r"(?P<anchor>%s)(?P<tail>(?:%s%s*)+)" % (anchor, _SEP, _SEGCH),
                             re.IGNORECASE)

    # -- disk ---------------------------------------------------------------
    def _entries(self, d: str):
        if not d or d.startswith("\\\\"):       # never stat a network share per response
            return None
        k = _norm(d)
        if k not in self.listing:
            try:
                self.listing[k] = os.listdir(d)
            except OSError:
                self.listing[k] = None
        return self.listing[k]

    # -- policy -------------------------------------------------------------
    def readable(self, full: str) -> bool:
        f = _norm(full)
        hit = self._readable.get(f)
        if hit is None:
            hit = self._readable[f] = self._readable_uncached(full, f)
        return hit

    def _readable_uncached(self, full: str, f: str) -> bool:
        for t in self.trees:
            if _under(f, t) or _under(t, f):
                return True
        for mr in self.mask_roots:
            if _under(f, mr) and f != mr:
                return False
        if _under(f, self.pn) and f != self.pn:
            rel = full.replace("/", "\\")[len(self.profile):].strip("\\")
            return any(p.fullmatch(rel) for p in _READABLE_LEVELS)
        return False

    # -- one path -----------------------------------------------------------
    def inside_tree(self, full: str) -> bool:
        f = _norm(full)
        hit = self._readable.get(("in", f))
        if hit is None:
            hit = self._readable[("in", f)] = any(_under(f, t) for t in self.trees)
        return hit

    def rewrite_tail(self, base: str, tail: str, token_for, closed: bool = False) -> str:
        """closed: the path was followed by a closing quote / delimiter, so
        its last segment runs exactly to the end of the name."""
        parts = re.split(r"(\\\\|\\|/)", tail)
        out = [parts[0]]
        real = base                      # real folder the next segment lives in (None = unknown)
        full = base
        i = 1
        while i < len(parts):
            sep, seg = parts[i], parts[i + 1] if i + 1 < len(parts) else ""
            last = i + 2 >= len(parts)
            out.append(sep)
            i += 2
            if seg in ("", ".", ".."):
                out.append(seg)
                if seg == ".." and real:
                    real = os.path.dirname(real)
                    full = real
                continue
            if TOKEN_RE.search(seg):
                # Already masked (a response re-read). Follow it for real-dir
                # tracking when the map knows it; never re-mask.
                out.append(seg)
                try:
                    name = expand_tokens(seg, self.root)
                except PrivacyError:
                    name = None
                full = os.path.join(full, name) if name else full + "\\?"
                real = full if name else None
                continue
            if last and self.inside_tree(full):
                out.append(seg)             # everything in a readable tree is readable
                continue
            if last:
                name, rest, kind = self._resolve_last(seg, real, closed)
            else:
                name, rest, kind = seg, "", "dir"
            path = os.path.join(full, name) if name else full
            if name and not self.readable(path):
                out.append(token_for(kind, name, full) + rest)
            else:
                out.append(seg)
            full = path
            real = path if real else None
        return "".join(out)

    def _resolve_last(self, seg: str, real, closed: bool = False):
        """The last segment may run into prose ('...\\Invoice.pdf to disk'). The
        folder's listing says where the name ends when it exists; otherwise a
        closing quote, then the last extension, ends it.

        The listing is trusted only when what follows reads as prose: a
        message may name a file that is NOT there ('Smith Jane.pdf' moved
        away, 'Smith John Jr' never made) beside one that merely starts the
        same ('Smith'), and cutting at the sibling would leave ' Jane.pdf' in
        the clear. So the longer reading wins when it ends in an extension,
        when the path was closed by a quote (the whole segment is the name),
        or when the next word starts with a capital or a digit. When unsure
        this masks too much, never too little."""
        fb = self._fallback(seg)
        ents = self._entries(real) if real else None
        if ents:
            low = seg.casefold()
            best = None
            for e in ents:
                el = e.casefold()
                if low.startswith(el) and (len(el) == len(low) or seg[len(el)] in _BOUNDARY):
                    if best is None or len(e) > len(best):
                        best = e
            if best:
                rest = seg[len(best):]
                longer = len(fb[0]) > len(best)
                if not (longer and (fb[2] == "file" or closed
                                    or re.match(r"[ \t]+[A-Z0-9&(#]", rest))):
                    kind = "dir" if os.path.isdir(os.path.join(real, best)) else "file"
                    return seg[:len(best)], rest, kind
        if closed and not fb[1].strip(" \t.,;:)]!?"):
            return fb
        if closed:
            s2 = re.sub(r"[\s.,;:)\]!?]+$", "", seg)
            return s2, seg[len(s2):], fb[2]
        return fb

    @staticmethod
    def _fallback(seg: str):
        cut = len(seg)
        m = re.search(r"'(?=\s|$|[.,;:)\]!?])", seg)
        if m:
            cut = m.start()
        s = seg[:cut]
        exts = list(re.finditer(_EXT_OK.pattern + r"(?=$|[\s.,;:)\]'!?(])", s))
        if exts:
            e = exts[-1].end()
            return s[:e], s[e:] + seg[cut:], "file"
        m2 = re.search(r"[\s.,;:)\]!?(]+$", s)
        if m2:
            return s[:m2.start()], s[m2.start():] + seg[cut:], "dir"
        return s, seg[cut:], "dir"

    # -- tokens -------------------------------------------------------------
    def collect(self, kind: str, name: str, parent: str) -> str:
        """Record one name to mask; returns a placeholder that finish() turns
        into the token once every name in the response has one."""
        text, ext = _split_name(kind, name)
        f = text.casefold()
        if f not in self.found:
            self.found[f] = (text, self.normalize_parent(parent), kind)
        if _bare_ok(text):
            self.bare.setdefault(f, (f, "", text))
            if ext:
                self.bare.setdefault((text + ext).casefold(), (f, ext, text + ext))
        if "%" in text:                     # a file:/// URL's name: its decoded form too
            dec = unquote(text)
            if dec != text and _bare_ok(dec):
                self.bare.setdefault(dec.casefold(), (f, "", dec))
        return "\0" + kind + "\0" + f + "\0" + ext

    def normalize_parent(self, parent: str) -> str:
        p = parent
        for anchor, base in (("%TEMP%", self.temp), ("%USERPROFILE%", self.profile)):
            if _under(_norm(p), _norm(base)):
                return anchor + p[len(base):]
        return p


def _split_name(kind: str, name: str) -> tuple[str, str]:
    if kind != "file":
        return name, ""
    stem, ext = os.path.splitext(name)
    if stem and stem.strip() and _EXT_OK.fullmatch(ext or ""):
        return stem, ext
    return name, ""


def _bare_ok(text: str) -> bool:
    """Worth a bare-name pass: 3+ chars with a letter, not a well-known
    folder name (masking 'Documents' everywhere would help nobody)."""
    t = text.strip()
    return (len(t) >= 3 and any(ch.isalpha() for ch in t)
            and t.casefold() not in _KNOWN_WORDS)


def _bare_matcher(entries, token_for):
    """chunk -> chunk with every whole-word occurrence of an entry's text
    (caseless, longest first, not inside a longer ASCII word) replaced by
    its token. Built from dicts, not one big regex alternation: Python's re
    tries an N-name alternation at every position, which made a log with
    thousands of distinct masked names take seconds. Per candidate start: the
    3-char prefix picks the (few) distinct name LENGTHS to try, and each is
    one dict lookup — so names sharing a prefix ('2025 Invoice ...', 'Client
    0001', ...) cost no more than names that don't."""
    table: dict = {}
    lens: dict = {}
    firsts = set()
    for f, ext, text in entries:
        if len(text) < 3:
            continue
        low = text.lower()
        table.setdefault(low, (f, ext))
        lens.setdefault(text[:3].lower(), set()).add(len(text))
        firsts.add(text[0])
    if not table:
        return None
    lens = {k: sorted(v, reverse=True) for k, v in lens.items()}
    starts = re.compile(r"(?<![A-Za-z0-9])[%s]" % "".join(re.escape(c) for c in sorted(firsts)),
                        re.IGNORECASE)

    def sub(chunk: str) -> str:
        out, pos, n = [], 0, len(chunk)
        for m in starts.finditer(chunk):
            i = m.start()
            if i < pos:
                continue
            for ln in lens.get(chunk[i:i + 3].lower(), ()):
                j = i + ln
                if j > n or (j < n and chunk[j].isascii() and chunk[j].isalnum()):
                    continue
                hit = table.get(chunk[i:j].lower())
                if hit is not None:
                    out.append(chunk[pos:i])
                    out.append(token_for(*hit))
                    pos = j
                    break
        if not out:
            return chunk
        out.append(chunk[pos:])
        return "".join(out)
    return sub


def _walk(obj, fn, exempt=(), keys=True):
    if isinstance(obj, str):
        return fn(obj)
    if isinstance(obj, PurePath):          # serialized as text later — mask it as text now
        return fn(str(obj))
    if isinstance(obj, dict):
        return {(fn(k) if keys and isinstance(k, str) else k):
                (v if k in exempt else _walk(v, fn, (), keys)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_walk(v, fn, (), keys) for v in obj]
    if isinstance(obj, tuple):
        return tuple(_walk(v, fn, (), keys) for v in obj)
    return obj


_OVERRIDE_RULES: dict = {}


def _override_norm(s: str) -> str:
    """With a test profile/temp configured, their prefixes become
    %USERPROFILE% / %TEMP% first (the real ones are voicekit_writer's job)."""
    if not (PROFILE_OVERRIDE or TEMP_OVERRIDE) or not isinstance(s, str):
        return s
    k = (temp_dir(), profile_dir())
    rx = _OVERRIDE_RULES.get(k)
    if rx is None:
        pairs = []
        for base, tok in ((k[0], "%TEMP%"), (k[1], "%USERPROFILE%")):
            for spelled in {base, base.replace("\\", "/"), base.replace("\\", "\\\\")}:
                pairs.append((spelled, tok))
        pairs.sort(key=lambda st: -len(st[0]))
        rx = re.compile("(?:%s)" % "|".join("(%s)" % re.escape(sp) for sp, _t in pairs)
                        + r"(?![\w.\-~$])", re.IGNORECASE)
        _OVERRIDE_RULES.clear()
        _OVERRIDE_RULES[k] = (rx, [t for _sp, t in pairs])
        rx = _OVERRIDE_RULES[k]
    pat, toks = rx
    return pat.sub(lambda m: toks[m.lastindex - 1], s)


# SSN: 3-2-4 with dashes; EIN: 2-7. Never part of a longer digit/dash run, so
# dates (2025-10-15), phones (555-123-4567) and amounts (12-3456) don't match.
_SSN_RE = re.compile(r"(?<![\d-])\d{3}-\d{2}-\d{4}(?![\d-])")
_EIN_RE = re.compile(r"(?<![\d-])\d{2}-\d{7}(?![\d-])")
# Nine bare digits only right after an ID label ("SSN: 123456789",
# "TIN 123 45 6789", "EIN#123456789") — a bare 9-digit number alone is far
# more often an account or invoice number.
_LABELLED_RE = re.compile(
    r"(?P<label>\b(?:SSN|ITIN|TIN|F?EIN|Social\s+Security(?:\s+(?:Number|No\.?|#))?"
    r"|Tax(?:payer)?\s+ID(?:entification)?(?:\s+(?:Number|No\.?|#))?)"
    r"(?:\s*(?:No\.?|Number|#))?)[\s:#=.\-]{0,4}"
    r"(?P<num>(?<!\d)\d{3}[ ]?\d{2}[ ]?\d{4}(?!\d))",
    re.IGNORECASE)


def _mask_ids(s: str, key: bytes) -> str:
    def tok(kind, digits):
        d = re.sub(r"\D", "", digits)
        return f"<{kind}#{_digest(key, d, kind + ':')[:ID_TOKEN_HEX]}>"

    def one(chunk: str) -> str:
        chunk = _LABELLED_RE.sub(
            lambda m: m.group(0)[: m.start("num") - m.start()] + tok(
                "ein" if re.search(r"EIN", m.group("label"), re.IGNORECASE) else "ssn",
                m.group("num")), chunk)
        chunk = _SSN_RE.sub(lambda m: tok("ssn", m.group(0)), chunk)
        return _EIN_RE.sub(lambda m: tok("ein", m.group(0)), chunk)
    return _protected(s, one)


def _protected(s: str, fn) -> str:
    """Apply fn to the parts of s that aren't tokens / %VAR% prefixes."""
    out, pos = [], 0
    for m in _PROTECT_RE.finditer(s):
        out.append(fn(s[pos:m.start()]))
        out.append(m.group(0))
        pos = m.end()
    out.append(fn(s[pos:]))
    return "".join(out)


def _has_id_shape(s: str) -> bool:
    return bool(_SSN_RE.search(s) or _EIN_RE.search(s) or _LABELLED_RE.search(s))


def protect(obj, root=None, normalize=None, exempt=(), unmask: bool = False,
            known: dict | None = None):
    """The whole outbound pipeline for one response (dict/list/str):
    phase-1 normalization, then (paths/strict) path-segment tokens and the
    bare-name pass, then (strict) ID masks. `exempt` top-level keys are left
    byte-for-byte. unmask=True skips the path tokens (normalization and, in
    strict mode, the ID masks still apply). `known` ({folded: (name, kind)},
    from take_expanded) are names this call's input carried as tokens: they
    get the bare-name pass here even if no path in the answer shows them."""
    cfg = settings(root)
    norm = (lambda s: normalize(_override_norm(s))) if normalize else _override_norm
    obj = _walk(obj, lambda s: norm(s), exempt)
    md = cfg["mode"]
    if md == "off":
        return obj
    if not unmask:
        ctx = _Ctx(root, cfg, norm)

        def scan(s):
            if not isinstance(s, str) or not ctx.rx.search(s):
                return s
            return ctx.rx.sub(lambda m: m.group("anchor") + ctx.rewrite_tail(
                ctx.anchor_base[m.group("anchor").casefold()], m.group("tail"), ctx.collect,
                closed=m.end() < len(m.string) and m.string[m.end()] in '"<>|'), s)
        marked = _walk(obj, scan, exempt)
        for f, (name, kind) in (known or {}).items():
            ctx.found.setdefault(f, (name, "", kind))
            if _bare_ok(name):
                ctx.bare.setdefault(f, (f, "", name))
        if ctx.found:
            ctx.tokens = _assign(root, ctx.found)
            bare_sub = _bare_matcher(
                ctx.bare.values(),
                lambda f, ext: f"<{ctx.found[f][2]}#{ctx.tokens[f]}>{ext}") if ctx.bare else None

            def finish(s):
                if not isinstance(s, str):
                    return s
                if "\0" in s:
                    s = re.sub(r"\0(dir|file)\0([^\0]*)\0",
                               lambda m: f"<{m.group(1)}#{ctx.tokens[m.group(2)]}>", s)
                return s

            def bare(s):
                if not isinstance(s, str) or bare_sub is None:
                    return s
                return _protected(s, bare_sub)
            obj = _walk(marked, finish, exempt)
            obj = _walk(obj, bare, exempt, keys=False)
        else:
            obj = marked
    if md == "strict":
        def ids(s):
            if not isinstance(s, str) or not _has_id_shape(s):
                return s
            key = _key(root)
            return _mask_ids(s, key) if key else s
        obj = _walk(obj, ids, exempt)
    return obj


def protect_text(s: str, root=None, normalize=None, unmask: bool = False) -> str:
    return protect(s, root=root, normalize=normalize, unmask=unmask)


def mask_ids_text(s: str, root=None) -> str:
    """Strict mode's ID pass alone (reveal applies it to what it returns)."""
    if settings(root)["mode"] != "strict" or not isinstance(s, str) or not _has_id_shape(s):
        return s
    key = _key(root)
    return _mask_ids(s, key) if key else s


# ---------------------------------------------------------------------------
# reveal + audit
# ---------------------------------------------------------------------------
def audit(root, tool: str, what: str) -> None:
    """One line in logs\\privacy-audit.log: when, which tool, which tokens —
    never the revealed value. Capped (the newest half is kept). Never raises."""
    p = _logs(root) / AUDIT_FILE
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} | {tool} | {what}\n"
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.exists() and p.stat().st_size > AUDIT_CAP_BYTES:
            text = p.read_text(encoding="utf-8", errors="replace")
            cut = text.find("\n", len(text) // 2)
            tmp = p.with_name(f"{p.name}.tmp-{os.getpid()}")
            tmp.write_text(text[cut + 1:] if cut >= 0 else "", encoding="utf-8")
            os.replace(tmp, p)
        with open(p, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass


def reveal(text: str, root=None) -> dict:
    """The real text behind every <dir#..>/<file#..> in `text` (a single token
    or a whole masked path). One-way ID tokens are refused; the call is
    audited by token, never by value."""
    if not isinstance(text, str) or not text.strip():
        raise PrivacyError("Pass the token to reveal, e.g. '<file#3a9f>' or a whole masked "
                           "path like '%USERPROFILE%\\Documents\\<dir#1c2e>\\<file#3a9f>.pdf'.")
    if len(text) > REVEAL_MAX_CHARS:
        raise PrivacyError(f"That's {len(text)} characters — reveal takes one token or one "
                           f"path (up to {REVEAL_MAX_CHARS}).")
    toks = find_tokens(text)
    if not toks:
        raise PrivacyError("No privacy token in that text — tokens look like <dir#1c2e> or "
                           "<file#3a9f>.pdf.")
    for t in toks:
        if t.startswith(("<ssn#", "<ein#")):
            _lookup(root, t[1:4], "0" * TOKEN_MIN_HEX)          # raises the one-way message
    real = expand_tokens(text, root)
    audit(root, "reveal", ", ".join(dict.fromkeys(toks)))
    return {"text": real, "tokens": list(dict.fromkeys(toks))}
