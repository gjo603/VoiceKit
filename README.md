# VoiceKit — Voice Access + AutoHotkey v2

A small system, not a pile of macros. Voice Access does exactly one job: turn speech into a trigger. AutoHotkey v2 does everything else. Two phrases carry the whole thing: **"open voice kit"** (the home window — everything you can say, searchable, with Run / Edit / Delete) and **"open new automation"** (pick what should happen, answer one dialog, and VoiceKit writes the automation itself — no code by default).

## Install in one click

**[⬇ Download VoiceKit-Setup.exe](https://github.com/gjo603/VoiceKit/releases/latest/download/VoiceKit-Setup.exe)** — then double-click the download. That's the whole install: it unpacks itself, installs VoiceKit, and starts it. Nothing else is needed (AutoHotkey is bundled).

- Windows shows a one-time SmartScreen prompt because the file is unsigned: click **More info → Run anyway**.
- Prefer a zip? **[Download VoiceKit-Setup.zip](https://github.com/gjo603/VoiceKit/releases/latest/download/VoiceKit-Setup.zip)**, extract it, and double-click `Install-VoiceKit.cmd` inside.
- **Updating later:** use the same links again — they always point at the newest release, and updating preserves your automations, snippets, hotkeys, and settings.

After installing, start **Voice Access** (Win+Ctrl+S) and say **"open voice kit"**.

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

Your own lists — `bridge-map.txt`, `hotkeys\_index.ahk` (the module manifest) and `hotkeys\Snippets.ahk` — are made on first start from the shipped `*.default` copies beside them, and are never overwritten by an update (a newer version only *adds* any hotkey it ships). They hold your personal wiring, so git ignores them. `templates\examples\` has a few sample automations to copy from.

## Manual setup (if Setup.bat doesn't work)

1. **Install AutoHotkey v2** from https://www.autohotkey.com — pick **v2** (v1 is deprecated; never install it). Accept the default install, which makes `.ahk` files run with v2.
2. **Double-click `VoiceKitLauncher.ahk`** (it load-checks everything, then starts `VoiceKit.ahk`). First run installs voice-launchable entries into your Start Menu (`Voice Macros` group) and shows a short welcome screen: it tells you whether Voice Access is on (with a button to turn it on), keeps "start when I sign in" ticked, and teaches the first phrase.
3. **Start Voice Access** (Win+Ctrl+S, or Settings → Accessibility → Speech). Requires Windows 11 22H2+ with recent updates for voice shortcuts.

Test: say **"open new automation"**. If the chooser window appears, you're done. (Give Windows a few seconds to index new Start Menu entries the first time.)

## Uninstalling

**Double-click `Uninstall.bat`.** It stops the VoiceKit tray app, removes the `Voice Macros` Start Menu group and the login shortcut, and resets the first-run flag. It does **not** delete this folder or remove AutoHotkey — do those yourself if you want them gone. To reinstall afterward, run your installer again (`Install-VoiceKit.cmd` for the bundled package, or `Setup.bat` from a source folder). (Voice Access shortcuts you paired for bridge hotkeys are managed inside Voice Access; remove them there.)

## How triggering works — two paths

**Path 1 — Launch macros (default, zero Voice Access config).** Each macro is a file in `macros\` with a Start Menu shortcut. Voice Access natively opens anything in the Start Menu, so "open meeting notes" just works the moment the file exists. Best for: run-some-steps-now automations (open layouts, tabs, file cleanups).

**Path 2 — Hotkey modules (the bridge you already discovered).** A module in `hotkeys\` binds `Ctrl+Alt+Shift+<letter>`; you create one Voice Access shortcut whose action is *Press keys* with that combo. Best for: always-on hotkeys, toggles, anything needing shared state, or a natural phrase without the word "open". Costs ~30 seconds of manual Voice Access setup per command — unavoidable, see limits below.

**Snippets** are a third mini-path: typed abbreviations (`/sig`, `/date`) that expand instantly — single-line or multi-line — fully automated end to end by the scaffolder, and editable in place from the home window.

**Split Pages** is a filing tool: select a multi-page PDF (a stack of scanned receipts, say) in File Explorer and say **"open split pages"** — each page opens in your PDF viewer while a small dialog asks what it is, and the page is saved beside the original as `<today's date> <your words>.pdf` (e.g. `2026-07-23 Home Depot receipt.pdf`). Skip pages you don't want; the original document is never modified. Needs Python 3 — the small `pypdf` component is offered as a one-time install on first use.

**Any Path-1 automation can ALSO get a keyboard trigger** — a companion `Ctrl+Alt+Shift+<key>` assigned in the home window (say "open voice kit" → select it → **Hotkey**) for the moments voice isn't available. Unlike Path 2 there's no Voice Access step at all: the key is live the moment you save it.

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

Say **"open workflow studio"** (or New Automation → Record My Steps). In a hurry? Say **"open record my steps"** — or press **Ctrl+Alt+Shift+W** — to jump straight into recording a new workflow (if a Studio window is already open it's used instead, so an unsaved session is never lost). It's a Power-Automate-style builder for linear step lists. The window (like every VoiceKit window) follows your Windows light/dark setting, and every button is voice-clickable — say "click" plus its word:

- **Record** — the Studio hides, a small REC bar floats bottom-left, and you just do the thing. Stop with the bar's Stop button, by voice ("click stop"), or with **Ctrl+Alt+Shift+X** (works even if something covers the bar). It captures window switches, clicks (double- and right-clicks too), drags and typing. Clicks are stored by the **name of what you clicked** (button caption, link, file name) and replayed by finding that name again — raw position is kept only as a silent fallback, so recordings survive windows moving. Double-clicking a file in Explorer is recorded as **Open \<full path\>** automatically, and folder windows are recorded with their full path so playback reopens them if they've been closed. Typed keystrokes become visible, editable Type/Press steps — so don't type passwords while recording. To capture a **hover** (resting the mouse to reveal a menu or tooltip), point at it and press **Ctrl+Alt+Shift+H** — a Hover step is added where the mouse is. To make playback **ask you for a value that changes each run** (a name, an order number, today's notes), press **Ctrl+Alt+Shift+I** while recording and label the input — every run then asks for all labeled inputs **up front** (one dialog each, suggestion prefillable) and types your answer at that spot. The same dialog takes an optional **answer to use while recording**: VoiceKit types it into the app for you, **without recording it**, so the app reacts normally (autocomplete, validation, buttons enabling) and you don't have to leave the field blank — at run time only the real answer is typed there, and your practice answer shows up as the suggestion. The mirror image is **collecting**: select some text the app is showing and press **Ctrl+Alt+Shift+C** — a **Collect** step is recorded (the dialog previews what's selected and asks what to call it), and every run **grabs that value and saves it to the workflow's sheet** as a column. Selecting is recorded like any other action, so playback re-selects and copies by itself; your clipboard is left untouched. (The Add dialog also offers a variant that reads a **named box's** content without selecting.) Your **pauses are captured too**: wait for a page to load or a suggestion list to appear while recording, and a matching, editable **Wait** step is saved automatically, so playback runs at roughly the pace you recorded (brief beats between clicks and keystrokes are ignored, and a long distraction is capped at 30 seconds — delete any Wait row you didn't mean). **Drags are captured too**: press, move and release (selecting text, dragging across a region, pulling a slider) becomes a **Drag** step that replays the same press-and-release path. A drag is remembered by position (there's no element name for a gesture), so it carries the **⚠** marker — keep the window layout stable (the Maximize option helps). Scrolling isn't captured.
- **Close browser tabs before recording** (checkbox, off by default) — tick it and clicking Record first closes every open browser window (Chrome, Edge, Firefox, Brave, Opera), so the recording starts from a fresh browser instead of whatever tabs were already open (leftover tabs shift positions and break playback). It closes gracefully: any window that pops an "unsaved changes / leave site?" warning is **left open** (nothing is discarded) and you're told how many — deal with those yourself for a fully clean start. The setting is remembered between sessions.
- **Maximize windows while recording** (checkbox, **on** by default) — every window that enters the recording is maximized (and a *maximize* step is saved with it), so playback re-creates the same window layout. This is what stops "it worked when I recorded it" breakage from apps opening half-screen in a snap layout. One honest edge: a **⚠ position-only click** that itself brings a new window into the recording is captured before that window gets maximized — those are exactly the steps the ⚠ marker tells you to re-record on a labeled control. Untick the box only for automations that depend on a specific window arrangement.
- **Record clicks by position only** (checkbox, off by default) — skips element-name detection and stores just the window-relative X,Y of each click (and hover), for apps where accessible names are unreliable or misleading: maps, canvases, games, custom-drawn UIs. Everything captured this way is a **⚠** position-only step, so keep the window layout stable (the Maximize option helps). Double-clicking a file in Explorer is still recorded as a reliable **Open \<full path\>** step, not a raw position. Remembered between sessions.
- **Vary click positions slightly when running** (checkbox, **on** by default) — the one setting here about *playing back* rather than recording. When a workflow clicks something by name, it lands a couple of pixels off dead centre instead of the exact same pixel every single time. It matters when you loop a workflow against a **website**: clicking the identical pixel a hundred times in a row, at identical intervals, is the easiest possible pattern for a site to flag as a robot. It cannot make a click miss — the wobble is kept well inside whatever it's clicking — and clicks recorded **by position** (the ⚠ ones), drags and hovers are always exact, since a position is the whole point of them. Untick it if you're driving something that needs pixel-exact clicks. (Pair it with a **random Wait** — see below.)
- **Record raw input only** (checkbox, off by default) — turns the smart extras off and records nothing but what you actually do: no automatic **Wait** steps when you pause, no **Focus** steps when you switch windows, no maximizing (that option grays out while this is on). For quick key sequences and keyboard macros where the added steps just get in the way — playback replays exactly what you pressed, into whatever window is active when it runs. Clicks are still captured normally (by name, or by position with the option above), and the on-demand hotkeys (hover / ask / collect) still work. Remembered between sessions.
- **Playback is patient and runs at your pace** — the pauses captured while recording replay as their Wait steps, every typed-text and key-press step gets a small breather so back-to-back keystrokes can't outrun the app, and each step waits up to 10 seconds for its window to appear before giving up, so slow-loading apps and dialogs don't need hand-added Wait steps. Clicks that couldn't be captured by an element's name are marked **⚠** in the step list (they replay by position, which is fragile) — the stop message counts them so you know before you save. Position-only clicks wait extra hard before firing: the window must be focused and its app finished starting up, plus a longer settle pause — a blind click can't retry the way a named click can, so it isn't allowed to fire into a half-loaded window. If content appears even later than that, add a Wait step before the click.
- **Add** — for anything recording can't see or you want to tweak: focus a window (launching it if needed), open an app/file/site (with a Browse button — no path typing), wait for a window, pause, type text, **ask you for input** (labeled; asked before the run starts, typed at that step), press keys, click by element name, **hover** over something (to reveal a menu/tooltip), **drag** between two points, **set a value** to reuse later (see below), position (left/right/top/bottom/max) or close a window. "Grab a Window" fills in window identities for you — no Window Spy needed. At the bottom of the Action list are the optional **if / else / end if** steps (see below).
- **Test** — plays the steps immediately; a failing step stops the run and names itself.
- **Save** / **Save and Close** — writes the step list to `workflows\<Name>.steps.txt`, generates a stub in `macros\`, and creates the Start Menu entry. Saying **"open \<name\>"** runs it — zero Voice Access setup. Save also creates a companion **"loop \<name\>"** entry (see below). You're asked for a name **only the first time**: once a workflow has one, saving it again just overwrites it — no name prompt, no confirmation popup, so the tweak-test-save loop stays quick (the status line confirms it). **Save and Close** does exactly the same and shuts the Studio afterwards.

**Looping a workflow.** Every saved workflow gets a companion command so you can run it over and over: say **"open loop \<name\>"** (e.g. "open loop morning tabs"). A small **Stop Looping** bar floats bottom-left while it runs; end it by saying **"click stop looping"**, clicking the button, or pressing **Ctrl+Alt+Shift+X**. Stopping takes effect **immediately** — even mid-run, in the middle of a long Wait step or while a step is waiting for a window — with no error popup. It pauses briefly between passes (adjustable for workflows with inputs) and stops automatically if a step fails. (Voice Access can't intercept a spoken "loop" before an arbitrary command — it launches whole Start-Menu names — so the loop is its own "loop \<name\>" entry, run with "open" like any other.) Loops repeat until you stop them, so pick actions that make sense to repeat; a workflow that opens new windows will keep piling them up.

**Looping with inputs — run a whole list.** If the workflow has **ask-for-input** steps, starting its loop opens a chooser first. The easiest path is the workflow's own **inputs sheet**: click **Create my sheet** and VoiceKit writes a CSV with one column per input and opens it for you (Excel if you have it, Notepad otherwise) — fill in **one row per run**, save, come back and click **Run from my sheet**. The sheet lives next to the workflow (`workflows\<Name>.inputs.csv`), so the next time the loop starts the dialog already shows how many rows are ready — edit the sheet any time and re-run the list (the row count even updates live while the dialog is open). The chooser also has a **Pause between runs** box (how long the loop breathes between passes, remembered per workflow), and the old routes still work: **import a CSV you already have** (header row = the input names, extra columns ignored), **type the rows in** (a small form with an Add Row button), or **ask each time around**. With a batch, the bar shows *row 3/10* and the loop stops by itself after the last row — the classic "do this once per line of my spreadsheet" automation, no code.

**Collecting data — the loop in reverse.** If the workflow has **Collect** steps (see the recording section), every run *writes back*: a loop fed by your sheet fills the collected values into **new columns beside each row that ran**, and any other run appends a row of inputs-used + values-collected — so "look up each of these and note the price" becomes: fill the sheet, say "open loop \<name\>", and open the sheet afterwards to read the answers. If the sheet is locked because you're watching it in Excel, results go to `<Name>.results.csv` next to it instead (nothing is lost). When a loop that collected anything finishes — or is stopped partway — a tray notification says where the values went; nothing pops up to be dismissed, and you open the sheet whenever you like.

**Waiting for things to actually happen.** A plain **Wait** step is a guess — "give it 1500 milliseconds and hope" — and it's wrong on a slow morning, or wastes time on a fast one. The **Wait until…** steps in the Add dialog wait for the real thing instead, carry on the *instant* it's true, and if it never happens they stop and tell you what they were waiting for rather than typing into a window that was never ready:

- **Wait until something appears on screen** — a button, a link, a row of results. The usual replacement for a guessed pause after a search or a page load.
- **Wait until something disappears** — a "Loading…" message or a progress spinner going away.
- **Wait until a window closes** — a save dialog finishing, an export completing.
- **Wait until some text appears** — for when you know the *words* on screen but not the exact name of anything: "Upload complete", "3 results".
- **Wait until something new is copied** — for a Copy button that takes a moment to actually put things on the clipboard.

Each has a **give up after N seconds** box (10 by default — raise it for slow pages). Stopping a loop still cuts a wait short immediately.

**Random pauses — `600-1400`.** A plain Wait step also takes a **range**: type `600-1400` instead of `1500` and each run pauses a random amount between 0.6 and 1.4 seconds. Same reason as the click-jitter checkbox above: a workflow looped against a website that pauses for the identical number of milliseconds every single pass looks exactly like what it is. The step list spells it out (*Wait 600 ms to 1.4 s (random)*), and a plain number still means precisely that number.

The same checks work as **If** conditions, which is how a workflow stops before doing something silly: *If the text "No results found" IS on screen → stop / take the other branch*. Use plain **Wait** only for a deliberate pause when there's genuinely nothing to watch for.

**Reusing a value — `{{name}}`.** Anything the workflow names can be used again anywhere later: type **`{{name}}`** into a step and the real value is filled in when it runs. Every **Ask** label, every **Collect** label, and the new **Set a value** step all create names. So "ask for the customer once, then use it in the subject, the greeting *and* the file name" is just `{{Customer}}` in three places — no clipboard juggling, no asking twice. It works in typed text, key presses, web addresses, window names and element names.

- **Set a value** (Add dialog) names a value outright, and it can be built out of other values: name it `Greeting`, give it `Hi {{First Name}}`, then type `{{Greeting}}` wherever you like.
- Four names are always available: **`{{clipboard}}`**, **`{{date}}`**, **`{{time}}`**, **`{{datetime}}`** — though if you have your own value called "date", yours wins.
- Two more work on **the file you selected in File Explorer** before starting the workflow: **`{{selected_file}}`** is that file's full path (say "open Extract Invoice" with a client's invoice selected, and a step can hand `{{selected_file}}` to a program), and **`{{selected_files}}`** is every selected file, each in double quotes, ready for a command line. The selection is read once, the moment the workflow starts, from the front-most File Explorer window's **visible tab**. If a workflow uses `{{selected_file}}` and you've selected nothing — or several files — it refuses to start and tells you, rather than guessing which one you meant. An **Open** step whose target is just `{{selected_file}}` opens it in its usual app. Inside a command (an **Open** step or a **Run a command** step) both names are **quoted for you** — `python extract.py {{selected_file}}` works for `Invoice 2025 Smith & Co.pdf`, and so does writing the quotes yourself. Any *other* value in a command goes in as-is, so quote it: `"{{Customer}}"`.
- The Add dialog lists the names you can use, so you don't have to remember them. **Test** shows what every name actually came out as.
- Names are not case-sensitive and may contain spaces (`{{Order Id}}`). A name **nothing sets** is typed out exactly as written — so a typo is visible rather than silently blank; Test and Save warn you about those before you run.
- Running a whole list works unchanged: the columns of your inputs sheet are names too, so `{{Customer}}` picks up each row's value as the loop goes. Collected values become usable the moment their Collect step runs. (Values from **Set** are used during the run only — they don't become sheet columns; Collect is what writes to the sheet.)
- One caveat: in a **Press keys** step the value is inserted as key syntax, so characters like `{ ^ ! +` are treated as commands. Use **Type text** for ordinary values.

**Run a command and save its output.** This step runs a program the way a command prompt would — hidden, from the VoiceKit folder, up to a time limit (30 seconds unless you set one) — and saves whatever it prints as a value, e.g. `{{Invoice Data}}`, for the steps after it. If the program fails (a nonzero exit code), the workflow stops and tells you; the popup shows the last lines of its error output, but the run history and anything reported to Claude say only "Command exited with code N", because an error message can name a client's file. Stop Looping (or the time limit) ends the program *and* anything it started. The value is used during the run only — it isn't written to your sheet.

*Act on the selected file — the "Extract Invoice" recipe.* Select a client's invoice PDF in File Explorer and say **"open Extract Invoice"**:

1. **Run a command and save its output** — name `Invoice Data`, command `python "C:\tools\invoice.py" {{selected_file}}` (time limit 120)
2. **Focus window** — your billing program
3. **Type text** — `{{Invoice Data}}`
4. **Press keys** — `{Enter}`
5. (optional) **Wait until some text appears** — the program's confirmation

If nothing or several files are selected it refuses to start instead of guessing. The script decides what "extract" means; VoiceKit hands it the file and carries its answer to the next steps. **A workflow with a command step runs programs — share one the way you'd share a script, only with people you trust, and read its commands first** (the Studio shows each command in the step list). Don't paste an **Ask** answer straight into a command unless you quote it. Draft With AI never writes command steps; you add them yourself.

**Fill in a box by its label.** Typing into a form used to be a click followed by a **Type text** step — and nothing said whether it worked: a click that missed, a pop-up that grabbed the keyboard, or a box that quietly kept only part of the value all looked exactly like success. **Fill in a box by its label** (in the Add dialog, right after *Type text*) does the whole job and checks it:

- **Window**, the **box's label** and the **value** — which can be `{{name}}`, so each row of a sheet fills in its own figure. Point **Pick element** at the *box itself* (not the text beside it) and the label is filled in for you; it works inside web pages too.
- It finds the **box**, never the label text next to it, clicks it for real, and types nothing at all unless the keyboard is actually in that box — so a value can't end up in the wrong field. Then it **reads the box back**. A box that tidies up what you typed is fine (`1234.5` showing as `1,234.50`, `123456789` as `123-45-6789`); one that holds a *different* value stops the workflow.
- **Several boxes with the same label?** Write `Amount#2` for the second one (`#3` for the third…). Without a number the first one is filled and the run history says there were several. A label with a real `#` in it is written `##`.
- A **password box** is filled but not read back (it can't be). A disabled box, or a label that isn't there, stops the workflow before anything is typed. A blank value clears the box.
- The values you fill may be client data, so a value that arrives through a `{{name}}` never appears in the run history or in anything reported to Claude (the history shows the step as written — `{{Box 1}}`; a value typed straight into a step is part of the workflow and shows like any Type text) — only the popup on your own screen shows what was typed and what the box held.
- A `{{name}}` used in a fill value that no other step sets **becomes one of the workflow's inputs**: it's asked for when you run it, it's a column in the inputs sheet, and it's a column a batch fills in. No **Ask** step needed.

*Enter invoice figures into a web form — the "Enter Invoice" recipe.* With the invoice entry screen open in the browser:

1. **Wait until some text appears** — the screen's own heading (so nothing is typed into the wrong page)
2. **Fill in a box by its label** — label `Invoice total`, value `{{Box 1}}`
3. **Fill in a box by its label** — label `Shipping`, value `{{Box 2}}`
4. …one Fill per box; `Amount#2` where a label repeats
5. (optional) **Collect what's in a named box** — a total the program works out, to check against your sheet

Put one invoice per row in a sheet with columns `Box 1`, `Box 2`, … (the loop's **Create my sheet** makes one with exactly those columns) and run the list, or have Claude run it straight from your Excel file's Invoices tab: `run_workflow_batch(source=..., sheet="Invoices", columns={"Box 1": "Invoice total", ...})`. Each pass stops at the first box that didn't take its value, so a bad figure is never followed by twenty more. Labels have to match what the page tells screen readers — Pick element shows it, and Claude's `dump_uia_tree` lists every one on the screen; the first real use against a new program is worth a dry run on a test client.

**Conditional steps (if / then).** An optional, opt-in feature for branching — nothing you record uses it, and existing workflows are unaffected. In the **Add** dialog's Action list (at the bottom) pick one of: *If a window IS/​is NOT open*, *If something IS/​is NOT on screen* (a named button, link, etc.), or *If some text IS/​is NOT on screen* (any words the app is showing). Follow it with the steps to run when the condition holds, an optional **Otherwise (else)**, and an **End if**. The step list indents each block so you can see the structure. Conditions are deterministic state checks only (is a window/element present) — no pixel or image guessing. Example: *If the "Save changes?" dialog is open → click "Save" → End if*. Tip: because these aren't recordable, the easiest way to build them is to describe the workflow in plain words — either **New Automation → Draft With AI** (OpenRouter, reviewed in the Studio) or Claude via the MCP add-on.

**Clicking things inside a web page.** Windows offers programs two different ways of describing what's on screen, an old one and a newer one, and Chrome stopped publishing web page content over the old one — so a workflow that clicked a button *inside a page* could find nothing at all, even one that used to work. VoiceKit now looks in **both** places (the old one first, so nothing about your existing desktop workflows changes) and falls back to the newer one when the old one comes up empty. Nothing to turn on and no steps to change; browser workflows simply work again. If a click still can't find its target, the usual causes remain: the name on screen changed, or the page hadn't finished rendering — put a **Wait until some text appears** step in front of it.

Workflows stay editable: reopen the Studio and pick one from the dropdown. The `macros\` file is generated — edit steps in the Studio, not Notepad. If a workflow stops mid-run, the popup names the failing step; usually the fix is a longer wait or a looser window title.

## The home window — say "open voice kit"

One calm place for everything (inspired by the disappearing-UI school of tools like Wispr Flow): every workflow, macro, AI action, hotkey, and snippet in a searchable list with the exact phrase to say, plus **Run**, **Edit** (workflows open straight in the Studio; AI prompts and text snippets get an inline editor — the snippet editor takes multi-line text and renames), **Hotkey** (below), **Delete** (removes all of an automation's artifacts, including Start Menu entries and its hotkey), **New Automation**, and **AI Settings**. The old **"open voice kit help"** phrase still works — it lands here.

**Give any automation a hotkey — for when you can't use your voice.** Select it, click **Hotkey**, pick a free key, done: pressing **Ctrl+Alt+Shift+\<key\>** now runs the same automation the phrase does (mic muted, on a call, voice tired — the keyboard still works, and the phrase keeps working too). The assigned combo shows in the list's **Hotkey** column; the same dialog changes or removes it. No Voice Access setup is involved — the key lives in VoiceKit itself, so it works the moment you save it (VoiceKit must be running, as always).

## AI features (optional) — the OpenRouter layer

Strictly **additive and opt-in**: nothing calls the network until you paste an [OpenRouter](https://openrouter.ai/keys) API key into **AI Settings** (home window → AI Settings), and the deterministic workflow engine never touches it. The key is stored DPAPI-encrypted (readable only by your Windows account); the model defaults to `openrouter/auto` — change it if you care, ignore it if you don't. Three features sit on this layer:

- **Ask AI anywhere** — say **"open ask ai"**: a slim bar appears at the bottom of the screen, you dictate (or type) a question, and the answer is **typed into the app you were just using** — then the bar disappears. If there's nowhere to type, you get the answer with a Copy button instead.
- **AI text actions** — New Automation → **AI Text Action**. Name it, write the prompt once ("Fix the grammar and spelling…"), and you get a voice phrase: select text in any app, say **"open fix grammar"**, and the AI's answer types itself in, replacing the selection. Your clipboard is preserved. Prompts are editable any time from the home window.
- **Draft With AI** — New Automation → **Draft With AI**. Describe the automation in plain words; the AI drafts real workflow steps, which open in **Workflow Studio for review** — nothing runs or saves until you test and save it yourself. Drafts are validated (step types, if/endif balance) before the Studio ever sees them.

What leaves your machine: only what a feature needs at the moment you trigger it — your question, the selected text (**or, if nothing is selected, the text currently on your clipboard** — the fallback an AI text action uses), the description, and the saved prompt. Sent to OpenRouter only when you speak the phrase, never in the background. Mind the clipboard fallback if you copy sensitive things.

## Create automations with Claude (MCP) — optional

Prefer to *describe* an automation instead of recording it? There's an optional
**MCP server** in `mcp\` that lets Claude (Desktop or Claude Code) build every
automation type for you from natural language — launch macros (including the
no-code "open something" kind), hotkey modules, snippets, step workflows, and AI
text actions — "make a workflow that opens Notepad and types my address" —
writing the exact same files the GUI does. Claude can also **trigger** them:
`run_automation` is the MCP equivalent of you saying "open \<name\>" (including
"loop \<name\>" for repeat runs), and `press_hotkey` fires an always-on hotkey
module. It's an add-on, not a
replacement: recording and New Automation still work unchanged. Setup, the tool
list, and the security model are in **`mcp\README.md`** (needs Python 3.10+).
Every script it generates is load-checked before it's kept.

## Hard limits — know these, don't fight them

- **Voice Access shortcuts cannot be created programmatically.** No API, no PowerShell, no registry path. This is why Path 1 exists and why Path 2 keeps a 30-second manual step.
- **Voice shortcuts max out at 8 actions, with no variables, conditionals, or loops.** Never build logic in Voice Access. One shortcut = one handoff to AHK.
- **Voice shortcuts don't sync or back up.** `bridge-map.txt` is your recreate list for a new machine or reinstall. (Lines in it whose file ends `.hotkey.ahk` are companion hotkeys assigned in the home window — those need no Voice Access recreation; they're keyboard-only.)
- **Say phrases exactly**; distinct, uncommon phrases misfire less. Mute Voice Access during calls or your meeting will run your macros.

## Troubleshooting

- **Error mentioning "this line does not contain a recognized action" or similar on pasted code** → you copied AutoHotkey **v1** syntax from an old tutorial or forum post. Most of the internet's AHK content is v1. Check any snippet against the v2 docs (autohotkey.com/docs/v2) or ask Claude to convert it.
- **"open <name>" isn't recognized** → wait ~30s for Start Menu indexing; confirm the `.lnk` exists in `Start Menu\Programs\Voice Macros`; try the exact phrase shown by "open voice kit".
- **Want a particular key?** → When you create an always-on hotkey, the dialog now lets you **pick** which Ctrl+Alt+Shift key it uses from the ones still free — including symbols like `[  ]  ;  '  ,  .  /  -  =  \`, not just letters and numbers. (E, N, R, X, H, I and C are reserved by VoiceKit itself.) If you later want a different key, delete it and create it again — the key is tied to the Voice Access shortcut you paired by hand, so it's never moved behind your back.
- **New hotkey does nothing** → VoiceKit must be running (tray icon). Press Ctrl+Alt+Shift+R to reload, or double-click **`VoiceKitLauncher.ahk`** (which checks everything loads before starting).
- **"VoiceKit turned off some files that wouldn't load"** → one of your hotkey modules has a mistake in it. Rather than let a single bad file take down every hotkey and snippet you own, VoiceKit switches that one off and starts normally. Fix the file, then remove the `;` from its line in `hotkeys\_index.ahk` and reload (Ctrl+Alt+Shift+R). The reason is logged in `logs\errors.log`.
- **"VoiceKit kept crashing, so it restarted with all hotkey modules turned off"** (safe mode) → VoiceKit died three times in two minutes, so its watchdog restarted it with everything off to break the loop. Turn modules back on one at a time in `hotkeys\_index.ahk` (reload after each) to find the culprit, then delete `logs\safe-mode.flag`.
- **A hotkey has been running for ages — is it stuck?** → A hotkey whose code reports its progress shows its latest line in the home window, with how long ago it was written; a line that stops getting newer is a job that died. (For anyone writing that code: call `BodyStatus("<ModuleName>", "3 / 766 - Acme Holdings")` in `hotkeys\bodies\<ModuleName>.body.ahk` — newly created modules come with the example already in their header.)
- **A hotkey's own window shows an AutoHotkey error** → that's the module's code failing in its own separate process. Nothing else is affected — VoiceKit, your other hotkeys and your snippets keep working. The dialog names the file and line; edit it from the home window (select it → Edit).
- **Snippets don't fire when dictating by voice** → hotstrings react to typed keys; expansion via Voice Access dictation is not guaranteed. For purely static text you want to *speak*, Voice Access's own "paste text" shortcut action is the right tool — no AHK needed. Use snippets for typing and for dynamic text like `/date`.
- **AI features do nothing / error immediately** → no key saved, or the key was revoked. Home window → AI Settings → paste a key and click **Test Key**. AI features also need an internet connection; everything else in VoiceKit works offline.
- **Find an app's window identity** for `RunOrActivate`: right-click the VoiceKit tray icon → Window Spy.

## Acceptance checks (run these once after setup)

1. Say "open voice kit" → the home window appears, listing every automation.
2. Say "open new automation" → Open Something → name it "Test Ping", target `notepad.exe` → say "open test ping" → Notepad opens.
3. New Automation → Type Text For Me: `/hi` → "hello world" → typing `/hi` in Notepad expands it.
4. New Automation → Always-On Hotkey "Test Bridge" (Open something → notepad.exe) → pressing the assigned Ctrl+Alt+Shift key opens Notepad; register the phrase in Voice Access and repeat by voice.
5. Say "open workflow studio" → click Record, open Notepad and type a few words, click Stop → click Test replays it; Save as "Test Flow" → say "open test flow".
6. Say "open voice kit" → select "open test ping" → click **Hotkey** → Save Hotkey → press the shown Ctrl+Alt+Shift key (no voice) → Notepad opens.
7. (With an OpenRouter key saved) say "open ask ai", ask something small → the answer types into your last app.

## Out of scope, on purpose

No coordinate-click macros (they rot — Workflow Studio records clicks by the element's on-screen name instead, keeping raw position only as a last-resort fallback), no pixel/image searching, nothing non-deterministic in the core. (Random Wait ranges and the couple of pixels of click wobble are not an exception to that: the same steps run in the same order and hit the same things — only the *timing* and the *exact pixel* vary, and both are bounded. Nothing about what the workflow does is left to chance.) The **one deliberate exception** is the opt-in AI layer above: it calls OpenRouter when — and only when — you trigger an AI feature with a key saved, and the deterministic engine itself never does. When a future automation needs real logic (loops, parsing, decisions), design it in chat first, then write code — fixing a plan is 10x cheaper than fixing a script.
