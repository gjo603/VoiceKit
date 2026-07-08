# VoiceKit — Voice Access + AutoHotkey v2

A small system, not a pile of macros. Voice Access does exactly one job: turn speech into a trigger. AutoHotkey v2 does everything else. The centerpiece is **New Automation** — a scaffolder that creates, wires up, and loads new automations so each one costs you about a minute.

## Quick setup (new computer)

1. Clone or download this folder to a permanent home, e.g. `C:\Automations\VoiceKit`.
2. **Double-click `Setup.bat`.** It installs AutoHotkey v2 (via winget) if needed, creates Start Menu entries, and launches VoiceKit.
3. **Start Voice Access** (Win+Ctrl+S, or Settings → Accessibility → Speech). Requires Windows 11 22H2+ with recent updates for voice shortcuts.
4. Test: say **"open new automation"**. If the chooser window appears, you're done.

If you have bridge hotkeys from your old machine, re-create the Voice Access shortcuts listed in `bridge-map.txt`.

## Manual setup (if Setup.bat doesn't work)

1. **Install AutoHotkey v2** from https://www.autohotkey.com — pick **v2** (v1 is deprecated; never install it). Accept the default install, which makes `.ahk` files run with v2.
2. **Double-click `VoiceKit.ahk`.** First run installs voice-launchable entries into your Start Menu (`Voice Macros` group) and offers to auto-start at login. Say yes.
3. **Start Voice Access** (Win+Ctrl+S, or Settings → Accessibility → Speech). Requires Windows 11 22H2+ with recent updates for voice shortcuts.

Test: say **"open new automation"**. If the chooser window appears, you're done. (Give Windows a few seconds to index new Start Menu entries the first time.)

## Uninstalling

**Double-click `Uninstall.bat`.** It stops the VoiceKit tray app, removes the `Voice Macros` Start Menu group and the login shortcut, and resets the first-run flag. It does **not** delete this folder or remove AutoHotkey — do those yourself if you want them gone. To reinstall afterward, run `Setup.bat` again. (Voice Access shortcuts you paired for bridge hotkeys are managed inside Voice Access; remove them there.)

## How triggering works — two paths

**Path 1 — Launch macros (default, zero Voice Access config).** Each macro is a file in `macros\` with a Start Menu shortcut. Voice Access natively opens anything in the Start Menu, so "open meeting notes" just works the moment the file exists. Best for: run-some-steps-now automations (open layouts, tabs, file cleanups).

**Path 2 — Hotkey modules (the bridge you already discovered).** A module in `hotkeys\` binds `Ctrl+Alt+Shift+<letter>`; you create one Voice Access shortcut whose action is *Press keys* with that combo. Best for: always-on hotkeys, toggles, anything needing shared state, or a natural phrase without the word "open". Costs ~30 seconds of manual Voice Access setup per command — unavoidable, see limits below.

**Snippets** are a third mini-path: typed abbreviations (`/sig`, `/date`) that expand instantly, fully automated end to end by the scaffolder.

**Step Workflows** are Path-1 macros you build visually instead of writing code — see **Workflow Studio** below.

## The workflow (this is the whole method)

Do **not** brainstorm automations. Work normally; the moment you notice you've done the same annoying thing twice, say **"open new automation"**, pick a type, name it, and either the scaffolder finishes everything (snippets) or drops you into a template where you write 1–5 lines between the markers. Say **"open voice kit help"** whenever you forget a phrase.

Your library will grow from real friction. That's the only kind worth having.

## Workflow Studio — multi-step workflows, no code

Say **"open workflow studio"** (or New Automation → Step Workflow). It's a Power-Automate-style builder for linear step lists. The window (like every VoiceKit window) follows your Windows light/dark setting, and every button is voice-clickable — say "click" plus its word:

- **Record** — the Studio hides, a small REC bar floats top-right, and you just do the thing. Stop with the bar's Stop button, by voice ("click stop"), or with **Ctrl+Alt+Shift+X** (works even if something covers the bar). It captures window switches, clicks (double- and right-clicks too) and typing. Clicks are stored by the **name of what you clicked** (button caption, link, file name) and replayed by finding that name again — raw position is kept only as a silent fallback, so recordings survive windows moving. Double-clicking a file in Explorer is recorded as **Open \<full path\>** automatically, and folder windows are recorded with their full path so playback reopens them if they've been closed. Typed keystrokes become visible, editable Type/Press steps — so don't type passwords while recording. Drags and scrolling aren't captured.
- **Close browser tabs before recording** (checkbox, off by default) — tick it and clicking Record first closes every open browser window (Chrome, Edge, Firefox, Brave, Opera), so the recording starts from a fresh browser instead of whatever tabs were already open (leftover tabs shift positions and break playback). It closes gracefully: any window that pops an "unsaved changes / leave site?" warning is **left open** (nothing is discarded) and you're told how many — deal with those yourself for a fully clean start. The setting is remembered between sessions.
- **Add** — for anything recording can't see or you want to tweak: focus a window (launching it if needed), open an app/file/site (with a Browse button — no path typing), wait for a window, pause, type text, press keys, click by element name, position (left/right/top/bottom/max) or close a window. "Grab a Window" fills in window identities for you — no Window Spy needed.
- **Test** — plays the steps immediately; a failing step stops the run and names itself.
- **Save** — writes the step list to `workflows\<Name>.steps.txt`, generates a stub in `macros\`, and creates the Start Menu entry. Saying **"open \<name\>"** runs it — zero Voice Access setup.

Workflows stay editable: reopen the Studio and pick one from the dropdown. The `macros\` file is generated — edit steps in the Studio, not Notepad. If a workflow stops mid-run, the popup names the failing step; usually the fix is a longer wait or a looser window title.

## Create automations with Claude (MCP) — optional

Prefer to *describe* an automation instead of recording it? There's an optional
**MCP server** in `mcp\` that lets Claude (Desktop or Claude Code) build any of the
four types for you from natural language — "make a workflow that opens Notepad and
types my address" — writing the exact same files the recorder does. It's an add-on,
not a replacement: recording and New Automation still work unchanged. Setup and the
tool list are in **`mcp\README.md`** (needs Python 3.10+). Every script it generates
is load-checked before it's kept.

## Hard limits — know these, don't fight them

- **Voice Access shortcuts cannot be created programmatically.** No API, no PowerShell, no registry path. This is why Path 1 exists and why Path 2 keeps a 30-second manual step.
- **Voice shortcuts max out at 8 actions, with no variables, conditionals, or loops.** Never build logic in Voice Access. One shortcut = one handoff to AHK.
- **Voice shortcuts don't sync or back up.** `bridge-map.txt` is your recreate list for a new machine or reinstall.
- **Say phrases exactly**; distinct, uncommon phrases misfire less. Mute Voice Access during calls or your meeting will run your macros.

## Troubleshooting

- **Error mentioning "this line does not contain a recognized action" or similar on pasted code** → you copied AutoHotkey **v1** syntax from an old tutorial or forum post. Most of the internet's AHK content is v1. Check any snippet against the v2 docs (autohotkey.com/docs/v2) or ask Claude to convert it.
- **"open <name>" isn't recognized** → wait ~30s for Start Menu indexing; confirm the `.lnk` exists in `Start Menu\Programs\Voice Macros`; try the exact name shown by "open voice kit help".
- **New hotkey does nothing** → VoiceKit must be running (tray icon). Press Ctrl+Alt+Shift+R to reload, or double-click `VoiceKit.ahk`.
- **Snippets don't fire when dictating by voice** → hotstrings react to typed keys; expansion via Voice Access dictation is not guaranteed. For purely static text you want to *speak*, Voice Access's own "paste text" shortcut action is the right tool — no AHK needed. Use snippets for typing and for dynamic text like `/date`.
- **Find an app's window identity** for `RunOrActivate`: right-click the VoiceKit tray icon → Window Spy.

## Acceptance checks (run these once after setup)

1. Say "open new automation" → chooser appears.
2. Create a Launch Macro named "Test Ping" → file opens; say "open test ping" → the placeholder MsgBox fires.
3. Create a Snippet `/hi` → "hello world" → typing `/hi` in Notepad expands it.
4. Create a Hotkey Module "Test Bridge" → pressing the assigned Ctrl+Alt+Shift key fires the placeholder; register the phrase in Voice Access and repeat by voice.
5. Say "open workflow studio" → click Record, open Notepad and type a few words, click Stop → click Test replays it; Save as "Test Flow" → say "open test flow".

## Out of scope, on purpose

No coordinate-click macros (they rot — Workflow Studio records clicks by the element's on-screen name instead, keeping raw position only as a last-resort fallback), no pixel/image searching, no cloud calls, nothing non-deterministic. When a future automation needs real logic (loops, parsing, decisions), design it in chat first, then write code — fixing a plan is 10x cheaper than fixing a script.
