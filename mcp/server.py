"""VoiceKit MCP server.

Exposes VoiceKit's automation-creation as MCP tools so Claude (Desktop or
Claude Code) can build the same launch macros, snippets, hotkey modules and
step-workflows the GUI scaffolder/recorder build — but from natural language.

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
      move     -> window + position (left/right/top/bottom/max)
      close    -> window
    """

    type: Literal["run", "focus", "waitwin", "wait", "text", "keys",
                  "click", "dblclick", "rclick", "move", "close"]
    window: Optional[str] = Field(
        None, description="Window criterion: 'ahk_exe notepad.exe', 'ahk_class CabinetWClass', "
        "or a partial title. For focus/waitwin/click/dblclick/rclick/move/close.")
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
        None, description="click/dblclick/rclick: the on-screen name of what to click "
        "(button caption, link text, file name). Preferred — survives windows moving.")
    xy: Optional[str] = Field(
        None, description="click/dblclick/rclick: fallback window-relative 'x,y' when there's no name.")
    position: Optional[Literal["left", "right", "top", "bottom", "max"]] = Field(
        None, description="move: where to snap the window.")

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
        if t in ("click", "dblclick", "rclick"):
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
) -> dict:
    """Create a launch macro: a standalone script with a Start Menu shortcut, so
    Voice Access can run it with 'open <name>'. Best for run-some-steps-now
    automations. The generated script is load-checked; if it fails, nothing is
    kept. No Voice Access setup needed."""
    return _guard(vk.create_launch_macro, name, ahk_body)


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
    expansion: Annotated[str, "Text it expands to."],
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
    """List everything VoiceKit knows: launch macros, workflows, hotkey modules,
    and snippets. Use before creating to avoid name collisions or to find what
    to edit/run/delete."""
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
# Run / delete
# ---------------------------------------------------------------------------
@mcp.tool
def run_workflow(name: Annotated[str, "Workflow (or launch macro) name to run."]) -> dict:
    """Run a saved workflow/launch macro now. NOTE: this drives the real desktop
    (moves windows, types, clicks). A failing step stops with a popup naming it."""
    return _guard(vk.run_workflow, name)


@mcp.tool
def delete_automation(
    name: Annotated[str, "Name of the automation (for snippets, the abbreviation)."],
    type: Annotated[Literal["launch_macro", "workflow", "hotkey_module", "snippet"],
                    "Which kind to delete."],
) -> dict:
    """Delete an automation and its artifacts (script/steps file, generated stub,
    Start Menu shortcut, index/bridge-map/snippet line). Destructive. Hand-written
    macros are protected: a macro without the 'Workflow Studio' marker is only
    removed via type='launch_macro'."""
    return _guard(vk.delete_automation, name, type)


if __name__ == "__main__":
    mcp.run()
