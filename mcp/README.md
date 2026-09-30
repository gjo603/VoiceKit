# VoiceKit MCP server

Create **and trigger** VoiceKit automations from natural language. This is an
**optional** add-on to VoiceKit: a [FastMCP](https://gofastmcp.com) server that
exposes the same automation-creation the GUI does — launch macros, snippets,
hotkey modules, multi-step workflows, and AI text actions — as MCP tools, and can
run any of them the same way Voice Access does. The recorder/scaffolder still
work unchanged; this is a third path.

## What it can do

Every tool the server exposes (30). `test_conformance.py` checks this table
names each one, so a new tool can't ship undocumented.

**Create and change**

| Tool | Creates / does |
|------|----------------|
| `create_launch_macro` | A `macros\<Name>.ahk` + Start Menu shortcut → say "open \<name\>". `opens` (no-code: app/file/folder/URL) or `ahk_body` (custom code; `lib\_Common.ahk` is pre-included). |
| `read_macro_source`, `update_macro`, `edit_macro` | Read any `macros\` script's full source (with its `kind` and header description), replace it in full, or splice one exact-match change. Load-checked with byte-exact rollback; the overwritten source is banked one step deep (`previous=True` reads it back). Generated workflow stubs and VoiceKit's own tools are refused (Split Pages stays editable). |
| `create_ai_action` | A saved AI prompt with its own voice phrase (select text → say it → the answer replaces the selection). Opt-in OpenRouter layer; creating it makes no network calls. |
| `read_ai_prompt`, `update_ai_prompt` | Read an AI action's full prompt; rewrite it (returns the previous prompt for undo). |
| `create_hotkey_module` | A hotkey module on a `Ctrl+Alt+Shift+<key>` (auto-allocated, or pick one with `key=`); by default an isolated body in `hotkeys\bodies\` that runs in its own process. On an existing name it **replaces in place** and keeps the registered key. Returns the one-time Voice Access pairing steps. |
| `read_hotkey_module`, `edit_hotkey_module`, `update_hotkey_module` | Read a module's current code (the body, for an isolated module), splice one exact-match change, or replace the file in full (verbatim — what `read` returns is what `update` writes). Every write is load-checked and rolled back on failure, the overwritten text is banked for undo (`previous=True`), and the module's assigned key — with its hand-made Voice Access pairing — is always kept. |
| `create_snippet` | A hotstring in `hotkeys\Snippets.ahk` (e.g. `/addr` → your address). |
| `create_workflow` | The recorder's output, **authored** instead of recorded: `workflows\<Name>.steps.txt` + generated stub + shortcut + `loop <name>` companion. Replacing an existing workflow is rolled back to the previous version if the new one fails its check. |
| `delete_automation` | Remove an automation and all its artifacts (companion hotkey, sheets, backups included). VoiceKit's own tools, Split Pages and `Snippets` are protected. |

**Inspect (read-only)**

| Tool | Returns |
|------|---------|
| `list_automations` | Everything sayable/typable, with exact voice phrases: workflows (+ loop phrase), launch macros (`kind` = `opens` / `raw_script`), AI actions, hotkey modules (+ combo, latest body `status`), snippets, tools. |
| `read_workflow`, `get_bridge_map` | A workflow's steps; the hotkey registry with free and reserved keys. |
| `read_workflow_sheet` | A workflow's inputs sheet and results overflow as columns/rows, plus `last_run` — how collected values come back after a batch. |
| `read_log` | The tail of `activity` (created.log), `errors` (errors.log — uncaught errors from any VoiceKit script) or `runs` (workflow-runs.log), optionally filtered. |
| `read_reference` | Worked example code to copy (currently `web-scrape`, a complete scraper body). |
| `inspect_focus`, `dump_uia_tree` | What has keyboard focus, and a window's UI Automation tree as an outline — the real on-screen names to use in a workflow or a module's `UiaFind`. Out-of-process probes; nothing is clicked. |
| `list_running`, `read_module_status` | Which module bodies are executing now (pid, start time, latest status line); one module's status line joined to whether its process is actually alive. |
| `server_info` | Which VoiceKit server you are talking to: version, install root, Python, pid and start time, whether its code changed since it started, every other VoiceKit `server.py` process running, and each client config that registers VoiceKit (command + args, never `env`). The first call when tools show up twice or one seems missing. |
| `reveal` | The real file/folder name behind a privacy token (`<dir#1c2e>`, `<file#3a9f>.pdf`, or a whole masked path). Audited locally (token and time, never the name); one-way `<ssn#..>`/`<ein#..>` tokens are refused. See **Privacy masking** below. |

**Run and stop**

| Tool | Does |
|------|------|
| `run_automation` | **Trigger** any spoken automation now — the MCP equivalent of "open \<name\>". `loop <name>` starts a workflow's loop companion. Optional `wait_seconds` to wait and report the outcome (read from the run record, never guessed from an exit code). Optional `args` are the script's command-line arguments (an argv list, no shell); for a workflow they must be existing files and stand in for the File Explorer selection, so a selected-file workflow can be tested on a fixture. Runs in the macro's folder, like the voice shortcut. |
| `run_workflow_batch` | **Run a workflow once per row of inputs**, no dialogs. Pass `rows` (one object per run, keys = the workflow's ask labels) **or `source`** — a CSV or an Excel range (see below); the loop runs headlessly with the floating Stop bar still up, and `collect` steps save each pass's values to the workflow's sheet. `dry_run=True` previews the mapped rows and launches nothing. Refused while another loop is running. |
| `press_hotkey` | **Trigger** a hotkey module (or a companion hotkey) by synthesizing its registered combo — bridge-map entries only, never arbitrary keys; needs the resident VoiceKit running. |
| `run_ahk_snippet` | Run one-off AutoHotkey v2 code in a throwaway process (`_Common.ahk` + `Browser.ahk` + `UIA.ahk` + `ExplorerSel.ahk` pre-included, `Out(value)` to report) — for probes and experiments. Uncaught errors come back as text instead of a hidden dialog. A masked path inside a quoted string is expanded locally; `unmask=True` returns one result without name tokens (audited). |
| `stop_module` | Stop a module's running body: drops the cooperative stop flag, waits `grace_s`, then force-kills that module's own processes. |

Every generated `.ahk` is load-checked with AutoHotkey before it's kept; if it
fails, nothing is written (edits and replacements roll back byte for byte).
Hotkey/snippet changes reload the running VoiceKit automatically; an isolated
module's body is live on the next press with no reload at all. Every response
also carries a `health` block (is the master up, what's parked, safe mode).
After updating the server, **restart your MCP client** (or the `voicekit`
connection) so it picks up the new tool list — the `health` block says
`server_stale: true` (with a note) when `server.py` or `voicekit_writer.py`
changed after the running server started, and carries the install's
`version` (the root `VERSION` file; the installer build stamps the commit and
date into it) and `install_root`.

**Written for an agent.** The server sends session-level instructions once
(FastMCP `instructions`): what each kind of code gets pre-included, the names
that are therefore taken at top level (generated from the libraries at start:
the collision-prone built-ins such as `Log`, VoiceKit's short names such as
`Out`/`Notify`/`EnsureDir`, and the `Uia*`/`Browser*`/`Body*`/... prefix
families), the v2 quote rule, and "edit/update, don't recreate". A load error
that hits a taken name, or a v1-style `""` quote, comes back with a `Hint:`
line saying who owns the name (an AutoHotkey built-in, `lib\_Common.ahk`
line N, the snippet's `Out()`) and how to fix it.

**Batches from a spreadsheet.** `run_workflow_batch(source=...)` reads a
`.csv`/`.tsv`/`.txt` or `.xlsx`/`.xlsm` directly — pick the tab (`sheet`) and
cells (`cell_range`: `A2:C40`, `A2:C` to the last used row, `A:C`), map the
workflow's ask labels to headers or columns (`columns={'Amount': 'col:A'}`; a
label left out matches a header of its own name, case-insensitively), and skip
rows (`skip_blank`, `require=['Amount']`, `skip_if_filled=['col:B']` for a
"done" column). All skipping happens before launch, so the reply can say
exactly which sheet rows ran (`pass_rows`), which were skipped and why (by row
number), which column each label read, the file's `source_modified` time, and
a `next_cell_range` / `resume_with` for the next call. Example — a *Send
Amount* workflow typing invoice amounts, where column A is the amount, B a done
mark and C the label, headers in row 3:

```
run_workflow_batch('Send Amount', source='%USERPROFILE%\Documents\Invoices.xlsx', sheet='Invoices',
                   cell_range='A3:C', columns={'Amount': 'col:A', 'Label': 'col:C'},
                   require=['Amount'], skip_if_filled=['col:B'], dry_run=True)
```

Value rules: CSV text passes exactly as written (`00123` keeps its zeros; the
file is read as UTF-8, else Windows-1252; `,` / `;` / tab is detected from the
first line holding one). An xlsx cell passes its stored value — integers without `.0`,
floats at Excel's 15-digit precision (`1234.5`, never `1234.4999…`), not the
displayed format (`$1,234.50` arrives as `1234.5`, `25%` as `0.25`); a number
formatted `00000` keeps its zeros; dates are `YYYY-MM-DD` unless `date_format`
(strftime, e.g. `%m/%d/%Y`) says otherwise. A cell holding an Excel error
(`#N/A`, `#REF!`, …) refuses the whole batch, naming its row. Only the
`dry_run` preview ever shows cell values — they're client data. Where
collected values land: with the workflow's own `workflows\<Name>.inputs.csv`
as `source`, beside each row in it; any other source, appended to that sheet
as new rows (inputs used + values collected). **The source file is never
written.** Known limits: rows hidden by an Excel filter are still read (use
`require` / `skip_if_filled` / a range instead), a formula Excel never
calculated reads as blank, and an open workbook is read as last saved.
`.xlsx` needs `openpyxl` (in `requirements.txt`; imported only when an xlsx
is read — a CSV never needs it).

**Paths are normalized.** Every response shows your profile folder as
`%USERPROFILE%` and the temp folder as `%TEMP%` (so the Windows user name
never reaches the model); tools that take a path (`opens`, a workflow `run`
target or `focus` launch command, a batch `source` and `rows` values) accept
that form back. Authored source
(`read_macro_source`, `read_hotkey_module`, `read_workflow`, `read_ai_prompt`,
`read_reference`) is returned byte-for-byte so it round-trips.

### Privacy masking

Tool results go to the model provider, and on a PC that handles client
files, file and folder *names* are client data (`Documents\Clients\Smith
John\2025 Invoice Smith.pdf`). So by default every name under your profile is
replaced by a stable token that keeps the extension:

```
%USERPROFILE%\Documents\<dir#1c2e>\<dir#9b07>\<file#3a9f>.pdf
```

- **What stays readable:** the well-known profile folders (Desktop,
  Documents, Downloads, Pictures, Videos, Music, `OneDrive` / `OneDrive -
  <org>` and their Desktop/Documents, `AppData` and its `Local` / `Roaming` /
  `Temp` / `Programs`), the **VoiceKit folder and everything in it** (macro,
  workflow and module names are your *automation* names, which the agent needs
  to do its job — so don't name an automation after a client), the Voice
  Macros Start Menu folder, and Python / program folders. Everything else under
  the profile — including `%TEMP%` — is masked.
- **Tokens are stable** (the same name always gets the same token, across
  calls and restarts) so the model can still say "page 7 of `<file#3a9f>.pdf`
  failed". They're an HMAC of the name under a random per-PC key
  (`logs\privacy.key`); the token → name map is `logs\privacy-tokens.json`.
  Both live in `logs\`, which is never committed and never shipped.
- **Round trips work.** Pass a token back exactly as shown wherever a tool
  acts on a path or value — `run_automation` args, `run_workflow_batch`
  `rows` and `source` (a `read_workflow_sheet` row handed back as shown),
  `create_launch_macro(opens=)`, a workflow `run` target / `focus` launch /
  `capture` command, and quoted strings in `run_ahk_snippet` code — and it is
  expanded to the real name on this PC. An unknown token is an error, never a
  guess. A token in saved code, prompts, snippets or other step fields is
  refused (read tools return saved code verbatim, so a real name written there
  would come back unmasked later).
- **Bare names too.** A name masked as part of a path is also masked where it
  appears on its own in the same response (a snippet that prints the file
  name after the path). A client name that never appears as part of a masked
  path is *not* caught.
- **When the real name is needed:** `reveal(token)` returns it, and
  `run_ahk_snippet(..., unmask=True)` returns one result without name tokens.
  Both append a line to `logs\privacy-audit.log` (time, tool, token — never
  the name).

**Settings** — edit `logs\settings.ini` (create the section if it isn't
there); no tool can change it:

```ini
[Privacy]
; paths (default) | strict | off
Mode=paths
; extra folders whose contents are masked too, ; separated — e.g. a client share
MaskRoots=D:\Clients;\\server\clients
```

Desktop / Documents / Downloads / Pictures / Videos / Music that Windows
redirects *outside* the profile (to a server share or another drive — common
on an office domain) are masked automatically, as if listed in `MaskRoots`.
Any other place client files live (a mapped `Z:` drive, a shared folder) has
to be listed. Restart the MCP server after changing folder redirection.

`strict` adds SSN (`123-45-6789`) and EIN (`12-3456789`) masking, plus nine
bare digits only right after an SSN / TIN / EIN / Social Security / Tax ID
label; they become `<ssn#..>` / `<ein#..>` tokens that can **never** be
revealed or expanded (dates, phone numbers and amounts don't match). `off`
keeps only the `%USERPROFILE%` / `%TEMP%` normalization. The current mode
rides on every response as `voicekit.privacy`.

**What masking is not:** data-loss prevention. It stops *incidental* leakage —
paths in listings, errors, logs, window titles that contain a masked path,
snippet output. A snippet that deliberately `Out()`s a document's contents, an
`inspect_focus` / `dump_uia_tree` of a client's form and a `dry_run` preview of
a sheet's cells are sent as they are (apart from paths in them and, in strict
mode, the ID patterns); the authored source the read tools return
(`read_macro_source`, `read_hotkey_module`, `read_workflow`, `read_ai_prompt`,
`read_reference`) is never touched at all, so don't hard-code client names in
automations. A path wrapped onto a second line is masked only up to the line
break. Calling the writer directly from Python (the fallback when the MCP
connection is down) is not masked either.

## Setup

Requires **Python 3.10+** and VoiceKit's **AutoHotkey v2** (the server shells out
to `AutoHotkey64.exe` to validate/reload). From this `mcp\` folder:

```
Setup-MCP.bat
```

That creates `.venv`, installs `fastmcp` and `openpyxl` (for Excel batch
sources), and prints your exact paths. (Manual equivalent: `python -m venv .venv
&& .venv\Scripts\activate && pip install -r requirements.txt`.) A `.venv` made
before Excel sources existed needs `openpyxl` added once:
`.venv\Scripts\python.exe -m pip install openpyxl`.

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
{ "type": "waitfor", "window": "ahk_exe notepad.exe", "element": "Untitled", "condition": "textvisible", "seconds": 15 }
{ "type": "wait",    "ms": 600, "ms_max": 1400 }
{ "type": "ask",     "label": "Customer name", "suggestion": "Acme" }
{ "type": "text",    "text": "Dear {{Customer name}}," }
{ "type": "fill",    "window": "ahk_exe chrome.exe", "element": "Invoice total", "value": "{{Box 1}}" }
{ "type": "set",     "label": "Greeting", "value": "Hi {{Customer name}}" }
{ "type": "capture", "label": "Invoice Data", "command": "python invoice.py {{selected_file}}", "seconds": 120 }
{ "type": "keys",    "keys": "^s" }
{ "type": "click",   "window": "Untitled - Notepad", "element": "File" }
{ "type": "hover",   "window": "Untitled - Notepad", "element": "Format" }
{ "type": "drag",    "window": "ahk_exe mspaint.exe", "xy": "100,200,400,200" }
{ "type": "collect", "label": "Order number", "element": "Order no." }
{ "type": "move",    "window": "ahk_exe notepad.exe", "position": "left" }
{ "type": "close",   "window": "ahk_exe notepad.exe" }
```

Step types: `run`, `focus`, `waitwin`, `wait`, `waitfor`, `text`, `fill`, `ask`,
`collect`, `set`, `capture`, `keys`, `click`, `dblclick`, `rclick`, `hover`,
`drag`, `move`, `close`, and `if` / `else` / `endif`. Prefer `waitfor` to a fixed
`wait`: it continues the moment the thing is true and fails saying what never
happened. Every ask label, collect label and set name can be reused later as
`{{Name}}` (plus the built-ins `{{clipboard}}`, `{{date}}`, `{{time}}`,
`{{datetime}}`, and the File Explorer selection: `{{selected_file}}` — one
file; the run refuses to start unless exactly one is selected — and
`{{selected_files}}` — every selected path, each quoted, space-joined). In a
command line (a `capture` command, a `run` target) both arrive quoted whether
or not you write quotes around them; any other value goes in as-is.

`capture` runs a cmd.exe command line hidden, from the VoiceKit folder, and
saves its stdout (UTF-8, trailing whitespace trimmed) as `{{label}}` for later
steps — run-local, never a sheet column. stderr is kept out of the value; a
nonzero exit stops the run, and the run record (and so `run_automation`'s
report) says only `Command exited with code N` — no stderr, no filled-in
command, since either can name a client's file. The timeout (`seconds`,
default 30) and Stop Looping kill the whole process tree. A workflow with a
`capture` step runs programs: share it like a script. Draft With AI never
emits one.

`fill` puts a value into an input box found by its label (its accessible name
— a web form's field label; `dump_uia_tree` shows it), clicks it for real,
refuses to type unless the keyboard focus landed there, types the value and
reads it back. A box that reformats still passes (`1234.5` matches `1,234.50`)
but a different value never does. `"Amount#2"` is the second input with that
label (without `#N` the first is filled and the run log says so; `##` is a
literal `#`). A password box is filled, not read back. The value is the one
paramC that takes `{{Name}}`; `""` clears the box; a failure reason never
contains it.

Workflows can also **branch** — deterministic state checks only (no pixel
guessing), each `if` closed by an `endif`, `else` optional:

```
{ "type": "if",    "window": "ahk_exe notepad.exe", "condition": "winexists" }
{ "type": "text",  "text": "already open" }
{ "type": "else" }
{ "type": "run",   "target": "notepad.exe" }
{ "type": "endif" }
```

Conditions (for `if` and `waitfor`): `winexists` / `winnotexists` (is the
window open), `elementexists` / `elementnotexists` (is a named element in it —
set `element` too), and `textvisible` / `textnotvisible` (does `element`'s
text appear anywhere in the window, case-insensitively). `clipboardchanged`
is `waitfor`-only. Balance is validated at create time.

## Security

**These tools create and run code with your privileges.** A launch macro or
hotkey module can contain arbitrary AutoHotkey; a workflow `run` step can launch
any program; `run_ahk_snippet` runs arbitrary AutoHotkey *immediately*. That is
VoiceKit's purpose — but exposing it over MCP means an *LLM* decides when to
call these tools, so treat it accordingly.

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
  run code now or leave a persistent payload. Know which tools have an
  **immediate effect**:
  - `run_ahk_snippet` — runs arbitrary code on the desktop right now;
  - `run_automation` and `run_workflow_batch` — run an automation now,
    including `loop <name>` runs that repeat until stopped;
  - `press_hotkey` — fires a registered combo now (only combos already in
    `bridge-map.txt`, never arbitrary keys);
  - `stop_module` — force-kills a module's running processes;
  - `update_macro`, `edit_macro`, `edit_hotkey_module`, `update_hotkey_module`
    — rewrite code that is already wired to a voice phrase or a key, so the
    next "open …" or key press runs the new code (an isolated module's body is
    live on its very next press);
  - everything that reloads the resident master: `create_hotkey_module`,
    `create_snippet` (the new hotstring is armed the moment it loads — it fires
    on ordinary typing), in-process module edits, and `delete_automation` for
    hotkeys/snippets.

  `create_launch_macro`, `create_workflow` and `create_ai_action` only fire
  when later triggered.
- **What leaves the machine.** Tool results go to your MCP client — and so to
  the model provider. That includes whatever a snippet `Out()`s, log lines
  (`read_log`), file paths (`list_automations`, errors), on-screen text
  (`inspect_focus`, `dump_uia_tree`), sheet rows (`read_workflow_sheet`) and a
  batch's `dry_run` preview (`run_workflow_batch` — a real run's reply never
  carries cell values).
  If the screen or the files hold client data, assume it can end up in the
  conversation. Profile and temp paths are shown as `%USERPROFILE%` /
  `%TEMP%`, which keeps your Windows user name out of responses, and file and
  folder names under the profile are masked by default (see **Privacy
  masking**) — that stops incidental leakage only, not what a snippet
  deliberately `Out()`s. `reveal` and `run_ahk_snippet(unmask=True)` return
  real names on request; both are audited in `logs\privacy-audit.log`.
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
   blanket-allow it. Review `create_*` / `update_*` / `edit_*` arguments
   (especially `ahk_body`, `code` and `run` targets), `run_ahk_snippet` code,
   `run_automation`, `press_hotkey` and `stop_module` before approving.
2. **Don't use this server in sessions that ingest untrusted content** without
   watching the tool calls.
3. **Don't put secrets in automations.** Your macros, hotkey modules,
   workflows, `hotkeys\Snippets.ahk` and `bridge-map.txt` are gitignored (they
   never enter the repo or an installer package), but they are plain text on
   disk and the read tools above return them to the model. (Snippet expansions
   can also include keystrokes like `{Enter}`, not just inert text.)
4. FastMCP and its dependencies come from PyPI (pinned `>=2.9,<4`); they run
   in-process, so treat them like any other supply-chain dependency.

## Troubleshooting

- **VoiceKit's tools appear twice, or a tool is missing** → call `server_info`.
  Each registration (`~/.claude.json`, Claude Desktop's config, a project
  `.mcp.json`) starts its own server process with its own copy of the tools;
  two entries in ONE client mean two sets of names. A server that started
  before its code changed shows `server_stale` — reconnect it (`/mcp` in
  Claude Code, restart Claude Desktop).

## Maintenance

`voicekit_writer.py` mirrors VoiceKit's on-disk format (a deliberate second copy
of the AHK write-side). **`test_conformance.py` is what keeps them honest** — it
feeds the writer's output through the real AutoHotkey engine and byte-compares.
Run the whole suite (every AHK self-test plus this conformance test) after any
change:

```
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tests\Run-Tests.ps1
```

or just the conformance half from this folder:

```
.venv\Scripts\python test_conformance.py
```
