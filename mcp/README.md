# VoiceKit MCP server

Create **and trigger** VoiceKit automations from natural language. This is an
**optional** add-on to VoiceKit: a [FastMCP](https://gofastmcp.com) server that
exposes the same automation-creation the GUI does — launch macros, snippets,
hotkey modules, multi-step workflows, and AI text actions — as MCP tools, and can
run any of them the same way Voice Access does. The recorder/scaffolder still
work unchanged; this is a third path.

## What it can do

| Tool | Creates / does |
|------|----------------|
| `create_launch_macro` | A `macros\<Name>.ahk` + Start Menu shortcut → say "open \<name\>". `opens` (no-code: app/file/folder/URL) or `ahk_body` (custom code). |
| `create_ai_action` | A saved AI prompt with its own voice phrase (select text → say it → the answer replaces the selection). Opt-in OpenRouter layer; creating it makes no network calls. |
| `update_ai_prompt` | Rewrite an existing AI action's prompt. |
| `create_hotkey_module` | A `hotkeys\<Name>.ahk` on an auto-allocated `Ctrl+Alt+Shift+<key>`; returns the one-time Voice Access pairing steps. |
| `create_snippet` | A hotstring in `Snippets.ahk` (e.g. `/addr` → your address). |
| `create_workflow` | The recorder's output, **authored** instead of recorded: `workflows\<Name>.steps.txt` + generated stub + shortcut. |
| `list_automations`, `read_workflow`, `read_ai_prompt`, `get_bridge_map` | Inspect what exists (exact voice phrases, full AI prompts). |
| `run_automation` | **Trigger** any spoken automation now — the MCP equivalent of "open \<name\>". `loop <name>` starts a workflow's loop companion (repeats until the user stops it). Optional `wait_seconds` to wait and report the outcome. |
| `run_workflow_batch` | **Run a workflow once per row of inputs**, no dialogs — "send a personalized message to each of these people". Pass `rows` (one object per run, keys = the workflow's ask labels); the loop runs headlessly with the floating Stop bar still up, and `collect` steps save each pass's values to the workflow's sheet. |
| `read_workflow_sheet` | Read a workflow's data back: its inputs sheet (ask columns + collect columns filled by runs) and any results overflow file — how collected values return to you after a batch. |
| `press_hotkey` | **Trigger** an always-on hotkey module by synthesizing its registered combo (bridge-map entries only; needs the resident VoiceKit running). |
| `delete_automation` | Remove an automation and its artifacts (VoiceKit's own tools are protected). |

Every generated `.ahk` is load-checked with AutoHotkey before it's kept; if it
fails, nothing is written (snippets roll back). Hotkey/snippet changes reload the
running VoiceKit automatically. After updating the server, **restart your MCP
client** (or the `voicekit` connection) so it picks up the new tool list.

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
{ "type": "hover",   "window": "Untitled - Notepad", "element": "Format" }
{ "type": "move",    "window": "ahk_exe notepad.exe", "position": "left" }
{ "type": "close",   "window": "ahk_exe notepad.exe" }
```

Workflows can also **branch** — deterministic state checks only (no pixel
guessing), each `if` closed by an `endif`, `else` optional:

```
{ "type": "if",    "window": "ahk_exe notepad.exe", "condition": "winexists" }
{ "type": "text",  "text": "already open" }
{ "type": "else" }
{ "type": "run",   "target": "notepad.exe" }
{ "type": "endif" }
```

Conditions: `winexists` / `winnotexists` (is the window open) and
`elementexists` / `elementnotexists` (is a named element on screen in it —
set `element` too). Balance is validated at create time.

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
  create a persistent payload. Note which tools have an **immediate effect**:
  `run_automation` (runs on the desktop now, including `loop <name>` runs),
  `press_hotkey` (fires a registered combo now — it can only press combos
  already in bridge-map.txt, never arbitrary keys), and everything that
  reloads the resident master: `create_hotkey_module`, `create_snippet`
  (the new hotstring is armed the moment it loads — it fires on ordinary
  typing), and `delete_automation` for hotkeys/snippets. `create_launch_macro`,
  `create_workflow`, and `create_ai_action` only fire when later triggered.
- **AI actions and the network.** Creating or editing an AI action writes
  only local files. When the *user* (or `run_automation`) later triggers it,
  it sends the saved prompt plus the current selection/clipboard to
  OpenRouter under the user's own key — same behavior as actions made in the
  GUI. No key, no network.
- **The load-check is not a safety check.** Generated scripts are `/validate`d
  so a broken one is rolled back — but that only proves it *loads*, not that
  it's *safe*. There is deliberately no allow/blocklist on AHK content; that
  would be security theater for an arbitrary-automation tool.

**What you should do:**
1. **Keep your MCP client's tool-approval prompts on** for `voicekit` — don't
   blanket-allow it. Review `create_*` arguments (especially `ahk_body` and
   `run` targets), `run_automation`, and `press_hotkey` before approving.
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
