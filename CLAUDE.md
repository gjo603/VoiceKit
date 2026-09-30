# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It holds the **rules**; the design notes and the dated "why" behind them are in `docs\architecture\` (index at the end).

## What this is

VoiceKit is a Windows 11 voice-automation system: **Voice Access turns speech into triggers; AutoHotkey v2 does everything else.** There is no build system, package manager, or test framework — just AutoHotkey v2 scripts, pipe-delimited text data, and Start Menu shortcuts. Everything is AutoHotkey **v2 only**; most AHK code on the internet is v1 and will not run. An optional Python MCP server (`mcp\`) is a third way to create and run automations.

## Commands

AutoHotkey is at `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`.

**Syntax-check a script** (the closest thing to a build). AutoHotkey is a GUI-subsystem exe, so `$LASTEXITCODE` after `&` is unreliable in PowerShell — use `Start-Process -Wait -PassThru` and read `.ExitCode`. Always pass `/ErrorStdOut`, otherwise load errors open a dialog and hang (and bound the wait — a `#Warn` warning pops a dialog even under `/validate`; see the traps):

```powershell
$p = Start-Process "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe" `
     -ArgumentList '/ErrorStdOut','/validate','"C:\Automations\VoiceKit\lib\Workflow.ahk"' `
     -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\ahkval.txt"
$p.ExitCode   # 0 = OK; error text is in the redirected stdout file
```

**Run the test suite** (one command, both languages; exits nonzero on any failure):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

It load-checks the shipped entry points (tracked `macros\*.ahk`, the launcher, loop runner, watchdog, UIA probe, complete templates, and `VoiceKit.ahk` against an empty module index), runs every `tests\*-selftest.ahk` (not `*-target.ahk` helpers), then `mcp\test_conformance.py` with `mcp\.venv`'s Python when it exists. Run the suite after touching:

| Suite | Run it after touching |
|---|---|
| `tests\preflight-selftest.ahk` | `lib\_Common.ahk` reload/preflight/quarantine code, the `Watchdog*` decisions + `lib\Watchdog.ahk`, `BodyStatus*`, `RobustMove`, `ErrorLog*`/`LogUncaughtError` |
| `tests\common-selftest.ahk` | `lib\_Common.ahk` snippet/hotkey/delete/tool/naming helpers, `SeedUserFiles`, `lib\Json.ahk`, `lib\Theme.ahk` `ThemeShowModal` |
| `tests\sheet-selftest.ahk` | `lib\Workflow.ahk` sheet/CSV code, `lib\WorkflowLoop.ahk` |
| `tests\engine-vars-selftest.ahk` | `lib\Workflow.ahk` (`{{Name}}` substitution incl. `fill`'s paramC, fill-value inputs `WfFillInputNames`, `{{selected_file(s)}}` + the selection snapshot) |
| `tests\explorer-selftest.ahk` | `lib\ExplorerSel.ahk` (failure paths always; the active-tab / zip / multi-select checks only when no Explorer window is open — it opens and closes its own) |
| `tests\engine-capture-selftest.ahk` | `lib\Workflow.ahk` `capture` step (`WfCapture*`, `WfDecodeBytes`, `WfKillTree`), the command-line quoting of `{{selected_file(s)}}` (`WfSubst(..., cmdLine)`), `macros\NewAutomation.ahk` `ParseDraft` (lifted from the source, run in a child) |
| `tests\engine-waitfor-selftest.ahk` | `lib\Workflow.ahk` waits/conditions, `lib\Acc.ahk` |
| `tests\engine-runlog-selftest.ahk` | `lib\Workflow.ahk` run log/record, `lib\WorkflowLoop.ahk` |
| `tests\engine-hybrid-selftest.ahk` | `lib\Workflow.ahk` `WfFindElement`/`WfUiaRect`/`WfElementPresent`/`WfTextVisible`/`WfFieldValue`/`WfIsBrowserWindow` |
| `tests\engine-fill-selftest.ahk` | `lib\Workflow.ahk` `fill` step (`WfFill*`, `WfFillLabel`, `WfFillMatches`), `lib\Acc.ahk` `AccInputNodes`/`AccRole`/`AccState`/`AccWindowOf` |
| `tests\engine-pacing-selftest.ahk` | `lib\Workflow.ahk` pacing code (wait ranges, click jitter) |
| `tests\uia-selftest.ahk` | `lib\UIA.ahk` (every vtable offset) |
| `tests\browser-selftest.ahk` | `lib\Browser.ahk` |
| `mcp\test_conformance.py` | anything in the lockstep lists below, the per-user file seed, the log cap, `mcp\README.md`'s tool table, `run_ahk_snippet`, `server.py`'s cancel patch |

What each suite covers, in detail: `docs\architecture\testing.md`.

**Reload the resident master** after touching `hotkeys\`: press Ctrl+Alt+Shift+R, or run **`VoiceKitLauncher.ahk`** (not `VoiceKit.ahk` directly). Both go through `ReloadMasterNotify`/`MasterPreflight`, which make the per-user files (`SeedUserFiles`) and load-check before replacing the running instance, parking a module that won't load. Launching `VoiceKit.ahk` by hand still works (it seeds the per-user files too) and is fine for a quick test, but it skips the load check, which is the whole point of the launcher.

**Never launch `macros\WorkflowStudio.ahk` as a smoke test without checking for a running instance** — `#SingleInstance Force` silently kills the user's open session and any unsaved recorded steps:

```powershell
Get-Process AutoHotkey64 -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like '*Workflow Studio*' }
```

## Test conventions

The runner depends on these — keep them when adding a suite (the measurements behind each are in `docs\architecture\testing.md`):

- **No framework, one shared include.** `tests\_harness.ahk` (`TestBegin(name)`, the retrying `Emit`/`Say`, `Check`, `TestEnd()`, and `TargetLaunch`/`TargetState`/`TargetStop`) and `tests\_target.ahk` (`TargetServe`) for target helpers. Both are named so the runner never executes them.
- **The result file is the verdict, never the process exit.** Each `<name>-selftest.ahk` writes PASS/FAIL lines to `<name>.result` beside itself, ending `ALL PASSED` / `N FAILURE(S)`. A bad vtable offset can hang and a step failure's MsgBox blocks forever; the runner kills a test at 120 s and reaps leftover `*-target*` processes.
- **Result-file writes retry** (`Emit`/`Say`), and the runner polls with `FileShare.ReadWrite` — a colliding bare `FileAppend` throws, pops a dialog and reads as a phantom timeout.
- **A test pins its target window to the PID it just launched** (`TargetLaunch`: `Run(..., &pid)` + `WinWait("Title ahk_pid " pid)`), never a bare title.
- **A test never raises a real toast** — engine/loop notifications go through `WfTray`; a harness sets `wfTrayOff := true` and asserts on `wfTrayLast`.
- **Tests drive their own throwaway windows and processes** — never the user's apps, the resident master, the real Start Menu (`VoiceMacrosDir(sandbox)` / `_sandbox()` redirect it), or the user's files; fixtures go in `%TEMP%`. Scratch output (`tests\*.result` / `.state` / `.stop`) is gitignored. `tests\` is dev-only and never ships.
- **Runner scripts stay ASCII-only** — PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI, and a mojibaked em-dash in a string can break parsing.
- **End-to-end engine tests**: a throwaway `.steps.txt` + a harness calling `RunWorkflow()` against a throwaway GUI with a unique title, PASS/FAIL to a result file, run with a timeout. A timeout with no result file almost always means a step's error MsgBox is blocking. `Start-Process -Wait` waits on the whole process TREE, so a harness that reloads the master never "finishes" — check the result file, and never kill such a wrapper's tree without restarting VoiceKit (through `VoiceKitLauncher.ahk`) afterward.

## Hard rules

- **The per-user files are the user's data.** `hotkeys\_index.ahk`, `bridge-map.txt` and `hotkeys\Snippets.ahk` are gitignored and never shipped; git tracks `hotkeys\_index.default.ahk`, `bridge-map.default.txt` and `hotkeys\Snippets.default.ahk`. A new shipped hotkey goes into the **defaults** (plus its tracked module file); `SeedUserFiles` (AHK) / `seed_user_files` (Python) add it to existing installs. Never commit or ship a live copy. Details: "Per-user files" in `docs\architecture\modules-and-bodies.md`.
- **Never point UIA at your own process** (it hangs — no timeout, nothing to catch), and `lib\UIA.ahk` / `lib\Browser.ahk` / `lib\Workflow.ahk` belong in out-of-process scripts (bodies, macros, snippets) — never `#Include`d into `VoiceKit.ahk`, which includes only `_Common.ahk` + `Theme.ahk` + `hotkeys\_index.ahk`.
- **Every reload goes through `ReloadMasterNotify`** (AHK) or `reload_voicekit` (Python) — never relaunch `VoiceKit.ahk` without the preflight from code.
- **Every generated or edited `.ahk` is load-checked before anything points at it**, and a failed check restores the exact previous bytes (`AhkWriteChecked`/`HotkeyWriteChecked`/`SnippetFileChange`; Python `_write_validated`/`_replace_validated`). A new write path follows the same rule.
- **A replace keeps its bridge key** — the Voice Access pairing is manual and cannot be recreated by code.
- **Generated workflow stubs are never hand-edited** — the steps file is canonical and the stub is regenerated on every save.
- **Keep GUI controls native** — Voice Access clicks a button by its accessible name (its caption); see "UI conventions".
- **Every new MCP response path goes through `server._guard`** — it is the ONE outbound privacy chokepoint (`_protect`): phase 1 path normalization (profile/temp prefixes → `%USERPROFILE%` / `%TEMP%`, `vk.normalize_paths`, always on) then phase 2 masking (`mcp\privacy.py`: names under the profile → `<dir#..>` / `<file#..>.ext` tokens by default, `[Privacy] Mode` in `logs\settings.ini`, which no tool may change), for results AND error text, failing closed. A tool that returns a value any other way leaks it. A new tool that returns authored source a caller will send back lists that field in `NORMALIZE_EXEMPT`; a new tool that takes a path or value to act on runs it through `expand_user_paths` (which expands tokens too); a new field that SAVES code or text calls `_no_tokens`. Tests never mask against the real profile — `privacy.PROFILE_OVERRIDE` / `_privacy_sandbox()`. The session-level `instructions` (`server_instructions`) list the taken names from the libraries at start — never hand-maintain that list.

## Lockstep lists

**Mirrored AHK↔Python pairs** — change both sides together and re-run `mcp\test_conformance.py`: `CleanPhrase`/`clean_phrase`, `SpaceOut`, `WfEncode`, `AhkStrLit`/`ahk_str_lit`, `SnipEncode`, the generators (`HotkeyLauncherContent`, `HotkeyBodyContent`, `VkOpensMacroContent`, `WfStubContent`, the `ai-template` fill), `MasterErrorModule`/`_error_module`, `MasterPreflight`/`master_preflight`, `IndexModules`/`index_modules`, `SeedUserFiles`/`seed_user_files`, `LogTrimIfOver`/`_log_trim_if_over` (crash-safe via `FileReplaceText`/`_replace_text`: temp file + move, never delete-then-append), `BridgeKeyPool`/`BRIDGE_POOL` and `BridgeFreeKeys`/`_used_bridge_keys`, `BodyStatus*`/`body_status`, `BodyStopFile`/`_body_stop_file`, `WfFillLabel`/`fill_label` and `WfAskLabels`/`_input_labels` (a workflow's inputs: ask labels + fill-value inputs), and the tool lists (`VkBuiltinTools`/`VkDeleteProtected` vs `_BUILTINS`/`_DELETE_PROTECTED_LOWER`). The writer's internals that must stay single-sourced (`_write_validated`, `_reload_outcome`, `_macro_info`, `_ahk_processes`, …) are listed in `docs\architecture\mcp.md`. Not a mirror but a drift point: the MCP's taken-names index (`_snippet_scope_defs`, `ahk_defs_in_chain`) follows what run_ahk_snippet's prelude and the generated body/macro headers `#Include` — change those includes and `test_instructions_names_exist` / `test_load_error_explains_name_clash` say so.

`mcp\voicekit_writer.py` duplicates the AHK write-side on purpose (the full list and the reasoning: `docs\architecture\mcp.md`); `mcp\test_conformance.py` enforces parity by feeding the writer's output through the **real** engine (`WorkflowLoad`) and running every mirrored generator on both sides (`test_generators_match_ahk`). **If you change any on-disk format (encoding, stub text, the `Generated by Workflow Studio` marker, file naming, BOM/LF), update `voicekit_writer.py` in lockstep and re-run the conformance test.** Newly created files are UTF-8 **with BOM** and **LF** endings (matching AHK `FileOpen`). Deletion protects VoiceKit's own tools **case-insensitively**. Step-type coverage is a **five-way** lockstep. All five must list the same types, or a type the engine supports becomes unreachable somewhere (this bit `if`/`else`/`endif` until the MCP schema was extended, and `set` touched all five):
1. `lib\Workflow.ahk` — `RunWorkflowSteps` / `WfRunStep` + `WfDesc` (and, for anything holding a value, `WfSubstStep` + `WfStepSubstText`)
   — the lockstep covers **param formats**, not just types: `wait` accepting a range (`600-1400`) touched all five, exactly like adding a step type would.
2. `macros\WorkflowStudio.ahk` — the parallel `typeIds` / `typeConds` / `typeLabels` arrays plus `StepDialog`'s `UpdateFields` and `OK` branches
3. `mcp\voicekit_writer.py` — `STEP_TYPES` + the per-type guards in `create_workflow`
4. `mcp\server.py` — `WorkflowStep`'s `Literal`, its fields, and `to_abc()`
5. `macros\NewAutomation.ahk` — `DraftSystemPrompt` + `ParseDraftInner.validTypes` + `paramCless` (the AI-draft path). A type may be deliberately REFUSED there with a named message instead (`capture` is — a draft must not carry a shell command), but it must be handled; a type that stores something in paramC needs its own branch — the old blank-paramC catch-all is gone, and an unlisted type is refused rather than silently stripped.

`capture` (2026-09-30) is the first step that EXECUTES something: `capture|<name>|<command line>|<seconds>` runs a cmd.exe command line hidden and keeps its stdout as a run-local `{{name}}`. Two rules to keep: a failed capture's reason in the run record/log/MCP is only `Command exited with code N` (no stderr, no resolved command — both can name a client's file; the stderr tail goes to the LOCAL popup only, through `WfRunFail`'s `detail`), and in a command line (`capture` paramB, `run` paramA) `{{selected_file(s)}}` always arrive quoted (`WfSubst(text, vars, true)`). Details: `docs\architecture\workflow-engine.md`.

`fill` (2026-09-30) is `fill|<window>|<label>[#N]|<value>` — find an input by its label, click it, refuse to type unless the focus landed on it (the **focus gate**), type, read it back. Three rules to keep: its **paramC is the value and the only paramC that is substituted** (`WfSubstStep`/`WfStepSubstText`, Python `_SUBST_FIELDS`); a failure reason or log note **never contains the value** — the box is named by its as-written label, typed-vs-held goes only to the local popup (`WfRunFail`'s `detail`); and a `{{Name}}` in a fill value that nothing defines is an **input** of the workflow (`WfFillInputNames` → `WfAskLabels`, Python `_input_labels`), so a batch column reaches a fill without an `ask` step typing it elsewhere. `"Amount#2"` = the 2nd input with that label, `##` = a literal `#`. Details: `docs\architecture\workflow-engine.md`.

`mcp\test_conformance.py`'s `STEPS` fixture is what mechanically catches drift between 1 and 3 — add every new type to it — and `test_server_schema_matches_the_writer` compares 4's `Literal`s (types, conditions, move positions) with `STEP_TYPES` / `WAIT_CONDS` / `MOVE_POSITIONS` (skipped when fastmcp isn't installed). Every per-type rule lives in 3 (`create_workflow`, errors prefixed `Step N:`); 4's `to_abc()` only maps fields, so the writer imported directly enforces exactly what the server does.

## AutoHotkey v2 traps specific to this codebase

- **Functions and variables share one case-insensitive namespace.** `statusBar` exists because `sb` collides with `SB()`; don't name a variable `log` (`Log` is an AutoHotkey **built-in** — the math function — *and* `_Common.ahk` redefines it, so a top-level `LOG := ...` fails to load even in a script that includes nothing) or reuse any function name as a variable. Only top-level code is hit: a plain variable inside a function is local. The MCP explains these errors itself (`_explain_ahk_error`: "'Log' is an AutoHotkey built-in…", "'Notify' is … defined in lib\_Common.ahk line N"), and so does the v1-style `""` quote (v2 escapes a quote as `` `" ``).
- **`lib\Acc.ahk`: oleacc.dll must stay pinned** (`AccPin()` calls `LoadLibrary` once). AHK frees on-demand DLLs after each `DllCall`; the COM objects oleacc returns point back into the DLL image, so without the pin the first method call is a hard process crash (an unreadable vtable, no catchable error).
- **`AccessibleChildren` returns S_FALSE (1) for "fewer than you asked for"** — routine with a stale `accChildCount`. Only `hr < 0` is failure; `AccChildren` treated S_FALSE as failure until 2026-09-30, silently dropping whole subtrees and leaking every child. Its return type is spelled `"int"` explicitly, and non-object VARIANT slots are `VariantClear`ed.
- **`accLocation` must be called through the raw vtable** (`ComCall(22, ComObjValue(acc), ...)` with a by-ref VARIANT) — IDispatch marshaling of its four `long*` out-params fails with "Type mismatch". Names/roles/children work fine through IDispatch.
- **Windows 11 Explorer tabs share ONE top-level HWND**, and each tab is its own `Shell.Application` window entry — so `w.HWND = hwnd` plus "first entry with a selection" reads a *background* tab (measured: the list put the background tab first). `lib\ExplorerSel.ahk` is the one copy of the lookup: the entry whose `IShellBrowser::GetWindow` (QueryService `SID_STopLevelBrowser`, vtable slot 3) equals `ShellTabWindowClass1` (always the active tab; `IsWindowVisible` is 1 for every tab, so visibility can't tell them apart). Never write another Shell.Application selection loop. `WinClose` on a tabbed window closes only its active tab — a test closes its own window with each tab's `.Quit()`.
- **Always pass `"UTF-8"` to `FileRead`** — the default ANSI read turns em-dashes in templates into mojibake (this bug shipped once already).
- **Single-quoted strings STILL process backtick escapes.** `'...:`n"'` puts a real newline in the output, not the two characters `` `n ``. This shipped broken in `HotkeyLauncherContent`: the generated launcher had an unterminated `TrayTip("...` string, so the AHK side of isolated-module creation always failed its load check while the Python side (no backtick escapes) worked fine — a parity break that only an AHK-side test could catch. When a generator must EMIT `` `n ``, write ` ``n `.
- **A `;` preceded by whitespace starts a comment even INSIDE a double-quoted string.** `x := "  ; "` is a load error ("Missing `"`") because the parser takes the `;` as a comment and the string never closes. `"; "` is fine (the `;` follows the quote, not a space), and `` "  `; " `` is fine (escaped). This is the same trap `SnipEncode` escapes semicolons for; it also bites any *generator* that emits AHK code with an inline comment — see `HotkeyLauncherContent` in `_Common.ahk`, which writes `` `; `` for exactly this reason. When a string just needs a literal semicolon, build it from `Chr(59)`.
- **`until` is a reserved word** (`loop … until`) and can't be a variable name — it fails with "The following reserved word must not be used as a variable name". Same family as the `Log`/`sb` collisions above.
- **A v2 script with NO `#SingleInstance` directive defaults to Prompt** — a second launch of the same path pops a modal "already running, replace it?" dialog and sits there. Measured the hard way: a mutex-test script without the directive wedged its second instance on that dialog *before* the auto-execute section ever ran, which read as the mutex failing. Test/probe scripts that may overlap must say `#SingleInstance Off` explicitly; generated bodies carry `Ignore`.
- **Functions and variables share one namespace, and a PARAMETER can shadow a built-in.** A helper written `Jitter(max, extent)` makes `Max(0, ...)` inside it resolve to the parameter, and the call fails at **run time** with *"This value of type Integer has no method named Call"*. It load-checks clean, so `/validate` says nothing — `tests\uia-selftest.ahk` is what caught it. Same family as the `statusBar`/`sb` and `Log` collisions above; the fix is `maxPx`.
- **AutoHotkey is a GUI-subsystem exe, so `/ErrorStdOut` needs a real stdout handle.** A `WScript.Shell.Exec` pipe silently yields empty output; a `cmd.exe` file redirect works. `AhkValidate` in `_Common.ahk` uses the redirect for that reason (measured — the pipe version load-checked correctly but could never name the failing file, which would have quietly disabled quarantining). **The same trap from Git Bash / MSYS**: `AutoHotkey64.exe /ErrorStdOut=UTF-8 /validate file.ahk` there exits **2 with empty output even for a known-good script**, so a validating tool or agent that trusts the exit code reports every file as broken. `AhkValidate` goes through `cmd /c` and is unaffected; anything validating out of band should do the same, or use PowerShell's `Start-Process -Wait -PassThru` and read `.ExitCode` (the recipe at the top of this file). Treat `/validate`'s exit code as the signal and its stdout text as best-effort.
- **`/validate` can still show a dialog: `#Warn`.** A `#Warn` warning pops its MsgBox even under `/validate /ErrorStdOut` (measured) — and launched hidden, nobody can see it — so an unbounded load check hung every reload, every preflight and the login launcher forever. `AhkValidate(file, timeoutMs := 20000)` and Python `validate_ahk` (`VALIDATE_TIMEOUT_S`) therefore kill the whole tree (`taskkill /T /F`) after the bound and fail with text saying a `#Warn`/dialog blocked it (AHK also sets `timedOut`; Python's text starts with `VALIDATE_BLOCKED`). Don't reach for `#Warn` in modules or bodies. Related: `ComSpecPath()` in `_Common.ahk` is the command interpreter even from a stripped environment (`A_ComSpec`, else `A_WinDir "\System32\cmd.exe"` — not `SystemRoot`, which a scrubbed environment loses too); `AhkValidate` and Split Pages use it, and `validate_ahk` reads AutoHotkey's error text as UTF-8 (`/ErrorStdOut=UTF-8`), like `run_ahk_snippet`.
- **`IniWrite` creates the file as UTF-16LE with a BOM.** Anything reading `logs\master-status.ini` outside AHK must handle that — `voicekit_writer._read_text_any` sniffs the BOM.
- **Dialog ownership**: the Studio window is AlwaysOnTop, so every MsgBox it opens must carry `"Owner" g.Hwnd` or it appears *behind* the Studio, unfocused. Prefer custom `Gui()` dialogs with `ThemeApply()` over `InputBox` so dialogs match the Studio's themed look (the save-name dialog already does this). Engine popups use the `262144` (always-on-top) MsgBox flag because they appear over arbitrary apps.
- **A modal dialog helper must capture the Gui's HWND into a local BEFORE `d.Show()`, then wait on the raw `"ahk_id " hwnd`** — never read `d.Hwnd` (or any property) again after Show. A voice click or a fast Enter on the `Default` button can destroy the Gui in the instant between `Show()` and the next line, and a property read on a destroyed Gui **throws "Gui has no window"** — which pops an error dialog and *hangs the whole run* (it surfaced as an intermittent ~50%-of-runs timeout in the ask-input engine test). `WinActivate`/`ControlFocus` also go in a `try` (the window may already be gone); `WinWaitClose` on an absent hwnd simply returns, so it's safe outside the try. This bit `RunOwnedDialog` (Add/Edit/Save) as well as the ask-input and loop-input dialogs — the fix pattern is `hwnd := d.Hwnd, edHwnd := ed.Hwnd` on the line above `d.Show()`. GUIs now get it for free from `ThemeShowModal` in `lib\Theme.ahk` (`tests\common-selftest.ahk` destroys a dialog the instant it appears to pin it); a handler that can outlive its dialog — anything awaiting `AIComplete`, which keeps the dialog responsive — must check `WinExist("ahk_id " hwnd)` before touching controls.
- Steps are 4-element arrays (`[type, a, b, c]`) everywhere in memory; keep writes 4-field.
- Generated workflow stubs in `macros\` must never be hand-edited or treated as the source of truth — they are regenerated on every save; the steps file is canonical.
- **`lib\AI.ahk` include order**: hosts must include `_Common.ahk` and `Theme.ahk` *before* `AI.ahk` (it uses `EnsureDir`/`ThemeApply`/`ThemeDim` but deliberately doesn't include them — a second `#Include` via a different relative spelling risks duplicate definitions). `AI.ahk` pulls in `Json.ahk` itself.
- An AI action's prompt lives in `prompts\<Base>.prompt.txt`, NOT inside the generated macro — so user prompts never need AHK string-escaping and Home can edit them in place. Deleting an AI action must remove the prompt file too.

## UI conventions

- The **REC bar** floats at the **bottom-left** of the screen during recording, with a prominent **Stop Recording** button (bold, accent-bordered).
- The **Record My Steps** button in the New Automation chooser uses the `Default` (accent-bordered) style to stand out from the other choices.
- The **click** step type is labeled "Left-click" in the Add Step dialog to distinguish it from double-click and right-click.

## Design rules (from README — keep them)

- Voice Access shortcuts cannot be created programmatically; never promise otherwise. Anything voice-triggerable without manual setup must go through the Start Menu path.
- No raw coordinate-click automation as a primary mechanism (recorded clicks are element-name first; coordinates only as fallback), no pixel/image searching, nothing non-deterministic in the core. **Wait ranges and click jitter are not a breach of that rule** (2026-08-01): the same steps run in the same order and act on the same elements — only the timing and the exact pixel vary, both bounded (jitter is clamped inside the target rect, so it cannot change *what* is clicked). Nothing about the outcome is left to chance, and both are there to stop a looped workflow reading as a machine gun to the site it's driving. Read any future "add randomness" proposal against that line: varying *how* a deterministic action is performed is fine; varying *which* action happens is not. The OpenRouter/LLM integration the user floated **is now built** as the one sanctioned exception: strictly opt-in (dead until a key is saved), strictly additive (`lib\AI.ahk` + its three surfaces), and the deterministic engine (`lib\Workflow.ahk`) must never grow an AI step type or import.

## Architecture index

**Two trigger paths**: (1) **launch macros** — scripts in `macros\`, each with a Start Menu → `Voice Macros` shortcut, so "open \<name\>" works with zero Voice Access setup; (2) **bridge hotkeys** — modules in `hotkeys\` bound to `Ctrl+Alt+Shift+<key>`, which the user pairs with a Voice Access shortcut by hand (no API can). The resident master `VoiceKit.ahk` loads every module through `hotkeys\_index.ahk`; `bridge-map.txt` is the key registry. Reserved keys: **E, N, R** (master), **X, H, I, C** (Workflow Studio while recording / loop stop).

| File | Covers |
|---|---|
| `docs\architecture\resilience.md` | Surviving a bad module: `ReloadMasterNotify`/`MasterPreflight` quarantine (missing files, `#Warn` timeouts), per-user file seeding at start, `VoiceKitLauncher.ahk` at boot, runtime `OnError`, the watchdog (heartbeat, safe mode, sleep/resume), health reporting |
| `docs\architecture\modules-and-bodies.md` | The trigger paths and reserved keys, **per-user files** (`*.default` + `SeedUserFiles`), isolated module bodies (`hotkeys\bodies\`, `BodySingleInstance`), body status + cooperative stop, replace semantics and backups, companion hotkeys, choosing a key |
| `docs\architecture\uia-and-browser.md` | `lib\UIA.ahk` (verified vtable offsets, finding the right element, reading/clicking, the own-process rule), `lib\Browser.ahk`, and the hard-won rules for driving a browser from a body |
| `docs\architecture\workflow-engine.md` | `lib\Workflow.ahk` (step format, run log/record, quiet mode, conditionals, `waitfor`, ask/collect/set and `{{Name}}`, `{{selected_file(s)}}` + `lib\ExplorerSel.ahk`, the `capture` step, MSAA→UIA lookup, pacing), `lib\Acc.ahk`, the loop runner and sheets |
| `docs\architecture\studio-and-recorder.md` | Workflow Studio: recorder, `ClassifyWindow`, saving, the artifacts of a saved workflow, recording options, the recorder's known limitations |
| `docs\architecture\gui.md` | New Automation (the scaffolder), the home window, the AI layer, `lib\_Common.ahk` (incl. `RobustMove`, uncaught-error capture, the log cap), `lib\Theme.ahk`, Split Pages |
| `docs\architecture\mcp.md` | The MCP server: tools, run outcomes, batches from any CSV/Excel range (`run_workflow_batch(source=)`), **privacy masking** (`mcp\privacy.py`: modes, readable folders, tokens + map + key, input expansion, `reveal`/unmask audit), cancellation safety, macro source tools, writer internals |
| `docs\architecture\distribution.md` | `build\` and `Install-VoiceKit.cmd`: what ships, what never does, upgrades, line endings |
| `docs\architecture\testing.md` | The full suite table and the reasoning behind each test convention |

Open work: `docs\backlog.md` (and `docs\roadmap-extraction.md`); shipped history: `docs\CHANGELOG.md`.
