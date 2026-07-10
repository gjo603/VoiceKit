# VoiceKit — Voice Access + AutoHotkey v2

A small system, not a pile of macros. Voice Access does exactly one job: turn speech into a trigger. AutoHotkey v2 does everything else. Two phrases carry the whole thing: **"open voice kit"** (the home window — everything you can say, searchable, with Run / Edit / Delete) and **"open new automation"** (pick what should happen, answer one dialog, and VoiceKit writes the automation itself — no code by default).

## Got the bundled installer? (VoiceKit-Setup.zip / .exe)

If someone sent you **VoiceKit-Setup.zip**, you need nothing else installed:

1. Right-click the zip → **Extract All**.
2. Open the extracted folder and **double-click `Install-VoiceKit.cmd`**. It installs VoiceKit and starts it.
3. **Start Voice Access** (Win+Ctrl+S) and say **"open voice kit"** to check it worked.

(Sent a single **VoiceKit-Setup.exe** instead? Just double-click it — Windows may show a one-time "More info → Run anyway".) The rest of this page is for setting up from the source folder.

## Quick setup (from the source folder)

1. Clone or download this folder to a permanent home, e.g. `C:\Automations\VoiceKit`.
2. **Double-click `Setup.bat`.** It installs AutoHotkey v2 (via winget) if needed, creates Start Menu entries, and launches VoiceKit.
3. **Start Voice Access** (Win+Ctrl+S, or Settings → Accessibility → Speech). Requires Windows 11 22H2+ with recent updates for voice shortcuts.
4. Test: say **"open new automation"**. If the chooser window appears, you're done.

If you have bridge hotkeys from your old machine, re-create the Voice Access shortcuts listed in `bridge-map.txt`.

## Manual setup (if Setup.bat doesn't work)

1. **Install AutoHotkey v2** from https://www.autohotkey.com — pick **v2** (v1 is deprecated; never install it). Accept the default install, which makes `.ahk` files run with v2.
2. **Double-click `VoiceKit.ahk`.** First run installs voice-launchable entries into your Start Menu (`Voice Macros` group) and shows a short welcome screen: it tells you whether Voice Access is on (with a button to turn it on), keeps "start when I sign in" ticked, and teaches the first phrase.
3. **Start Voice Access** (Win+Ctrl+S, or Settings → Accessibility → Speech). Requires Windows 11 22H2+ with recent updates for voice shortcuts.

Test: say **"open new automation"**. If the chooser window appears, you're done. (Give Windows a few seconds to index new Start Menu entries the first time.)

## Uninstalling

**Double-click `Uninstall.bat`.** It stops the VoiceKit tray app, removes the `Voice Macros` Start Menu group and the login shortcut, and resets the first-run flag. It does **not** delete this folder or remove AutoHotkey — do those yourself if you want them gone. To reinstall afterward, run your installer again (`Install-VoiceKit.cmd` for the bundled package, or `Setup.bat` from a source folder). (Voice Access shortcuts you paired for bridge hotkeys are managed inside Voice Access; remove them there.)

## How triggering works — two paths

**Path 1 — Launch macros (default, zero Voice Access config).** Each macro is a file in `macros\` with a Start Menu shortcut. Voice Access natively opens anything in the Start Menu, so "open meeting notes" just works the moment the file exists. Best for: run-some-steps-now automations (open layouts, tabs, file cleanups).

**Path 2 — Hotkey modules (the bridge you already discovered).** A module in `hotkeys\` binds `Ctrl+Alt+Shift+<letter>`; you create one Voice Access shortcut whose action is *Press keys* with that combo. Best for: always-on hotkeys, toggles, anything needing shared state, or a natural phrase without the word "open". Costs ~30 seconds of manual Voice Access setup per command — unavoidable, see limits below.

**Snippets** are a third mini-path: typed abbreviations (`/sig`, `/date`) that expand instantly, fully automated end to end by the scaffolder.

**Step Workflows** are Path-1 macros you build visually instead of writing code — see **Workflow Studio** below. **AI text actions** (optional — see the AI section) are Path-1 macros too: a saved prompt with its own voice phrase.

## The workflow (this is the whole method)

Do **not** brainstorm automations. Work normally; the moment you notice you've done the same annoying thing twice, say **"open new automation"** and pick what should happen:

- **Open Something** — an app, file, folder, or website. One dialog (with Browse buttons), zero code, voice-ready instantly.
- **Record My Steps** — Workflow Studio records what you do and replays it (below).
- **Type Text For Me** — a snippet, one dialog, done.
- **AI Text Action** — your own AI command over selected text (optional, needs an OpenRouter key).
- **Draft With AI** — describe the automation in plain words; the AI drafts steps you review in Workflow Studio.
- **Always-On Hotkey** — advanced; the common cases (open something / type text) are no-code, and "custom code" remains the escape hatch.

Say **"open voice kit"** whenever you forget a phrase — every automation is listed there, searchable, with Run / Edit / Delete.

Your library will grow from real friction. That's the only kind worth having.

## Workflow Studio — multi-step workflows, no code

Say **"open workflow studio"** (or New Automation → Record My Steps). It's a Power-Automate-style builder for linear step lists. The window (like every VoiceKit window) follows your Windows light/dark setting, and every button is voice-clickable — say "click" plus its word:

- **Record** — the Studio hides, a small REC bar floats bottom-left, and you just do the thing. Stop with the bar's Stop button, by voice ("click stop"), or with **Ctrl+Alt+Shift+X** (works even if something covers the bar). It captures window switches, clicks (double- and right-clicks too) and typing. Clicks are stored by the **name of what you clicked** (button caption, link, file name) and replayed by finding that name again — raw position is kept only as a silent fallback, so recordings survive windows moving. Double-clicking a file in Explorer is recorded as **Open \<full path\>** automatically, and folder windows are recorded with their full path so playback reopens them if they've been closed. Typed keystrokes become visible, editable Type/Press steps — so don't type passwords while recording. Drags and scrolling aren't captured.
- **Close browser tabs before recording** (checkbox, off by default) — tick it and clicking Record first closes every open browser window (Chrome, Edge, Firefox, Brave, Opera), so the recording starts from a fresh browser instead of whatever tabs were already open (leftover tabs shift positions and break playback). It closes gracefully: any window that pops an "unsaved changes / leave site?" warning is **left open** (nothing is discarded) and you're told how many — deal with those yourself for a fully clean start. The setting is remembered between sessions.
- **Maximize windows while recording** (checkbox, **on** by default) — every window that enters the recording is maximized (and a *maximize* step is saved with it), so playback re-creates the same window layout. This is what stops "it worked when I recorded it" breakage from apps opening half-screen in a snap layout. One honest edge: a **⚠ position-only click** that itself brings a new window into the recording is captured before that window gets maximized — those are exactly the steps the ⚠ marker tells you to re-record on a labeled control. Untick the box only for automations that depend on a specific window arrangement.
- **Playback is patient** — each step waits up to 10 seconds for its window to appear before giving up, so slow-loading apps and dialogs don't need hand-added Wait steps. Clicks that couldn't be captured by an element's name are marked **⚠** in the step list (they replay by position, which is fragile) — the stop message counts them so you know before you save.
- **Add** — for anything recording can't see or you want to tweak: focus a window (launching it if needed), open an app/file/site (with a Browse button — no path typing), wait for a window, pause, type text, press keys, click by element name, position (left/right/top/bottom/max) or close a window. "Grab a Window" fills in window identities for you — no Window Spy needed. At the bottom of the Action list are the optional **if / else / end if** steps (see below).
- **Test** — plays the steps immediately; a failing step stops the run and names itself.
- **Save** — writes the step list to `workflows\<Name>.steps.txt`, generates a stub in `macros\`, and creates the Start Menu entry. Saying **"open \<name\>"** runs it — zero Voice Access setup. Save also creates a companion **"loop \<name\>"** entry (see below).

**Looping a workflow.** Every saved workflow gets a companion command so you can run it over and over: say **"open loop \<name\>"** (e.g. "open loop morning tabs"). A small **Stop Looping** bar floats bottom-left while it runs; end it by saying **"click stop looping"**, clicking the button, or pressing **Ctrl+Alt+Shift+X**. It pauses briefly between passes and stops automatically if a step fails. (Voice Access can't intercept a spoken "loop" before an arbitrary command — it launches whole Start-Menu names — so the loop is its own "loop \<name\>" entry, run with "open" like any other.) Loops repeat until you stop them, so pick actions that make sense to repeat; a workflow that opens new windows will keep piling them up.

**Conditional steps (if / then).** An optional, opt-in feature for branching — nothing you record uses it, and existing workflows are unaffected. In the **Add** dialog's Action list (at the bottom) pick one of: *If a window IS/​is NOT open*, or *If something IS/​is NOT on screen* (a named button, link, etc.). Follow it with the steps to run when the condition holds, an optional **Otherwise (else)**, and an **End if**. The step list indents each block so you can see the structure. Conditions are deterministic state checks only (is a window/element present) — no pixel or image guessing. Example: *If the "Save changes?" dialog is open → click "Save" → End if*. Tip: because these aren't recordable, the easiest way to build them is to describe the workflow in plain words — either **New Automation → Draft With AI** (OpenRouter, reviewed in the Studio) or Claude via the MCP add-on.

Workflows stay editable: reopen the Studio and pick one from the dropdown. The `macros\` file is generated — edit steps in the Studio, not Notepad. If a workflow stops mid-run, the popup names the failing step; usually the fix is a longer wait or a looser window title.

## The home window — say "open voice kit"

One calm place for everything (inspired by the disappearing-UI school of tools like Wispr Flow): every workflow, macro, AI action, hotkey, and snippet in a searchable list with the exact phrase to say, plus **Run**, **Edit** (workflows open straight in the Studio; AI prompts get an inline editor), **Delete** (removes all of an automation's artifacts, including Start Menu entries), **New Automation**, and **AI Settings**. The old **"open voice kit help"** phrase still works — it lands here.

## AI features (optional) — the OpenRouter layer

Strictly **additive and opt-in**: nothing calls the network until you paste an [OpenRouter](https://openrouter.ai/keys) API key into **AI Settings** (home window → AI Settings), and the deterministic workflow engine never touches it. The key is stored DPAPI-encrypted (readable only by your Windows account); the model defaults to `openrouter/auto` — change it if you care, ignore it if you don't. Three features sit on this layer:

- **Ask AI anywhere** — say **"open ask ai"**: a slim bar appears at the bottom of the screen, you dictate (or type) a question, and the answer is **typed into the app you were just using** — then the bar disappears. If there's nowhere to type, you get the answer with a Copy button instead.
- **AI text actions** — New Automation → **AI Text Action**. Name it, write the prompt once ("Fix the grammar and spelling…"), and you get a voice phrase: select text in any app, say **"open fix grammar"**, and the AI's answer types itself in, replacing the selection. Your clipboard is preserved. Prompts are editable any time from the home window.
- **Draft With AI** — New Automation → **Draft With AI**. Describe the automation in plain words; the AI drafts real workflow steps, which open in **Workflow Studio for review** — nothing runs or saves until you test and save it yourself. Drafts are validated (step types, if/endif balance) before the Studio ever sees them.

What leaves your machine: only what a feature needs at the moment you trigger it — your question, the selected text (**or, if nothing is selected, the text currently on your clipboard** — the fallback an AI text action uses), the description, and the saved prompt. Sent to OpenRouter only when you speak the phrase, never in the background. Mind the clipboard fallback if you copy sensitive things.

## Create automations with Claude (MCP) — optional

Prefer to *describe* an automation instead of recording it? There's an optional
**MCP server** in `mcp\` that lets Claude (Desktop or Claude Code) build launch
macros, hotkey modules, snippets, and step workflows for you from natural language
(the AI text actions above are created in New Automation, not through MCP) — "make a workflow that opens Notepad and
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
- **"open <name>" isn't recognized** → wait ~30s for Start Menu indexing; confirm the `.lnk` exists in `Start Menu\Programs\Voice Macros`; try the exact phrase shown by "open voice kit".
- **New hotkey does nothing** → VoiceKit must be running (tray icon). Press Ctrl+Alt+Shift+R to reload, or double-click `VoiceKit.ahk`.
- **Snippets don't fire when dictating by voice** → hotstrings react to typed keys; expansion via Voice Access dictation is not guaranteed. For purely static text you want to *speak*, Voice Access's own "paste text" shortcut action is the right tool — no AHK needed. Use snippets for typing and for dynamic text like `/date`.
- **AI features do nothing / error immediately** → no key saved, or the key was revoked. Home window → AI Settings → paste a key and click **Test Key**. AI features also need an internet connection; everything else in VoiceKit works offline.
- **Find an app's window identity** for `RunOrActivate`: right-click the VoiceKit tray icon → Window Spy.

## Acceptance checks (run these once after setup)

1. Say "open voice kit" → the home window appears, listing every automation.
2. Say "open new automation" → Open Something → name it "Test Ping", target `notepad.exe` → say "open test ping" → Notepad opens.
3. New Automation → Type Text For Me: `/hi` → "hello world" → typing `/hi` in Notepad expands it.
4. New Automation → Always-On Hotkey "Test Bridge" (Open something → notepad.exe) → pressing the assigned Ctrl+Alt+Shift key opens Notepad; register the phrase in Voice Access and repeat by voice.
5. Say "open workflow studio" → click Record, open Notepad and type a few words, click Stop → click Test replays it; Save as "Test Flow" → say "open test flow".
6. (With an OpenRouter key saved) say "open ask ai", ask something small → the answer types into your last app.

## Out of scope, on purpose

No coordinate-click macros (they rot — Workflow Studio records clicks by the element's on-screen name instead, keeping raw position only as a last-resort fallback), no pixel/image searching, nothing non-deterministic in the core. The **one deliberate exception** is the opt-in AI layer above: it calls OpenRouter when — and only when — you trigger an AI feature with a key saved, and the deterministic engine itself never does. When a future automation needs real logic (loops, parsing, decisions), design it in chat first, then write code — fixing a plan is 10x cheaper than fixing a script.
