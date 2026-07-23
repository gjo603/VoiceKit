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

import subprocess
from typing import Annotated, Literal, Optional

from pydantic import BaseModel, Field, model_validator

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

import voicekit_writer as vk

mcp = FastMCP(name="VoiceKit")


# ---------------------------------------------------------------------------
# Workflow step schema — semantic fields the LLM fills, mapped to type|a|b|c
# ---------------------------------------------------------------------------
class WorkflowStep(BaseModel):
    """One step of a workflow. Set the fields relevant to `type`:

      run      -> target
      focus    -> window   (+ launch to open it if not running)
      waitwin  -> window   (+ seconds, default 10)
      wait     -> ms
      text     -> text
      keys     -> keys
      click/dblclick/rclick -> window + element (name on screen)   [or xy]
      hover    -> window + element (or xy) — moves the mouse there and pauses
      move     -> window + position (left/right/top/bottom/max)
      close    -> window
      if       -> window + condition (+ element for the *element* conditions)
      else     -> (no fields)   branch to run when the `if` was false
      endif    -> (no fields)   closes the `if` block

    Branching is optional. An `if` runs its following steps only when the
    condition holds; pair it with an optional `else` and a closing `endif`.
    """

    type: Literal["run", "focus", "waitwin", "wait", "text", "keys",
                  "click", "dblclick", "rclick", "hover", "move", "close",
                  "if", "else", "endif"]
    window: Optional[str] = Field(
        None, description="Window criterion: 'ahk_exe notepad.exe', 'ahk_class CabinetWClass', "
        "or a partial title. For focus/waitwin/click/dblclick/rclick/hover/move/close.")
    target: Optional[str] = Field(
        None, description="run: a program, file, folder, or https:// URL to open.")
    launch: Optional[str] = Field(
        None, description="focus: command to start the app if its window isn't open yet (optional).")
    seconds: Optional[int] = Field(
        None, description="waitwin: seconds to wait for the window (default 10).")
    ms: Optional[int] = Field(None, description="wait: milliseconds to pause.")
    text: Optional[str] = Field(None, description="text: the literal text to type.")
    keys: Optional[str] = Field(
        None, description="keys: an AutoHotkey Send string, e.g. '{Enter}', '{Tab 2}', '^s'.")
    element: Optional[str] = Field(
        None, description="click/dblclick/rclick/hover: the on-screen name of what to click or "
        "hover over (button caption, link text, file name). Preferred — survives windows moving.")
    xy: Optional[str] = Field(
        None, description="click/dblclick/rclick/hover: fallback window-relative 'x,y' when there's no name.")
    position: Optional[Literal["left", "right", "top", "bottom", "max"]] = Field(
        None, description="move: where to snap the window.")
    condition: Optional[Literal["winexists", "winnotexists",
                                "elementexists", "elementnotexists"]] = Field(
        None, description="if: which check to run. winexists/winnotexists test whether 'window' is "
        "open; elementexists/elementnotexists test whether 'element' (an on-screen name) is present "
        "in 'window'.")

    def to_abc(self) -> tuple:
        t = self.type
        if t == "run":
            _need(self.target, "run", "target")
            return (t, self.target, "", "")
        if t == "focus":
            _need(self.window, "focus", "window")
            return (t, self.window, self.launch or "", "")
        if t == "waitwin":
            _need(self.window, "waitwin", "window")
            return (t, self.window, "" if self.seconds is None else str(self.seconds), "")
        if t == "wait":
            if self.ms is None:
                raise ValueError("wait step needs 'ms'")
            return (t, str(self.ms), "", "")
        if t == "text":
            if self.text is None:
                raise ValueError("text step needs 'text'")
            return (t, self.text, "", "")
        if t == "keys":
            _need(self.keys, "keys", "keys")
            return (t, self.keys, "", "")
        if t in ("click", "dblclick", "rclick", "hover"):
            _need(self.window, t, "window")
            if not self.element and not self.xy:
                raise ValueError(f"{t} step needs 'element' (preferred) or 'xy'")
            return (t, self.window, self.element or "", self.xy or "")
        if t == "move":
            _need(self.window, "move", "window")
            _need(self.position, "move", "position")
            return (t, self.window, self.position, "")
        if t == "close":
            _need(self.window, "close", "window")
            return (t, self.window, "", "")
        if t == "if":
            _need(self.condition, "if", "condition")
            _need(self.window, "if", "window")
            needs_elem = self.condition in ("elementexists", "elementnotexists")
            if needs_elem and not self.element:
                raise ValueError("if with an element condition needs 'element'")
            # on disk: if|window|element|condType
            return (t, self.window, self.element or "" if needs_elem else "", self.condition)
        if t in ("else", "endif"):
            return (t, "", "", "")
        raise ValueError(f"unknown step type '{t}'")


def _need(value, step_type, field):
    if not value:
        raise ValueError(f"{step_type} step needs '{field}'")


def _guard(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except (vk.VoiceKitError, ValueError) as e:
        raise ToolError(str(e))
    except (OSError, subprocess.SubprocessError) as e:
        raise ToolError(
            f"Couldn't run AutoHotkey/PowerShell: {e}. Is AutoHotkey v2 installed at "
            f"{vk.AHK_EXE}? Set the VOICEKIT_AHK env var if it's somewhere else.")


# ---------------------------------------------------------------------------
# Create tools
# ---------------------------------------------------------------------------
@mcp.tool
def create_launch_macro(
    name: Annotated[str, "Spoken name / voice phrase, e.g. 'Meeting Notes'. Becomes 'open <name>'."],
    ahk_body: Annotated[Optional[str], "Optional AutoHotkey v2 code to run (top to bottom). "
                        "Omit to scaffold a placeholder you fill in later."] = None,
    opens: Annotated[Optional[str], "No-code alternative to ahk_body: an app, file path, folder "
                     "path, or https:// URL — VoiceKit writes the macro itself (the same "
                     "'Open Something' generator the GUI uses)."] = None,
) -> dict:
    """Create a launch macro: a standalone script with a Start Menu shortcut, so
    Voice Access can run it with 'open <name>'. Prefer `opens` for open-a-thing
    automations (no code); use `ahk_body` for custom steps. The generated script
    is load-checked; if it fails, nothing is kept. No Voice Access setup needed."""
    return _guard(vk.create_launch_macro, name, ahk_body, opens)


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
                        "Omit for a placeholder."] = None,
) -> dict:
    """Create an always-on hotkey module bound to an auto-allocated
    Ctrl+Alt+Shift+<key>, and register it in bridge-map.txt. Returns the key and
    the one-time Voice Access pairing steps (there is no API to create the voice
    shortcut — that stays manual). Reloads VoiceKit so the key is live."""
    return _guard(vk.create_hotkey_module, name, ahk_body)


@mcp.tool
def create_snippet(
    abbrev: Annotated[str, "Abbreviation to type, e.g. '/addr'. No spaces or colons."],
    expansion: Annotated[str, "Text it expands to. May be multiple lines (newlines are preserved)."],
) -> dict:
    """Create a text snippet (hotstring): typing the abbreviation expands it.
    Fully automated — reloads VoiceKit. The change is load-checked and rolled
    back if it would break Snippets.ahk."""
    return _guard(vk.create_snippet, abbrev, expansion)


@mcp.tool
def create_workflow(
    name: Annotated[str, "Spoken name, e.g. 'Morning Setup'. Becomes 'open <name>'."],
    steps: Annotated[list[WorkflowStep], "Ordered steps. See WorkflowStep for the fields per type."],
) -> dict:
    """Create a multi-step workflow (the recorder's output, authored instead of
    recorded): writes workflows/<Base>.steps.txt, a generated macro stub, and a
    Start Menu shortcut. Prefer clicking by `element` name over `xy`. The stub is
    load-checked; if it fails, nothing is kept. Run it by saying 'open <name>'."""
    abc = [_guard(s.to_abc) for s in steps]
    return _guard(vk.create_workflow, name, abc)


# ---------------------------------------------------------------------------
# Read tools
# ---------------------------------------------------------------------------
@mcp.tool
def list_automations() -> dict:
    """List everything VoiceKit knows, with the exact voice phrases: workflows
    (+ their loop phrase), launch macros (+ what they open), AI actions
    (+ prompt preview), hotkey modules (+ key combo), snippets (+ expansion),
    and VoiceKit's own tools. An automation with a companion hotkey (assigned
    via the home window's Hotkey button, for voice-free triggering) carries it
    as "hotkey"; such combos are also press_hotkey-able. Use before creating
    (name collisions) or to find what to run/edit/delete."""
    return _guard(vk.list_automations)


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


# ---------------------------------------------------------------------------
# Trigger / delete
# ---------------------------------------------------------------------------
@mcp.tool
def run_automation(
    name: Annotated[str, "Any spoken automation: a workflow, launch macro, AI action, "
                    "or VoiceKit tool — e.g. 'Morning Tabs'. 'loop Morning Tabs' starts "
                    "the workflow's loop companion (repeats until the user stops it)."],
    wait_seconds: Annotated[int, "0 (default) = fire-and-forget. >0 = wait up to this "
                            "long for it to finish and report the outcome."] = 0,
) -> dict:
    """Trigger an automation now — the MCP equivalent of the user saying
    'open <name>'. NOTE: this drives the real desktop (moves windows, types,
    clicks); a failing workflow step stops with a popup naming it. AI actions
    act on whatever the user currently has selected/focused. Loop runs repeat
    until stopped (Stop Looping button / Ctrl+Alt+Shift+X / a failing step) —
    only start one when the user asked for looping."""
    return _guard(vk.run_automation, name, wait_seconds)


@mcp.tool
def press_hotkey(
    name_or_key: Annotated[str, "A hotkey module's voice phrase ('Toggle Timer'), its "
                           "file base ('ToggleTimer'), or its bare key letter ('A')."],
) -> dict:
    """Trigger an always-on hotkey module by synthesizing its registered
    Ctrl+Alt+Shift combo (only combos in bridge-map.txt can be pressed).
    Requires the resident VoiceKit master to be running."""
    return _guard(vk.press_hotkey, name_or_key)


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
