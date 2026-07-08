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

**The workflow subsystem** (three files, one data format):

- `lib\Workflow.ahk` — the engine. Parses and runs `workflows\<Base>.steps.txt`: one step per line, `type|paramA|paramB|paramC`, params percent-encoded (`WfEncode`/`WfDecode`; `%`, `|`, newlines). Step types: `run`, `focus` (activate-or-launch), `waitwin`, `wait`, `text`, `keys`, `click`/`dblclick`/`rclick` (element-name first via Acc, recorded window-relative coords as fallback in paramC), `move`, `close`. The loader pads short lines, so older 3-field files still work. A failing step stops the run with an always-on-top MsgBox naming the step.
- `lib\Acc.ahk` — minimal MSAA (oleacc) wrapper used for click-by-name. See the traps below before touching it.
- `macros\WorkflowStudio.ahk` — builder GUI + recorder. Recording = window-switch polling timer + `#HotIf recording` mouse hotkeys + an `InputHook("V")` for keystrokes, with a floating always-on-top REC bar. `ClassifyWindow()` is the single decision point for what gets recorded and how windows are identified: Explorer folders → cleaned title + `ahk_class CabinetWClass` with an `explorer.exe "<path>"` relaunch command (path via `Shell.Application` COM); UWP apps → title + `ahk_exe ApplicationFrameHost.exe` (no relaunch command); everything else → `ahk_exe <name>.exe` + process path. Double-clicking a file in Explorer is rewritten into a `run|<full path>` step.

**A saved workflow is three artifacts**: `workflows\<Base>.steps.txt` (the single source of truth), `macros\<Base>.ahk` (a generated stub that just calls `RunWorkflow`; contains the marker text "Workflow Studio", which save/delete checks before overwriting or removing so hand-written macros are never clobbered), and the Start Menu `.lnk` named by the spoken phrase.

`lib\_Common.ahk` holds shared helpers (`EnsureDir`, `Notify`, `RunOrActivate`, `CleanPhrase`, `Log`, plus `RunAhk`/`MakeAhkShortcut`/`IsReservedName` — the last three make launching/shortcuts association-proof by targeting `A_AhkPath` with the script as an argument). Standalone macros include it via `#Include "%A_ScriptDir%\..\lib\_Common.ahk"`.

`lib\Theme.ahk` gives every GUI one modern look: it follows the Windows light/dark setting (`AppsUseLightTheme`), sets a matching title bar (DWM `DWMWA_USE_IMMERSIVE_DARK_MODE`), and dark-themes the **native** controls (`SetPreferredAppMode` ordinal 135 + `SetWindowTheme`, plus a `WM_CTLCOLOR*` hook for edit backgrounds). Call `ThemeApply(gui [, statusTextCtrl])` right before `Gui.Show()`; `ThemePalette()` returns the colors. **Keep controls native — never swap buttons for owner-drawn/custom widgets** — because Voice Access clicks a button by its accessible name (its caption); a custom widget has none. Button captions may carry a leading **monochrome, text-presentation** glyph (e.g. `●▶✕＋✎↑↓`, and `🖫` U+1F5AB for Save) but must keep the real word so voice matching still works; avoid emoji-presentation glyphs (`🗑💾⏺`) — they render in color and clash. Studio, New Automation and Help all call `ThemeApply`.

Workflow Studio has a **"Close browser tabs before recording"** checkbox (`CloseBrowserTabs()`): when ticked, clicking Record first `WinClose`s every visible window of the common browsers so a recording starts from a clean browser. It is deliberately **graceful only** — a window still up after a few seconds is blocked by an unsaved-changes/"Leave site?" prompt, and it is left open and reported (never force-confirmed with a synthetic keystroke, which would silently discard the user's work). Its on/off state persists in `logs\settings.ini` (`[Studio] CloseBrowserTabs`).

**The MCP server** (`mcp\`, optional add-on — the repo's only Python) is a third automation-creation path alongside the scaffolder and recorder: a FastMCP `server.py` exposing create/list/run/delete tools so Claude can build automations from natural language. `mcp\voicekit_writer.py` is a **deliberate second implementation** of the AHK write-side (`CleanPhrase`, `WfEncode`, the bridge allocator, the stub/steps formats, `.lnk` creation, reload). This duplicates format knowledge that otherwise lives only in AHK — the tradeoff was accepted because `mcp\test_conformance.py` mechanically enforces parity: it feeds the writer's output through the **real** engine (`lib\Workflow.ahk` `WorkflowLoad`) and byte-compares, and diffs a generated stub against a committed one. **If you change any on-disk format (encoding, stub text, the `Workflow Studio` marker, file naming, BOM/LF), update `voicekit_writer.py` in lockstep and re-run the conformance test.** Newly created files are UTF-8 **with BOM** and **LF** endings (matching AHK `FileOpen`); the writer reproduces that exactly.

## AutoHotkey v2 traps specific to this codebase

- **Functions and variables share one case-insensitive namespace.** `statusBar` exists because `sb` collides with `SB()`; don't name a variable `log` (`Log()` is defined in `_Common.ahk`, shadowing the math built-in) or reuse any function name as a variable.
- **`lib\Acc.ahk`: oleacc.dll must stay pinned** (`AccPin()` calls `LoadLibrary` once). AHK frees on-demand DLLs after each `DllCall`; the COM objects oleacc returns point back into the DLL image, so without the pin the first method call is a hard process crash (an unreadable vtable, no catchable error).
- **`accLocation` must be called through the raw vtable** (`ComCall(22, ComObjValue(acc), ...)` with a by-ref VARIANT) — IDispatch marshaling of its four `long*` out-params fails with "Type mismatch". Names/roles/children work fine through IDispatch.
- **Always pass `"UTF-8"` to `FileRead`** — the default ANSI read turns em-dashes in templates into mojibake (this bug shipped once already).
- **Dialog ownership**: the Studio window is AlwaysOnTop, so every MsgBox it opens must carry `"Owner" g.Hwnd` or it appears *behind* the Studio, unfocused. `InputBox` cannot be owned — toggle `g.Opt("-AlwaysOnTop")` around it instead. Engine popups use the `262144` (always-on-top) MsgBox flag because they appear over arbitrary apps.
- Steps are 4-element arrays (`[type, a, b, c]`) everywhere in memory; keep writes 4-field.
- Generated workflow stubs in `macros\` must never be hand-edited or treated as the source of truth — they are regenerated on every save; the steps file is canonical.

## Design rules (from README — keep them)

- Voice Access shortcuts cannot be created programmatically; never promise otherwise. Anything voice-triggerable without manual setup must go through the Start Menu path.
- No raw coordinate-click automation as a primary mechanism (recorded clicks are element-name first; coordinates only as fallback), no pixel/image searching, no cloud calls, nothing non-deterministic. (The user has floated an OpenRouter/LLM integration as a possible future exception — it is not built.)
