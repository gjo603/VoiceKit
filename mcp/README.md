# VoiceKit MCP server

Create **and trigger** VoiceKit automations from natural language. This is an
**optional** add-on to VoiceKit: a [FastMCP](https://gofastmcp.com) server that
exposes the same automation-creation the GUI does — launch macros, snippets,
hotkey modules, multi-step workflows, and AI text actions — as MCP tools, and can
run any of them the same way Voice Access does. The recorder/scaffolder still
work unchanged; this is a third path.

## What it can do

Every tool the server exposes (34). `test_conformance.py` checks this table
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
| `create_workflow` | The recorder's output, **authored** instead of recorded: `workflows\<Name>.steps.txt` + generated stub + shortcut + `loop <name>` companion. Replacing an existing workflow is rolled back to the previous version if the new one fails its check; a replace keeps the companion hotkey and returns it as `hotkey`. |
| `delete_automation` | Remove an automation and all its artifacts (companion hotkey, sheets, backups included). VoiceKit's own tools, Split Pages and `Snippets` are protected. |

**Inspect (read-only)**

| Tool | Returns |
|------|---------|
| `list_automations` | Everything sayable/typable, with exact voice phrases: workflows (+ loop phrase), launch macros (`kind` = `opens` / `raw_script`), AI actions, hotkey modules (+ combo, latest body `status`), snippets, tools. |
| `read_workflow`, `get_bridge_map` | A workflow's steps; the hotkey registry with free and reserved keys. |
| `read_workflow_sheet` | A workflow's inputs sheet and results overflow as columns/rows, plus `last_run` — how collected values come back after a batch. |
| `read_log` | The tail of `activity` (created.log), `errors` (errors.log — uncaught errors from any VoiceKit script) or `runs` (workflow-runs.log), optionally filtered. |
| `read_reference` | Worked example code to copy (`web-scrape`, a complete scraper body), or a library's function reference (`uia`, `browser`) — every signature and its comment, generated from the source on each read. |
| `inspect_focus`, `dump_uia_tree` | What has keyboard focus, and a window's UI Automation tree as an outline — the real on-screen names to use in a workflow or a module's `UiaFind`. The dump says when its walk was cut (`cut_at_depth`, `budget_hit`, a plain-words `note`) and carries a `fingerprint` that changes when the page does, even under the same title. Out-of-process probes; nothing is clicked. |
| `list_running`, `read_module_status` | Which module bodies are executing now (pid, start time, latest status line); one module's status line joined to whether its process is actually alive. |
| `list_processes` | Every running process (or those whose image name contains `name`): pid, parent pid, image, start time, command line, and a `voicekit` tag on VoiceKit's own — this MCP server, other server instances, the master, module bodies, macros, loops, snippets, `run_process` runs and background jobs. `python.exe` includes this server itself, so check your own program by pid or job id. |
| `server_info` | Which VoiceKit server you are talking to: version, install root, Python, pid and start time, whether its code changed since it started, every other VoiceKit `server.py` process running, and each client config that registers VoiceKit (command + args, never `env`); `connected_client` (the MCP client of this session) and `same_client_duplicates` (registrations ONE client loads twice — the real problem; one per client is normal). The first call when tools show up twice or one seems missing. |
| `reveal` | The real file/folder name behind a privacy token (`<dir#1c2e>`, `<file#3a9f>.pdf`, or a whole masked path). Audited locally (token and time, never the name); one-way `<ssn#..>`/`<ein#..>` tokens are refused. See **Privacy masking** below. |
| `check_path` | Does a path exist — given exactly as a response showed it (`%USERPROFILE%`/`%TEMP%` and tokens welcome) — without revealing a name: `exists`, `kind` (`file`/`dir`/`missing`, or `unresolved`), size and modified time or item count, and `tokens_resolved` / `unknown_tokens`. Tells a token this PC never issued apart from a path that expanded but has nothing there (then `deepest_existing` and `missing_part`, both masked — `missing_part` is cut from the masked path, so even a short or all-digit name stays masked). |

**Run and stop**

| Tool | Does |
|------|------|
| `run_automation` | **Trigger** any spoken automation now — the MCP equivalent of "open \<name\>". `loop <name>` starts a workflow's loop companion. Optional `wait_seconds` to wait and report the outcome (read from the run record, never guessed from an exit code). Optional `args` are the script's command-line arguments (an argv list, no shell); for a workflow they must be existing files and stand in for the File Explorer selection, so a selected-file workflow can be tested on a fixture. Runs in the macro's folder, like the voice shortcut. Any run it waits on returns `result` — the values the macro passed to `VkResult(value)` — and its `stdout` / `stderr` (the launched macro's alone: a program it starts inherits the variables, but `VkResult`/`VkTestMode` ignore them there). **`test=True`** is a quiet test run: MsgBox / TrayTip / InputBox / ToolTip / file pickers are returned in `dialogs` instead of shown — MsgBox answers its default button (what Enter would), InputBox, FileSelect and DirSelect are **cancelled**, ToolTip returns a real but invisible window; the macro's own `OnError` handlers run, an error none of them handles comes back as `uncaught_error` with no dialog (exit 3; its `OnExit` callbacks are skipped), `VkTestMode()` is true in the macro, and a timeout kills the run and every process it started. Quiet, not sandboxed: Gui windows still appear and real side effects still happen. **`dry_run=True`** (implies `test=True`) also replaces the input built-ins (`lib\DryRunShim.ahk`): keystrokes, clicks, mouse moves, control writes and `lib\UIA.ahk`'s `UiaSetValue` / `UiaInvoke` / `UiaFocus` are logged instead of performed and returned in order as `actions` (a workflow's typed text as lengths only); menus (`MenuSelect`) likewise; not covered (every dry-run reply says so): what the script `Run()`s, file and clipboard writes, window commands, `PostMessage`/`SendMessage`, its own COM/`DllCall` — `VkDryRun()` lets it skip those. With `test`/`dry_run`, `name` may also be an **isolated hotkey module**: its body runs directly under the shim (refused while that body is running). |
| `run_workflow_batch` | **Run a workflow once per row of inputs**, no dialogs. Pass `rows` (one object per run, keys = the workflow's ask labels) **or `source`** — a CSV or an Excel range (see below); the loop runs headlessly with the floating Stop bar still up, and `collect` steps save each pass's values to the workflow's sheet. `dry_run=True` previews the mapped rows and launches nothing. Refused while another loop is running. |
| `press_hotkey` | **Trigger** a hotkey module (or a companion hotkey) by synthesizing its registered combo — bridge-map entries only, never arbitrary keys; needs the resident VoiceKit running. |
| `run_ahk_snippet` | Run one-off AutoHotkey v2 code in a throwaway process (`_Common.ahk` + `Browser.ahk` + `UIA.ahk` + `ExplorerSel.ahk` pre-included, `Out(value)` to report) — for probes and experiments. Uncaught errors come back as text instead of a hidden dialog. A timeout (or a cancelled call) ends the snippet **and every process it started** (`killed` lists them; a COM server it drove, e.g. `ComObject("Excel.Application")`, is started by Windows outside its tree — after a timeout `possibly_left_running` names it). A masked path inside a quoted string is expanded locally; `unmask=['<file#..>']` shows just those tokens in clear (audited). |
| `run_process` | **Run a program directly** — `exe` + an `args` list, no shell, no AHK quoting — and get `exit_code`, `stdout`, `stderr` (decoded, 100 KB each, head + tail kept), `timed_out`, `killed`, `duration_s`. Runs hidden in a Windows job object: a timeout or a cancelled call ends its whole process tree — but not a COM server it drives (Excel.Application through win32com or `New-Object -ComObject`) or an app it hands work to through the shell: Windows starts those outside the tree, so after a timeout check `possibly_left_running` / `list_processes` before re-running on the same file. Arguments may span lines (`python -c` with several lines works; only `cmd.exe` refuses them). `timeout_s=0` = up to the cap. Python children get `PYTHONUNBUFFERED=1` (output shows up in `read_job` as printed). `.bat`/`.cmd`/`.ps1` are refused with the explicit form. `background=True` starts a **job** instead and returns its `job_id` at once. Takes the same scoped `unmask` as `run_ahk_snippet` (so does `read_job`). |
| `read_job`, `stop_job` | A background job's state (running / exited / killed / stopped), exit code, duration and output tails — or, with no id, every job; end a job and everything it started. Output lives in `%TEMP%\VoiceKit\jobs\<id>\`; finished jobs are pruned after 7 days (50 kept at most). |
| `stop_module` | Stop a module's running body: drops the cooperative stop flag, waits `grace_s`, then force-kills that module's own processes. |

**No wait you choose blocks a call longer than 50 s** (`run_ahk_snippet`
`timeout_s`, `run_process` `timeout_s`, `run_automation` /
`run_workflow_batch` `wait_seconds`, `stop_job` `grace_s`, and `stop_module`
`grace_s` — less the ~10 s that call spends around its wait) — a remote
bridge gives up on a call at 60 s and the work used to run on unseen. A
larger value is clamped and the reply says so (`timeout_capped` /
`wait_capped` / `grace_capped`). (A create or update that reloads VoiceKit
is not on that list: its load checks and the reload have bounds of their
own, and can take longer when a module is slow to load.) Set `[MCP]
MaxWaitSeconds=<5-230>` in `logs\settings.ini` for a client that waits
longer. Longer work: `run_process(background=True)` + `read_job`, or a
fire-and-forget run you poll. When a client cancels a call, the processes it
started (snippet, `run_process`, UIA probe) are ended too; your own
automations (`run_automation`, `press_hotkey`, loops) are never put in a job
and keep running.

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
  Macros Start Menu folder, Python / program folders, and the names of
  `run_process`'s background-job folders (`%TEMP%\VoiceKit\jobs\<job id>` —
  not what a job writes there). Everything else under the profile —
  including `%TEMP%` — is masked.
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
- **When the real name is needed:** `reveal(token)` returns it. To read
  names where they appear in a run's output, `run_ahk_snippet`, `run_process`
  and `read_job` take `unmask=['<file#3a9f>', ...]` (tokens, or whole masked
  paths — every token in one counts): the answer is masked as usual and only
  the tokens listed are shown in clear; the reply's `unmasked` lists them and
  `unmask_unused` any that weren't in the output. An unknown or one-way token
  refuses the call before anything runs. A blanket `unmask=True` (everything
  in clear) is **refused** unless you set `AllowBlanketUnmask=1` (below). Every
  reveal and unmask appends a line to `logs\privacy-audit.log` (time, tool,
  tokens — never the name).
- **Does that masked path still exist?** `check_path(path)` answers without
  revealing anything: whether the path's tokens expanded at all (a token this
  PC never issued is listed in `unknown_tokens`) and, if they did, whether
  something is there — for a missing path, the deepest part that still exists
  and the first part that doesn't, both masked. The "isn't there" errors of
  `run_automation` (workflow args), `run_workflow_batch` (`source`) and
  `run_process` (`exe`, `cwd`) say which of the two it is too.

**Settings** — edit `logs\settings.ini` (create the section if it isn't
there); no tool can change it:

```ini
[Privacy]
; paths (default) | strict | off
Mode=paths
; extra folders whose contents are masked too, ; separated — e.g. a client share
MaskRoots=D:\Clients;\\server\clients
; 1 = allow unmask=True (a whole answer in clear). Default 0: only the
; scoped unmask=['<file#..>'] form works
AllowBlanketUnmask=0
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
{ "type": "fill",    "window": "ahk_exe chrome.exe", "element": "after \"Deductions\" > \"Insurance\"", "value": "{{Insurance}}" }
{ "type": "set",     "label": "Greeting", "value": "Hi {{Customer name}}" }
{ "type": "capture", "label": "Invoice Data", "command": "python invoice.py {{selected_file}}", "seconds": 120 }
{ "type": "module",  "module": "send number", "seconds": 120 }
{ "type": "keys",    "keys": "^s" }
{ "type": "click",   "window": "Untitled - Notepad", "element": "File" }
{ "type": "hover",   "window": "Untitled - Notepad", "element": "Format" }
{ "type": "drag",    "window": "ahk_exe mspaint.exe", "xy": "100,200,400,200" }
{ "type": "collect", "label": "Order number", "element": "Order no." }
{ "type": "move",    "window": "ahk_exe notepad.exe", "position": "left" }
{ "type": "close",   "window": "ahk_exe notepad.exe" }
```

Step types: `run`, `focus`, `waitwin`, `wait`, `waitfor`, `text`, `fill`, `ask`,
`collect`, `set`, `capture`, `module`, `keys`, `click`, `dblclick`, `rclick`, `hover`,
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

`module` runs an isolated hotkey module (named as `list_automations` shows it;
stored as its bridge-map phrase) and WAITS for it to exit — pressing a module's
key only starts it. Exit code 0 carries on; anything else stops the run, so a
body says it failed with `ExitApp(1)`, and an uncaught error ends a body this
step started with exit 3 instead of a dialog. `seconds` (default 60, at most
3600) and Stop Looping end its whole process tree. Refused for an
`isolate=False` module (it runs inside VoiceKit; nothing can wait on it) and,
at run time, while the same body is already running. The run record says only
`Module '<phrase>' failed (exit code N)` / `didn't finish within N s`; the
body's error text and last `BodyStatus` line reach the local popup only. Under
`run_automation(test=True / dry_run=True)` the body runs as a test run under the
same shim (`VkTestMode()` is true in it; an uncaught error there comes back as
`module_errors`, its text withheld). A body that stops on a stop request
(`ExitApp()` after `BodyStopRequested`) fails the step — it didn't finish.
Draft With AI never emits one.

`fill` puts a value into an input box found by its label (its accessible name
— a web form's field label; `dump_uia_tree` shows it), clicks it for real,
refuses to type unless the keyboard focus landed there, types the value and
reads it back. A box that reformats still passes (`1234.5` matches `1,234.50`)
but a different value never does. `"Amount#2"` is the second input with that
label (without `#N` the first is filled and the run log says so; `##` is a
literal `#`). When the boxes share one name, the label can be the text before
the box instead: `after "Insurance"` is the first input after the element
saying Insurance, `after "Deductions" > "Insurance"` looks for Insurance
within Deductions (a section: when its element contains its content, the
search stays inside it and a miss fails by name rather than filling the next
section's box; a bare heading only orders it, and the run log says so), and
`#N` after the last quote picks the Nth input after it. A password box is filled, not read back. The value is the one
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
  - `run_process` — runs any program with your privileges right now (a
    background job keeps running until it ends, its lifetime runs out, or
    `stop_job` ends it);
  - `stop_job` — ends a background job's whole process tree;
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
  the model provider. That includes whatever a snippet `Out()`s or a program
  run by `run_process` prints, other programs' command lines
  (`list_processes`), log lines
  (`read_log`), file paths (`list_automations`, errors), on-screen text
  (`inspect_focus`, `dump_uia_tree`), sheet rows (`read_workflow_sheet`) and a
  batch's `dry_run` preview (`run_workflow_batch` — a real run's reply never
  carries cell values).
  If the screen or the files hold client data, assume it can end up in the
  conversation. Profile and temp paths are shown as `%USERPROFILE%` /
  `%TEMP%`, which keeps your Windows user name out of responses, and file and
  folder names under the profile are masked by default (see **Privacy
  masking**) — that stops incidental leakage only, not what a snippet
  deliberately `Out()`s. `reveal` and a scoped `unmask=['<file#..>']`
  (`run_ahk_snippet`, `run_process`, `read_job`) return real names on
  request; both are audited in `logs\privacy-audit.log`.
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
   `run_process` programs and arguments, `run_automation`, `press_hotkey`,
   `stop_module` and `stop_job` before approving.
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
- **The tool names changed mid-session** (`mcp__voicekit__...` became
  `mcp__remote-devices__voicekit__...`) → the prefix is added by the client
  or a bridge, not by VoiceKit, and can change when the client reconnects
  through a different path. The names after it are stable: re-list the
  tools and retry with the new prefix.

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
