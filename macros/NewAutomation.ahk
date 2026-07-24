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
masterPath := root "\VoiceKit.ahk"

choice := ChooseType()
switch choice {
    case 1: NewOpenSomething(root)
    case 2: OpenStudioSafely(root)
    case 3: NewSnippet(root, masterPath)
    case 4: NewAIAction(root)
    case 5: NewAIDraft(root)
    case 6: NewHotkeyModule(root, masterPath)
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

    ThemeApply(g)
    for d in descs
        ThemeDim(d)
    hwnd := g.Hwnd
    g.Show()
    WinWaitClose("ahk_id " hwnd)
    return state.choice
}

; ------------------------------------------------------------
;  Shared dialog plumbing
; ------------------------------------------------------------

; Theme a dialog, show it, and wait until it's gone.
ShowModal(d, dims := "") {
    ThemeApply(d)
    if IsObject(dims)
        for c in dims
            ThemeDim(c)
    hwnd := d.Hwnd
    d.Show()
    WinWaitClose("ahk_id " hwnd)
}

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

; Render a value as an AutoHotkey v2 double-quoted string literal.
AhkStrLit(s) {
    s := StrReplace(s, "``", "````")
    s := StrReplace(s, '"', '``"')
    s := StrReplace(s, "`r", "")
    s := StrReplace(s, "`n", "``n")
    return '"' s '"'
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
    ThemeApply(d)
    ThemeDim(lead)
    ThemeDim(tail)
    phraseCtrl.Opt("c" Format("{:06X}", ThemePalette().accent))
    hwnd := d.Hwnd
    d.Show()
    WinWaitClose("ahk_id " hwnd)
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
        if FileExist(newFile) {
            MsgBox("An automation named '" nm.fileBase "' already exists. Pick another name.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        ; Name the .lnk by SpaceOut(fileBase) — the same name Home's list,
        ; Home's Delete, and first-run reinstall all reconstruct — so they
        ; never drift (same rule SaveWorkflow follows; phrases with digits,
        ; like "Plan 9", don't round-trip through SpaceOut otherwise).
        disp := SpaceOut(nm.fileBase)
        vmDir := A_Programs "\Voice Macros"
        EnsureDir(vmDir)
        if FileExist(vmDir "\" disp ".lnk") {
            MsgBox("The voice phrase `"open " disp "`" is already taken by another entry. Pick another name.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        runArg := (InStr(target, " ") && FileExist(target)) ? '"' target '"' : target
        content := "#Requires AutoHotkey v2.0`n"
            . "#SingleInstance Force`n"
            . "; ============================================================`n"
            . ";  " nm.phrase "   (created " FormatTime(A_Now, "yyyy-MM-dd") ")`n"
            . ';  Trigger by voice:  "open ' nm.phrase '"`n'
            . ";  Opens:  " target "`n"
            . ";`n"
            . ";  Created by New Automation — no code needed. To add steps,`n"
            . ";  edit below (building blocks: templates\launch-template.ahk).`n"
            . "; ============================================================`n"
            . '#Include "%A_ScriptDir%\..\lib\_Common.ahk"`n'
            . "Run(" AhkStrLit(runArg) ")`n"
        FileAppend(content, newFile, "UTF-8")

        MakeAhkShortcut(vmDir "\" disp ".lnk", newFile)
        Log(root, "launch | " disp " | macros\" nm.fileBase ".ahk | opens " target)
        d.Destroy()
        DoneDialog("open " disp, "It opens:  " target, newFile)
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ShowModal(d, [exName, exTarget])
}

; ------------------------------------------------------------
;  2) Record My Steps — hand off to Workflow Studio, WITHOUT
;     killing a session that's already open (#SingleInstance
;     Force would silently discard unsaved recorded steps).
; ------------------------------------------------------------
OpenStudioSafely(root, draftFile := "") {
    if WinExist("Workflow Studio ahk_class AutoHotkeyGUI") {
        if (draftFile != "") {
            MsgBox("Workflow Studio is already open. Save or close it first, then try Draft With AI again.",
                "New Automation", "Icon! 262144")
            return false
        }
        WinActivate("Workflow Studio ahk_class AutoHotkeyGUI")
        return true
    }
    cmd := '"' A_AhkPath '" "' root '\macros\WorkflowStudio.ahk"'
    if (draftFile != "")
        cmd .= ' "' draftFile '"'
    Run(cmd)
    return true
}

; ------------------------------------------------------------
;  3) Type Text For Me — a snippet, one dialog, fully automated.
; ------------------------------------------------------------
NewSnippet(root, masterPath) {
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
        abbrev := RegExReplace(Trim(edAbbrev.Value), "\s", "")
        if (abbrev = "" || InStr(abbrev, ":")) {
            MsgBox("The abbreviation can't be empty or contain a colon (:) — a colon breaks the snippet format. Pick another.",
                "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        expansion := edText.Value
        if (Trim(expansion, " `t`r`n") = "") {
            MsgBox("Give it the text to expand into.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        ; A lone "{" would be parsed as an opening code block — the file then
        ; fails to load and takes EVERY hotkey and snippet down with it.
        if (Trim(expansion) = "{") {
            MsgBox("The text can't be just '{' — that's code syntax in the snippets file. Add the rest of the text.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        snipFile := root "\hotkeys\Snippets.ahk"
        if FileExist(snipFile) {
            Loop Parse FileRead(snipFile, "UTF-8"), "`n", "`r" {
                if (RegExMatch(A_LoopField, "^:\*?[^:]*:(.+?)::", &m) && m[1] = abbrev) {
                    MsgBox("A snippet  " abbrev "  already exists. Delete it first (say `"open voice kit`") or pick another abbreviation.", "New Automation", "Icon! Owner" d.Hwnd)
                    return
                }
            }
        }
        expansion := SnipEncode(expansion)                 ; multi-line -> `n; escape ` and ;
        FileAppend("`n:*:" abbrev "::" expansion, snipFile, "UTF-8")
        RunAhk(masterPath)               ; reload VoiceKit so it works immediately
        Log(root, "snippet | " abbrev)
        d.Destroy()
        d2 := Gui("+AlwaysOnTop", "New Automation")
        d2.SetFont("s10", "Segoe UI")
        d2.MarginX := 22, d2.MarginY := 18
        d2.SetFont("s13 bold")
        d2.AddText("xm", "Ready ✓")
        d2.SetFont("s10 norm")
        d2.AddText("xm y+10 w420", "Type  " abbrev "  anywhere and it expands immediately — no voice setup needed.")
        b := d2.AddButton("xm y+16 w130 h34 Default", "Done")
        b.OnEvent("Click", (*) => d2.Destroy())
        d2.OnEvent("Close", (*) => d2.Destroy())
        d2.OnEvent("Escape", (*) => d2.Destroy())
        ShowModal(d2)
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ShowModal(d, [exA, exB])
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
        if FileExist(newFile) {
            MsgBox("An automation named '" nm.fileBase "' already exists. Pick another name.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        disp := SpaceOut(nm.fileBase)          ; same naming rule as everywhere else
        vmDir := A_Programs "\Voice Macros"
        EnsureDir(vmDir)
        if FileExist(vmDir "\" disp ".lnk") {
            MsgBox("The voice phrase `"open " disp "`" is already taken by another entry. Pick another name.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }
        EnsureDir(root "\prompts")
        f := FileOpen(root "\prompts\" nm.fileBase ".prompt.txt", "w", "UTF-8")
        f.Write(prompt "`n")
        f.Close()
        tpl := FileRead(root "\templates\ai-template.ahk", "UTF-8")
        tpl := StrReplace(tpl, "{{PHRASE}}", nm.phrase)
        tpl := StrReplace(tpl, "{{BASE}}", nm.fileBase)
        tpl := StrReplace(tpl, "{{DATE}}", FormatTime(A_Now, "yyyy-MM-dd"))
        FileAppend(tpl, newFile, "UTF-8")
        MakeAhkShortcut(vmDir "\" disp ".lnk", newFile)
        Log(root, "ai-action | " disp " | macros\" nm.fileBase ".ahk")
        d.Destroy()
        DoneDialog("open " disp,
            "Select text first, then say it — the answer replaces the selection. The prompt is editable any time from Voice Kit (say “open voice kit”).")
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ShowModal(d, [how, exName, exPrompt])
}

; ------------------------------------------------------------
;  5) Draft With AI — describe it, review the steps in Studio.
; ------------------------------------------------------------
NewAIDraft(root) {
    ; Check Studio BEFORE spending an API call — launching it with a draft
    ; would replace (and silently discard) an already-open session.
    if WinExist("Workflow Studio ahk_class AutoHotkeyGUI") {
        MsgBox("Workflow Studio is already open. Save or close it first, then run Draft With AI again.",
            "New Automation", "Icon! 262144")
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

    OK(*) {
        desc := Trim(edDesc.Value, " `t`r`n")
        if (desc = "")
            return
        edDesc.Enabled := false
        btnOK.Enabled := false
        status.Text := "Drafting… (this takes a few seconds)"
        err := ""
        raw := AIComplete(DraftSystemPrompt(), desc, &err, 4096)
        if (raw = "") {
            status.Text := err
            edDesc.Enabled := true
            btnOK.Enabled := true
            return
        }
        perr := ""
        steps := ParseDraft(raw, &perr)
        if !IsObject(steps) {
            status.Text := perr " — click Draft It to retry."
            edDesc.Enabled := true
            btnOK.Enabled := true
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
        OpenStudioSafely(root, draftFile)
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ShowModal(d, [how, tips])
}

DraftSystemPrompt() {
    return "You convert a plain-English description of a Windows task into steps for a deterministic automation engine. "
        . "Reply with ONLY a JSON array - no markdown fences, no commentary. Each element is an object "
        . '{"type":"...","a":"...","b":"...","c":"..."}; unused fields may be omitted or "". All values must be strings.' "`n`n"
        . "Step types:`n"
        . "- run: a = program, file path, folder path, or https:// URL to open.`n"
        . "- focus: a = window to focus ('ahk_exe app.exe' or part of its title); b = command to launch it if it isn't running (optional).`n"
        . "- waitwin: a = window to wait for; b = timeout in seconds (optional, default 10).`n"
        . "- wait: a = milliseconds to pause.`n"
        . "- text: a = text to type into the focused window.`n"
        . "- ask: a = a short label for a value the USER should supply when the workflow runs (e.g. 'Customer name'); b = suggested answer (optional). All ask inputs are collected in dialogs before the run starts, and the answer is typed into the focused window at this step's position. Use ask instead of text whenever the description implies the value changes each run.`n"
        . "- keys: a = keys in AutoHotkey v2 Send syntax, e.g. {Enter}, {Tab 2}, ^s.`n"
        . "- click / dblclick / rclick: a = window; b = the EXACT on-screen name of the thing to click (button caption, link text, menu item).`n"
        . "- hover: a = window; b = the on-screen name to rest the mouse over (moves there and pauses so a hover menu/tooltip appears; follow with a click on what it reveals).`n"
        . "- move: a = window; b = one of left, right, top, bottom, max.`n"
        . "- close: a = window to close.`n"
        . '- if: a = window; b = element name ("" unless the condition checks an element); c = one of winexists, winnotexists, elementexists, elementnotexists.' "`n"
        . "- else: no fields. endif: no fields.`n`n"
        . "Rules:`n"
        . "- Every if needs a matching endif (else is optional). Only branch when the description clearly needs it.`n"
        . "- After a run/focus that launches an app, add waitwin (preferred) or wait 800-1500 ms before typing or clicking.`n"
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
    validTypes := Map("run",1, "focus",1, "waitwin",1, "wait",1, "text",1, "ask",1, "keys",1,
        "click",1, "dblclick",1, "rclick",1, "hover",1, "move",1, "close",1, "if",1, "else",1, "endif",1)
    validConds := Map("winexists",1, "winnotexists",1, "elementexists",1, "elementnotexists",1)
    steps := []
    for i, el in arr {
        if !(el is Map) {
            perr := "Draft step " i " wasn't an object"
            return ""
        }
        ok := true
        t := StrLower(DraftField(el, "type", &ok))
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
        if (t = "if") {
            c := StrLower(c)
            if !validConds.Has(c) {
                perr := "Draft step " i " has a bad if-condition ('" c "')"
                return ""
            }
        } else if (t != "click" && t != "dblclick" && t != "rclick" && t != "hover")
            c := ""                       ; paramC is only meaningful for if + click/hover steps
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
NewHotkeyModule(root, masterPath) {
    d := Gui("+AlwaysOnTop", "New Automation — Always-On Hotkey")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "An always-on key combo")
    d.SetFont("s10 norm")
    how := d.AddText("xm y+4 w500", "VoiceKit assigns a free Ctrl+Alt+Shift key. Pairing a voice phrase to it is one manual step at the end (~30 seconds — Windows allows no shortcut API).")
    d.AddText("xm y+14", "Name it — also the suggested voice phrase:")
    edName := d.AddEdit("xm y+4 w500")
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
        mapFile := root "\bridge-map.txt"
        key := AllocateBridgeKey(mapFile)
        if (key = "") {
            MsgBox("No free bridge keys left. Retire something in bridge-map.txt first.", "New Automation", "Icon! Owner" d.Hwnd)
            return
        }

        if rCode.Value {
            tpl := FileRead(root "\templates\hotkey-template.ahk", "UTF-8")
            tpl := StrReplace(tpl, "{{PHRASE}}", nm.phrase)
            tpl := StrReplace(tpl, "{{KEY}}", key)
            tpl := StrReplace(tpl, "{{DATE}}", FormatTime(A_Now, "yyyy-MM-dd"))
            FileAppend(tpl, newFile, "UTF-8")
        } else {
            if rOpen.Value {
                runArg := (InStr(target, " ") && FileExist(target)) ? '"' target '"' : target
                actionLine := "Run(" AhkStrLit(runArg) ")"
                actionDesc := "Opens:  " target
            } else {
                actionLine := "SendText(" AhkStrLit(target) ")"
                actionDesc := "Types the saved text"
            }
            content := "#Requires AutoHotkey v2.0`n"
                . "; ============================================================`n"
                . ";  " nm.phrase "   (created " FormatTime(A_Now, "yyyy-MM-dd") ")`n"
                . ";  Loaded by VoiceKit.ahk — do not run this file directly.`n"
                . ";  Trigger key:  Ctrl+Alt+Shift+" key "`n"
                . ";  " actionDesc "`n"
                . ";`n"
                . ";  Voice pairing (one-time, ~30 sec):`n"
                . ';    1. Say: "show voice shortcuts"`n'
                . ";    2. Create new shortcut  ->  When I say:  " nm.phrase "`n"
                . ";    3. Action: Press keys   ->  Ctrl + Alt + Shift + " key "`n"
                . ";  This pairing is recorded in bridge-map.txt.`n"
                . "; ============================================================`n`n"
                . "^!+" key ":: {`n"
                . "    " actionLine "`n"
                . "}`n"
            FileAppend(content, newFile, "UTF-8")
        }

        BridgeRegisterModule(root, key, nm.phrase, "hotkeys\" nm.fileBase ".ahk")
        RunAhk(masterPath)               ; reload VoiceKit so the hotkey is live now
        Log(root, "hotkey | " nm.phrase " | Ctrl+Alt+Shift+" key " | hotkeys\" nm.fileBase ".ahk")
        if rCode.Value
            Run('notepad.exe "' newFile '"')
        d.Destroy()
        PairingDialog(nm.phrase, key)
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    SyncFields()
    ShowModal(d, [how])
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
    ShowModal(d, [lead, tail])
}

; First free key from the shared pool (lib\_Common.ahk BridgeKeyPool —
; E, N, R, X, H, I reserved; companion hotkeys assigned in Voice Kit draw
; from the same pool, so the registry keeps everyone honest).
AllocateBridgeKey(mapFile) {
    free := BridgeFreeKeys(mapFile)
    return free.Length ? free[1] : ""
}
