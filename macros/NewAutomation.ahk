#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  New Automation — the automation that creates automations.
;  Say "open new automation"  (or press Ctrl+Alt+Shift+N).
;
;  Intent-first and no-code: pick what should HAPPEN, answer one
;  themed dialog, and VoiceKit writes the script, the Start Menu
;  entry, and (where needed) reloads itself. Editing code is an
;  escape hatch, never the default.
;
;  The two AI choices (AI Text Action, Draft With AI) are the
;  opt-in OpenRouter layer — they ask for a key on first use and
;  never touch the deterministic workflow engine.
; ============================================================

#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"
#Include "%A_ScriptDir%\..\lib\AI.ahk"

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")   ; parent of \macros

choice := ChooseType()
switch choice {
    case 1: NewOpenSomething(root)
    ; Record My Steps hands off to Workflow Studio WITHOUT killing a session
    ; that's already open (#SingleInstance Force would silently discard
    ; unsaved recorded steps) — lib\_Common.ahk OpenStudioSafely, which also
    ; sees a Studio that's hidden because it's recording or testing.
    case 2: OpenStudioSafely(root, , "Workflow Studio is busy recording or testing right now."
                . " Finish that first (Ctrl+Alt+Shift+X stops a recording), then try again.")
    case 3: NewSnippet(root)
    case 4: NewAIAction(root)
    case 5: NewAIDraft(root)
    case 6: NewHotkeyModule(root)
}
ExitApp()

; ------------------------------------------------------------
;  The chooser — plain-language intents, not artifact types.
; ------------------------------------------------------------
ChooseType() {
    state := {choice: 0}
    g := Gui("+AlwaysOnTop", "New Automation")
    g.SetFont("s11", "Segoe UI")
    g.MarginX := 20, g.MarginY := 18
    g.SetFont("s13 bold")
    g.AddText("xm", "What should happen when you speak?")
    g.SetFont("s9 norm")
    subtitle := g.AddText("xm y+3 w480", "Every button is voice-clickable — say “click” plus its name.")

    descs := [subtitle]
    MakeCard(title, desc, choiceNum, opts := "") {
        g.SetFont("s10 bold")
        b := g.AddButton("xm y+14 w480 h38 " opts, title)
        b.OnEvent("Click", (*) => (state.choice := choiceNum, g.Destroy()))
        g.SetFont("s9 norm")
        descs.Push(g.AddText("xm y+3 w480", desc))
    }
    MakeCard("Open Something", "An app, file, folder, or website — ready instantly, no code. Say “open <name>”.", 1)
    MakeCard("Record My Steps", "Do the thing once while VoiceKit watches, then replay it any time by voice.", 2, "Default")
    MakeCard("Type Text For Me", "A short abbreviation (like /sig) that expands into full text wherever you type.", 3)
    MakeCard("AI Text Action", "Your own AI command: select text anywhere, speak the phrase, the answer replaces it.", 4)
    MakeCard("Draft With AI", "Describe the automation in plain words — AI drafts the steps, you review and save.", 5)
    MakeCard("Always-On Hotkey", "Advanced: a Ctrl+Alt+Shift key that's always live; pair a voice phrase to it once.", 6)

    g.SetFont("s10")
    bCancel := g.AddButton("xm y+20 w120 h32", "Cancel")
    bCancel.OnEvent("Click", (*) => g.Destroy())
    g.OnEvent("Close", (*) => g.Destroy())
    g.OnEvent("Escape", (*) => g.Destroy())

    ThemeShowModal(g, 0, descs)
    return state.choice
}

; ------------------------------------------------------------
;  Shared dialog plumbing (showing a dialog modally is
;  lib\Theme.ahk ThemeShowModal; AhkStrLit lives in _Common)
; ------------------------------------------------------------

; Normalize + validate a name. Returns {phrase, base} or "" (after its
; own error popup, owned by the calling dialog).
ValidNewName(raw, ownerHwnd) {
    phrase := CleanPhrase(raw)
    base := StrReplace(phrase, " ")
    if (base = "" || IsReservedName(base)) {
        MsgBox("'" Trim(raw) "' isn't a usable name (empty after cleanup, or a reserved Windows name). Pick another.",
            "New Automation", "Icon! Owner" ownerHwnd)
        return ""
    }
    return {phrase: phrase, fileBase: base}
}

; The calm "you're done" screen: the phrase to say, front and center.
DoneDialog(sayThis, note, scriptPath := "") {
    d := Gui("+AlwaysOnTop", "New Automation")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 22, d.MarginY := 18
    d.SetFont("s13 bold")
    d.AddText("xm", "Ready ✓")
    d.SetFont("s10 norm")
    lead := d.AddText("xm y+10", "Say it any time:")
    d.SetFont("s14 bold")
    phraseCtrl := d.AddText("xm y+4 w460", "“" sayThis "”")
    d.SetFont("s10 norm")
    d.AddText("xm y+12 w460", note)
    tail := d.AddText("xm y+8 w460", "First time only: give Windows a few seconds to index the new Start Menu entry.")
    btnDone := d.AddButton("xm y+16 w130 h34 Default", "Done")
    if (scriptPath != "") {
        btnScript := d.AddButton("x+8 w170 h34", "Open Script")
        btnScript.OnEvent("Click", (*) => Run('notepad.exe "' scriptPath '"'))
    }
    btnDone.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d, 0, [lead, tail, (*) => phraseCtrl.Opt("c" Format("{:06X}", ThemePalette().accent))])
}

; ------------------------------------------------------------
;  1) Open Something — a launch macro, written for you.
; ------------------------------------------------------------
NewOpenSomething(root) {
    d := Gui("+AlwaysOnTop", "New Automation — Open Something")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "Open something by voice")
    d.SetFont("s10 norm")
    d.AddText("xm y+14", "Name it — this becomes the voice phrase:")
    edName := d.AddEdit("xm y+4 w480")
    exName := d.AddText("xm y+3 w480", "Example:  Team Dashboard   →   you'll say “open team dashboard”")
    d.AddText("xm y+14", "What should it open?")
    edTarget := d.AddEdit("xm y+4 w480")
    exTarget := d.AddText("xm y+3 w480", "Paste a web address (https://…) or an app (notepad.exe) — or browse:")
    btnFile := d.AddButton("xm y+8 w150 h30", "Browse File")
    btnFolder := d.AddButton("x+8 w150 h30", "Browse Folder")
    btnOK := d.AddButton("xm y+18 w150 h36 Default", "Create")
    btnCancel := d.AddButton("x+8 w110 h36", "Cancel")

    BrowseFile(*) {
        f := FileSelect(3, , "Pick the file to open")
        if (f != "")
            edTarget.Value := f
    }
    BrowseFolder(*) {
        f := DirSelect(, 3, "Pick the folder to open")
        if (f != "")
            edTarget.Value := f
    }
    btnFile.OnEvent("Click", BrowseFile)
    btnFolder.OnEvent("Click", BrowseFolder)

    OK(*) {
        nm := ValidNewName(edName.Value, d.Hwnd)
        if !IsObject(nm)
            return
        target := Trim(edTarget.Value)
        if (target = "") {
            MsgBox("Point it at something — a path, an app, or a web address.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        newFile := root "\macros\" nm.fileBase ".ahk"
        if ((disp := ClaimNewMacroName(root, nm.fileBase, d.Hwnd)) = "")
            return
        content := VkOpensMacroContent(nm.phrase, target)
        ; Load-checked before the voice phrase points at it — a macro that
        ; won't load would only fail later, when spoken, with a code error.
        if !AhkWriteChecked(newFile, content, &err) {
            MsgBox(err, "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        EnsureVoiceShortcut(disp, newFile)
        Log(root, "launch | " disp " | macros\" nm.fileBase ".ahk | opens " target)
        d.Destroy()
        DoneDialog("open " disp, "It opens:  " target, newFile)
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d, 0, [exName, exTarget])
}

; (2) Record My Steps is lib\_Common.ahk OpenStudioSafely — see the switch
; at the top.

; ------------------------------------------------------------
;  3) Type Text For Me — a snippet, one dialog, fully automated.
; ------------------------------------------------------------
NewSnippet(root) {
    d := Gui("+AlwaysOnTop", "New Automation — Type Text For Me")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "Text that types itself")
    d.SetFont("s10 norm")
    d.AddText("xm y+14", "Abbreviation to type (no spaces):")
    edAbbrev := d.AddEdit("xm y+4 w200")
    exA := d.AddText("xm y+3 w480", "Example:  /sig    (a / prefix avoids firing by accident)")
    d.AddText("xm y+14", "Expands to:")
    edText := d.AddEdit("xm y+4 w480 r6 +Wrap")
    exB := d.AddText("xm y+3 w480", "Typing the abbreviation anywhere replaces it with this text. Press Enter for line breaks — it expands to as many lines as you type.")
    btnOK := d.AddButton("xm y+18 w150 h36 Default", "Create")
    btnCancel := d.AddButton("x+8 w110 h36", "Cancel")

    OK(*) {
        abb := RegExReplace(Trim(edAbbrev.Value), "\s", "")
        expansion := edText.Value
        ; One bad line stops Snippets.ahk loading, and the reload would then
        ; switch EVERY snippet off — so the rules are checked first, and the
        ; written file is load-checked (and put back) below.
        if ((why := SnippetValidate(abb, expansion)) != "") {
            MsgBox(why, "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        snipFile := root "\hotkeys\Snippets.ahk"
        if SnippetExists(snipFile, abb) {
            MsgBox("A snippet  " abb "  already exists. Delete it first (say `"open voice kit`") or pick another abbreviation.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        line := "`n:*:" abb "::" SnipEncode(expansion)     ; multi-line -> `n; escape ` and ;
        if !SnippetFileChange(snipFile, () => (FileAppend(line, snipFile, "UTF-8"), true), &err) {
            MsgBox("That snippet would stop the snippets file loading, so it wasn't added:`n`n" err,
                "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        ReloadMasterNotify(root)         ; reload VoiceKit so it works immediately
        Log(root, "snippet | " abb)
        d.Destroy()
        d2 := Gui("+AlwaysOnTop", "New Automation")
        d2.SetFont("s10", "Segoe UI")
        d2.MarginX := 22, d2.MarginY := 18
        d2.SetFont("s13 bold")
        d2.AddText("xm", "Ready ✓")
        d2.SetFont("s10 norm")
        d2.AddText("xm y+10 w420", "Type  " abb "  anywhere and it expands immediately — no voice setup needed.")
        b := d2.AddButton("xm y+16 w130 h34 Default", "Done")
        b.OnEvent("Click", (*) => d2.Destroy())
        d2.OnEvent("Close", (*) => d2.Destroy())
        d2.OnEvent("Escape", (*) => d2.Destroy())
        ThemeShowModal(d2)
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d, 0, [exA, exB])
}

; ------------------------------------------------------------
;  4) AI Text Action — a saved prompt with its own voice phrase.
; ------------------------------------------------------------
NewAIAction(root) {
    if !AIEnsureConfigured()
        return
    d := Gui("+AlwaysOnTop", "New Automation — AI Text Action")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "Your own AI command")
    d.SetFont("s10 norm")
    how := d.AddText("xm y+4 w500", "Select text in any app, speak the phrase, and the AI's answer types itself in — replacing the selection.")
    d.AddText("xm y+14", "Name it — this becomes the voice phrase:")
    edName := d.AddEdit("xm y+4 w500")
    exName := d.AddText("xm y+3 w500", "Example:  Fix Grammar   →   you'll say “open fix grammar”")
    d.AddText("xm y+14", "What should the AI do with the selected text?")
    edPrompt := d.AddEdit("xm y+4 w500 r6 +Wrap")
    exPrompt := d.AddText("xm y+3 w500", "Example:  Fix the grammar and spelling. Keep the meaning and tone. Return only the corrected text.")
    btnOK := d.AddButton("xm y+18 w150 h36 Default", "Create")
    btnCancel := d.AddButton("x+8 w110 h36", "Cancel")

    OK(*) {
        nm := ValidNewName(edName.Value, d.Hwnd)
        if !IsObject(nm)
            return
        prompt := Trim(edPrompt.Value, " `t`r`n")
        if (prompt = "") {
            MsgBox("Tell the AI what to do — that text becomes the saved prompt.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        newFile := root "\macros\" nm.fileBase ".ahk"
        if ((disp := ClaimNewMacroName(root, nm.fileBase, d.Hwnd)) = "")
            return
        promptFile := root "\prompts\" nm.fileBase ".prompt.txt"
        EnsureDir(root "\prompts")
        f := FileOpen(promptFile, "w", "UTF-8")
        f.Write(prompt "`n")
        f.Close()
        tpl := FileRead(root "\templates\ai-template.ahk", "UTF-8")
        tpl := StrReplace(tpl, "{{PHRASE}}", nm.phrase)
        tpl := StrReplace(tpl, "{{BASE}}", nm.fileBase)
        tpl := StrReplace(tpl, "{{DATE}}", FormatTime(A_Now, "yyyy-MM-dd"))
        if !AhkWriteChecked(newFile, tpl, &err) {      ; before the phrase points at it
            try FileDelete(promptFile)
            MsgBox(err, "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        EnsureVoiceShortcut(disp, newFile)
        Log(root, "ai-action | " disp " | macros\" nm.fileBase ".ahk")
        d.Destroy()
        DoneDialog("open " disp,
            "Select text first, then say it — the answer replaces the selection. The prompt is editable any time from Voice Kit (say “open voice kit”).")
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d, 0, [how, exName, exPrompt])
}

; ------------------------------------------------------------
;  5) Draft With AI — describe it, review the steps in Studio.
; ------------------------------------------------------------
NewAIDraft(root) {
    ; Check Studio BEFORE spending an API call — launching it with a draft
    ; would replace (and silently discard) an already-open session. Hidden
    ; counts as open: it hides while recording or testing.
    if StudioWindow().hwnd {
        MsgBox(StudioOpenForDraftMsg(), "New Automation", "Icon! 262144")
        return
    }
    if !AIEnsureConfigured()
        return
    d := Gui("+AlwaysOnTop", "New Automation — Draft With AI")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "Describe it — AI drafts the steps")
    d.SetFont("s10 norm")
    how := d.AddText("xm y+4 w560", "The draft opens in Workflow Studio for you to review, test, and save. Nothing runs until you say so.")
    d.AddText("xm y+14", "What should happen, step by step, in plain words?")
    edDesc := d.AddEdit("xm y+4 w560 r8 +Wrap")
    tips := d.AddText("xm y+6 w560", "Mention app names, exact button labels, and any text to type."
        . "  Example:  open Chrome, go to gmail.com, wait for it to load, click Compose.")
    btnOK := d.AddButton("xm y+16 w150 h36 Default", "Draft It")
    btnCancel := d.AddButton("x+8 w110 h36", "Cancel")
    status := d.AddText("xm y+12 w560 h30", "")
    dHwnd := d.Hwnd          ; read now: OK below can outlive the Gui

    ; Back to editable, with a message. try: see the check in OK.
    Retry(msg) {
        try {
            status.Text := msg
            edDesc.Enabled := true
            btnOK.Enabled := true
        }
    }
    OK(*) {
        desc := Trim(edDesc.Value, " `t`r`n")
        if (desc = "")
            return
        edDesc.Enabled := false
        btnOK.Enabled := false
        status.Text := "Drafting… (this takes a few seconds)"
        err := ""
        raw := AIComplete(DraftSystemPrompt(), desc, &err, 4096)
        ; AIComplete keeps the dialog responsive while it waits, so Cancel /
        ; Escape / X may have closed it meanwhile. That means "never mind":
        ; don't open the draft the user just walked away from (and don't
        ; write into controls that no longer exist — that throws).
        if !WinExist("ahk_id " dHwnd)
            return
        if (raw = "") {
            Retry(err)
            return
        }
        perr := ""
        steps := ParseDraft(raw, &perr)
        if !IsObject(steps) {
            Retry(perr " — click Draft It to retry.")
            return
        }
        EnsureDir(root "\logs")
        draftFile := root "\logs\ai-draft.steps.txt"
        content := "; AI draft — review in Workflow Studio, then Save`n"
        for s in steps
            content .= s[1] "|" WfEncode(s[2]) "|" WfEncode(s[3]) "|" WfEncode(s[4]) "`n"
        f := FileOpen(draftFile, "w", "UTF-8")
        f.Write(content)
        f.Close()
        Log(root, "ai-draft | " steps.Length " steps")
        d.Destroy()
        ; The Studio may have been opened while the AI was drafting; a
        ; relaunch would kill it, so the draft waits in its file instead.
        if (OpenStudioSafely(root, draftFile) != "launched")
            MsgBox(StudioOpenForDraftMsg() "`n`nYour draft is kept in logs\ai-draft.steps.txt.",
                "New Automation", "Icon! 262144")
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d, 0, [how, tips])
}

StudioOpenForDraftMsg() {
    return "Workflow Studio is already open (or busy recording or testing). "
        . "Save or close it first, then run Draft With AI again."
}

DraftSystemPrompt() {
    return "You convert a plain-English description of a Windows task into steps for a deterministic automation engine. "
        . "Reply with ONLY a JSON array - no markdown fences, no commentary. Each element is an object "
        . '{"type":"...","a":"...","b":"...","c":"..."}; unused fields may be omitted or "". All values must be strings.' "`n`n"
        . "Step types:`n"
        . "- run: a = program, file path, folder path, or https:// URL to open.`n"
        . "- focus: a = window to focus ('ahk_exe app.exe' or part of its title); b = command to launch it if it isn't running (optional).`n"
        . "- waitwin: a = window to wait for; b = timeout in seconds (optional, default 10).`n"
        . '- wait: a = milliseconds to pause, or a RANGE like "600-1400" to pause a random amount in between. Use this only when there is nothing observable to wait on — prefer waitfor. Use a range whenever the workflow will be repeated against a website: pausing the identical number of milliseconds every pass is the easiest robot pattern to detect.' "`n"
        . '- waitfor: waits until something is actually true, then continues at once. a = window; b = the element name or on-screen text to wait for (empty for the window/clipboard conditions); c = one of winexists, winnotexists, elementexists, elementnotexists, textvisible, textnotvisible, clipboardchanged - optionally followed by ",<seconds>" (default 10), e.g. "textvisible,30". Use it after anything slow: a page loading, a save, a search. clipboardchanged needs no window and waits for a copy to land.' "`n"
        . "- text: a = text to type into the focused window.`n"
        . "- fill: a = window; b = the EXACT on-screen label of an input box (its accessible name - for a web form, the field's label), with #2, #3... appended when several boxes share that label (Amount#2 = the second; write ## for a # that is part of the label itself, e.g. Line ##4); c = the value to put in it (may use {{Name}}; an empty c clears the box). It clicks the box, types the value and checks the box took it. Prefer fill over click + text for form fields.`n"
        . "- ask: a = a short label for a value the USER should supply when the workflow runs (e.g. 'Customer name'); b = suggested answer (optional). All ask inputs are collected in dialogs before the run starts, and the answer is typed into the focused window at this step's position. Use ask instead of text whenever the description implies the value changes each run.`n"
        . "- collect: a = a short label for a value the workflow should GRAB from the screen and save (it becomes a column in the workflow's results sheet); b = the exact on-screen name of the box to read (optional — leave empty to copy whatever text the previous steps left SELECTED, e.g. after a select-all or a double-click on a word). Use collect when the description implies reading or saving something the app shows.`n"
        . "- set: a = a name (no braces) for a value; b = the value, which may itself contain {{other}} references. Use it to build a value once and reuse it.`n"
        . "- keys: a = keys in AutoHotkey v2 Send syntax, e.g. {Enter}, {Tab 2}, ^s.`n"
        . "- click / dblclick / rclick: a = window; b = the EXACT on-screen name of the thing to click (button caption, link text, menu item).`n"
        . "- hover: a = window; b = the on-screen name to rest the mouse over (moves there and pauses so a hover menu/tooltip appears; follow with a click on what it reveals).`n"
        . '- drag: a = window; c = "x1,y1,x2,y2" window-relative press and release points (selects a region by dragging). Only use when the description gives exact pixel coordinates; never invent them.' "`n"
        . "- move: a = window; b = one of left, right, top, bottom, max.`n"
        . "- close: a = window to close.`n"
        . '- if: a = window; b = element name or on-screen text ("" for the window conditions); c = one of winexists, winnotexists, elementexists, elementnotexists, textvisible, textnotvisible. Use textvisible/textnotvisible to react to what the app says, e.g. "No results found".' "`n"
        . "- else: no fields. endif: no fields.`n"
        . "- NEVER use a capture step (running a command and saving its output): drafts can't contain commands. If the task needs one, draft the other steps; the user adds the command in Workflow Studio.`n`n"
        . "Named values:`n"
        . "- Every ask label, collect label and set name becomes a value you can reuse ANYWHERE later by writing {{Name}} — in text, keys, run targets, window criteria and element names.`n"
        . "- That is how one answer reaches two places: ask once for 'Customer', then write {{Customer}} in every step that needs it. Never ask for the same thing twice.`n"
        . "- {{clipboard}}, {{date}}, {{time}} and {{datetime}} are always available.`n"
        . "- {{selected_file}} is the one file the user selected in File Explorer before starting (full path; put it in double quotes inside a command line) - the run refuses to start unless exactly one is selected. {{selected_files}} is every selected file, each already in double quotes, space-joined. Use them only when the description is about the selected file(s).`n"
        . "- Only reference a name something defines; an unknown name is typed out literally. The one exception is a fill value: an undefined {{Name}} there becomes an input the user supplies when the workflow runs (no ask step needed).`n`n"
        . "Rules:`n"
        . "- Every if needs a matching endif (else is optional). Only branch when the description clearly needs it.`n"
        . "- After a run/focus that launches an app, add waitwin. After anything else slow (a search, a save, a page load), add a waitfor for the thing that proves it finished — not a guessed wait.`n"
        . "- Prefer element-name clicks; never invent coordinates (leave c empty for clicks).`n"
        . "- Windows are 'ahk_exe name.exe' or a distinctive part of the window title.`n"
        . "- Keep it minimal and linear."
}

; The AI's reply -> validated steps array, or "" with perr set.
; Defensive on purpose: models sometimes capitalize keywords (lowercase
; them — the engine wants lowercase anyway) or nest objects where a
; string belongs (String(Map) throws, so fields go through DraftField).
ParseDraft(raw, &perr) {
    perr := ""
    try return ParseDraftInner(raw, &perr)
    catch as e {
        perr := "Couldn't read the AI's step list (" e.Message ")"
        return ""
    }
}

ParseDraftInner(raw, &perr) {
    p1 := InStr(raw, "[")
    p2 := InStr(raw, "]", , -1)          ; last ] — tolerates fences/prose around the array
    if (!p1 || !p2 || p2 < p1) {
        perr := "The AI didn't return a step list"
        return ""
    }
    arr := ""
    try arr := JsonParse(SubStr(raw, p1, p2 - p1 + 1))
    catch {
        perr := "Couldn't read the AI's step list"
        return ""
    }
    if !(arr is Array) || !arr.Length {
        perr := "The AI returned an empty step list"
        return ""
    }
    validTypes := Map("run",1, "focus",1, "waitwin",1, "wait",1, "waitfor",1, "text",1, "fill",1, "ask",1, "collect",1, "set",1, "keys",1,
        "click",1, "dblclick",1, "rclick",1, "hover",1, "drag",1, "move",1, "close",1, "if",1, "else",1, "endif",1)
    ; Types that store nothing in paramC (the Studio's generic path agrees).
    ; if/waitfor/drag and the pointer steps keep theirs, checked below.
    paramCless := Map("run",1, "focus",1, "waitwin",1, "wait",1, "text",1, "ask",1, "collect",1,
        "set",1, "keys",1, "move",1, "close",1, "else",1, "endif",1)
    validConds := Map("winexists",1, "winnotexists",1, "elementexists",1, "elementnotexists",1,
        "textvisible",1, "textnotvisible",1)
    steps := []
    for i, el in arr {
        if !(el is Map) {
            perr := "Draft step " i " wasn't an object"
            return ""
        }
        ok := true
        t := StrLower(DraftField(el, "type", &ok))
        ; capture runs a command line. The engine has it, but a draft is
        ; text from a model, and a command belongs to someone who read it —
        ; so drafts can't carry one (yet). Named, so the user knows why.
        if (t = "capture") {
            perr := "Draft step " i " runs a command ('capture') — Draft With AI can't add commands. "
                . "Draft it without that step, then add it yourself in Workflow Studio "
                . "(Add → Run a command and save its output)"
            return ""
        }
        if !validTypes.Has(t) {
            perr := "Draft step " i " has an unknown type ('" t "')"
            return ""
        }
        a := DraftField(el, "a", &ok)
        b := DraftField(el, "b", &ok)
        c := DraftField(el, "c", &ok)
        if !ok {
            perr := "Draft step " i " has a non-text value in it"
            return ""
        }
        if (t = "ask" && Trim(a) = "") {
            perr := "Draft step " i " is an 'ask' with no label"
            return ""
        }
        if (t = "collect" && Trim(a) = "") {
            perr := "Draft step " i " is a 'collect' with no label"
            return ""
        }
        ; wait: whole milliseconds or a range ("600-1400"). Checked with the
        ; engine's own parser so the draft can't produce a step the run rejects.
        if (t = "wait" && WfWaitMs(a).err != "") {
            perr := "Draft step " i " has a bad wait ('" a "') — milliseconds or a range like 600-1400"
            return ""
        }
        if (t = "if") {
            c := StrLower(c)
            if !validConds.Has(c) {
                perr := "Draft step " i " has a bad if-condition ('" c "')"
                return ""
            }
        } else if (t = "waitfor") {
            ; paramC is "<condType>[,<seconds>]" — normalise and check both
            ; halves.
            parts := StrSplit(c, ",")
            wc := StrLower(Trim(parts.Length ? parts[1] : ""))
            if !(validConds.Has(wc) || wc = "clipboardchanged") {
                perr := "Draft step " i " has a bad wait-until condition ('" wc "')"
                return ""
            }
            secs := (parts.Length >= 2) ? Trim(parts[2]) : ""
            if (secs != "" && (!IsNumber(secs) || Number(secs) <= 0)) {
                perr := "Draft step " i " has a bad wait-until timeout ('" secs "')"
                return ""
            }
            c := wc (secs != "" ? "," secs : "")
        } else if (t = "drag") {
            if !(c ~= "^\s*-?\d+\s*,\s*-?\d+\s*,\s*-?\d+\s*,\s*-?\d+\s*$") {
                perr := "Draft step " i " is a 'drag' without an x1,y1,x2,y2 path"
                return ""
            }
        } else if (t = "fill") {
            ; paramC is the VALUE — kept exactly as drafted ("" clears the box).
            if (Trim(a) = "" || Trim(b) = "") {
                perr := "Draft step " i " is a 'fill' without a window and a box label"
                return ""
            }
            if ((lerr := WfFillLabel(b).err) != "") {
                perr := "Draft step " i ": " lerr
                return ""
            }
            if RegExMatch(c, "[\r\n]") {
                perr := "Draft step " i " fills a box with a line break — a fill types one line"
                return ""
            }
        } else if paramCless.Has(t)
            c := ""                       ; nothing lives in paramC for these — drop model noise
        else if (t != "click" && t != "dblclick" && t != "rclick" && t != "hover") {
            ; A type that stores something in paramC but has no branch above.
            ; This used to be a catch-all that blanked paramC for "everything
            ; else" — a new paramC type (waitfor's timeout, capture's) would
            ; have lost its value silently. Now a type must be listed in
            ; paramCless or get its own branch; anything else is refused.
            perr := "Draft step " i " ('" t "') isn't supported in drafts yet"
            return ""
        }
        steps.Push([t, a, b, c])
    }
    if (berr := DraftBalanceError(steps)) {
        perr := berr
        return ""
    }
    return steps
}

; One string field of a draft step. Numbers become strings; anything
; else non-string (nested object/array) clears `ok`.
DraftField(el, k, &ok) {
    if !el.Has(k)
        return ""
    v := el[k]
    if (v is String)
        return v
    if (v is Number)
        return String(v)
    ok := false
    return ""
}

; Same rule Workflow Studio enforces at save: unbalanced blocks would
; silently truncate a run, so refuse them at draft time too.
DraftBalanceError(steps) {
    depth := 0
    for i, s in steps {
        switch s[1] {
            case "if":    depth += 1
            case "else":  if (depth = 0)
                              return "Draft step " i ": 'else' has no matching 'if'"
            case "endif": if (depth = 0)
                              return "Draft step " i ": 'endif' has no matching 'if'"
                          else
                              depth -= 1
        }
    }
    if (depth > 0)
        return "The draft has an 'if' with no matching 'endif'"
    return ""
}

; ------------------------------------------------------------
;  6) Always-On Hotkey — no-code for the common cases; custom
;     code stays available as the escape hatch.
; ------------------------------------------------------------
NewHotkeyModule(root) {
    ; Offer the key up front rather than assigning one and hoping: the pool
    ; includes symbols now, and "I wanted [ and there was no way to ask" was
    ; the complaint that put this here.
    freeKeys := BridgeFreeKeys(root "\bridge-map.txt")
    if !freeKeys.Length {
        MsgBox("No free Ctrl+Alt+Shift keys are left — retire one in bridge-map.txt first.",
            "New Automation", "Icon! 262144")
        return
    }
    d := Gui("+AlwaysOnTop", "New Automation — Always-On Hotkey")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "An always-on key combo")
    d.SetFont("s10 norm")
    how := d.AddText("xm y+4 w500", "VoiceKit assigns a free Ctrl+Alt+Shift key. Pairing a voice phrase to it is one manual step at the end (~30 seconds — Windows allows no shortcut API).")
    d.AddText("xm y+14", "Name it — also the suggested voice phrase:")
    edName := d.AddEdit("xm y+4 w500")
    d.AddText("xm y+14", "Key to press:")
    d.SetFont("s11 bold")
    d.AddText("x+8 yp-1", "Ctrl + Alt + Shift  +")
    ddlKey := d.AddDropDownList("x+8 yp-3 w66 Choose1", freeKeys)
    d.SetFont("s10 norm")
    d.AddText("xm y+14", "When the key is pressed, what should happen?")
    rOpen := d.AddRadio("xm y+6 Checked Group", "Open something (app, file, folder, or web address)")
    rType := d.AddRadio("xm y+4", "Type text")
    rCode := d.AddRadio("xm y+4", "Custom code (opens the script for editing — advanced)")
    edTarget := d.AddEdit("xm y+10 w500")
    btnFile := d.AddButton("xm y+6 w150 h30", "Browse File")
    btnFolder := d.AddButton("x+8 w150 h30", "Browse Folder")
    btnOK := d.AddButton("xm y+18 w150 h36 Default", "Create")
    btnCancel := d.AddButton("x+8 w110 h36", "Cancel")

    SyncFields(*) {
        edTarget.Visible := !rCode.Value
        btnFile.Visible := rOpen.Value
        btnFolder.Visible := rOpen.Value
    }
    rOpen.OnEvent("Click", SyncFields)
    rType.OnEvent("Click", SyncFields)
    rCode.OnEvent("Click", SyncFields)
    BrowseFile(*) {
        f := FileSelect(3, , "Pick the file to open")
        if (f != "")
            edTarget.Value := f
    }
    BrowseFolder(*) {
        f := DirSelect(, 3, "Pick the folder to open")
        if (f != "")
            edTarget.Value := f
    }
    btnFile.OnEvent("Click", BrowseFile)
    btnFolder.OnEvent("Click", BrowseFolder)

    OK(*) {
        nm := ValidNewName(edName.Value, d.Hwnd)
        if !IsObject(nm)
            return
        newFile := root "\hotkeys\" nm.fileBase ".ahk"
        if FileExist(newFile) {
            MsgBox("A hotkey named '" nm.fileBase "' already exists. Pick another name.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        target := Trim(edTarget.Value)
        if (!rCode.Value && target = "") {
            MsgBox(rOpen.Value ? "Point it at something — a path, an app, or a web address."
                : "Give it the text to type.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        key := ddlKey.Text
        if (key = "") {
            MsgBox("Pick a key for it.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }

        ; Custom code runs OUT of process: hotkeys\<Base>.ahk becomes a key
        ; binding that launches hotkeys\bodies\<Base>.body.ahk. Hand-written
        ; code is the half that can crash hard (a bad ComCall, an unpinned
        ; COM vtable), and in the master that kills every other hotkey and
        ; every snippet too. The no-code branches below stay in-process:
        ; one Run()/SendText() line can't crash, and a launch would only
        ; add latency.
        if rCode.Value {
            if (cerr := HotkeyIsolatedCreate(root, nm.fileBase, nm.phrase, key)) {
                MsgBox(cerr, "New Automation", "Icon! Owner" d.Hwnd)
                return
            }
        } else {
            if rOpen.Value {
                runArg := (InStr(target, " ") && FileExist(target)) ? '"' target '"' : target
                actionLine := "Run(" AhkStrLit(runArg) ")"
                actionDesc := "Opens:  " target
            } else {
                actionLine := "SendText(" AhkStrLit(target) ")"
                actionDesc := "Types the saved text"
            }
            ; Load-checked BEFORE it's wired in: the master #Includes it, and
            ; a module that won't parse gets parked on the reload — which
            ; used to happen AFTER this dialog had already said it worked.
            if !HotkeyWriteChecked(root, "hotkeys\" nm.fileBase ".ahk",
                    HotkeyInProcessContent(nm.phrase, key, actionLine, actionDesc), &err) {
                MsgBox(err, "New Automation", "Icon! Owner" d.Hwnd)
                return
            }
        }

        BridgeRegisterModule(root, key, nm.phrase, "hotkeys\" nm.fileBase ".ahk")
        ReloadMasterNotify(root)         ; reload VoiceKit so the hotkey is live now
        Log(root, "hotkey | " nm.phrase " | Ctrl+Alt+Shift+" key " | hotkeys\" nm.fileBase ".ahk")
        if rCode.Value                   ; open the BODY — that's where steps go
            Run('notepad.exe "' HotkeyBodyFile(root, nm.fileBase) '"')
        d.Destroy()
        PairingDialog(nm.phrase, key)
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    SyncFields()
    ThemeShowModal(d, 0, [how])
}

; The one manual step Windows forces on us, spelled out calmly.
PairingDialog(phrase, key) {
    d := Gui("+AlwaysOnTop", "New Automation")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 22, d.MarginY := 18
    d.SetFont("s13 bold")
    d.AddText("xm", "Created — the key works now ✓")
    d.SetFont("s10 norm")
    d.AddText("xm y+6 w460", "Trigger key:  Ctrl + Alt + Shift + " key)
    lead := d.AddText("xm y+14 w460", "To trigger it by VOICE, pair a phrase once (~30 seconds):")
    d.SetFont("s10")
    d.AddText("xm y+8 w460", "1.  Say:  “show voice shortcuts”")
    d.AddText("xm y+4 w460", "2.  Create new shortcut  →  When I say:  " phrase)
    d.AddText("xm y+4 w460", "3.  Action: Press keys  →  Ctrl + Alt + Shift + " key)
    tail := d.AddText("xm y+12 w460", "The pairing is recorded in bridge-map.txt — your recreate list for a new machine.")
    btn := d.AddButton("xm y+16 w130 h34 Default", "Done")
    btn.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d, 0, [lead, tail])
}

; (AllocateBridgeKey lived here and took the first free key. It went when the
; hotkey dialog started offering the whole free list instead — dead code that
; claims to mirror the Python allocator is a drift hazard. BridgeFreeKeys in
; lib\_Common.ahk remains the shared source of truth.)
