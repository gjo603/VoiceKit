# VoiceKit changelog

What shipped, newest first — moved here from `docs\backlog.md` on 2026-09-30
so the backlog can lead with what is still open. Each entry keeps the
what-happened / why / what-shipped record it was written with; file pointers
were accurate when written (check `CLAUDE.md` and the code for the current
names).

---

### 2026-09-30 — privacy masking of MCP results (WP9 phase 2) — BUILT

An office that handles client documents keeps client names in its file and
folder names (`Documents\Clients\Smith John\2025 Invoice Smith.pdf`), and every MCP tool
result goes to a cloud model. Phase 1 already hid the Windows user name;
phase 2 hides the names.

- **On by default**: `logs\settings.ini [Privacy] Mode=paths` (the default
  when absent) turns every file and folder name under the profile — and
  under each extra `MaskRoots=` root (a drive folder, a UNC client share) —
  into a stable token that keeps the extension:
  `%USERPROFILE%\Documents\<dir#1c2e>\<dir#9b07>\<file#3a9f>.pdf`. The
  well-known profile folders, the VoiceKit folder (an installed copy
  lives under the profile) and its automation names, the Voice Macros Start
  Menu folder and Python/program folders stay readable. A name hidden in a
  path is also hidden where it appears bare in the same response.
- `strict` adds SSN / EIN masking (and nine bare digits only after an ID
  label) as one-way `<ssn#..>` / `<ein#..>` tokens; `off` keeps phase 1 only.
  No tool can change the mode.
- **Round trips**: tokens handed back where a tool acts on a path or value
  (run_automation args, batch rows/source — a `read_workflow_sheet` row as
  shown —, opens, run/focus/capture steps, quoted strings in snippet code)
  expand to the real names locally; unknown or tampered tokens are errors.
  Tokens in saved code, prompts, snippets or other step fields are refused.
- **When the name is needed**: `reveal(token)` and
  `run_ahk_snippet(unmask=True)`, both audited in `logs\privacy-audit.log`
  (token and time, never the name). Key and map (`logs\privacy.key`,
  `logs\privacy-tokens.json`) never leave the PC — `logs\` is gitignored and
  the build now drops a staged `logs\` outright.
- **Value leaks scrubbed at the source**: a workflow failure reason in the
  run record/log names a `{{Name}}`-filled window or element as written
  (`WfUnsubst`), never the value; `run_workflow_batch`'s mapping error quotes
  header cells only when the row looks like titles.
- Honest scope, in the README: this stops incidental leakage, not a snippet
  that deliberately `Out()`s a document's text; authored source reads are
  returned verbatim, so don't hard-code client names in automations.
- **Adversarial review** closed: a missing name beside a sibling that merely
  starts the same (`Smith` vs `Smith Jane.pdf`) and quoted paths no longer
  leave the tail readable; `file:///…%20…` URLs, `%APPDATA%` /
  `%LOCALAPPDATA%` / `%OneDrive%` / `~\` spellings and `Path` values are
  masked; Desktop/Documents redirected to a server share are masked like a
  MaskRoot; a name that came IN as a token is masked where it goes out bare;
  every result type and every exception (not just the writer's own) goes
  through the pipeline; tokens are 6 hex (4 collided routinely), ids dropped
  by the map cap are retired rather than reissued, and a map that won't read
  is never replaced by an empty one. The bare-name pass is dict-based (5 000
  masked paths in one log: 3 s → 0.3 s).

---

### 2026-09-30 — `fill` step: put a value in a box by its label and check it took (WP8) — BUILT

The form-entry case: an office types invoice figures into a web-based form
app's input screens, and the agent driving it had fallen back on a Ctrl+F trick to reach
each box — with nothing to say whether the value landed, or where.
`fill|<window>|<label>[#N]|<value>` is the step for that.

- **Finds the input by its label** (its accessible name), UIA first and
  input kinds only (Edit, ComboBox, Spinner — never the Text label sharing
  the name, never a page's Document), MSAA as the fallback for desktop boxes
  only it can see. `"Amount#2"` is the 2nd box with that label; `##` is a
  literal `#`; several matches and no `#N` fill the first and say so in the
  run log. A duplicate-label decision was taken GENERIC on purpose — to be
  tuned from a real form's `dump_uia_tree`.
- **Clicks it for real**, then a **focus gate**: nothing is typed unless the
  keyboard focus sits on that box (`UiaSameElement`). `^a` + `SendText`, no
  `{Esc}`.
- **Reads it back**: `WfFillMatches` accepts reformatting (`1234.5` =
  `1,234.50`, `123456789` = `123-45-6789`) and never a different value
  (`1.5` ≠ `15`, `01234` ≠ `1234`). A password box is filled, not read back.
- **Private by construction**: no failure reason, log note or run record
  contains the value — typed-vs-held shows only in the local popup.
- **Fill values declare inputs**: a `{{Name}}` in a fill value that nothing
  defines is an input of the workflow — asked up front, a sheet column, a
  batch column — so `run_workflow_batch` over an invoice tab reaches fill steps
  without an `ask` step typing each value somewhere else.
- `fill`'s paramC (the value) is the first substituted paramC. Five-way
  lockstep: engine, Studio ("Fill in a box by its label"; Pick element now
  falls back to UIA, so it reads web inputs), writer + server, Draft With AI.
- New `UiaIsPassword` (element slot 35) and `UiaSameElement`
  (CompareElements, IUIAutomation slot 3), both proved in `uia-selftest`;
  `AccInputNodes`/`AccRole`/`AccState`/`AccWindowOf` in `Acc.ahk`.
- Tests: new `engine-fill-selftest` (73 checks) against a separate target
  form; `engine-vars-selftest`, `engine-capture-selftest` (ParseDraft) and
  `uia-selftest` extended; conformance adds the fill round trip, guards,
  schema mapping, and two AHK-vs-Python parity checks (`fill_label`,
  `_input_labels`).
- Review fixes: `WfFillMatches` takes a comma only as a properly placed
  thousands separator (`1,5` no longer equals `15`); the MSAA focus gate's
  window test only vouches for a node that is its own window (a windowless
  box can't pass because a sibling in the same host has focus); Pick element
  doubles `#` in a picked fill label; an unreadable box ends as "couldn't
  read it back", not a mismatch; the stray BOM added to `Acc.ahk` removed.
- Not built: the SetValue no-rectangle rescue has no test (a rect-less box
  with a ValuePattern is hard to stage with Win32 controls); a
  password-manager drop-down is not detected (no `{Esc}` is ever sent — the
  focus gate refuses if one takes the focus).

### 2026-09-30 — `collect` reads browser boxes; faster browser lookups (WP6) — BUILT

`collect|<label>|<box name>|` read a box through MSAA only, and current Chrome
publishes no page content over MSAA — so every collect inside a web app (the
read half of the fill-and-verify story) failed with "Couldn't find a box".

- **`WfFieldValue`** (`lib\Workflow.ahk`) backs collect-from-a-named-box with
  the click path's interleaved MSAA→UIA lookup. MSAA first every round, and
  its value wins — desktop workflows read the same box as before. The UIA
  half asks for the **Edit** of that name (`UiaFindEdit`), so the label that
  shares its name is never what gets read, via `UiaValueOnly(el, &has)` (no
  Name fallback). Found-but-empty stays a legitimate empty value at the
  deadline; not found stays a step failure.
- **Needles are trimmed** in `WfFindElement`/`WfUiaRect`/`WfElementPresent`
  (MSAA always trimmed; UIA's exact match did not).
- **Browser pacing**: a `Chrome_WidgetWin_1` / `MozillaWindowClass` window
  gets one MSAA walk per round instead of the 400 ms retry turn
  (`WfIsBrowserWindow`) — a UIA-only button in a pretend Chrome window went
  from ~580 ms to ~45 ms. Desktop windows are untouched.
- Tests: `engine-hybrid-selftest` grew a form window whose deep panel only
  UIA can see (nine nested child windows, past MSAA's depth-14 walk), the
  label-vs-input trap, a decoy proving MSAA still wins, and a pretend
  browser window of the real Chromium class.

### 2026-09-30 — batch a workflow from any CSV or Excel range (WP7) — BUILT

The form-entry case again: a *Send Amount* workflow typed each amount into the
web form app by walking an Excel sheet with hard-coded arrow keys — one misplaced
cell and every later amount lands in the wrong box. Now the sheet feeds the
workflow's ask labels directly, one pass per row. Details: "Batch from any
CSV or Excel range" in `docs\architecture\mcp.md`.

- **`run_workflow_batch(source=...)`** — exactly one of `rows` (unchanged) or
  `source`: a `.csv`/`.tsv`/`.txt` or `.xlsx`/`.xlsm`, with `sheet`,
  `cell_range` (`A2:C40`, `A2:C`, `A:C`), `header`, `columns` (label → header
  / `col:C` / column number), `require`, `skip_if_filled` (a "done" column),
  `skip_blank`, `date_format`, `dry_run` (+ `preview_rows`).
- **Pass N is source row N.** Python does every skip before launch and writes
  each kept row's source row number into the batch file's extra
  `VoiceKit source row` column — which also keeps `WfLoopCsvRows` from
  dropping any row. The reply names the rows that ran (`pass_rows`), each
  skip by reason and row, the column each label read, the file's
  modified time, and `next_cell_range` / `resume_with` for the next call
  (from the first unfinished pass when a waited run stopped partway).
- **Values.** CSV text exactly as written (`00123` stays); UTF-8, else
  Windows-1252; `,`/`;`/tab detected. xlsx through openpyxl (read-only,
  cached values): ints without `.0`, floats at Excel's 15-digit precision,
  `00000`-formatted numbers keep their zeros, dates `YYYY-MM-DD` or
  `date_format`. An Excel error cell (`#N/A`, …) refuses the batch, by row.
- **Privacy.** No reply or error carries a cell value except the explicit
  `dry_run` preview (path-normalized like everything else).
- **Results.** The workflow's own inputs sheet as source runs in place (values
  filled in beside each row); any other source appends results to that sheet.
  The source file is never written.
- **Fixed in review.** A headless batch handed the workflow's own sheet never
  recognized it (`lib\WorkflowLoop.ahk` compared LoopRunner's
  `lib\..\workflows\` spelling as a plain string), so "write back beside each
  row" silently appended a copy of every row — now `WfLoopIsOwnSheet` compares
  full paths. An open-ended xlsx range whose file records a wrong `<dimension>`
  (just `A1`) read only row 1 — now read to the real end. A title line above a
  `;` table no longer decides the delimiter; bytes undefined in Windows-1252
  are refused instead of typed as `?`; a closed CSV range past the file's end
  no longer invents blank rows; `resume_with` carries `date_format` and
  `skip_blank`.
- **Dependency.** `openpyxl` (3.1.5 verified) joins `mcp\requirements.txt`,
  imported only when an xlsx is read; `Setup-MCP.bat` installs and verifies
  it. An existing `mcp\.venv` — and a second PC's installed copy, after a
  rebuilt installer — needs `pip install openpyxl` once; without it an xlsx
  request says exactly that and a CSV still works.
- **Also:** `run_ahk_snippet` now pre-includes `lib\ExplorerSel.ahk`
  (`ExplorerSelectedFiles`), listed in the session instructions and the
  taken-names scope (`Explorer*`; no clashes). Not built:
  `run_workflow_batch(files=[...])` — per-pass files need a per-pass
  selection in the engine.
- **Tests:** 12 new `test_batch_*` cases in `mcp\test_conformance.py`, one of
  them a round trip through the real `WfLoopCsvRows`
  (`mcp\_conformance\batchrows.ahk`).

---

### 2026-09-30 — the `capture` step: run a command, keep its output (WP4) — BUILT

The last piece of the document-extraction case: select the PDF, say "open
Extract Invoice", and a workflow of about five steps runs a Python extractor on
it and types the result where it belongs. Details: "The `capture` step" in
`docs\architecture\workflow-engine.md`.

- **`capture|<name>|<command line>|<seconds>`** runs a cmd.exe command line
  hidden, from the VoiceKit folder (the install root on an installed copy),
  and keeps what it printed as `{{name}}` — run-local like `set`, never a
  sheet column. stdout and stderr are kept apart (a warning can't end up in
  the value), output is read as UTF-8 (`chcp 65001` in a nested cmd +
  `PYTHONIOENCODING=utf-8`; not-UTF-8 falls back to the ANSI code page),
  trailing whitespace is trimmed, more than 1 MB fails. The timeout (default
  30 s) and Stop Looping kill the whole process tree; a Stop ends the run as
  `stopped`.
- **What a failure says, and where.** A nonzero exit stops the run. The run
  record, the log and MCP results say only "Command exited with code N" — no
  stderr, no filled-in command, because a traceback or a resolved
  `{{selected_file}}` names a client's file. The last ~10 stderr lines appear
  only in the local failure popup.
- **The selection is quoted for you in a command.** In a capture command or a
  run target, `{{selected_file}}` / `{{selected_files}}` always arrive
  correctly quoted — written bare or inside quotes — so a client file name
  with spaces or `&` is one argument. Elsewhere `{{selected_file}}` is still
  the bare path.
- **Five-way lockstep.** Engine, Studio ("Run a command and save its output",
  timeout in the timeout box → paramC), MCP writer guards (name without
  braces, a command, a positive timeout) and `WorkflowStep` (`command` +
  `seconds`). Draft With AI refuses a `capture` step by name — a model's
  draft must not carry a shell command — and the old blank-paramC catch-all
  in `ParseDraftInner` became an explicit `paramCless` list (an unlisted type
  is now refused instead of silently losing paramC).
- **Trust.** A workflow can now run programs: the README says to share one
  like a script, and the Studio shows each command in the step list.
- Tests: `tests\engine-capture-selftest.ahk` (+ its command-line child),
  conformance STEPS/guards/schema, and the args → `{{selected_file}}` →
  capture → later step round trip through `run_automation`.
- **Review fixes (same day).** (1) Quoting follows cmd's quote parity:
  inside a quoted argument the author opened (`"--in={{selected_file}}"`)
  the path now goes in bare — the first cut only handled quotes hugging the
  placeholder and broke that form. (2) A capture command's stdin is NUL, so
  one that prompts (`set /p`, `input()`, `pause`) fails or continues at once
  instead of sitting to its timeout on a console nobody can see. (3) A failed
  `run` step records its target as written — `run|{{selected_file}}` used to
  put the client's path in the run record. (4) `run_automation` refuses
  several `args` for a workflow that uses the singular `{{selected_file}}`
  (the engine's refusal would be a popup on the user's desktop).

### 2026-09-30 — selected files and run arguments (WP2, WP3, WP5) — BUILT

For the document-extraction case: select a client's PDF in File Explorer, say
"open Extract Invoice". Details: "The File Explorer selection" in
`docs\architecture\workflow-engine.md`.

- **One tab-correct Explorer lookup** — `lib\ExplorerSel.ahk`
  (`ExplorerSelectedFiles`, `ExplorerFolderPath`). The two old copies (the
  recorder's `ExplorerSelection`/`ExplorerPath`, Split Pages'
  `ExplorerSelectedFile`) matched Shell windows on HWND alone, and Windows 11
  tabs all share one — measured: the list put the BACKGROUND tab first, so
  the old code read the wrong tab's file. The active tab is the entry whose
  `IShellBrowser::GetWindow` equals `ShellTabWindowClass1`; only file-system
  items count (not a file inside a `.zip`). Both old copies now delegate;
  Split Pages refuses several selected files instead of taking the first.
  `tests\explorer-selftest.ahk` verifies it live on its own window (only
  when no Explorer window is open).
- **`{{selected_file}}` / `{{selected_files}}`** — built-in values from one
  snapshot taken before any ask dialog or step. The singular with 0 or
  several items selected refuses to start (outcome `error`, "Select exactly
  one file in File Explorer first — found N"); the plural is every path,
  quoted, space-joined. Studio's Add dialog lists them; Draft With AI knows
  them.
- **`run_automation(args=[...])`** — arguments as an argv list (no shell);
  every launch now uses the voice shortcut's working directory. A workflow's
  arguments must be existing files and become its selection (the stub's
  `A_Args`, no stub change), so a selected-file workflow is testable on a
  fixture. Refused for Workflow Studio and `loop <name>`. Raw scripts get a
  documented convention (`files := A_Args.Length ? A_Args :
  ExplorerSelectedFiles()`) and an optional script-owned `/dry` — no generic
  dry-run flag.

### 2026-09-30 — agent developer experience (WP1, WP9 phase 1, WP10) — SHIPPED

From the document-extraction feedback (backlog items 1, 7 and 8; plan in
`docs\roadmap-extraction.md`). Details: "Written for an agent" in
`docs\architecture\mcp.md`.

- **Name clashes explain themselves.** `LOG := ...` at the top of a script
  fails because `Log` is an AutoHotkey built-in (reproduced with no include —
  a VK_ prefix would not have helped, so none was added). Every user-facing
  load error from the MCP (create/update/edit of macros, modules, bodies,
  workflow stubs; snippets; in-master clashes; `run_ahk_snippet` exit 2 and
  exit 3) now ends with a `Hint:` naming the owner — an AutoHotkey built-in,
  `lib\_Common.ahk line N`, the snippet's `Out()` — and the fix (rename, or
  move the code into a function). A v1-style `""` quote gets the `` `" `` rule.
- **Session instructions** for the MCP client: what is pre-included where,
  the taken names (generated from the libraries at start), the quote rule,
  edit/update-don't-recreate, and the path tokens. Tool descriptions for
  `run_ahk_snippet`, `create_hotkey_module`, `create_launch_macro` and
  `update_macro` point at them.
- **Which server is this?** Root `VERSION` (build-stamped with the commit and
  date), `health()` carries `version`, `install_root` and `server_stale`, and
  the new read-only `server_info` tool lists running VoiceKit servers and
  every client config that registers one (command + args, never `env`).
- **No user name in responses.** Every MCP response (and error) shows the
  profile and temp folders as `%USERPROFILE%` / `%TEMP%`, except authored
  source reads; path-taking inputs (including `run_workflow_batch` row
  values) accept that form back.
- **A snippet can no longer wedge on a warning.** v2's load-time warnings
  (an unset variable, unreachable code) are modal message boxes, so
  `Out(zz)` or a trailing `return` in `run_ahk_snippet` used to sit out the
  whole timeout with nothing reported. The prelude turns them off; an unset
  read now exits 3 naming the variable.

### 2026-09-30 — cleanup reviewer follow-ups — SHIPPED

- A legacy workflow under a tool's name no longer retires the tool's
  companion hotkey on delete (`DeleteWorkflowArtifacts`; RecordMySteps'
  shipped `^!+W` was the one at risk). The writer already refused such a
  delete outright; both sides are now pinned by a test.
- Log trims (`LogTrimIfOver`, `WfLogTrim`, Python `_log_trim_if_over`) write
  a temp file and move it over the log instead of delete-then-append.
- `stop_module` never calls a stop "graceful" when a pid couldn't be opened
  (`could_not_open`, `how: "exited"`), and checks a fully access-denied pid by
  the process scan instead of assuming it gone. `press_hotkey` waits out a
  reload hand-over and says "restarting" rather than "not running";
  `health()` carries `master_restarting`. A first-use seed of a live file is
  logged from Python like AHK logs it.
- `server.py`'s quiet cancel also patches `respond()`: a real race let a
  cancelled sync tool's late result trip "Request already responded to" (the
  wire test's one flake).
- A direct launch of `VoiceKit.ahk` that seeded the manifest exits as soon as
  its replacement is launched. The Theme placement helpers read the HWND
  before `Show`. The installer build lists tracked files with
  `core.quotepath=off` so non-ASCII paths ship.

### 2026-09-30 — cleanup batches A–E (the 2026-09-29 audit) — SHIPPED

The audit (`docs\roadmap-extraction.md` carries its roadmap) found three
start-stopping bugs and a list of drift; batches A–D2 fixed the bugs,
consolidated the duplicated helpers and closed the test gaps. Batch E was
hygiene:

- **Upgrades don't wire up newly shipped hotkeys — FIXED.** (Logged
  2026-07-27, below.) The per-user files are now split: git tracks
  `hotkeys\_index.default.ahk`, `bridge-map.default.txt` and
  `hotkeys\Snippets.default.ahk`; the live files are gitignored and never
  shipped. `SeedUserFiles` (`lib\_Common.ahk`, first step of
  `MasterPreflight`, so the launcher, every reload and the MCP all run it;
  mirrored by `voicekit_writer.seed_user_files`) creates a missing live file
  from its default and appends any shipped `_index` include / bridge-map line
  the live file lacks — keyed by module file, never duplicating or reordering
  user lines, never resurrecting a commented-out one, and holding a shipped
  hotkey back when its key is already taken. The RecordMySteps `^!+W`
  companion is the canonical case. Snippets are seeded only, never merged.
- The sample automations (ToggleTimer, MeetingNotes, MorningTabs, WorkLayout,
  CleanScreenshots, OpenPublicUserFolder) moved to `templates\examples\`;
  new installs no longer get key A taken by a placeholder.
- The build stages only index-tracked files, ships the defaults (never the
  live files), and `/validate`s the staged master before zipping.
- `.gitattributes` now matches the generators (LF for source and data, CRLF
  for `.bat`/`.cmd`/`.ps1`).
- `logs\errors.log` and `logs\created.log` are capped like
  `workflow-runs.log` (both writers).
- `mcp\README.md` documents all 29 tools (a conformance test keeps it so)
  and its security section names every immediate-effect tool.
- `CLAUDE.md` split into a rules file plus `docs\architecture\*.md`.

### 2026-08-12 — update_hotkey_module: full-file module rewrite over MCP — SHIPPED

Built from a pasted build spec asking for a read/update pair mirroring
`read_ai_prompt`/`update_ai_prompt`. The read half (`read_hotkey_module`, incl.
`bridge_key` and near-miss errors) and the splice (`edit_hotkey_module`) already
existed — the spec predated 2026-08-02 — so what actually shipped is the one
genuine gap: a full-file write that ROUND-TRIPS with read. A
`create_hotkey_module` replace wraps the passed code in a fresh generated
header, so restoring a banked backup or applying a whole-file rewrite meant
hand-stripping headers; `update_hotkey_module(name, code)` instead writes
exactly the file `read_hotkey_module` returns (the body, for an isolated
module), verbatim. Validate with byte-exact rollback; previous text banked in
the same `logs\module-backups\` slot a create replace uses, so
`read_hotkey_module(previous=True)` restores in one call (its note now says
so); no reload for isolated bodies, master reload + quarantine un-parking for
in-process modules. In-process code must still define the registered
`^!+<key>` combo (any modifier order) or the write is refused before touching
disk — the in-process file IS the key binding, and dropping it would strand
the hand-made Voice Access pairing. Deliberate deviations from the spec, per
existing repo decisions: previous code is banked + hashed, never echoed
(2026-08-02 token-sink measurement), and the backup lives in
`logs\module-backups\`, not a `.bak` beside the module.

Verified: `test_update_hotkey_module_replaces_verbatim_and_guards` (verbatim
write, rollback, bank survives a failed update, combo guard incl. reordered
modifiers, reload rules, empty/reserved/unknown guards).

### 2026-08-03 — Scrape feedback #9: worked web-scrape reference — SHIPPED (checklist COMPLETE)

Ninth and last item of `docs\feedback-web-scrape.md`.
`templates\web-scrape-body.ahk` is a complete, load-checked scraper body
distilled from the session's own 384-line fifth attempt: search term ->
keyboard walk of the results -> background-tab capture -> dedupe file ->
resumable queue, with varied pacing and a stop that answers both Esc and
`stop_module`. Half the original's length, because the machinery it
hand-rolled is now `lib\Browser.ahk` and `lib\_Common.ahk`. Its header names
what each guard is for, in the "its absence cost a failed run" form.

Two decisions worth recording:

- **It is served through the MCP** (`read_reference(name)`, catalogue when
  called bare) rather than pointed at on disk — the item-2 lesson again: an
  MCP-only client (Claude Desktop) has no filesystem access, so "it's in
  `templates\`" would be no answer. `create_hotkey_module`'s description
  points scraping jobs at it.
- **It is NOT a generator template.** Nothing fills it in; there are no
  `{{PLACEHOLDER}}`s. It lives in `templates\` for neighbourliness, and the
  five site-specific lines sit in one CONFIGURE ME block at the top.

Verified: `test_reference_bodies_are_readable_and_load` reads every
catalogued reference through the writer and load-checks it **as a body** —
building a `hotkeys\bodies\` layout with the three libs, since the file
carries a body's `..\..\lib\` include paths and would fail `/validate` in
place. A worked example that doesn't parse is worse than none. Full suite
green: 8 AHK suites + 31/31 conformance.

**All nine feedback items are now shipped.** The hourly loop that worked
through them ends here.

### 2026-08-03 — Scrape feedback #8: `read_module_status` — SHIPPED

Eighth item of `docs\feedback-web-scrape.md`. Its documentation half
(a `BodyStatus` line in `create_hotkey_module`'s description) shipped with
item 2; this is the tool.

`read_module_status(name)` **joins the two halves that answer "is it still
going, and how far in?"** — the status line the body published and whether
its process is alive. Neither alone is an answer: a fresh-looking line from a
body that died at 3 a.m. reads as progress, and a running body that has never
published reads as nothing happening. The response names which of the four
states you are in, and for a live body points out that a line which stops
getting newer means stuck, not done. Poll it instead of scheduling something
to notice a long run finishing — the workaround the report describes.

**The optional `BodyLog()` ring buffer was deliberately NOT built.** The
report marks it optional, and the two channels it would sit between already
exist: `BodyStatus` for "where am I now" (one overwritten line — cheap enough
to call every iteration) and, for anything a body wants to keep, a plain
`FileAppend` it already has. A third mechanism with its own trimming rules
and a second AHK-writes/Python-reads seam earns its keep only once something
actually needs replay, and nothing here does.

Verified: `test_read_module_status_joins_line_and_liveness` walks all four
states against REAL processes — never-ran, line-without-process (a body that
published then exited: the misleading case), running-with-line (both halves
plus `running_seconds`), and an unknown module raising. Full suite green:
8 AHK suites + 30/30 conformance.

### 2026-08-03 — Scrape feedback #7: `lib\Browser.ahk` + helper docs — SHIPPED

Seventh item of `docs\feedback-web-scrape.md` (theme 4 + theme 5.1).
Four incidents, four helpers, one new lib that `#Include`s `UIA.ahk` itself:

- **`BrowserEnsureDomain(hwnd, fragment, timeoutMs)`** — the "are you sure?"
  keystroke automation doesn't have. Reads the omnibox, navigates and polls
  if the fragment isn't there, false if it never arrives (an error page's URL
  won't contain it). This is what stops a query becoming a Google search.
- **`BrowserGrabPage`** — select-all/copy, retried once after `{Esc}` when the
  result looks like a stranded-omnibox URL (`BrowserLooksLikeUrlOnly`).
  **`BrowserUrl`** documents the ordering trap it recovers from.
- **`BrowserTypeVerified`** — find via `UiaFindEdit`, click for real, `{Esc}`
  the password-manager dropdown, select-all, type, read back.

**The readback got stronger than the report proposed, because the test caught
the report's version failing.** Verifying by select-all/copy checks *whatever
has focus*: with the pretend browser's `Esc` bouncing focus to the page, the
text landed in a different control and the check reported SUCCESS — the exact
false pass §4.3 exists to prevent. So verification now asks the element:
`UiaValueOnly(el)` (new in `UIA.ahk` — ValuePattern with no Name fallback,
since a check satisfiable by a label is not a check), with the clipboard
readback kept only for controls that expose no ValuePattern. `UiaValue` is
now a two-line wrapper over it.

Naming: everything carries the `Browser`/`Uia` prefix — a bare `TypeVerified`
in AHK's one shared namespace is a collision waiting to happen. Sends go out
at SendLevel 1, which real browsers can't distinguish but an AHK pretend
browser can hear — that is what makes the suite possible without touching a
real browser. §4.4's Tab-walk recipe stays documentation (site-specific).

Discoverability (theme 5.1) — the helper list now rides where an agent will
meet it: `create_hotkey_module`'s tool description lists all three libs with
their functions and the traps (`UiaFindEdit` for form fields; `UiaInvoke`
does nothing to many inputs; verify before Enter), and `run_ahk_snippet`
pre-includes `Browser.ahk` too.

New suite `tests\browser-selftest.ahk` (20 checks) against a separate
pretend-browser process that emulates `^l`/`Esc`/`Enter` and can stage an
unreachable site; 3 new UIA checks for `UiaValueOnly`. Full suite green:
8 AHK suites (browser 20, uia 79) + 29/29 conformance.

Two traps confirmed en route, both already in the traps list in spirit: a
control HWND passed to `ControlFocus` throws on a miss, and an uncaught throw
in a test pops a modal that reads as a timeout (the first version of the
strand check did exactly that); and `\U` inside a non-raw Python docstring is
a unicode escape — the tool-description edit broke `server.py`'s import until
the backslashes were doubled.

### 2026-08-03 — Scrape feedback #6: duplicate-instance bug — INVESTIGATED and FIXED

Sixth item of `docs\feedback-web-scrape.md`, and its one suspected
real bug: two `ScraperBody.body.ahk` processes ran at once despite
`#SingleInstance Ignore`. All three of the report's hypotheses were tested
with throwaway scripts; the evidence:

| Experiment | Result |
|---|---|
| E1 idle instance, second launch 1 s later | 1 process — detection works |
| E2 file REPLACED mid-run, then second launch | 1 process — hypothesis (a) **refuted**: a rewrite doesn't change the script path, and the path is the identity |
| E3 two launches with no gap | **2 processes — reproduced** |
| E4 instance blocked in a raw `DllCall("Sleep")` (no message pump), second launch 1 s later | 1 process — the busy-instance theory refuted too |

**Root cause:** `#SingleInstance` compares hidden-window titles, and a
starting script only creates that window once loading finishes. Two launches
inside that window-creation gap both look around, see nothing, and both
live. `press_hotkey` twice in quick succession (an agent retrying) fits the
gap comfortably. Hypothesis (c) — the launcher bypassing the directive — is
cleared by the same evidence: E1/E2/E4 all detect fine through the launcher's
plain `Run()`.

**Fix:** `BodySingleInstance(base)` in `_Common.ahk` — a kernel mutex
(`Local\VoiceKitBody_<Base>`), claimed atomically, so the second process
ALWAYS sees it regardless of timing. Loser exits 0 quietly (Ignore
semantics); handle held for process lifetime; a CreateMutex failure never
blocks real work. Generated bodies call it right after their include (both
generators, mirrored); the `#SingleInstance Ignore` directive stays as belt.
Existing bodies are untouched and can add the one-line call.

**Found en route, now in the traps list:** a v2 script with NO
`#SingleInstance` directive defaults to *Prompt* — the second instance sits
on a modal "replace it?" dialog. The first version of the mutex test omitted
the directive and its second instance wedged on that dialog before the mutex
line ever ran, which read exactly like the mutex failing. The shipped test
uses `#SingleInstance Off` so the mutex is proven ALONE: second launch of
the same base exits 0 before the body's code runs, the holder keeps running,
a different base sails through — all against real processes
(`test_body_single_instance_mutex`).

Full suite green: 7 AHK suites + 29/29 conformance.

### 2026-08-03 — Scrape feedback #5: `list_running` / `stop_module` — SHIPPED

Fifth item of `docs\feedback-web-scrape.md`. Stopping the harvester
meant PowerShell process-hacking by command-line substring — fragile, and far
outside the API. Now:

- **`list_running`** — every executing isolated-module body: name, pid,
  start time, running_seconds, and the latest `BodyStatus` line. Matching is
  anchored (our interpreter's basename + the `\hotkeys\bodies\*.body.ahk`
  path shape), not a loose substring.
- **`stop_module(name, grace_s)`** — graceful first, force-kill fallback,
  scoped to the module's own PIDs, never a name pattern.
- **The cooperative-stop convention the feedback asked to see documented**:
  `logs\body-stop-<Base>.flag`. Python write side `_body_stop_file`; AHK read
  side `BodyStopFile`/`BodyStopRequested` in `_Common.ahk` (same sanitize and
  root default as the BodyStatus pair — the two sides must derive the same
  name or graceful can never happen). `BodyStopRequested` CONSUMES the flag
  (one request = one stop) and `stop_module` deletes it in every path, so a
  stale flag can't kill the next press. Generated body headers now show the
  check (both generators, kept mirrored); existing bodies untouched — a body
  that never checks is force-killed after the grace period, no worse than
  before.

Verified: `test_list_running_and_stop_module` runs both paths against REAL
processes — a polite body (includes the real `_Common.ahk`, polls
`BodyStopRequested`) exits 0 within the grace and reports `how: graceful`,
which is the AHK-reads/Python-writes flag seam proven end to end; a body that
never checks reports `how: killed` with a nonzero exit; the flag never leaks.
Full suite green: 7 AHK suites + 28/28 conformance.

### 2026-08-03 — Scrape feedback #4: `run_ahk_snippet` — SHIPPED

Fourth item of `docs\feedback-web-scrape.md`. The session's "Tab
Probe" — 25 seconds of diagnostics — cost a real bridge key, `_index.ahk` and
`bridge-map.txt` lines, Voice Access pairing notes, and a `delete_automation`
call. `run_ahk_snippet(code, timeout_s)` runs AHK v2 once in a throwaway
process and costs nothing.

Shape worth keeping:

- **Zero path knowledge needed**: `lib\_Common.ahk` and `lib\UIA.ahk` are
  pre-included by absolute path, so `UiaFocused()` / `UiaDumpTree()` /
  `BodyStatus()` work on line one — the probes the feedback describes are
  one-liners now.
- **`Out(text)` is the report channel**, appending to a temp file the call
  returns as `output`. Deliberately not stdout: AutoHotkey is a GUI-subsystem
  exe and its stdout only works through a real redirect (the `AhkValidate`
  trap) — `/ErrorStdOut` load errors DO come back, as `errors`.
- **A trailing `ExitApp` keeps "runs once" true** even when the code declares
  hotkeys, timers or GUIs — a persistent script is a module's job, not a
  snippet's. cwd is the temp folder, so relative writes vanish with it.
- **A timeout kills the snippet but keeps the partial log** — for a wedged
  probe, what `Out()` said before the wedge is exactly the diagnostic.
  Bounded 1–120 s, default 15.
- The tool description points read-only probes at `inspect_focus` /
  `dump_uia_tree` first, and reminds that snippet code really drives the
  desktop.

No AHK-side change at all — the preamble is generated text, so the five-way
step lockstep and the selftests are untouched. Verified:
`test_run_ahk_snippet_runs_and_reports` (output round trip, ExitApp code
pass-through, lib pre-include proven via `UiaControlTypeName`, load-error
reporting, timeout-with-partial-log, empty-code guard). Full suite green:
7 AHK suites + 27/27 conformance.

### 2026-08-02 — Scrape feedback #3: `edit_hotkey_module` splice — SHIPPED

Third item of `docs\feedback-web-scrape.md`. Most of the session's
five body rewrites changed ONE function (the tile-matching predicate), and
each cost a full-body resend. `edit_hotkey_module(name, old_string,
new_string)` is the file-Edit-tool answer: old_string must match the current
code exactly once (0 matches and ambiguous matches are distinct errors;
whitespace exact; CRLF is normalized to LF first so a body the user touched
in Notepad still matches an agent's `\n` strings).

Safety and semantics worth keeping:

- **The edited file must still load** — `/validate` + rollback, proven in the
  test with a real parse-breaking splice. For an in-process module that guard
  is mandatory (the master includes it); for a body it turns a wasted press
  into an immediate error.
- **A body edit is live with NO master reload** — the body runs fresh on each
  press. Only an isolate=False edit reloads. (A replace always reloads; for
  the iterate-on-a-scraper loop this is the faster path twice over.)
- **Undo is the same call with the strings swapped** — a splice is its own
  inverse, so there is deliberately no backup file like the replace path
  keeps, and no `replace_all` option either (the feedback asked for an
  exact-match splice; uniqueness-or-error is the whole contract).
- Reserved names (`Snippets`) and missing modules are refused; the response
  carries `body_sha256`/`body_length` so an agent can confirm state without
  re-reading.

Verified: `test_edit_hotkey_module_splices_and_rolls_back` (splice, all five
guards, real-rollback, undo round trip, and the reload rule for both module
kinds — the temp root seeds `lib\_Common.ahk` so body validation resolves its
include). Full suite green: 7 AHK suites + 26/26 conformance.

### 2026-08-02 — Scrape feedback #2: replace echoes a hash, not the whole body — SHIPPED

Second item of `docs\feedback-web-scrape.md`. Replacing a hotkey
module returned the ENTIRE previous body in the response, so iterating on a
~300-line body five times paid for the old body's length every single time —
measured as the largest token sink of the session that produced the report.

Shipped: a replace now banks the overwritten file in
`logs\module-backups\<Base>.prev.ahk` (one per module, one step deep, written
only on a replace that succeeded — a failed load rolls back and leaves the
previous backup pointing at the last real overwrite) and returns
`previous_body_sha256` / `previous_body_length` / `previous_body_first_lines`
/ `previous_body_backup`. The undo promise survives THROUGH THE MCP SURFACE:
`read_hotkey_module(name, previous=True)` returns the banked version — the
feedback assumed plain `read_hotkey_module` could recover it, but that reads
the NEW body after a replace, and an MCP-only client (Claude Desktop) has no
filesystem access to the backup path, so without the parameter the hash-only
response would have quietly killed undo. Delete removes the backup with the
module. `update_ai_prompt` still echoes its previous prompt — deliberately;
prompts are short and it is a different tool.

Rode along (noted under item 8, which stays open for `read_module_status`):
the `create_hotkey_module` tool description now says long-running bodies
should report progress via `BodyStatus()` — the one-line doc fix §1.2 asked
for.

Verified: `test_hotkey_replace_returns_hash_not_body` (hash/length/lines
match the pre-replace read, backup round-trips exactly, no backup before a
first replace, delete removes it), and the older replace test now proves undo
via the new path. Full suite green: 7 AHK suites + 25/25 conformance. Also
fixed en route: the item-1 conformance test now `wait()`s for its target
process after `terminate()` — cleanup of the temp dir could race the dying
process's file handle (measured: one flaky failure in the first full-suite
run).

### 2026-08-02 — Scrape feedback #1: `inspect_focus` / `dump_uia_tree` — SHIPPED

First item of `docs\feedback-web-scrape.md` (the web-scraping
session's report; the rest of its checklist is being worked through
item by item). The agent driving that session was blind: to learn what a
focused listing tile calls itself it had to create, register and delete a
throwaway "Tab Probe" hotkey module — a real bridge key spent on one question,
"what am I looking at?".

Shipped as two read-only MCP tools backed by one committed probe script:

- **`inspect_focus`** — the focused element as UIA sees it (name, control
  type, value, rect, enabled, automation id), up to three ancestors, and the
  foreground window's title/class/exe. The tool description says why it
  matters: a focused element's accessible name routinely differs from its
  copied-text form, and matching against the wrong one is the classic
  silent-miss (measured in the session: tiles say
  `<title>, $price, <City>, ST, listing <id>` when focused, but
  `<title> in <City>, ST` when copied).
- **`dump_uia_tree`** — a window's tree as an indented `Type "Name" <id=…>`
  outline, with `max_depth` / `max_lines` / `name_filter`, all bounded by the
  node budget so a browser tree costs a capped report, never a stall.
- **`mcp\uia_probe.ahk`** — runs out of process (the UIA rule), reports to a
  temp FILE (AutoHotkey's GUI-subsystem stdout is only trustworthy through a
  real redirect), and an `error=` line is an answer, not a crash.
- **`lib\UIA.ahk` grew the structural walkers** the probe needed: `UiaParent`
  / `UiaFirstChild` / `UiaNextSibling` on the raw-view TreeWalker (raw view
  deliberately — Find* match the full tree, so a control-view dump could hide
  the very element a find would return), `UiaControlTypeName`, `UiaDumpTree`.
  New verified offsets, all taken from the SDK header and then measured:
  IUIAutomation 16 get_RawViewWalker; IUIAutomationTreeWalker 3
  GetParentElement, 4 GetFirstChildElement, 6 GetNextSiblingElement.

Deliberately NOT built: the feedback's optional `screenshot()` — image
plumbing far beyond "what am I looking at", and the two shipped tools are
what collapsed its debugging loop.

Verified: 25 new checks in `tests\uia-selftest.ahk` (76 total — every new
offset exercised, parent chain climbs to the window element, caps and filter
proven) and two new conformance tests, including a real end-to-end dump of a
throwaway GUI in another process. Full suite green: 7 AHK suites + 24/24
conformance.

From building and debugging a Chrome-driving scraper (hotkey body + `lib\UIA.ahk`)
against a public records site. Every item cost real failed runs.

- **1. The engine was blind in modern Chrome.** Element steps went through MSAA
  only, and current Chrome publishes **no page content** there — measured, an MSAA
  dump of a data-rich Chrome window gave ~109 descendants, all browser chrome; the
  same window over UIA gave the whole page. This closed the earlier open item B,
  which proposed a *diagnostic* ("your browser isn't exposing page content"). Once
  the measurement came in, a diagnostic was the wrong fix: it explains the failure
  instead of removing it. `WfFindElement` now tries **Acc first, then UIA**,
  interleaved in short passes so the total budget stays the 3 s it always was and
  browser clicks don't pay 3 s of futile MSAA walking first. Conditions
  (`elementexists`, `textvisible`) split their short budget the same way. No steps
  file changes; saved workflows that stopped working start working again.
- **2. Randomness primitives.** `wait|600-1400` pauses a random amount in that
  span, and named-element clicks land a few pixels off centre (clamped inside the
  rect, so a click can never miss; position-only clicks, drags and hovers stay
  exact). A looped workflow with metronome timing and pixel-identical clicks is
  the cheapest bot signal there is. Off switch: `[Workflow] ClickJitter` in
  `logs\settings.ini`, surfaced as the Studio's fifth checkbox.
- **3. Finding the right element.** `UiaFindAll`, an `occurrence` parameter, and
  int-property conditions (`UiaIntCondition` + `UiaAndCondition`) giving
  `UiaFindEdit` / `UiaFindOfType`. The trap is real and now reproduced in the
  self-test: a label and its input share one accessible name, `UiaFind` returns
  the label, and `UiaValue` falling back to the Name means nothing about the
  result tells you so.
- **4. `UiaTextPresent` + `UiaDumpText`.** Reading a page no longer means `^a`/`^c`
  (focus-dependent, clobbers the clipboard). Both bounded like `AccNodeOnce`.
- **5. `UiaClickCenter` / `UiaClickEl`.** Invoke is right for buttons, wrong for
  form fields — it moves no mouse, focuses nothing, and many inputs expose no
  InvokePattern, so it silently does nothing. These click for real and restore the
  caller's `CoordMode`.
- **6. Body status channel.** `logs\body-status-<Base>.txt`, written with
  `BodyStatus()`, read by the home window (with "how long ago") and by
  `list_automations`. A body that runs for hours could previously only talk to a
  ToolTip. Generated bodies now include `_Common.ahk` and carry the example.
- **7. The Git Bash `/ErrorStdOut` quirk** — documented in CLAUDE.md's traps
  section rather than worked around: from MSYS it exits 2 with empty output even
  for a good script. `AhkValidate` goes through `cmd /c` and is unaffected.

Also shipped as a **guard, not just a doc line**: the documented "never point UIA
at your own process" deadlock is refused at all three entrances — `UiaFromWindow`
(own-process window), `UiaFromPoint` (point over one), `UiaFocused` (one is
foreground) — each returning a quiet `""` instead of wedging. Every other
window-scoped call funnels through `UiaFromWindow`.

The danger notes from the report (never search-and-click a generic name like
"Close"; password-manager menus eat Enter/Tab; verify form input by reading it
back; detect pages by landmark text, not field names) are recorded in CLAUDE.md.

Found en route, by the new tests: `UiaJitter(max, extent)` — a **parameter**
shadowing the `Max()` built-in, which load-checks clean and fails at run time with
"Integer has no method named Call". Same namespace family as the earlier
`WfLogDir`/`wfLogDir` collision; both are in the traps list now.

Two new suites (`engine-hybrid-selftest` with its own target process,
`engine-pacing-selftest`), 25 new UIA checks including the own-process guard, and
two new conformance tests (the `wait`-range guard, and the body-status
AHK-writes/Python-reads seam). Full suite: 209 AHK checks + 22/22 conformance.

### 2026-08-01 — run evidence (#1 batch success lies, #2 no run log, #5 "no data yet") — SHIPPED

Three symptoms, one cause: **a run left no evidence**. `lib\LoopRunner.ahk` called
`ExitApp()` unconditionally, and the MCP's only success signal was that exit code —
so a batch that failed at step 7 and collected nothing reported `exit_code 0`,
`"Finished cleanly"`. The reason string existed the whole time; it went into a
MsgBox and was dropped.

Shipped:

- **A run record** — `logs\workflow-runs.ini`, one section per workflow, with
  outcome (ok / failed / stopped / cancelled / error), the failing step's number,
  description and reason, step and pass counts. Written **before** the failure
  popup, so a caller that gave up waiting can still see what happened.
- **A run log** — `logs\workflow-runs.log`, one line per step, rolling (newest
  half kept at 1 MB). Steps are logged **as written**, not with `{{Name}}`
  resolved: an ask answer may be a password.
- **Every failing step funnels through `WfRunFail`**, so ok/failed/stopped/
  cancelled are distinct instead of one bare `false`.
- **Meaningful exit codes** from `LoopRunner.ahk` (0/1/2/3), and `run_workflow_batch`
  / `run_automation` now report `ok`, `outcome`, `failed_step`, `reason`,
  `passes_done`/`passes_total` and a step `trace` — with a `since` stamp so a
  stale record can't be reported as this run's.
- **Quiet mode for headless batches** — the failure popup and the "Done, open it
  now?" prompt become TrayTips. A modal blocks *inside* the loop process, which is
  the other half of why `proc.wait()` said "finished cleanly".
- **`read_workflow_sheet` tells the three states apart** — never ran / ran and
  failed / ran but collected nothing — and always carries `last_run`.

Verified end to end: a failing 2-row batch reports `ok:false`, `failed_step:2`,
the reason and a 5-line trace, exit 1; a passing 2-row batch reports `ok:true`,
2/2 passes, exit 0; all three empty-sheet notes differ. 34 new engine checks and a
conformance test across the AHK-writes/Python-reads seam (`IniWrite` emits
UTF-16LE with a BOM); full suite 130 AHK checks + 20/20 conformance.

Found en route: `WfLogDir()` collided with a `wfLogDir` global — the shared
case-insensitive namespace trap, caught by the suite, fixed by renaming the
variable `wfLogFolder`.

Details in CLAUDE.md (engine bullet, "Run log and run record"; the MCP section).

### 2026-07-31 — #1 (blast radius) and #3 (workflow variables) — SHIPPED

**#1.** Named the three ways a module actually kills the master and fixed each:
won't-compile → `ReloadMasterNotify` load-checks and quarantines before every reload,
plus `VoiceKitLauncher.ahk` for boot; throws → `OnError` logs instead of leaving a
modal dialog; crashes hard → `lib\Watchdog.ahk` restarts from outside (heartbeat-based,
with crash-loop safe mode), and new custom module code runs out-of-process in
`hotkeys\bodies\`. Health now rides on **every** MCP response. Note: wrapping bodies in
`try/catch` — the literal ask — only covers the middle case; the crash that started this
was uncatchable by design.

**#3.** `{{Name}}` values in workflows, sourced from every ask label, collect label and
the new `set` step, with `{{clipboard}}/{{date}}/{{time}}/{{datetime}}` built in. No
on-disk format change and unknown names stay literal, so existing workflows are
untouched. Loop and MCP batch rows feed values for free.

Verified end to end: quarantine of a genuinely broken module, watchdog recovery of a
killed master (~23 s), clean-exit standdown, crash-loop safe mode, a crashing isolated
body leaving the master untouched, 26/26 engine checks for values, 17/17 conformance.

Details in CLAUDE.md ("Surviving a bad module", "Isolated module bodies", "Named values").

### 2026-07-31 — #2 (modules can't be overwritten) — SHIPPED

`create_hotkey_module` now **replaces in place** on an existing name, like
`create_workflow` — no more delete-confirm-recreate, no more name sprawl. The replace
keeps the module's bridge key (its Voice Access pairing is manual and unrecreatable),
adds no duplicate registry lines, switches a quarantined `#Include` back on, rolls back
on a failed load check, and returns `previous_body` so an unwanted overwrite is undoable.
Added `read_hotkey_module` so the loop is read → edit → replace rather than rewrite-blind.
`Snippets` is reserved (overwriting it would wipe every snippet).

Also fixed while in here: MCP deletes were stripping the UTF-8 BOM from `bridge-map.txt`
and `hotkeys\_index.ahk`, while the AHK side of the same operation preserves it — a
silent write-side parity break, now matched and covered by a conformance assertion.

Details in CLAUDE.md ("Modules are replaceable").

### 2026-07-31 — #4 (static waits and blind steps) — SHIPPED

New `waitfor` step: waits until something is actually true, continues the instant it is,
and on timeout fails saying *what never happened* instead of pressing on. Conditions are
shared with `if` via `WfEvalCond`, so the two vocabularies can't drift — element appears
/ disappears, window opens / closes, **text visible / not visible**, and (waitfor-only)
**clipboard changed**. Timeout defaults to 10 s and lives in paramC beside the condType.

`textvisible` is the "find matched nothing" detector the note asked for: a
case-insensitive substring search over the window, for when you know the words on screen
but not any element's exact name.

Measured on a throwaway window: element-appears returned in 1219 ms (not its 15 s
timeout), element-disappears in 1954 ms, clipboard-changed in 937 ms.

Details in CLAUDE.md (engine bullet, "Event waits / `waitfor`").

### 2026-07-31 — #5 (take-what-you're-given hotkeys) — SHIPPED

The pool now ends with punctuation — `[];',./-=\` — so `[` is available, and you can
**ask** for a key instead of being handed one: MCP `create_hotkey_module(key='[')`, and
New Automation's hotkey dialog offers the free list in a dropdown rather than assigning
silently. A taken key is refused by name; a replace keeps the key it already had.

Each symbol was measured rather than assumed: generated module loads, `Hotkey()`
registers it, and a synthesized SendLevel-1 press actually fires it. `"`, backtick, `|`,
Space and Enter failed one of those and stayed out.

**Found and fixed en route:** the AHK isolated-module generator emitted a broken file —
single-quoted AHK strings still process backtick escapes, so `` `n `` became a real
newline and left a `TrayTip("…` unterminated. New Automation → Custom code could not
create a module at all (it failed its own load check, so nothing broken was ever wired
in). The Python generator was unaffected, which is why every earlier MCP test passed —
a genuine two-implementation parity break. Conformance now byte-compares the two pools.

Details in CLAUDE.md ("Choosing a key", and the new backtick trap).

### 2026-08-01 — #6 (ship a UIA helper) — SHIPPED

`lib\UIA.ahk`: find by Name or AutomationId, read Name/Value/rect/enabled, set a
value outright via ValuePattern, invoke via InvokePattern (falling back to a click),
element-from-point, focused element, wait-for. Everything returns empty instead of
throwing, so a module built on it can be wrong without being fatal.

Every vtable offset is written down next to the interface it belongs to and exercised
by `tests\uia-selftest.ahk` — 30 checks, run against a **separate** target process.

Two things learned the hard way and now documented rather than rediscovered:

- **UIA against your own process hangs.** It calls back into the provider on the
  thread already blocked inside the UIA call. Timing-dependent: a small probe passed,
  the fuller test wedged forever. No timeout, nothing to catch. Automate other apps.
- A VARIANT argument is passed **by reference** on x64 — same trap as `accLocation`
  in Acc.ahk.

The workflow engine deliberately does NOT use it: the engine stays on MSAA so
recording and playback share one path. This is an escape hatch for hand-written
modules, and it belongs in a module body (out of process), never in VoiceKit.ahk.

Details in CLAUDE.md ("lib\UIA.ahk — the UI Automation escape hatch").

---

## 2026-07-31 — session notes (module authoring via MCP)

Six issues surfaced while hand-building hotkey modules that use MSAA/UIA. Ordered
roughly by impact. **All six are done — see above.**

### 1. One bad module kills the entire resident master — ~~HIGH~~ DONE

**What happened.** An MSAA bug in a single injected module didn't just fail on its
own: it took down *every* always-on hotkey and snippet the user owns, and the master
stayed dead until it was manually restarted.

**Why it matters.** A per-module authoring mistake becomes a whole-layer outage, and
nothing surfaces that it happened — the user finds out when a hotkey silently does
nothing.

**Proposed fix.**
- Wrap or isolate injected module bodies so a Critical Error in one can't nuke the
  layer.
- Report master health in **every** tool response, not as an occasional aside.

**Where this lives.** `VoiceKit.ahk` (resident master), `hotkeys\_index.ahk` (include
manifest), `mcp\server.py` (tool responses).

### 2. Modules can't be overwritten, but workflows can — ~~HIGH~~ DONE

**What happened.** The asymmetry forced delete-confirm-recreate cycles. Five throwaway
modules got churned through in one evening, partly because *replacing* a module costs
more than *creating a new one* — which produced real name sprawl.

**Why it matters.** The cheapest action should be the correct one. Right now it isn't.

**Proposed fix.** Give modules the same re-create semantics as workflows, or add an
explicit update call.

**Where this lives.** `mcp\server.py` (`create_hotkey_module`), `mcp\voicekit_writer.py`.

### 3. No variables in workflows — ~~HIGH~~ DONE

**What happened.** `ask` answers are typed at one position and the clipboard is the
only carrier, so using a single value in two places forced extra Excel↔Chrome round
trips.

**Why it matters.** Called out in the notes as *the single biggest capability unlock
available*.

**Proposed fix.** Named values — settable from `ask`, `collect`, or the clipboard, and
usable inside `text` / `keys` / element-name fields.

**Where this lives.** `lib\Workflow.ahk` (`RunWorkflowSteps`, the inline `ask`/`collect`
cases). Note this touches the three-way lockstep: engine, `voicekit_writer.STEP_TYPES`,
and `server.py`'s `WorkflowStep` schema — plus `DraftSystemPrompt`/`ParseDraft` in
`macros\NewAutomation.ahk` if step semantics change.

### 4. Static waits and blind steps — ~~MEDIUM~~ DONE

**What happened.** Milliseconds were hand-tuned by trial, and the workflow still can't
detect "find matched nothing" before typing into the void.

**Why it matters.** Workflows fail *fast* instead of failing *safe*.

**Proposed fix.**
- Event waits: window-changed, element-appeared, clipboard-changed.
- Richer `if` conditions: text visible, element exists.

**Where this lives.** `lib\Workflow.ahk` — `WfEvalCond` (currently `winexists` /
`winnotexists` / `elementexists` / `elementnotexists`), `WfSleep`, `WfWinWait`. Any new
condition must keep honoring the `wfRunAbortCheck` abort hook.

### 5. Hotkey allocation is take-what-you're-given — ~~LOW (cheap)~~ DONE

**What happened.** Allocation hands out letters and digits only. The user wanted `[`
and there was no path to it.

**Proposed fix.** An optional requested-key parameter, validated against the free list.

**Where this lives.** `BridgeKeyPool()` / `BridgeFreeKeys()` in `lib\_Common.ahk`
(source of truth), mirrored by `BRIDGE_POOL` in `mcp\voicekit_writer.py` — both sides
must change together.

### 6. Ship a UIA helper library that modules can include — ~~MEDIUM~~ DONE

**What happened.** ComCall vtable offsets were hand-rolled, and that's what crashed the
master while learning which approach actually works.

**Why it matters.** Nobody should have to pay that cost twice — and item 1 means paying
it is expensive.

**Proposed fix.** A shipped UIA helper in `lib\`, alongside the existing MSAA wrapper
(`lib\Acc.ahk`), that modules can `#Include`.

---

---

## Previously logged

### Upgrades don't wire up newly shipped hotkeys

The installer's upgrade guard preserves `_index.ahk` and `bridge-map.txt`, so a **new**
shipped companion hotkey (e.g. `Ctrl+Alt+Shift+W` → RecordMySteps) never registers on an
upgraded machine — dead key, and the allocator may hand that key away to something else.
Diagnosed live on a second machine on 2026-07-27 and fixed there by hand.

**FIXED 2026-09-30** (see the top entry) — by the per-user file split and
`SeedUserFiles`, a data-driven version of the agreed fix.

*Originally agreed fix:* A `VoiceKit.ahk` startup self-heal that appends missing
shipped-companion lines, mirroring the existing Start-Menu self-heal.
