"""VoiceKit MCP server.

Exposes VoiceKit's automations as MCP tools so Claude (Desktop or Claude Code)
can BUILD them from natural language — launch macros, snippets, hotkey modules,
step-workflows, and AI text actions, the same artifacts the GUI scaffolder /
recorder write — and TRIGGER them (run_automation, press_hotkey), the same way
Voice Access does.

All file-writing lives in voicekit_writer.py (kept byte-compatible with the
AutoHotkey generators and proven so by test_conformance.py). This file is just
the MCP surface: schema, validation, and thin wrappers.

Run:  python server.py         (stdio)   — or:  fastmcp run server.py
"""

from __future__ import annotations

import inspect
import logging
import subprocess
from typing import Annotated, Literal, Optional

from pydantic import BaseModel, Field

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

import privacy
import voicekit_writer as vk


def _install_quiet_cancel() -> bool:
    """A client-cancelled request must go quiet, never be answered.

    Measured 2026-08-03, from a real session: the client cancelled a slow
    dump_uia_tree after ~3.4 s and discarded the message id — then the mcp
    SDK's RequestResponder.cancel() sent an error reply ("Request cancelled")
    for that id. The client treated the orphaned reply as a protocol fault,
    closed the stdio pipes, and every later call returned -32000 Connection
    closed for the rest of the session. The spec agrees with the client
    keeping no state: after a cancellation notification the receiver SHOULD
    NOT send a response for that request at all. So: cancel the work, mark
    the request done, write nothing.

    Version-guarded — if the SDK's internals move (verified against mcp
    1.28.1), stock behavior is left alone and the conformance test
    (test_mcp_cancellation_is_not_connection_fatal) fails loudly at dev time
    instead of this silently doing nothing.

    respond() is patched too — a real race, not load timing (2026-09-30: the
    wire test flaked once with "Request already responded to" in the
    server's stderr). A sync tool runs in a worker thread that a cancel
    can't interrupt; when the thread finishes, the handler can reach
    respond() without passing another checkpoint, so the cancellation never
    raises — and respond() then asserts on the _completed flag cancel() just
    set. The AssertionError escaped the request handler into the server's
    task group. A request the client cancelled is now simply never answered,
    however late its work finishes."""
    try:
        from mcp.shared.session import RequestResponder
    except Exception:
        return False
    orig = getattr(RequestResponder, "cancel", None)
    orig_respond = getattr(RequestResponder, "respond", None)
    if (orig is None or not inspect.iscoroutinefunction(orig)
            or orig_respond is None or not inspect.iscoroutinefunction(orig_respond)):
        return False

    async def _cancel_without_reply(self):
        scope = getattr(self, "_cancel_scope", None)
        if scope is None:                       # unknown SDK shape — stock path
            return await orig(self)
        self._vk_client_cancelled = True        # respond() below goes quiet for good
        scope.cancel()
        self._completed = True                  # drops it from the in-flight table
        try:
            logging.getLogger("voicekit.mcp").info(
                "request %s cancelled by client; suppressing the reply", self.request_id)
        except Exception:
            pass

    async def _respond_unless_cancelled(self, response):
        if getattr(self, "_vk_client_cancelled", False):
            return                              # late result of a cancelled request: drop it
        return await orig_respond(self, response)

    RequestResponder.cancel = _cancel_without_reply
    RequestResponder.respond = _respond_unless_cancelled
    return True


_install_quiet_cancel()


def _make_server() -> FastMCP:
    """FastMCP with VoiceKit's session-level instructions (loaded once per
    session, not once per tool — the list of taken names is generated from
    the libraries at start, see vk.server_instructions) and its version in
    serverInfo when the installed SDK takes one (fastmcp 2.x may not)."""
    kwargs: dict = {"name": "VoiceKit"}
    try:
        kwargs["instructions"] = vk.server_instructions()
    except Exception:                      # never a reason not to start
        logging.getLogger("voicekit.mcp").exception("instructions")
    try:
        if "version" in inspect.signature(FastMCP.__init__).parameters:
            kwargs["version"] = vk.VERSION
    except (TypeError, ValueError):
        pass
    return FastMCP(**kwargs)


mcp = _make_server()


# ---------------------------------------------------------------------------
# Workflow step schema — semantic fields the LLM fills, mapped to type|a|b|c
# ---------------------------------------------------------------------------
class WorkflowStep(BaseModel):
    """One step of a workflow. Set the fields relevant to `type`:

      run      -> target
      focus    -> window   (+ launch to open it if not running)
      waitwin  -> window   (+ seconds, default 10)
      wait     -> ms (+ ms_max for a random pause in between)
      waitfor  -> condition + window (+ element/text, + seconds) — waits for
                  something to HAPPEN. Prefer this over `wait`.
      text     -> text
      fill     -> window + element (the input's label, "#2" for the 2nd with
                  that label) + value — clicks the box, types the value and
                  READS IT BACK; prefer it over click + text for form fields
      ask      -> label (+ suggestion)   collects an input from the user
      collect  -> label (+ element)      grabs a value and saves it to the sheet
      set      -> label (+ value)        names a value for later steps to reuse
      capture  -> label + command (+ seconds, default 30) — runs a command line
                  hidden and saves what it printed as {{label}}
      keys     -> keys
      click/dblclick/rclick -> window + element (name on screen)   [or xy]
      hover    -> window + element (or xy) — moves the mouse there and pauses
      drag     -> window + xy "x1,y1,x2,y2" — press, travel, release (selects a region)
      move     -> window + position (left/right/top/bottom/max)
      close    -> window
      if       -> window + condition (+ element for the *element* conditions)
      else     -> (no fields)   branch to run when the `if` was false
      endif    -> (no fields)   closes the `if` block

    Branching is optional. An `if` runs its following steps only when the
    condition holds; pair it with an optional `else` and a closing `endif`.

    WAITING: reach for `waitfor` before `wait`. A `wait` is a guess at how long
    an app will take and is wrong on a slower day; a `waitfor` continues the
    moment its condition is true and otherwise fails saying what never
    happened, instead of typing into a window that was never ready. Use `wait`
    only for a deliberate pause with nothing observable to wait on.

    NAMED VALUES: every ask label, collect label and set name can be reused
    anywhere later in the run by writing {{Name}} — in `text`, `keys`, `run`
    targets, window criteria, element names and a `fill` value. That is how one answer reaches
    two places without the clipboard. {{clipboard}}, {{date}}, {{time}} and
    {{datetime}} are built-in fallbacks, and an unknown name is left exactly as
    written rather than becoming blank.

    SELECTED FILES: {{selected_file}} is the one file selected in File Explorer
    when the run starts (its full path). The run refuses to start unless
    exactly one item is selected — it never guesses. {{selected_files}} is
    every selected path, each in double quotes, space-joined. In a COMMAND
    LINE (a capture `command`, a run `target`) both always arrive correctly
    quoted, whether or not you write quotes around them — so
    `python "C:\\tools\\invoice.py" {{selected_file}}` is right for a path with
    spaces. Elsewhere (text, set values) {{selected_file}} is the bare path.
    Any OTHER value inside a command is inserted as-is: quote it yourself.
    Both come from one snapshot taken before any step or ask dialog;
    run_automation's `args` stand in for the selection when testing.

    COMMANDS: a `capture` step runs a cmd.exe command line (cwd = the VoiceKit
    folder, stdout decoded as UTF-8) and keeps its stdout, trailing whitespace
    trimmed, as a run-local value — never a sheet column. stderr never enters
    the value; a nonzero exit code stops the run and the run record says only
    "Command exited with code N" (no stderr, no filled-in command — they can
    carry client data). A workflow with a capture step runs programs, so treat
    it like a script: never build a command from an `ask` answer unless you
    quote it, and keep destructive commands out of workflows.

    FILLING FORMS: `fill` finds an input by its label (its accessible name —
    for a web form, the field's <label>; dump_uia_tree shows it), clicks it,
    refuses to type unless the keyboard focus actually landed there, types the
    value and reads it back. A reformatted box still passes (1234.5 matches
    1,234.50; 123456789 matches 123-45-6789) but a different value never does.
    Several inputs with one label: "Amount#2" is the second, and without #N the
    first is filled (the run log says so) — write "##" for a literal "#". A
    password box is filled but not read back. Failure reasons never contain the
    value; in a batch keep values as {{Column}} so the run log shows the
    placeholder, not client data.
    """

    type: Literal["run", "focus", "waitwin", "wait", "waitfor", "text", "fill", "ask", "collect",
                  "set", "capture", "keys", "click", "dblclick", "rclick", "hover", "drag", "move",
                  "close", "if", "else", "endif"]
    window: Optional[str] = Field(
        None, description="Window criterion: 'ahk_exe notepad.exe', 'ahk_class CabinetWClass', "
        "or a partial title. For focus/waitwin/click/dblclick/rclick/hover/drag/move/close/fill, "
        "and for if/waitfor (a waitfor on clipboardchanged needs none).")
    target: Optional[str] = Field(
        None, description="run: a program, file, folder, or https:// URL to open.")
    launch: Optional[str] = Field(
        None, description="focus: command to start the app if its window isn't open yet (optional).")
    seconds: Optional[int] = Field(
        None, description="waitwin/waitfor: how long to keep waiting before giving up "
        "(default 10). Raise it for slow pages or big exports. capture: how long the "
        "command may run before its whole process tree is killed and the run stops "
        "(default 30).")
    command: Optional[str] = Field(
        None, description="capture: the cmd.exe command line to run, e.g. "
        "'python \"C:\\tools\\invoice.py\" {{selected_file}}'. Runs hidden from the VoiceKit "
        "folder; may use {{names}} (the selection names arrive quoted for you).")
    ms: Optional[int] = Field(
        None, description="wait: milliseconds to pause (the shortest, if ms_max is set too).")
    ms_max: Optional[int] = Field(
        None, description="wait: pause a RANDOM time between 'ms' and this, e.g. ms=600 "
        "ms_max=1400. Use it whenever the workflow will be looped against a website: "
        "pausing the exact same number of milliseconds every pass is the easiest bot "
        "pattern to spot. Omit for a fixed pause.")
    text: Optional[str] = Field(None, description="text: the literal text to type.")
    label: Optional[str] = Field(
        None, description="ask: what to ask the user for (e.g. 'Customer name'). Every ask input "
        "is collected in dialogs BEFORE the run starts; the answer is typed at this step's "
        "position. Loop runs can batch the answers (typed-in rows or a CSV whose columns are "
        "these labels, one pass per row). collect: the name the grabbed value is saved under — "
        "a column in the workflow's <Base>.inputs.csv sheet (single runs append a row; a loop "
        "fed by the sheet fills the row that ran). set: the name being defined — later steps "
        "use it as {{name}}. capture: the name the command's output is saved under. "
        "Give the name WITHOUT braces.")
    value: Optional[str] = Field(
        None, description="set: what the name stands for. May itself contain {{other}} "
        "references, so values compose (e.g. 'Hi {{First Name}}'), including the built-ins "
        "{{clipboard}}, {{date}}, {{time}}, {{datetime}}, {{selected_file}}, "
        "{{selected_files}}. Unlike collect, a set value is "
        "run-local — it is NOT written to the workflow's sheet. fill: REQUIRED — the value to "
        "put in the box, usually a {{Column}} of a batch row; '' clears the box; one line only.")
    suggestion: Optional[str] = Field(
        None, description="ask: optional answer to prefill in the input dialog.")
    keys: Optional[str] = Field(
        None, description="keys: an AutoHotkey Send string, e.g. '{Enter}', '{Tab 2}', '^s'.")
    element: Optional[str] = Field(
        None, description="click/dblclick/rclick/hover: the on-screen name of what to click or "
        "hover over (button caption, link text, file name). Preferred — survives windows moving. "
        "collect: the named box whose content to read (omit to copy the current selection instead). "
        "fill: the input's label exactly as its accessible name reads (a web form's field label); "
        "append #2, #3... when several inputs share it, and write ## for a literal #.")
    xy: Optional[str] = Field(
        None, description="click/dblclick/rclick/hover: fallback window-relative 'x,y' when there's no name. "
        "drag: required, the window-relative press and release points 'x1,y1,x2,y2'.")
    position: Optional[Literal["left", "right", "top", "bottom", "max"]] = Field(
        None, description="move: where to snap the window.")
    condition: Optional[Literal["winexists", "winnotexists",
                                "elementexists", "elementnotexists",
                                "textvisible", "textnotvisible",
                                "clipboardchanged"]] = Field(
        None, description="if / waitfor: which check to run. winexists/winnotexists test whether "
        "'window' is open; elementexists/elementnotexists test whether 'element' (an exact "
        "on-screen name) is present in 'window'; textvisible/textnotvisible test whether "
        "'element' appears anywhere in 'window' as a case-insensitive substring — use these when "
        "you know the words on screen but not an element's exact name, e.g. waiting for results "
        "or detecting 'No matches found'. clipboardchanged is waitfor-only (an `if` has no "
        "before-value to compare against) and waits for a copy to actually land.")

    def to_abc(self) -> tuple:
        """Map the semantic fields onto the on-disk type|a|b|c — nothing more.
        Every rule about what a step NEEDS lives in vk.create_workflow, so the
        writer imported directly (the fallback when the MCP connection is
        down) enforces exactly what this server does; a missing field maps
        to "" and the writer's "Step N: ..." error names it."""
        t = self.type
        if t == "run":
            return (t, self.target or "", "", "")
        if t == "focus":
            return (t, self.window or "", self.launch or "", "")
        if t == "waitwin":
            return (t, self.window or "", "" if self.seconds is None else str(self.seconds), "")
        if t == "wait":
            if self.ms is None:
                return (t, "", "", "")
            if self.ms_max is not None:
                lo, hi = sorted((int(self.ms), int(self.ms_max)))
                return (t, f"{lo}-{hi}", "", "")     # engine pauses Random(lo, hi)
            return (t, str(self.ms), "", "")
        if t == "text":
            return (t, self.text or "", "", "")
        if t == "ask":
            return (t, self.label or "", self.suggestion or "", "")
        if t == "collect":
            # on disk: collect|label|element| — empty element = copy the
            # current selection; a name = read that box's accessible value.
            return (t, self.label or "", self.element or "", "")
        if t == "set":
            # on disk: set|name|value| — the name is an identifier, never
            # substituted; the value is, so values can compose.
            return (t, self.label or "", self.value or "", "")
        if t == "capture":
            # on disk: capture|name|command|seconds — the name is never
            # substituted, the command is, the timeout rides in paramC.
            return (t, self.label or "", self.command or "",
                    "" if self.seconds is None else str(self.seconds))
        if t == "fill":
            # on disk: fill|window|label|value — the value is passed through
            # as given, None included, so the writer can tell "forgot it"
            # from "" (which deliberately clears the box).
            return (t, self.window or "", self.element or "", self.value)
        if t == "keys":
            return (t, self.keys or "", "", "")
        if t in ("click", "dblclick", "rclick", "hover"):
            return (t, self.window or "", self.element or "", _xy(self.xy))
        if t == "drag":
            # on disk: drag|window||x1,y1,x2,y2 (no element name — positional)
            return (t, self.window or "", "", _xy(self.xy))
        if t == "move":
            return (t, self.window or "", self.position or "", "")
        if t == "close":
            return (t, self.window or "", "", "")
        if t in ("waitfor", "if"):
            cond = self.condition or ""
            needs_elem = cond in vk.CONDS_NEEDING_ELEMENT
            if t == "waitfor" and self.seconds is not None:
                cond = f"{cond},{self.seconds}"        # waitfor|window|element|cond[,secs]
            return (t, self.window or "", (self.element or "") if needs_elem else "", cond)
        if t in ("else", "endif"):
            return (t, "", "", "")
        raise ValueError(f"unknown step type '{t}'")


def _xy(xy: Optional[str]) -> str:
    """'120, 44' -> '120,44' (positions are stored without spaces)."""
    return ",".join(p.strip() for p in xy.split(",")) if xy else ""


def _protect(obj, fn_name: str = "", unmask: bool = False, known: dict | None = None):
    """The outbound privacy pipeline (WP9): phase-1 path normalization
    (always on) and phase-2 masking (privacy.py — the [Privacy] mode in
    logs\\settings.ini). Exempt fields are authored source a caller sends
    back, left byte-for-byte."""
    return privacy.protect(obj, root=vk.REPO_ROOT, normalize=vk.normalize_paths_text,
                           exempt=vk.NORMALIZE_EXEMPT.get(fn_name, ()), unmask=unmask,
                           known=known)


def _guard(fn, *args, _unmask: bool = False, **kwargs):
    """Run a writer call, turning its errors into ToolErrors — and attach the
    state of the always-on layer to every dict result.

    Health rides on EVERY response on purpose. VoiceKit is one AutoHotkey
    process holding every hotkey and every snippet, and a single module can
    take it down (or be parked for having taken it down). Before this, nothing
    said so: the hotkeys just quietly stopped working and stayed that way.

    Every dict result and every error message also goes through _protect —
    the ONE outbound privacy chokepoint (a new response path must too):
    vk.normalize_paths (WP9 phase 1, always on — the profile and temp
    prefixes become %USERPROFILE% / %TEMP%, so a response never carries the
    Windows user name), then privacy.protect (phase 2 — file/folder names
    under the profile become <dir#..>/<file#..> tokens; strict mode adds
    SSN/EIN masks). Authored source a caller will send back
    (vk.NORMALIZE_EXEMPT — read_macro_source's 'source' and friends) is left
    byte-for-byte. _unmask (run_ahk_snippet's audited opt-out) skips the
    tokens for that one response."""
    name = getattr(fn, "__name__", "")
    privacy.start_call()
    try:
        result = fn(*args, **kwargs)
    except (vk.VoiceKitError, ValueError) as e:
        raise ToolError(_protect_error(str(e), name, privacy.take_expanded()))
    except (OSError, subprocess.SubprocessError) as e:
        raise ToolError(_protect_error(
            f"Couldn't run AutoHotkey/PowerShell: {e}. Is AutoHotkey v2 installed at "
            f"{vk.AHK_EXE}? Set the VOICEKIT_AHK env var if it's somewhere else.", name,
            privacy.take_expanded()))
    except Exception as e:              # noqa: BLE001
        # Anything else (a KeyError carrying a path, a bug) would otherwise
        # reach the client as FastMCP's own error text — unmasked.
        logging.getLogger("voicekit.mcp").exception("tool %s", name)
        raise ToolError(_protect_error(f"Internal error in {name or 'the tool'} "
                                       f"({type(e).__name__}): {e}", name,
                                       privacy.take_expanded()))
    known = privacy.take_expanded()
    # Only dict results carry it: to_abc() and friends return tuples.
    if isinstance(result, dict):
        try:
            h = vk.health()
            h["privacy"] = privacy.settings(vk.REPO_ROOT)["mode"]
            note = privacy.settings(vk.REPO_ROOT)["note"]
            if note:
                h["note"] = (h.get("note", "") + " " + note).strip()
            result.setdefault("voicekit", h)
        except Exception:
            pass          # health is a courtesy, never a reason to fail a call
    if _unmask:
        privacy.audit(vk.REPO_ROOT, name or "tool", "unmask=True (output returned "
                      "without path tokens)")
    # EVERY result is protected, whatever its type — a list or a bare string
    # would otherwise go out untouched.
    try:
        result = _protect(result, name, unmask=_unmask, known=known)
    except Exception as e:          # noqa: BLE001 — fail CLOSED, never open
        # Masking itself failed (e.g. no key file could be created): the
        # unmasked result is never sent — only that it was withheld.
        logging.getLogger("voicekit.mcp").exception("privacy masking")
        raise ToolError(f"Privacy masking failed ({type(e).__name__}); the result was "
                        f"withheld rather than sent unmasked. Check that the VoiceKit "
                        f"logs folder is writable (logs/privacy.key, "
                        f"logs/privacy-tokens.json).")
    return result


def _protect_error(msg: str, fn_name: str, known: dict | None = None) -> str:
    """An error message through the same pipeline — and, if masking itself
    fails, withheld rather than sent unmasked."""
    try:
        return _protect(msg, fn_name, known=known)
    except Exception:                   # noqa: BLE001
        return ("The call failed, and its error text was withheld because privacy masking "
                "failed (check that the VoiceKit logs folder is writable).")


# ---------------------------------------------------------------------------
# Create tools
# ---------------------------------------------------------------------------
@mcp.tool
def create_launch_macro(
    name: Annotated[str, "Spoken name / voice phrase, e.g. 'Meeting Notes'. Becomes 'open <name>'."],
    ahk_body: Annotated[Optional[str], "Optional AutoHotkey v2 code to run (top to bottom). "
                        "The generated file #Includes lib\\_Common.ahk, so its names are "
                        "taken at top level (see the server instructions). Omit to "
                        "scaffold a placeholder you fill in later."] = None,
    opens: Annotated[Optional[str], "No-code alternative to ahk_body: an app, file path, folder "
                     "path, or https:// URL — VoiceKit writes the macro itself (the same "
                     "'Open Something' generator the GUI uses). A path may start with "
                     "%USERPROFILE% or %TEMP%, as responses show them."] = None,
) -> dict:
    """Create a launch macro: a standalone script with a Start Menu shortcut, so
    Voice Access can run it with 'open <name>'. Prefer `opens` for open-a-thing
    automations (no code); use `ahk_body` for custom steps. The generated script
    is load-checked; if it fails, nothing is kept. No Voice Access setup needed.
    An existing name is refused — update_macro / edit_macro change an existing
    macro's code.

    A script that acts on the file(s) the user selected in File Explorer should
    take them like this, so it can be tested on a fixture through
    run_automation(args=[...]) without touching the user's windows:
        #Include "%A_ScriptDir%\\..\\lib\\ExplorerSel.ahk"
        files := A_Args.Length ? A_Args : ExplorerSelectedFiles()
    ExplorerSelectedFiles() returns full paths from the ACTIVE tab of the
    front-most Explorer window ([] if none) — insist on the count you need
    rather than taking files[1] of several. There is no generic dry-run flag;
    a script that wants one can honour its own '/dry' argument."""
    return _guard(vk.create_launch_macro, name, ahk_body, opens)


@mcp.tool
def read_macro_source(
    name: Annotated[str, "The macro to read, e.g. 'Split Pages'."],
    previous: Annotated[bool, "True = return the version the last update_macro "
                        "overwrote (the undo path) instead of the current "
                        "source."] = False,
) -> dict:
    """The full source of a macros\\ script — launch macros, hand-written tool
    scripts (kind 'raw_script' in list_automations), AI-action macros, even
    workflow stubs (with a note that the steps file is canonical). Debugging a
    macro used to mean a human opening the file and pasting its 250 lines into
    chat; this is that, as one call. Read before update_macro / edit_macro so
    you change what's there instead of rewriting from memory. Also returns
    'kind' and the header-comment 'description' when the script carries one."""
    return _guard(vk.read_macro_source, name, previous)


@mcp.tool
def update_macro(
    name: Annotated[str, "The existing macro to replace, e.g. 'Split Pages'."],
    ahk_source: Annotated[str, "The complete new AutoHotkey v2 source for the file. Keep "
                          "its #Include lines; a name its includes define (e.g. Notify "
                          "from lib\\_Common.ahk) can't be a top-level variable."],
) -> dict:
    """Replace an existing macro's source in full — the write half of the
    read/patch loop (read_macro_source is the read half; for one-function
    fixes prefer edit_macro, which sends only the changed lines). The new
    source is load-checked and the file rolled back untouched on failure; the
    overwritten source is banked (one step deep) and retrievable via
    read_macro_source(name, previous=True), so an unwanted overwrite stays
    undoable. Refused for VoiceKit's own tools and for generated workflow
    stubs (their steps file is canonical — use create_workflow)."""
    return _guard(vk.update_macro, name, ahk_source)


@mcp.tool
def edit_macro(
    name: Annotated[str, "The macro to edit, e.g. 'Split Pages'."],
    old_string: Annotated[str, "Exact text to find in the macro's current source. Must "
                          "match exactly once — include enough surrounding lines to be "
                          "unique. Whitespace must match exactly."],
    new_string: Annotated[str, "The replacement text."],
) -> dict:
    """Splice-edit a macro in place — same semantics as a file Edit tool, and
    the cheap way to apply a patch: a session that diagnosed a one-function
    bug used to end with 'here's the fix, please apply it by hand'. Read the
    current source with read_macro_source first, then splice. The edited file
    is load-checked and rolled back if it wouldn't parse. Undo = call again
    with the two strings swapped. Live on the macro's next run."""
    return _guard(vk.edit_macro, name, old_string, new_string)


@mcp.tool
def create_ai_action(
    name: Annotated[str, "Spoken name, e.g. 'Fix Grammar'. Becomes 'open <name>'."],
    prompt: Annotated[str, "What the AI should do with the user's selected text, e.g. "
                      "'Fix the grammar and spelling. Return only the corrected text.'"],
) -> dict:
    """Create an AI text action: a saved prompt with its own voice phrase. The
    user selects text in any app, says 'open <name>', and the AI's answer types
    itself in, replacing the selection. Part of VoiceKit's opt-in OpenRouter
    layer — it runs only once the user has saved an API key in AI Settings;
    creating the action makes no network calls."""
    return _guard(vk.create_ai_action, name, prompt)


@mcp.tool
def read_ai_prompt(
    name: Annotated[str, "The AI action to read, e.g. 'Fix Grammar'."],
) -> dict:
    """The full current prompt of an AI action (list_automations only shows a
    120-char preview). Read it before update_ai_prompt when refining a prompt."""
    return _guard(vk.read_ai_prompt, name)


@mcp.tool
def update_ai_prompt(
    name: Annotated[str, "The AI action to change, e.g. 'Fix Grammar'."],
    prompt: Annotated[str, "The new prompt text."],
) -> dict:
    """Rewrite an existing AI action's saved prompt (prompts/<Base>.prompt.txt).
    Takes effect the next time the action runs. Returns the previous prompt so
    an unwanted overwrite can be undone."""
    return _guard(vk.update_ai_prompt, name, prompt)


@mcp.tool
def create_hotkey_module(
    name: Annotated[str, "Name / suggested voice phrase, e.g. 'Toggle Timer'."],
    ahk_body: Annotated[Optional[str], "Optional AutoHotkey v2 code for the hotkey body. "
                        "An isolated body #Includes lib\\_Common.ahk, so its names "
                        "(Notify, EnsureDir, Log, ... — see the server instructions) are "
                        "taken at top level. Omit for a placeholder."] = None,
    isolate: Annotated[bool, "Run the body in its own process (default, recommended). "
                       "VoiceKit is one process holding every hotkey and every snippet, "
                       "and code that crashes hard — a bad ComCall, an unpinned COM "
                       "vtable — takes all of it down. Isolated bodies can't. Set False "
                       "ONLY when the module must keep state between presses (a toggle "
                       "with a variable that has to persist); a separate process starts "
                       "fresh each time."] = True,
    key: Annotated[Optional[str], "Ask for a specific Ctrl+Alt+Shift key instead of taking "
                   "the next free one — a single character, e.g. 'J' or '['. Symbols are "
                   "allowed: [ ] ; ' , . / - = \\. Must be free (get_bridge_map lists free "
                   "keys); only honoured when creating, since a replace keeps its existing "
                   "key. Omit to auto-allocate."] = None,
) -> dict:
    """Create — or REPLACE — an always-on hotkey module bound to a
    Ctrl+Alt+Shift+<key>, registered in bridge-map.txt. Reloads VoiceKit so the
    key is live. Both the key binding and (for an isolated module) the body are
    load-checked; if either fails, nothing is changed.

    Calling this with an EXISTING name replaces that module in place rather than
    erroring, the same way create_workflow does — but it wraps ahk_body in a
    fresh generated header, so it is for regenerating a module from a bare body.
    To CHANGE an existing module, use edit_hotkey_module (one exact-match splice,
    cheapest) or update_hotkey_module (the whole file read_hotkey_module
    returned, written verbatim) — feeding read_hotkey_module's output back in
    here would nest a second generated header inside the first. Do NOT
    delete-then-recreate, and do not invent a near-identical new name to get
    around a collision. A replace keeps the module's existing key (its Voice
    Access pairing was made by hand and can't be recreated by API), adds no
    duplicate registry lines, and switches its #Include back on if it had been
    quarantined. The overwritten code is NOT echoed back — a replace reports
    previous_body_sha256 / length / first lines and banks the full text,
    retrievable via read_hotkey_module(name, previous=True) if you need to undo.
    Only a brand-new module returns voice_pairing steps.

    isolate=False code is load-checked on its own and then again inside
    VoiceKit on the reload: if it clashes with something already loaded there
    (a function or hotkey another file also defines), it is rolled back and the
    call fails with the load error.

    Long-running bodies should report progress with BodyStatus("<Base>", "msg")
    from _Common.ahk (generated bodies already include it) — the home window and
    list_automations surface the latest line. A long LOOP should also check
    BodyStopRequested("<Base>") each pass so stop_module can end it cleanly.

    LIBRARY HELPERS a body can #Include (paths relative to the body file):
      ..\\..\\lib\\_Common.ahk  — BodyStatus / BodyStatusDone / BodyStopRequested,
        BodySingleInstance (one instance per module, immune to the launch race
        #SingleInstance loses), EnsureDir, Notify, Log
      ..\\..\\lib\\UIA.ahk  — the eyes on modern apps (browsers publish NOTHING
        over MSAA): UiaFromWindow, UiaFind / UiaFindById / UiaFindEdit (prefer
        this for form fields — a label and its input share one accessible
        name), UiaFindAll, UiaWaitFor, UiaName / UiaValue / UiaValueOnly /
        UiaRect (an OBJECT {x,y,w,h}, or "" for offscreen/virtualized — never
        a string) / UiaControlType, UiaFocused, UiaClickCenter / UiaClickEl
        (click for real; UiaInvoke does nothing to many inputs; the click
        helpers scroll a rect-less target into view and on false say why via
        an optional &why out-param), UiaScrollIntoView, UiaSetValue,
        UiaTextPresent, UiaDumpText, UiaDumpTree
      ..\\..\\lib\\Browser.ahk  — driving a browser through its keyboard UI
        without the four ways that goes wrong: BrowserEnsureDomain (verify the
        tab BEFORE typing — this is what stops a query becoming a Google
        search), BrowserGrabPage (page text, retried when the grab looks like
        a stranded-omnibox URL), BrowserUrl, BrowserTypeVerified (click, type,
        read the FIELD back — never press Enter after an unverified type)
    For a scraping job, start from read_reference("web-scrape") rather than
    writing the walk/capture/dedupe/resume machinery again.

    By default the code you pass lands in hotkeys/bodies/<Base>.body.ahk and
    runs as its own process; hotkeys/<Base>.ahk is just the key binding the
    master loads. That way a crash in your code ends one short-lived process
    instead of every hotkey and snippet the user owns."""
    return _guard(vk.create_hotkey_module, name, ahk_body, isolate, key)


@mcp.tool
def read_hotkey_module(
    name: Annotated[str, "The hotkey module to read, e.g. 'Toggle Timer'."],
    previous: Annotated[bool, "True = return the version the last replace "
                        "overwrote (the undo path) instead of the current "
                        "code."] = False,
) -> dict:
    """Return a hotkey module's current code. For an isolated module (the
    default) this is the body that actually runs — the half holding the steps.
    Read before changing a module, so you edit what's there instead of
    rewriting it from memory: then edit_hotkey_module (one exact-match splice)
    or update_hotkey_module (pass the whole changed file back, verbatim). Don't
    feed this text to create_hotkey_module — that wraps it in a second
    generated header. previous=True reads the replace-undo snapshot instead —
    the full text a replace or update no longer echoes back."""
    return _guard(vk.read_hotkey_module, name, previous)


@mcp.tool
def edit_hotkey_module(
    name: Annotated[str, "The hotkey module to edit, e.g. 'Toggle Timer'."],
    old_string: Annotated[str, "Exact text to find in the module's current code. Must match "
                          "exactly once — include enough surrounding lines to be unique. "
                          "Whitespace must match exactly."],
    new_string: Annotated[str, "The replacement text."],
) -> dict:
    """Splice-edit a hotkey module in place — same semantics as a file Edit
    tool. This is the cheap way to fix one function: a create_hotkey_module
    replace resends the whole body, an edit sends only the changed lines.
    Read the current code with read_hotkey_module first, then splice. For an
    isolated module (the default) the change is live immediately — the body
    runs fresh on each press, no reload. The edited file is load-checked and
    the edit rolled back if it wouldn't parse, so a typo'd splice never
    bricks anything. Undo = call again with the two strings swapped."""
    return _guard(vk.edit_hotkey_module, name, old_string, new_string)


@mcp.tool
def update_hotkey_module(
    name: Annotated[str, "The hotkey module to rewrite, e.g. 'Toggle Timer'."],
    code: Annotated[str, "The complete new file content (AutoHotkey v2), written "
                    "verbatim. For an isolated module (the default kind) this "
                    "replaces the BODY file read_hotkey_module returns — keep its "
                    "#Include and BodySingleInstance lines, the body needs them. "
                    "An in-process module's code must still define its registered "
                    "^!+<key>:: combo."],
) -> dict:
    """Replace a hotkey module's code in full — read_hotkey_module's write
    half, for rewrites too broad for edit_hotkey_module's single splice.
    Unlike create_hotkey_module (which wraps what you pass in a fresh
    generated header), nothing is re-wrapped: `code` IS the new file, so
    read → change → update round-trips exactly (saved as UTF-8 with LF line
    endings), and passing read_hotkey_module(name, previous=True)'s text back
    restores the banked version's content. The module's registered
    Ctrl+Alt+Shift key is always kept; an in-process module's new code must
    still define that combo — a '^!+<key>::' hotkey line (any modifier order)
    or a Hotkey("^!+<key>", ...) call, outside a comment — or the write is
    refused (the Voice Access pairing is hand-made and would silently die).
    The new code is load-checked and rolled back byte-exact on failure; the
    overwritten file is banked for undo. An isolated body is live on the next
    press with no reload; an in-process module reloads the resident master
    (and is rolled back if VoiceKit won't load with it)."""
    return _guard(vk.update_hotkey_module, name, code)


@mcp.tool
def create_snippet(
    abbrev: Annotated[str, "Abbreviation to type, e.g. '/addr'. No spaces, colons or backticks."],
    expansion: Annotated[str, "Text it expands to. May be multiple lines (newlines are preserved)."],
) -> dict:
    """Create a text snippet (hotstring): typing the abbreviation expands it.
    Fully automated — reloads VoiceKit (reload_note says whether it did). The
    change is load-checked and rolled
    back if it would break Snippets.ahk."""
    return _guard(vk.create_snippet, abbrev, expansion)


@mcp.tool
def create_workflow(
    name: Annotated[str, "Spoken name, e.g. 'Morning Setup'. Becomes 'open <name>'."],
    steps: Annotated[list[WorkflowStep], "Ordered steps. See WorkflowStep for the fields per type."],
) -> dict:
    """Create a multi-step workflow (the recorder's output, authored instead of
    recorded): writes workflows/<Base>.steps.txt, a generated macro stub, and a
    Start Menu shortcut. Prefer clicking by `element` name over `xy`. An
    existing workflow of the same name is replaced ('replaced': true). The stub
    is load-checked; if it fails, nothing is changed — a workflow being
    replaced is put back exactly as it was. Every step is checked first and a
    bad one is named ('Step N: ...'). Run it by saying 'open <name>'; nothing
    needs reloading."""
    abc = []
    for i, s in enumerate(steps, 1):
        try:
            abc.append(s.to_abc())
        except ValueError as e:
            raise ToolError(f"Step {i}: {e}")
    return _guard(vk.create_workflow, name, abc)


# ---------------------------------------------------------------------------
# Read tools
# ---------------------------------------------------------------------------
@mcp.tool
def list_automations() -> dict:
    """List everything VoiceKit knows, with the exact voice phrases: workflows
    (+ their loop phrase), launch macros, AI actions (+ prompt preview),
    hotkey modules (+ key combo), snippets (+ expansion), and VoiceKit's own
    tools. Each launch-macro entry says what KIND it is: 'opens' (a no-code
    opener, + its target) or 'raw_script' (a hand-written application — its
    header comment rides along as 'description', and read_macro_source
    returns its full code). An automation with a companion hotkey (assigned
    via the home window's Hotkey button, for voice-free triggering) carries it
    as "hotkey"; such combos are also press_hotkey-able. Use before creating
    (name collisions) or to find what to run/edit/delete."""
    return _guard(vk.list_automations)


@mcp.tool
def read_log(
    log: Annotated[Literal["activity", "errors", "runs"],
                   "Which log: 'activity' (logs\\created.log — creations, deletions, "
                   "quarantines, and per-run lines tools write, e.g. Split Pages' "
                   "'split-pages | <saved> of <pages> | <file>'), 'errors' "
                   "(logs\\errors.log — uncaught AutoHotkey errors from VoiceKit and "
                   "every macro/body process, with script name and failing line), or "
                   "'runs' (logs\\workflow-runs.log — the engine's per-step log)."] = "activity",
    tail: Annotated[int, "How many lines from the end (default 50, max 500)."] = 50,
    filter: Annotated[Optional[str], "Case-insensitive substring; applied BEFORE the "
                      "tail, so filter='split-pages' gives that tool's last N runs "
                      "however much else happened in between."] = None,
) -> dict:
    """Read the tail of a VoiceKit log — turn 'it keeps crashing' from an
    interview into one call. A tool that fails at a DIFFERENT point each run
    (the activity log shows 'died at page 7, then 12, then 4') is the
    signature of a race; the same failure point every run is a logic bug; and
    'errors' holds the text of the error popup nobody was at the machine to
    read. Read-only."""
    return _guard(vk.read_log, log, tail, filter)


@mcp.tool
def read_workflow(name: Annotated[str, "Workflow name, e.g. 'Morning Setup'."]) -> dict:
    """Return a saved workflow's decoded steps (type + params), so you can review
    or rebuild it."""
    return _guard(vk.read_workflow, name)


@mcp.tool
def get_bridge_map() -> dict:
    """Show the hotkey bridge registry: existing Ctrl+Alt+Shift+<key> bindings,
    which keys are still free, and the reserved keys."""
    return _guard(vk.get_bridge_map)


@mcp.tool
def server_info() -> dict:
    """Which VoiceKit MCP server you are talking to, and what else is out
    there: version, install root, the Python running it, this server's pid
    and start time, whether its code changed on disk since it started (then
    reconnect it), every other VoiceKit server.py process running, and the
    client configs that register a VoiceKit server (Claude Code's
    ~/.claude.json, Claude Desktop's config) with their command paths. Call
    it when VoiceKit's tools show up twice or one seems missing — each
    registration starts its own server with its own copy of the tools.
    Read-only."""
    return _guard(vk.server_info)


@mcp.tool
def inspect_focus() -> dict:
    """What currently has keyboard focus, read over UI Automation: the
    element's name, control type, value, rect, up to three ancestors, and the
    window it lives in. Read-only and side-effect-free — call it freely while
    building or debugging a module that walks focus (e.g. Tab-walking a result
    grid). The accessible name a FOCUSED element reports often differs from
    the text you'd copy off the same page, and matching against the copied
    form is the classic reason a walk silently finds nothing — check here
    before writing the predicate."""
    return _guard(vk.inspect_focus)


@mcp.tool
def dump_uia_tree(
    window: Annotated[Optional[str], "Which window: 'ahk_exe chrome.exe', 'ahk_class ...', or "
                      "a title substring. Omit for the active window."] = None,
    max_depth: Annotated[int, "How deep into the tree to walk (default 8, max 25)."] = 8,
    name_filter: Annotated[Optional[str], "Case-insensitive substring; only elements whose name "
                           "contains it are listed. The walk still covers everything, so a match "
                           "keeps its real indent depth."] = None,
    max_lines: Annotated[int, "Cap on output lines (default 300, max 2000)."] = 300,
) -> dict:
    """A window's UI Automation tree as an indented text outline — control
    types, accessible names, automation ids. Read-only and side-effect-free.
    This answers 'what is actually on screen and what is it called' before you
    write element names into a workflow or a module's UiaFind calls, instead
    of guessing from copied page text (the two routinely differ). Browsers
    expose their whole page here (they publish nothing over MSAA) — but web
    pages VIRTUALIZE: only content near the viewport is realized, so what's
    scrolled out of view can be missing from the dump entirely. Scroll and
    dump again, or navigate to items directly by URL instead of hunting.
    Long-run helpers for module bodies live in lib/UIA.ahk — UiaFocused,
    UiaFind, UiaFindEdit, UiaDumpTree and friends."""
    return _guard(vk.dump_uia_tree, window, max_depth, name_filter, max_lines)


# ---------------------------------------------------------------------------
# Trigger / delete
# ---------------------------------------------------------------------------
@mcp.tool
def run_automation(
    name: Annotated[str, "Any spoken automation: a workflow, launch macro, AI action, "
                    "or VoiceKit tool — e.g. 'Morning Tabs'. 'loop Morning Tabs' starts "
                    "the workflow's loop companion (repeats until the user stops it)."],
    wait_seconds: Annotated[int, "0 (default) = fire-and-forget. >0 = wait up to this long "
                            "for it to finish and report the outcome. Capped at 120 — longer "
                            "blocking waits get cancelled by the client and can wedge the "
                            "connection; for long runs use 0 and check back."] = 0,
    args: Annotated[Optional[list[str]], "Optional command-line arguments for the script "
                    "(its A_Args), one list entry per argument — passed as an argv list, no "
                    "shell, so spaces and & need no quoting. For a WORKFLOW each must be an "
                    "existing file or folder (full path; %USERPROFILE%/%TEMP% forms accepted): "
                    "they replace the File Explorer selection as {{selected_file}} / "
                    "{{selected_files}}, so a selected-file workflow can be tried on a fixture "
                    "file. Test on a sample you created under %TEMP%, not a real client file. "
                    "A raw script decides what its arguments mean; for any script, "
                    "%USERPROFILE%/%TEMP% forms and privacy tokens (<dir#..>, <file#..>) "
                    "arrive as the real path. Refused for Workflow "
                    "Studio and for 'loop <name>'."] = None,
) -> dict:
    """Trigger an automation now — the MCP equivalent of the user saying
    'open <name>', with the same working directory the voice shortcut uses
    (the macro's own folder). NOTE: this drives the real desktop (moves
    windows, types, clicks); a failing workflow step stops with a popup naming
    it. AI actions act on whatever the user currently has selected/focused.
    Loop runs repeat until stopped (Stop Looping button / Ctrl+Alt+Shift+X / a
    failing step) — only start one when the user asked for looping, and a loop
    is refused while another loop or batch is still running (only one runs at a
    time, and a second launch would cut the first short). For workflows,
    waiting (wait_seconds > 0) returns what the run did: ok, outcome, the
    failing step and why. exit_code is not a success signal. There is no
    generic dry-run: to test safely, pass a fixture file via `args` (a raw
    script may implement its own '/dry' argument if it wants one)."""
    return _guard(vk.run_automation, name, wait_seconds, args)


@mcp.tool
def run_workflow_batch(
    name: Annotated[str, "The workflow to run, e.g. 'Send Invoice' (with or without a "
                    "leading 'loop')."],
    rows: Annotated[Optional[list[dict[str, str]]], "EITHER this or source. One object per "
                    "run: keys are the workflow's ask labels (case-insensitive; see "
                    "read_workflow), values are that pass's answers. Every row must answer "
                    "every label, and a row whose answers are all blank is refused."] = None,
    source: Annotated[Optional[str], "EITHER this or rows. Full path to a .csv / .tsv / .txt "
                      "or .xlsx / .xlsm whose rows feed the passes (%USERPROFILE%\\... and "
                      "%TEMP%\\... forms are fine). A CSV is read as UTF-8 (BOM or not), else "
                      "Windows-1252; ',' vs ';' vs tab is detected from the first line holding one. Save an "
                      "open workbook first — the last SAVED version is what's read. Never "
                      "written to."] = None,
    sheet: Annotated[Optional[str], "xlsx only: the tab to read (default: the active tab). "
                     "cell_range may also carry it, as 'Invoices!A2:C40'."] = None,
    cell_range: Annotated[Optional[str], "Which cells: 'A2:C40', 'A2:C' (row 2 down to the last "
                          "used row), 'A:C' (every row). Default: the whole used area. Row "
                          "numbers are sheet rows (CSV: record numbers)."] = None,
    header: Annotated[bool, "True (default): the FIRST row of the range holds the column "
                      "headers. False: no header — map every label with 'col:X' or a "
                      "number."] = True,
    columns: Annotated[Optional[dict[str, str | int]], "ask label -> source column: a header "
                       "name (case-insensitive), 'col:C' (a column letter) or a column number "
                       "(A = 1). Labels left out match a header of the same name."] = None,
    require: Annotated[Optional[list[str]], "Ask labels whose cell must be filled — a row "
                       "where any is blank is skipped (e.g. ['Amount'])."] = None,
    skip_if_filled: Annotated[Optional[list[str | int]], "Columns (header, 'col:B' or number) "
                              "that mark a row as already done — a row with any of them filled "
                              "is skipped (e.g. ['col:B'] for a 'done' column)."] = None,
    skip_blank: Annotated[bool, "True (default): skip rows whose mapped cells are all "
                          "blank."] = True,
    date_format: Annotated[Optional[str], "xlsx date cells: a strftime pattern, e.g. "
                           "'%m/%d/%Y'. Default ISO 'YYYY-MM-DD'."] = None,
    dry_run: Annotated[bool, "True: map, filter and report — including a preview of the "
                       "first rows' VALUES — and launch nothing. Do this first."] = False,
    preview_rows: Annotated[int, "How many mapped rows a dry run previews (default 10, "
                            "max 50)."] = 10,
    wait_seconds: Annotated[int, "0 (default) = fire-and-forget. >0 = wait up to this long "
                            "for the whole batch to finish and report the outcome. Capped at "
                            "120 — for batches longer than ~2 minutes pass 0, then poll "
                            "read_workflow_sheet: loop_running=False means it's done and any "
                            "collected values are final."] = 0,
) -> dict:
    """Run a workflow once per row of inputs — the programmatic version of its
    loop, with no dialogs. Use this for 'do X for each of these' requests:
    e.g. a personalized message per person, one pass per row. NOTE: this
    drives the real desktop; the floating Stop Looping bar lets the user end
    it early, and a failing step stops the batch. Refused while any loop or
    batch is still running (poll read_workflow_sheet's loop_running first):
    only one runs at a time, and a second launch would cut the first short.

    Rows come from `rows` (objects you pass) OR `source` (a CSV or Excel
    range). With source, every skip happens before launch, so pass N is the
    Nth row kept and the reply says which sheet rows ran (pass_rows), which
    were skipped and why (by row number), which column each label read
    (columns), the file's source_modified time, and next_cell_range /
    resume_with for the next call. Example — a 'Send Amount' workflow whose
    ask labels are Amount and Label, fed from an Invoices tab where A = amount,
    B = a 'done' mark, C = label, headers in row 3:
      run_workflow_batch('Send Amount', source='%USERPROFILE%\\Documents\\Invoices.xlsx',
        sheet='Invoices', cell_range='A3:C', columns={'Amount': 'col:A', 'Label': 'col:C'},
        require=['Amount'], skip_if_filled=['col:B'], dry_run=True)
    then the same call with dry_run=False. Values: CSV text passes exactly as
    written (leading zeros kept); an xlsx number is its stored value at
    Excel's 15-digit precision (1234.5, not 1234.4999…; 7, not 7.0; not the
    displayed '$1,234.50'), a '00000'-formatted number keeps its zeros, dates
    are YYYY-MM-DD unless date_format says otherwise, and a cell with an
    Excel error (#N/A, #REF!, ...) refuses the whole batch naming its row.
    Only a dry run's preview shows cell values.

    Where collected values (collect steps) land: with the workflow's own
    inputs sheet as source, beside each row in that sheet; otherwise
    appended to that sheet as new rows. The source file is never written.
    Read them back with read_workflow_sheet when the batch is done.

    When you wait for it (wait_seconds > 0) the reply carries what the run
    actually did, not just that the process ended: ok, outcome, the failing
    step's number/description/reason, passes done vs planned, and a
    step-by-step trace. Never read success from exit_code."""
    return _guard(vk.run_workflow_batch, name, rows, wait_seconds, source=source, sheet=sheet,
                  cell_range=cell_range, header=header, columns=columns, require=require,
                  skip_if_filled=skip_if_filled, skip_blank=skip_blank,
                  date_format=date_format, dry_run=dry_run, preview_rows=preview_rows)


@mcp.tool
def read_workflow_sheet(
    name: Annotated[str, "The workflow whose data to read, e.g. 'Send Invoice'."],
) -> dict:
    """Read a workflow's data files: its inputs sheet (ask columns plus any
    collect columns that runs have filled) and, if present, its results
    overflow file. This is how collected values get back to you after
    run_workflow_batch or a user-driven loop. Also returns loop_running —
    after a fire-and-forget batch, poll this: results are written when the
    loop ends, so loop_running=False means the data is final.

    Includes last_run (outcome, failing step and reason, passes done) whenever
    this workflow has a run record, and an empty sheet gets a note that tells
    never-ran from failed from ran-but-collected-nothing rather than reporting
    all three the same way."""
    return _guard(vk.read_workflow_sheet, name)


@mcp.tool
def run_ahk_snippet(
    code: Annotated[str, "AutoHotkey v2 code (v1 will not run), executed once top to bottom. "
                    "lib\\_Common.ahk, lib\\UIA.ahk, lib\\Browser.ahk and lib\\ExplorerSel.ahk "
                    "are pre-included (UiaFocused, UiaFind, UiaFindEdit, UiaDumpTree, "
                    "UiaClickCenter, BodyStatus, BrowserEnsureDomain, BrowserGrabPage, "
                    "BrowserTypeVerified, ExplorerSelectedFiles, ...), and Out(value) is predefined — every Out() line comes back in "
                    "'output', and it takes ANY value: objects print their properties, so "
                    "Out(UiaRect(el)) just works. The process exits when the code finishes, "
                    "so hotkeys/timers/GUIs won't persist. Every pre-included name (Out, "
                    "Log, Notify, Uia*, Browser*, ...) is taken at top level — `out := 1` "
                    "won't load; use it inside a function or rename. Quote inside \"...\" "
                    "as `\" (v1's \"\" won't load), or use single quotes."],
    timeout_s: Annotated[int, "Kill the snippet after this many seconds (default 15, max 120). "
                         "A timeout still returns whatever Out() wrote before it."] = 15,
    unmask: Annotated[bool, "Privacy (WP9): True returns this one result WITHOUT the "
                      "<dir#..>/<file#..> name tokens — for the debugging case where you must "
                      "read real file names. Audited in logs\\privacy-audit.log; the profile "
                      "still shows as %USERPROFILE%, and strict mode's SSN/EIN masks still "
                      "apply. Leave False unless you need it."] = False,
) -> dict:
    """Run a one-off AutoHotkey v2 snippet in a throwaway process — diagnostics
    without the registry. No bridge key, no module file, no Voice Access
    pairing, nothing to delete afterwards. Use it for probes and experiments:
    'what window titles exist right now?', 'Tab 5 times and Out() each focused
    element's name', 'does this UiaFind match anything?'. For the two commonest
    probes, inspect_focus and dump_uia_tree need no code at all. NOTE: the code
    really runs on the user's desktop — it can type and click like any module,
    so keep snippets read-only unless the user asked for action.

    Errors never vanish: an uncaught runtime error exits 3 with the message
    and failing snippet line in 'output' (in sequence with your Out() lines)
    and in 'errors'; a syntax error exits 2 with the load error in 'errors'.
    A name clash or a v1-style "" quote gets a 'Hint:' line naming the cause
    (e.g. which library defines the name).

    Contracts that bite (from a real session): UiaRect returns an OBJECT
    {x,y,w,h} on success and "" when the element has no rectangle (offscreen
    or virtualized) — never a string, so check IsObject() before member
    access. UiaClickEl / UiaClickCenter / UiaClickName / UiaInvoke scroll a
    rect-less target into view first (UiaScrollIntoView) and on false name
    the reason in an optional &why out-param, e.g.
    UiaClickCenter(hwnd, name, 3000, 0, &why) — check it instead of assuming
    the click landed. Web pages VIRTUALIZE: only content near the viewport
    exists in the UIA tree, so a find that misses something 'on the page'
    means scroll it into view or navigate directly by URL —
    read_reference('web-scrape') shows the robust pattern.

    Privacy: a masked path pasted back INSIDE a quoted string ("%USERPROFILE%
    \\Documents\\<dir#1c2e>\\<file#3a9f>.pdf") is expanded to the real path on
    this PC; a token outside a string literal is refused. The output is masked
    like every response (unmask=True to opt out, audited). Masking stops
    incidental leakage only — text a snippet deliberately Out()s (a document's
    contents) is sent as is."""
    return _guard(vk.run_ahk_snippet, code, timeout_s, _unmask=bool(unmask))


@mcp.tool
def reveal(
    token: Annotated[str, "A privacy token exactly as a response showed it — '<file#3a9f>', "
                     "'<dir#1c2e>' — or a whole masked path "
                     "('%USERPROFILE%\\Documents\\<dir#1c2e>\\<file#3a9f>.pdf')."],
) -> dict:
    """The real file/folder name behind a privacy token (WP9). Masking is on by
    default: names under the user's profile show as <dir#..>/<file#..> tokens
    because on a PC that handles client files they are often client names.
    You rarely need this — pass tokens back as-is wherever a tool acts on a path or value (they're
    expanded locally). Call reveal only when you must read the name itself
    (e.g. to tell the user which file failed). Every call is logged locally
    (token and time, never the name). <ssn#..>/<ein#..> (strict mode) are
    one-way and refused. Read-only."""
    return _guard(vk.reveal, token)


@mcp.tool
def press_hotkey(
    name_or_key: Annotated[str, "A hotkey module's voice phrase ('Toggle Timer'), its "
                           "file base ('ToggleTimer'), its bare key ('A', or a symbol "
                           "like '['), or — for a companion hotkey — the name of the "
                           "automation list_automations shows it under ('Record My "
                           "Steps')."],
) -> dict:
    """Trigger an always-on hotkey module by synthesizing its registered
    Ctrl+Alt+Shift combo (only combos in bridge-map.txt can be pressed, and
    the key must be one character of VoiceKit's key pool — letters, digits
    and a few measured-safe symbols). Requires the resident VoiceKit master to
    be running."""
    return _guard(vk.press_hotkey, name_or_key)


@mcp.tool
def read_reference(
    name: Annotated[Optional[str], "Which worked example: 'web-scrape'. Omit for the "
                    "catalogue."] = None,
) -> dict:
    """Worked example code to copy. Start here for a 'scrape a website' request
    instead of writing a body from scratch: 'web-scrape' is a complete,
    load-checked scraper body — search term, keyboard walk of the results,
    background-tab capture, dedupe file, resumable queue, varied pacing, and a
    stop the user (Esc) or stop_module can trigger. Every guard in it is there
    because its absence cost a real failed run. Copy it into
    hotkeys/bodies/<Base>.body.ahk and edit the CONFIGURE ME block; its
    #Include paths are already correct for that folder."""
    return _guard(vk.read_reference, name or "")


@mcp.tool
def read_module_status(
    name: Annotated[str, "The hotkey module to ask about, e.g. 'Web Scrape'."],
) -> dict:
    """Is this module's body still going, and how far in? Joins the two halves
    that answer it — the latest BodyStatus line it published (with how long
    ago) and whether its process is actually alive — because either alone
    misleads: a fresh-looking line from a body that died hours ago reads as
    progress, and a running body with no line reads as nothing happening. Poll
    this instead of scheduling something to notice a long run finishing.
    Read-only."""
    return _guard(vk.read_module_status, name)


@mcp.tool
def list_running() -> dict:
    """Which isolated module bodies are executing right now — name, pid, start
    time, how long, and the latest BodyStatus line each has published. The
    lifecycle view: press_hotkey starts a body, this shows it running,
    stop_module ends it. A long harvest that died shows up by being ABSENT
    here while its status line in list_automations goes stale. Read-only."""
    return _guard(vk.list_running)


@mcp.tool
def stop_module(
    name: Annotated[str, "The hotkey module whose running body to stop, e.g. "
                    "'Web Scrape'."],
    grace_s: Annotated[int, "Seconds to wait for a graceful exit before force-killing "
                       "(0-60, default 5). 0 = kill immediately."] = 5,
) -> dict:
    """Stop a module's running body process. Graceful first: drops the stop
    flag that BodyStopRequested() (lib/_Common.ahk) consumes — a body that
    checks it each loop pass finishes the item in hand and exits cleanly —
    then force-kills whatever is still alive after grace_s. Scoped to the
    named module's own PIDs, never a name-pattern kill. list_running shows
    what can be stopped; the flag is cleaned up in every path so a stop can
    never leak into the module's next run. A process this server may not end
    (e.g. one running elevated) is reported as stopped=False with
    still_running, never as stopped; a pid this server couldn't even open is
    listed in could_not_open, and a stop involving one is never "graceful"
    (how="exited" when it went away — whether it saw the flag can't be told)."""
    return _guard(vk.stop_module, name, grace_s)


@mcp.tool
def delete_automation(
    name: Annotated[str, "Name of the automation (for snippets, the abbreviation)."],
    type: Annotated[Literal["launch_macro", "workflow", "hotkey_module", "snippet", "ai_action"],
                    "Which kind to delete."],
) -> dict:
    """Delete an automation and its artifacts (script/steps file, generated stub,
    prompt file, Start Menu shortcuts, index/bridge-map/snippet line, and any
    companion hotkey the user assigned in the home window). Destructive.
    VoiceKit's own tools can't be deleted; a macro without the 'Workflow Studio'
    marker is only removed via type='launch_macro' (or 'ai_action' if it has a
    prompt file)."""
    return _guard(vk.delete_automation, name, type)


if __name__ == "__main__":
    mcp.run()
