# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

VoiceKit is a Windows 11 voice-automation system: **Voice Access turns speech into triggers; AutoHotkey v2 does everything else.** There is no build system, package manager, or test framework — just AutoHotkey v2 scripts, pipe-delimited text data, and Start Menu shortcuts. Everything is AutoHotkey **v2 only**; most AHK code on the internet is v1 and will not run.

## Commands

AutoHotkey is at `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`.

**Syntax-check a script** (the closest thing to a build). AutoHotkey is a GUI-subsystem exe, so `$LASTEXITCODE` after `&` is unreliable in PowerShell — use `Start-Process -Wait -PassThru` and read `.ExitCode`. Always pass `/ErrorStdOut`, otherwise load errors open a dialog and hang:

```powershell
$p = Start-Process "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe" `
     -ArgumentList '/ErrorStdOut','/validate','"C:\Automations\VoiceKit\lib\Workflow.ahk"' `
     -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\ahkval.txt"
$p.ExitCode   # 0 = OK; error text is in the redirected stdout file
```

**Test the workflow engine end-to-end** (the established pattern — no framework): write a throwaway `.steps.txt` plus a harness script that calls `RunWorkflow()` and writes PASS/FAIL to a result file, then run it with a timeout. A timeout with no result file almost always means a step failed and its error MsgBox is blocking. Target throwaway AHK GUI windows with unique titles (e.g. a button that writes a proof file when clicked) — never drive the user's real windows in tests.

**Reload the resident master** after touching `hotkeys\`: run `VoiceKit.ahk` again (`#SingleInstance Force` replaces the instance) or press Ctrl+Alt+Shift+R.

**Never launch `macros\WorkflowStudio.ahk` as a smoke test without checking for a running instance** — `#SingleInstance Force` silently kills the user's open session and any unsaved recorded steps:

```powershell
Get-Process AutoHotkey64 -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -like '*Workflow Studio*' }
```

## Architecture

**Two trigger paths** (see README for the user-facing story):

1. **Launch macros** — standalone scripts in `macros\`, each with a shortcut in Start Menu → `Voice Macros`. Voice Access natively opens Start Menu entries, so "open \<name\>" works with zero Voice Access config. This is why saving anything voice-triggerable means creating a `.lnk` there.
2. **Bridge hotkeys** — modules in `hotkeys\` bind `Ctrl+Alt+Shift+<key>`; the user manually pairs a Voice Access shortcut to that key combo (no API exists to do it programmatically — hard platform limit). `bridge-map.txt` is the registry of used keys and the user's recreate list. `_index.ahk` is the include manifest; `VoiceKit.ahk` (resident, tray icon) loads it. Reserved keys, excluded from the allocator pool in `NewAutomation.ahk`: **E, N, R** (master's own) and **X** (Workflow Studio's stop-recording hotkey).

**The scaffolder** — `macros\NewAutomation.ahk` ("open new automation") creates all four automation types: launch macro (from `templates\`), hotkey module (allocates a bridge key, appends to `_index.ahk` + `bridge-map.txt`, reloads master), snippet (appends a hotstring to `hotkeys\Snippets.ahk`), or hands off to Workflow Studio.

**The workflow subsystem** (one data format; engine + Acc + loop runner + builder):

- `lib\Workflow.ahk` — the engine. Parses and runs `workflows\<Base>.steps.txt`: one step per line, `type|paramA|paramB|paramC`, params percent-encoded (`WfEncode`/`WfDecode`; `%`, `|`, newlines). Step types: `run`, `focus` (activate-or-launch), `waitwin`, `wait`, `text`, `keys`, `click`/`dblclick`/`rclick` (element-name first via Acc, recorded window-relative coords as fallback in paramC), `move`, `close`, plus the **branching** trio `if`/`else`/`endif`. The loader pads short lines, so older 3-field files still work. A failing step stops the run with an always-on-top MsgBox naming the step.
  - **Conditionals**: `RunWorkflowSteps` is an index/program-counter `while` loop (not a `for`-each), so an `if` whose condition is false can skip to its matching `else` (or past `endif`); `WfSkipToElseOrEndif`/`WfSkipToEndif` do depth-aware matching so blocks nest. An `if` step is `if|<window>|<element>|<condType>` — condType lives in **paramC** (like `click` keeps coords there), so the Studio's edA→paramA, edB→paramB field model is unchanged. `WfEvalCond` supports deterministic state tests only: `winexists`, `winnotexists`, `elementexists`, `elementnotexists`. Guardrails (from the production review): `WfEvalCond` rejects an **empty window** (else `WinExist("")` would match the last-found window and mis-branch); `WfElementPresent` uses a **short 700 ms Acc budget** (not the 3 s click-path budget) since a condition is a point-in-time snapshot — the long budget stalled every absent-element check, badly inside a loop. `else`/`endif` are param-less markers; unknown condType stops the run like a failed step. Balance is enforced at authoring time, not run time: Studio `BlockBalanceError` (and the MCP writer) refuse to save/test/create unbalanced `if`/`else`/`endif` — an unbalanced block would otherwise *silently truncate* the run while Test falsely reports success. Backward compatible: workflows with no `if` run identically (every step is a normal step).
- `lib\Acc.ahk` — minimal MSAA (oleacc) wrapper used for click-by-name. See the traps below before touching it.
- `lib\WorkflowLoop.ahk` + `lib\LoopRunner.ahk` — the **loop** feature. `RunWorkflowLoop(stepsFile, phrase)` (in WorkflowLoop.ahk) re-runs a workflow's steps until stopped, showing a themed always-on-top **Stop Looping** bar (bottom-left, work-area anchored), pausing `delayMs` (default 1500) between passes via an interruptible `WfLoopSleep`, and **stopping automatically if a step fails** (so a broken workflow can't spin). Stop = the voice-clickable button, or `Ctrl+Alt+Shift+X` (`WfLoopRequestStop` sets the `wfLoopStop` global). `LoopRunner.ahk` is the entry script the `loop <name>` shortcut targets — it reads the workflow base from `A_Args[1]`, resolves the steps file, and calls `RunWorkflowLoop`; `#SingleInstance Force` means only one loop runs at a time. WorkflowLoop.ahk requires Workflow.ahk + Theme.ahk to be included first (LoopRunner does this); it is **not** included by normal workflow stubs, so the engine keeps no Theme dependency. The stop hotkey reuses `Ctrl+Alt+Shift+X` (Studio's stop-recording key) — safe because looping and recording aren't concurrent; if both ever were, only one process wins the global-hotkey registration and the Stop button still works.
- `macros\WorkflowStudio.ahk` — builder GUI + recorder. Recording = window-switch polling timer + `#HotIf recording` mouse hotkeys + an `InputHook("V")` for keystrokes, with a floating always-on-top REC bar. **Conditionals in the Add dialog**: the four `if` variants + `else` + `endif` sit at the END of the Action dropdown (so they're never the default and don't clutter recording); a parallel `typeConds` array maps the four `if` rows to their condType (the on-disk type is just `if`). `RefreshLV` indents each row by `if`/`endif` depth so blocks read as nested. Recording never emits conditionals — they're authored only. Pressing **F9** (or Enter — Record is the `Default` button and gets focus on show) starts recording. `ClassifyWindow()` is the single decision point for what gets recorded and how windows are identified: Explorer folders → cleaned title + `ahk_class CabinetWClass` with an `explorer.exe "<path>"` relaunch command (path via `Shell.Application` COM); UWP apps → title + `ahk_exe ApplicationFrameHost.exe` (no relaunch command); everything else → `ahk_exe <name>.exe` + process path. Double-clicking a file in Explorer is rewritten into a `run|<full path>` step.

**A saved workflow is three artifacts** (plus one companion `.lnk`): `workflows\<Base>.steps.txt` (the single source of truth), `macros\<Base>.ahk` (a generated stub that just calls `RunWorkflow`; contains the marker text "Workflow Studio", which save/delete checks before overwriting or removing so hand-written macros are never clobbered), the Start Menu `.lnk` named by the spoken phrase, and a companion **`loop <phrase>.lnk`** (created by `MakeLoopShortcut`) that targets `lib\LoopRunner.ahk` with the base as its argument. The loop companion is created at save (WorkflowStudio `SaveWorkflow`) and on first-run/reinstall (`VoiceKit.ahk` iterates `workflows\*.steps.txt`), and removed on delete. Note the loop companion is a `.lnk` only — it does **not** change the byte-compared stub/steps formats, so it is outside the MCP conformance check; but the MCP writer creates it too (`make_loop_shortcut`) for feature parity, so keep both sides in sync.

`lib\_Common.ahk` holds shared helpers (`EnsureDir`, `Notify`, `RunOrActivate`, `CleanPhrase`, `Log`, plus `RunAhk`/`MakeAhkShortcut`/`IsReservedName` — the last three make launching/shortcuts association-proof by targeting `A_AhkPath` with the script as an argument). Standalone macros include it via `#Include "%A_ScriptDir%\..\lib\_Common.ahk"`.

`lib\Theme.ahk` gives every GUI one modern look: it follows the Windows light/dark setting (`AppsUseLightTheme`), sets a matching title bar (DWM `DWMWA_USE_IMMERSIVE_DARK_MODE`), and dark-themes the **native** controls (`SetPreferredAppMode` ordinal 135 + `SetWindowTheme`, plus a `WM_CTLCOLOR*` hook for edit backgrounds). Call `ThemeApply(gui [, statusTextCtrl])` right before `Gui.Show()`; `ThemePalette()` returns the colors. **Keep controls native — never swap buttons for owner-drawn/custom widgets** — because Voice Access clicks a button by its accessible name (its caption); a custom widget has none. Button captions may carry a leading **monochrome, text-presentation** glyph (e.g. `●▶✕＋✎↑↓`, and `🖫` U+1F5AB for Save) but must keep the real word so voice matching still works; avoid emoji-presentation glyphs (`🗑💾⏺`) — they render in color and clash. Studio, New Automation and Help all call `ThemeApply`.

Workflow Studio has a **"Close browser tabs before recording"** checkbox (`CloseBrowserTabs()`): when ticked, clicking Record first `WinClose`s every visible window of the common browsers so a recording starts from a clean browser. It is deliberately **graceful only** — a window still up after a few seconds is blocked by an unsaved-changes/"Leave site?" prompt, and it is left open and reported (never force-confirmed with a synthetic keystroke, which would silently discard the user's work). Its on/off state persists in `logs\settings.ini` (`[Studio] CloseBrowserTabs`).

**The MCP server** (`mcp\`, optional add-on — the repo's only Python) is a third automation-creation path alongside the scaffolder and recorder: a FastMCP `server.py` exposing create/list/run/delete tools so Claude can build automations from natural language. `mcp\voicekit_writer.py` is a **deliberate second implementation** of the AHK write-side (`CleanPhrase`, `WfEncode`, the bridge allocator, the stub/steps formats, `.lnk` creation, reload). This duplicates format knowledge that otherwise lives only in AHK — the tradeoff was accepted because `mcp\test_conformance.py` mechanically enforces parity: it feeds the writer's output through the **real** engine (`lib\Workflow.ahk` `WorkflowLoad`) and byte-compares, and diffs a generated stub against a committed one. **If you change any on-disk format (encoding, stub text, the `Workflow Studio` marker, file naming, BOM/LF), update `voicekit_writer.py` in lockstep and re-run the conformance test.** Newly created files are UTF-8 **with BOM** and **LF** endings (matching AHK `FileOpen`); the writer reproduces that exactly. Step-type coverage is a **three-way** lockstep — the AHK engine, `voicekit_writer.STEP_TYPES`, AND `server.py`'s `WorkflowStep` Pydantic `Literal` + `to_abc()` must all list the same types, or a type the engine supports becomes unreachable through MCP (this bit `if`/`else`/`endif` until the schema was extended; the writer also validates the `if` condType and `if/else/endif` balance at create time).

**Distribution** — committed tooling lives in **`build\`**; outputs go to **`dist\`** (gitignored). Run `build\Build-Installer.cmd` (double-click) or `build\Build-Installer.ps1 [-Exe]`: it stages the **working tree** (so uncommitted/new files are included) minus dev/runtime cruft (`.git`, `dist`, `build`, `CLAUDE.md`, `__pycache__`, `.venv`, `logs`) and the legacy `Setup.bat`, bundles a portable `AutoHotkey64.exe` (so the tester needs no winget/AHK), adds `build\Install-VoiceKit.cmd`, and zips `dist\VoiceKit-Setup.zip`. `Install-VoiceKit.cmd` robocopies to `%LOCALAPPDATA%\Programs\VoiceKit` and launches via the bundled interpreter (so `A_AhkPath`, and thus every generated macro/loop shortcut, uses the bundle). Production-review hardening baked into `build\Install-VoiceKit.cmd`: **excludes `Setup.bat`** (a wrong-file click would do a fragile in-place install pointing shortcuts at a temp folder), **`Unblock-File`s the target** to strip Mark-of-the-Web (the unsigned bundled exe would otherwise trip a security prompt; cancel = silent no-op install), and **scopes the pre-copy `taskkill`** to AutoHotkey processes whose path is under the target (a blanket `/im` would kill unrelated AHK scripts, but a `VoiceKit.ahk`-only filter would miss a running loop/Studio holding the file lock). `-Exe` wraps the zip into a self-extracting `.exe` via IExpress (`bootstrap.cmd` → delegates to the same installer) — IExpress needs an interactive desktop, so it no-ops headless.

## AutoHotkey v2 traps specific to this codebase

- **Functions and variables share one case-insensitive namespace.** `statusBar` exists because `sb` collides with `SB()`; don't name a variable `log` (`Log()` is defined in `_Common.ahk`, shadowing the math built-in) or reuse any function name as a variable.
- **`lib\Acc.ahk`: oleacc.dll must stay pinned** (`AccPin()` calls `LoadLibrary` once). AHK frees on-demand DLLs after each `DllCall`; the COM objects oleacc returns point back into the DLL image, so without the pin the first method call is a hard process crash (an unreadable vtable, no catchable error).
- **`accLocation` must be called through the raw vtable** (`ComCall(22, ComObjValue(acc), ...)` with a by-ref VARIANT) — IDispatch marshaling of its four `long*` out-params fails with "Type mismatch". Names/roles/children work fine through IDispatch.
- **Always pass `"UTF-8"` to `FileRead`** — the default ANSI read turns em-dashes in templates into mojibake (this bug shipped once already).
- **Dialog ownership**: the Studio window is AlwaysOnTop, so every MsgBox it opens must carry `"Owner" g.Hwnd` or it appears *behind* the Studio, unfocused. Prefer custom `Gui()` dialogs with `ThemeApply()` over `InputBox` so dialogs match the Studio's themed look (the save-name dialog already does this). Engine popups use the `262144` (always-on-top) MsgBox flag because they appear over arbitrary apps.
- Steps are 4-element arrays (`[type, a, b, c]`) everywhere in memory; keep writes 4-field.
- Generated workflow stubs in `macros\` must never be hand-edited or treated as the source of truth — they are regenerated on every save; the steps file is canonical.


## Recorder known limitations

- **Hover interactions are not captured.** The recorder hooks mouse clicks and keystrokes only; mouse-move / hover events are not recorded. A `hover` step type is a desired future feature.
- **Windows may open half-screen (snap layouts).** During recording, apps sometimes open in half-screen rather than maximized. Auto-maximizing windows during recording is a desired future feature.
- **Drags and scrolling are not captured.** These are noted in the help text and remain unimplemented.

## UI conventions

- The **REC bar** floats at the **bottom-left** of the screen during recording, with a prominent **Stop Recording** button (bold, accent-bordered).
- The **Step Workflow Recording** button in the New Automation chooser uses the `Default` (accent-bordered) style to stand out from the other choices.
- The **click** step type is labeled "Left-click" in the Add Step dialog to distinguish it from double-click and right-click.

## Design rules (from README — keep them)

- Voice Access shortcuts cannot be created programmatically; never promise otherwise. Anything voice-triggerable without manual setup must go through the Start Menu path.
- No raw coordinate-click automation as a primary mechanism (recorded clicks are element-name first; coordinates only as fallback), no pixel/image searching, no cloud calls, nothing non-deterministic. (The user has floated an OpenRouter/LLM integration as a possible future exception — it is not built.)
