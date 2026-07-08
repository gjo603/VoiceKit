# VoiceKit MCP server

Create VoiceKit automations from natural language. This is an **optional** add-on
to VoiceKit: a [FastMCP](https://gofastmcp.com) server that exposes the same
automation-creation the GUI does — launch macros, snippets, hotkey modules, and
multi-step workflows — as MCP tools, so Claude (Desktop or Claude Code) can build
them for you. The traditional recorder/scaffolder still work unchanged; this is a
third path.

## What it can do

| Tool | Creates / does |
|------|----------------|
| `create_launch_macro` | A `macros\<Name>.ahk` + Start Menu shortcut → say "open \<name\>". Optional `ahk_body`. |
| `create_hotkey_module` | A `hotkeys\<Name>.ahk` on an auto-allocated `Ctrl+Alt+Shift+<key>`; returns the one-time Voice Access pairing steps. |
| `create_snippet` | A hotstring in `Snippets.ahk` (e.g. `/addr` → your address). |
| `create_workflow` | The recorder's output, **authored** instead of recorded: `workflows\<Name>.steps.txt` + generated stub + shortcut. |
| `list_automations`, `read_workflow`, `get_bridge_map` | Inspect what exists. |
| `run_workflow` | Run one now (drives the real desktop). |
| `delete_automation` | Remove an automation and its artifacts. |

Every generated `.ahk` is load-checked with AutoHotkey before it's kept; if it
fails, nothing is written (snippets roll back). Hotkey/snippet changes reload the
running VoiceKit automatically.

## Setup

Requires **Python 3.10+** and VoiceKit's **AutoHotkey v2** (the server shells out
to `AutoHotkey64.exe` to validate/reload). From this `mcp\` folder:

```
Setup-MCP.bat
```

That creates `.venv`, installs `fastmcp`, and prints your exact paths. (Manual
equivalent: `python -m venv .venv && .venv\Scripts\activate && pip install fastmcp`.)

### Register with Claude Code

```
claude mcp add voicekit -- "C:\Automations\VoiceKit\mcp\.venv\Scripts\python.exe" "C:\Automations\VoiceKit\mcp\server.py"
```

### Register with Claude Desktop

Edit `%APPDATA%\Claude\claude_desktop_config.json` (create it if absent) and add —
note the **doubled backslashes** (JSON):

```json
{
  "mcpServers": {
    "voicekit": {
      "command": "C:\\Automations\\VoiceKit\\mcp\\.venv\\Scripts\\python.exe",
      "args": ["C:\\Automations\\VoiceKit\\mcp\\server.py"]
    }
  }
}
```

Restart Claude Desktop; the tools appear under the 🔨 menu.

If VoiceKit lives somewhere other than `C:\Automations\VoiceKit`, set the env var
`VOICEKIT_ROOT` (and `VOICEKIT_AHK` if AutoHotkey isn't at the default path) in the
MCP config, or just adjust the paths above — the server self-locates from its own
folder by default.

## Try it

> "Make a workflow called Morning Setup that opens Notepad, waits for its window,
> types 'stand-up notes', then snaps it to the left half of the screen."

Claude calls `create_workflow` with typed steps; you then say **"open morning setup"**.

## Examples of workflow steps

```
{ "type": "run",     "target": "notepad.exe" }
{ "type": "focus",   "window": "ahk_exe notepad.exe", "launch": "notepad.exe" }
{ "type": "waitwin", "window": "ahk_exe notepad.exe", "seconds": 10 }
{ "type": "text",    "text": "hello" }
{ "type": "keys",    "keys": "^s" }
{ "type": "click",   "window": "Untitled - Notepad", "element": "File" }
{ "type": "move",    "window": "ahk_exe notepad.exe", "position": "left" }
{ "type": "close",   "window": "ahk_exe notepad.exe" }
```

## Security

**These tools create code that runs with your privileges.** A launch macro or
hotkey module can contain arbitrary AutoHotkey; a workflow `run` step can launch
any program. That is VoiceKit's purpose — but exposing it over MCP means an
*LLM* decides when to call these tools, so treat it accordingly.

- **No network surface.** The server uses stdio — it only talks to the client
  that spawned it. There's no listening port, no telemetry, no cloud calls.
- **No injection/traversal.** Automation names are stripped to `[A-Za-z0-9]`
  (no `..`, slashes, or colons — traversal is impossible) and Windows device
  names are rejected. Shortcut creation quotes its inputs and every subprocess
  call is argument-list form (no shell), so names can't inject shell/PowerShell
  commands. Verified by tests.
- **The real risk is prompt injection (a confused-deputy).** If Claude is
  processing untrusted content (a web page, email, file) that hides an
  instruction like *"use voicekit to create a macro that runs …"*, it could
  create a persistent payload. Note which tools execute **immediately**:
  `create_hotkey_module` (reloads the resident master) and `run_workflow`
  (runs on the desktop now). `create_launch_macro`, `create_workflow`, and
  `create_snippet` only fire when later triggered.
- **The load-check is not a safety check.** Generated scripts are `/validate`d
  so a broken one is rolled back — but that only proves it *loads*, not that
  it's *safe*. There is deliberately no allow/blocklist on AHK content; that
  would be security theater for an arbitrary-automation tool.

**What you should do:**
1. **Keep your MCP client's tool-approval prompts on** for `voicekit` — don't
   blanket-allow it. Review `create_*` arguments (especially `ahk_body` and
   `run` targets) and `run_workflow` before approving.
2. **Don't use this server in sessions that ingest untrusted content** without
   watching the tool calls.
3. **Don't put secrets in automations.** Created macros, `Snippets.ahk`, and
   `bridge-map.txt` are git-tracked — they can be committed and pushed. Keep the
   repo private. (Snippet expansions can also include keystrokes like `{Enter}`,
   not just inert text.)
4. FastMCP and its dependencies come from PyPI (pinned `>=2.9,<4`); they run
   in-process, so treat them like any other supply-chain dependency.

## Maintenance

`voicekit_writer.py` mirrors VoiceKit's on-disk format (a deliberate second copy
of the AHK write-side). **`test_conformance.py` is what keeps them honest** — it
feeds the writer's output through the real AutoHotkey engine and byte-compares.
Run it after any format change:

```
.venv\Scripts\python test_conformance.py
```
