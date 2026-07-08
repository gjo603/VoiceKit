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

## Maintenance

`voicekit_writer.py` mirrors VoiceKit's on-disk format (a deliberate second copy
of the AHK write-side). **`test_conformance.py` is what keeps them honest** — it
feeds the writer's output through the real AutoHotkey engine and byte-compares.
Run it after any format change:

```
.venv\Scripts\python test_conformance.py
```
