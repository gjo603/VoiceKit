#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Workflow Studio — build, record, test and save multi-step
;  workflows in a dialog. No code required.
;
;  Open it by voice:  "open workflow studio"
;  (or: New Automation -> Step Workflow Recording)
;
;  Record captures what you actually do:
;    - window switches            -> Focus steps
;    - clicks (double/right too)  -> Click steps, stored by the
;      clicked element's on-screen NAME (button caption, link,
;      file name), with the raw position kept only as fallback
;    - double-clicking a file in Explorer -> "Open <full path>"
;    - typing                     -> editable Type-text steps
;    - special keys / shortcuts   -> Press-keys steps
;  While recording, the Studio hides and a small REC bar floats
;  bottom-left; finish with its Stop button, by voice ("click
;  stop"), or with Ctrl+Alt+Shift+X.
;
;  Then Test plays it, and Save makes it a voice command:
;  "open <name>". Reopen the Studio any time to edit.
;
;  Don't type passwords while recording — keystrokes become
;  visible steps (that's the point, but remember it).
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"

CoordMode("Mouse", "Screen")

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
EnsureDir(root "\workflows")
EnsureStudioShortcut()

; ---- state ----
steps := []             ; array of [type, paramA, paramB, paramC]
currentPhrase := ""     ; name of the loaded workflow ("" = new)
dirty := false
recording := false
recLastHwnd := 0
recLastCrit := ""
dialogOpen := false
prevIndex := 1
ddlMap := Map()         ; DDL display text -> steps-file base name
ih := ""                ; InputHook while recording
typedBuf := ""          ; keystrokes waiting to become a Type step
lastCharTick := 0
lastClick := {tick: 0, x: 0, y: 0, idx: 0}

; Advanced if/else/endif entries live at the END so they're never the default
; and don't clutter ordinary recording. The four "if" rows all save as type
; "if"; typeConds carries the condition kind (paramC of the step).
typeIds    := ["focus", "run", "waitwin", "wait", "text", "keys", "click", "dblclick", "rclick", "move", "close"
             , "if", "if", "if", "if", "else", "endif"]
typeConds  := ["", "", "", "", "", "", "", "", "", "", ""
             , "winexists", "winnotexists", "elementexists", "elementnotexists", "", ""]
typeLabels := ["Focus window (launch it if needed)"
             , "Open app / file / website"
             , "Wait for a window to appear"
             , "Wait (pause for milliseconds)"
             , "Type text"
             , "Press keys (e.g. {Enter}, ^s)"
             , "Left-click something in a window (by its name)"
             , "Double-click something in a window"
             , "Right-click something in a window"
             , "Position window (left / right / top / bottom / max)"
             , "Close window"
             , "— If a window IS open …"
             , "— If a window is NOT open …"
             , "— If something IS on screen …"
             , "— If something is NOT on screen …"
             , "— Otherwise (else) …"
             , "— End if"]

; ---- click capture + stop hotkey (active only while recording) ----
#HotIf recording
~*LButton:: RecClick("L")
~*RButton:: RecClick("R")
^!+x:: StopRecording()      ; backup stop — works even if the REC bar is covered
#HotIf

; ---- main window ----
; Layout: a header (which workflow), the step list, a compact toolbar
; for editing steps, then a prominent row for the three actions that
; matter (Record / Test / Save). Every button keeps a real word in its
; caption so Voice Access can still click it ("click record", etc.);
; the leading glyph is decoration only. See lib\Theme.ahk for the look.
g := Gui("+AlwaysOnTop", "Workflow Studio")
g.SetFont("s10", "Segoe UI")
g.MarginX := 16, g.MarginY := 14
g.AddText("xm ym+6", "Workflow:")
ddl := g.AddDropDownList("x+10 yp-4 w468", [])
btnDel := g.AddButton("x+10 yp-1 w120", "Delete")

lv := g.AddListView("xm y+14 w720 r13 -Multi Grid NoSortHdr NoSort", ["#", "Step"])

g.SetFont("s9")
btnAdd  := g.AddButton("xm y+10 w96 h30",  "＋  Add")
btnEdit := g.AddButton("x+6 w96 h30",      "✎  Edit")
btnRem  := g.AddButton("x+6 w112 h30",     "✕  Remove")
btnUp   := g.AddButton("x+22 w96 h30",     "↑  Up")
btnDown := g.AddButton("x+6 w96 h30",      "↓  Down")

g.SetFont("s10")
chkCloseTabs := g.AddCheckBox("xm y+14", "Close browser tabs before recording")

g.SetFont("s11")
btnRec  := g.AddButton("xm y+8 w214 h44 Default", "●  Record (F9)")   ; Default: Enter starts recording
btnTest := g.AddButton("x+12 w150 h44",   "▶  Test")
btnSave := g.AddButton("x+12 w214 h44",   "🖫  Save")

g.SetFont("s9")
statusBar := g.AddText("xm y+14 w648 h30", "")
btnHelp := g.AddButton("x+8 yp w64 h30", "Help")

; ---- floating REC bar (shown while recording) ----
recBar := Gui("+AlwaysOnTop +ToolWindow -Caption +Border")
recBar.MarginX := 14
recBar.MarginY := 11
recBar.SetFont("s10 bold cRed", "Segoe UI")
recBar.AddText("ym", "●  REC")
recBar.SetFont("s10 norm", "Segoe UI")
recNote := recBar.AddText("x+12 yp w340", "Recording...")
recCount := recBar.AddText("x+8 yp w70 Right", "0 steps")
recBar.SetFont("s11 bold", "Segoe UI")
btnStop := recBar.AddButton("x+12 yp-8 w120 h36 Default", "■  Stop Recording")
btnStop.OnEvent("Click", (*) => StopRecording())
recBar.SetFont("s10 norm", "Segoe UI")
ThemeBar(recBar, recNote, recCount, btnStop)   ; keep the "REC" label red — set at build time above

ddl.OnEvent("Change", PickWorkflow)
btnDel.OnEvent("Click", DeleteWorkflow)
lv.OnEvent("DoubleClick", EditStep)
btnAdd.OnEvent("Click", AddStep)
btnEdit.OnEvent("Click", EditStep)
btnRem.OnEvent("Click", RemoveStep)
btnUp.OnEvent("Click", MoveUp)
btnDown.OnEvent("Click", MoveDown)
btnRec.OnEvent("Click", (*) => StartRecording())
btnTest.OnEvent("Click", TestRun)
btnSave.OnEvent("Click", SaveWorkflow)
btnHelp.OnEvent("Click", ShowHelp)
chkCloseTabs.OnEvent("Click", SaveSettings)
g.OnEvent("Close", CloseStudio)

; ---- F9 starts recording while the main Studio window is active ----
; (scoped by hwnd so it never fires on a dialog, MsgBox, or edit field)
#HotIf WinActive("ahk_id " g.Hwnd)
F9:: StartRecording()
#HotIf

RefreshWorkflowList()
NewWorkflowState()
LoadSettings()
ThemeApply(g, statusBar)
g.Show()
btnRec.Focus()           ; land on Record so pressing Enter starts recording
OfferRecovery()          ; restore an interrupted recording, if any

; ============================================================
;  Workflow list / load / new
; ============================================================
RefreshWorkflowList(selectDisplay := "") {
    global ddl, ddlMap, root, prevIndex
    ddlMap := Map()
    items := ["New workflow..."]
    Loop Files root "\workflows\*.steps.txt" {
        base := StrReplace(A_LoopFileName, ".steps.txt")
        disp := SpaceOut(base)
        ddlMap[disp] := base
        items.Push(disp)
    }
    ddl.Delete()
    ddl.Add(items)
    pick := 1
    for i, it in items
        if (it = selectDisplay)
            pick := i
    ddl.Choose(pick)
    prevIndex := pick
}

PickWorkflow(*) {
    global ddl, ddlMap, dirty, prevIndex
    if (ddl.Value = prevIndex)
        return
    if (dirty && !ConfirmDiscard()) {
        ddl.Choose(prevIndex)
        return
    }
    prevIndex := ddl.Value
    sel := ddl.Text
    if ddlMap.Has(sel)
        LoadWorkflow(ddlMap[sel])
    else
        NewWorkflowState()
}

LoadWorkflow(base) {
    global steps, currentPhrase, dirty, root
    steps := WorkflowLoad(root "\workflows\" base ".steps.txt")
    currentPhrase := SpaceOut(base)
    dirty := false
    RefreshLV()
    SB("Loaded '" currentPhrase "' — " steps.Length " steps. Say `"open " currentPhrase "`" to run it any time.")
}

NewWorkflowState() {
    global steps, currentPhrase, dirty
    steps := []
    currentPhrase := ""
    dirty := false
    RefreshLV()
    SB("New workflow — click Record and just do the thing, or build it up with Add.")
}

; ============================================================
;  Step list editing
; ============================================================
RefreshLV() {
    global lv, steps
    lv.Delete()
    depth := 0
    for i, s in steps {
        t := s[1]
        shown := (t = "else" || t = "endif") ? Max(0, depth - 1) : depth   ; dedent else/endif
        indent := ""
        Loop shown
            indent .= "      "
        lv.Add(, i, indent WfDesc(s))
        if (t = "if")
            depth += 1
        else if (t = "endif")
            depth := Max(0, depth - 1)
    }
    lv.ModifyCol(1, 44)
    lv.ModifyCol(2, 656)
}

SelectedRow() {
    global lv
    return lv.GetNext(0)
}

AddStep(*) {
    global steps, dirty, lv
    st := StepDialog()
    if !IsObject(st)
        return
    r := SelectedRow()
    idx := r ? r + 1 : steps.Length + 1
    steps.InsertAt(idx, st)
    dirty := true
    RefreshLV()
    lv.Modify(idx, "Select Focus Vis")
    SB("Added step " idx " of " steps.Length ". New steps insert after the selected row.")
}

EditStep(*) {
    global steps, dirty, lv
    r := SelectedRow()
    if !r {
        SB("Select a step first (click its row).")
        return
    }
    st := StepDialog(steps[r])
    if !IsObject(st)
        return
    steps[r] := st
    dirty := true
    RefreshLV()
    lv.Modify(r, "Select Focus Vis")
    SB("Updated step " r ".")
}

RemoveStep(*) {
    global steps, dirty, lv
    r := SelectedRow()
    if !r {
        SB("Select a step first (click its row).")
        return
    }
    steps.RemoveAt(r)
    dirty := true
    RefreshLV()
    if steps.Length
        lv.Modify(Min(r, steps.Length), "Select Focus Vis")
    SB("Removed step " r ".")
}

MoveUp(*) {
    global steps, dirty, lv
    r := SelectedRow()
    if (r <= 1) {
        SB(r ? "Already at the top." : "Select a step first.")
        return
    }
    tmp := steps[r - 1]
    steps[r - 1] := steps[r]
    steps[r] := tmp
    dirty := true
    RefreshLV()
    lv.Modify(r - 1, "Select Focus Vis")
}

MoveDown(*) {
    global steps, dirty, lv
    r := SelectedRow()
    if (!r || r >= steps.Length) {
        SB(r ? "Already at the bottom." : "Select a step first.")
        return
    }
    tmp := steps[r + 1]
    steps[r + 1] := steps[r]
    steps[r] := tmp
    dirty := true
    RefreshLV()
    lv.Modify(r + 1, "Select Focus Vis")
}

; ============================================================
;  Add / Edit step dialog
; ============================================================
StepDialog(existing := "") {
    global g, dialogOpen, typeIds, typeLabels, typeConds
    dialogOpen := true
    result := ""
    preservedC := (IsObject(existing) && existing.Length >= 4) ? existing[4] : ""

    d := Gui("+AlwaysOnTop +Owner" g.Hwnd, IsObject(existing) ? "Edit Step" : "Add Step")
    d.SetFont("s10", "Segoe UI")
    d.AddText("xm", "Action:")
    dt := d.AddDropDownList("xm w480", typeLabels)
    laA := d.AddText("xm y+12 w480", "")
    edA := d.AddEdit("xm w480")
    laB := d.AddText("xm y+10 w480", "")
    edB := d.AddEdit("xm w480")
    btnGrab := d.AddButton("xm y+12 w210", "Grab a Window (3 sec)")
    btnPick := d.AddButton("x+8 w210", "Pick element (3 sec)")
    btnBrowse := d.AddButton("xm yp w180", "Browse for File...")   ; same row; shown only for 'run'
    btnOK := d.AddButton("xm y+14 w120 Default", "OK")
    btnCancel := d.AddButton("x+8 w120", "Cancel")

    UpdateFields(*) {
        t := typeIds[dt.Value], cond := typeConds[dt.Value]
        ; else / endif are block markers — no fields at all.
        if (t = "else" || t = "endif") {
            laA.Visible := edA.Visible := laB.Visible := edB.Visible := false
            btnGrab.Visible := btnPick.Visible := btnBrowse.Visible := false
            return
        }
        ; if: a window to check for, plus an element name for the "on screen" tests.
        if (t = "if") {
            needElem := (cond = "elementexists" || cond = "elementnotexists")
            laA.Text := "Window to check for — 'ahk_exe app.exe' or part of its title:"
            laA.Visible := edA.Visible := true
            laB.Text := "Name of the thing to check for, exactly as shown on screen:"
            laB.Visible := edB.Visible := needElem
            btnGrab.Visible := true          ; Grab fills in the window for you
            btnPick.Visible := needElem      ; Pick fills in the element (and its window)
            btnBrowse.Visible := false
            return
        }
        labels := Map(
            "focus",    ["Window to focus — 'ahk_exe app.exe' or part of its title:",
                         "If it isn't running, launch this (path or command) — optional:"],
            "run",      ["What to open — a program, file, folder path, or https:// address:", ""],
            "waitwin",  ["Window to wait for (it gets focused when it appears):",
                         "Give up after this many seconds (blank = 10):"],
            "wait",     ["How long to pause, in milliseconds (1000 = 1 second):", ""],
            "text",     ["Text to type into the focused window:", ""],
            "keys",     ["Keys to press — AHK v2 syntax, e.g. {Enter}, {Tab 2}, ^s:", ""],
            "click",    ["Window:", "What to click — its name exactly as shown on screen:"],
            "dblclick", ["Window:", "What to double-click — its name exactly as shown on screen:"],
            "rclick",   ["Window:", "What to right-click — its name exactly as shown on screen:"],
            "move",     ["Window to position:", "Where: left / right / top / bottom / max"],
            "close",    ["Window to close:", ""])
        needB := (labels[t][2] != "")
        laA.Text := labels[t][1]
        laA.Visible := edA.Visible := true
        laB.Text := labels[t][2]
        laB.Visible := needB
        edB.Visible := needB
        btnGrab.Visible := (t != "run" && t != "wait" && t != "text" && t != "keys")
        btnPick.Visible := (t = "click" || t = "dblclick" || t = "rclick")   ; element-name steps
        btnBrowse.Visible := (t = "run")
    }

    Grab(*) {
        Loop 3 {
            ToolTip("Click / focus the window you want...  " (4 - A_Index))
            Sleep(1000)
        }
        ToolTip()
        info := ClassifyWindow(WinExist("A"))
        if !IsObject(info) {
            MsgBox("Couldn't use that window (it may be VoiceKit's own, or the desktop). Try again.", "Grab a Window", "Owner" d.Hwnd)
            return
        }
        edA.Value := info.crit
        if (typeIds[dt.Value] = "focus" && info.cmd != "")
            edB.Value := info.cmd
        WinActivate("ahk_id " d.Hwnd)
    }

    ; Point at an on-screen element and capture its accessible NAME (the same
    ; name playback matches on) into the element box — and its window into the
    ; window box. The dialog hides during the countdown so it isn't in the way.
    Pick(*) {
        d.Hide()
        g.Hide()                                   ; the always-on-top Studio would cover the target
        Loop 3 {
            ToolTip("Point the mouse at the thing, then wait...  " (4 - A_Index))
            Sleep(1000)
        }
        ToolTip()
        MouseGetPos(&mx, &my, &winHwnd)
        el := AccFromPoint(mx, my)                 ; query while the windows are hidden
        info := ClassifyWindow(winHwnd)            ; "" for VoiceKit's own window / desktop / shell
        g.Show()
        d.Show()
        WinActivate("ahk_id " d.Hwnd)
        if !IsObject(info) {
            MsgBox("Point at your app's window — not VoiceKit or the desktop. Try again.", "Pick element", "Owner" d.Hwnd)
            return
        }
        name := IsObject(el) ? AccName(el.acc, el.child) : ""
        if (name = "") {
            MsgBox("Couldn't read a name there. Point at a button, link, menu item or other labeled control — or type its name.", "Pick element", "Owner" d.Hwnd)
            return
        }
        edB.Value := name
        if (edA.Value = "")                         ; also capture the window it's in, if not set yet
            edA.Value := info.crit
    }

    Browse(*) {
        f := FileSelect(3, , "Pick the file to open")
        if (f != "")
            edA.Value := f
    }

    OK(*) {
        t := typeIds[dt.Value], cond := typeConds[dt.Value]
        ; else / endif: block markers with no params.
        if (t = "else" || t = "endif") {
            result := [t, "", "", ""]
            d.Destroy()
            return
        }
        a := Trim(edA.Value)
        b := Trim(edB.Value)
        ; if: window required; element required for the "on screen" conditions.
        if (t = "if") {
            if (a = "") {
                MsgBox("Give the window to check for.", "Add Step", "Owner" d.Hwnd)
                return
            }
            needElem := (cond = "elementexists" || cond = "elementnotexists")
            if (needElem && b = "") {
                MsgBox("Give the name of the thing to check for, as shown on screen.", "Add Step", "Owner" d.Hwnd)
                return
            }
            result := ["if", a, (needElem ? b : ""), cond]     ; if|window|element|condType
            d.Destroy()
            return
        }
        if (a = "") {
            MsgBox("Fill in the first box.", "Add Step", "Owner" d.Hwnd)
            return
        }
        if (t = "wait" && !IsInteger(a)) {
            MsgBox("Milliseconds must be a whole number, e.g. 1500.", "Add Step", "Owner" d.Hwnd)
            return
        }
        if (t = "waitwin" && b != "" && !IsInteger(b)) {
            MsgBox("The timeout must be a whole number of seconds, or blank.", "Add Step", "Owner" d.Hwnd)
            return
        }
        if (t = "move") {
            b := StrLower(b = "" ? "left" : b)
            if !(b ~= "^(left|right|top|bottom|max)$") {
                MsgBox("Position must be one of: left, right, top, bottom, max.", "Add Step", "Owner" d.Hwnd)
                return
            }
        }
        isClick := (t = "click" || t = "dblclick" || t = "rclick")
        if (isClick && b = "" && preservedC = "") {
            MsgBox("Give the element's name as shown on screen — or record the click instead.", "Add Step", "Owner" d.Hwnd)
            return
        }
        if !(t = "focus" || t = "waitwin" || t = "move" || isClick)
            b := ""
        result := [t, a, b, isClick ? preservedC : ""]
        d.Destroy()
    }

    dt.OnEvent("Change", UpdateFields)
    btnGrab.OnEvent("Click", Grab)
    btnPick.OnEvent("Click", Pick)
    btnBrowse.OnEvent("Click", Browse)
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())

    if IsObject(existing) {
        idx := 1
        exCond := (existing.Length >= 4) ? existing[4] : ""
        for i, id in typeIds {
            if (id != existing[1])
                continue
            if (id = "if") {                 ; pick the if-row whose condition matches
                if (typeConds[i] = exCond)
                    idx := i
            } else
                idx := i
        }
        dt.Choose(idx)
        UpdateFields()
        edA.Value := existing[2]
        edB.Value := existing[3]
    } else {
        dt.Choose(1)
        UpdateFields()
    }

    RunOwnedDialog(d)               ; show modally over the Studio, then refocus it
    dialogOpen := false
    return result
}

; ============================================================
;  Save-name dialog — themed replacement for InputBox.
; ============================================================
SaveNameDialog(defaultName := "") {
    global g
    result := ""

    d := Gui("+AlwaysOnTop +Owner" g.Hwnd, "Save Workflow")
    d.SetFont("s10", "Segoe UI")
    d.AddText("xm ym w420", "Name this workflow — the name becomes its voice phrase:")
    d.SetFont("s10 italic", "Segoe UI")
    d.AddText("xm y+6 w420", "`"open <name>`"")
    d.SetFont("s10 norm", "Segoe UI")
    edName := d.AddEdit("xm y+12 w420", defaultName)
    btnOK := d.AddButton("xm y+14 w120 Default", "OK")
    btnCancel := d.AddButton("x+8 w120", "Cancel")

    OK(*) {
        v := Trim(edName.Value)
        if (v = "")
            return
        result := CleanPhrase(v)
        d.Destroy()
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())

    RunOwnedDialog(d)
    return result
}

; Show an owned dialog modally over the Studio: theme it, show and focus it,
; disable the Studio behind it, wait for it to close, then re-enable + refocus.
RunOwnedDialog(d) {
    global g
    ThemeApply(d)
    d.Show()
    g.Opt("+Disabled")
    WinActivate("ahk_id " d.Hwnd)
    WinWaitClose("ahk_id " d.Hwnd)
    g.Opt("-Disabled")
    WinActivate("ahk_id " g.Hwnd)
}

; ============================================================
;  Recorder — captures window switches, clicks and typing.
;  Clicks are stored by accessible element NAME (position kept
;  only as fallback); keystrokes become visible, editable steps.
; ============================================================
StartRecording() {
    global recording, recLastHwnd, recLastCrit, typedBuf, lastClick, g, recBar, chkCloseTabs, steps
    if recording
        return
    ; Recording APPENDS to the current step list, so an accidental start
    ; (Enter on the Default button, F9, a stray click) on a loaded or
    ; in-progress workflow would tack junk on — and Save could then overwrite
    ; the saved file. Confirm when there's already something to append to.
    if (steps.Length > 0
        && MsgBox("Add recorded steps to the end of this workflow (" steps.Length " so far)?",
                  "Record", "YesNo Icon? Owner" g.Hwnd) != "Yes")
        return
    ; Optional clean slate: close existing browser windows first, so the
    ; recording starts from a fresh browser instead of whatever tabs were
    ; already open (which shift positions and break playback). Done before
    ; we start capturing, so none of this closing is recorded as steps.
    if chkCloseTabs.Value {
        g.Hide()                     ; so the always-on-top Studio can't hide a browser's prompt
        CloseBrowserTabs()
    }
    recording := true
    typedBuf := ""
    recLastHwnd := 0
    recLastCrit := ""
    lastClick := {tick: 0, x: 0, y: 0, idx: 0}
    StartKeyHook()
    g.Hide()
    UpdateRecBar("Recording — stop: Stop button or Ctrl+Alt+Shift+X")
    ShowBottomLeft(recBar)                    ; bottom-left, clear of the taskbar
    SetTimer(RecTick, 250)
}

StopRecording() {
    global recording, steps, lv, g, recBar, btnRec
    if !recording
        return
    recording := false
    SetTimer(RecTick, 0)
    StopKeyHook()
    FlushTypedText()
    recBar.Hide()
    RefreshLV()
    g.Show()
    WinActivate("ahk_id " g.Hwnd)
    if steps.Length
        lv.Modify(steps.Length, "Select Focus Vis")
    SB("Recorded — trim or edit steps, add waits if needed, then click Test and Save.")
}

RecPush(step, note) {
    global steps, dirty
    steps.Push(step)
    dirty := true
    UpdateRecBar(note)
    WriteAutosave()
}

UpdateRecBar(note) {
    global recNote, recCount, steps
    recNote.Text := Abbrev(note, 52)
    recCount.Text := steps.Length " steps"
}

; ---- crash-safe autosave of an in-progress recording ----
; #SingleInstance Force means re-launching the Studio kills this instance;
; if that happens mid-recording the steps would be lost. Mirror them to a
; recovery file after each captured step (same format as a saved workflow,
; via the engine's WfEncode) and offer to restore on the next launch. The
; file lives in logs\ so it never shows up in the workflow dropdown, and is
; cleared on a clean save or a clean close — so its presence means "an
; interrupted session left unsaved steps".
AutosaveFile() {
    global root
    return root "\logs\recording.autosave"
}
WriteAutosave() {
    global steps
    if !steps.Length
        return
    content := "; VoiceKit recording autosave`n"
    for s in steps
        content .= s[1] "|" WfEncode(s[2]) "|" WfEncode(s[3]) "|" WfEncode(s.Length >= 4 ? s[4] : "") "`n"
    try {
        EnsureDir(RegExReplace(AutosaveFile(), "\\[^\\]+$"))
        f := FileOpen(AutosaveFile(), "w", "UTF-8")
        f.Write(content)
        f.Close()
    }
}
ClearAutosave() {
    try FileDelete(AutosaveFile())
}
OfferRecovery() {
    global steps, dirty, g
    if !FileExist(AutosaveFile())
        return
    recovered := WorkflowLoad(AutosaveFile())   ; reuse the engine's parser
    if !recovered.Length {
        ClearAutosave()
        return
    }
    if (MsgBox("A recording from an interrupted session was found ("
        recovered.Length " steps). Recover it?", "Workflow Studio", "YesNo Icon? Owner" g.Hwnd) = "Yes") {
        steps := recovered
        dirty := true
        RefreshLV()
        SB("Recovered " steps.Length " steps — review them, then click Save.")
    } else {
        ClearAutosave()
    }
}

RecTick() {
    global recording, typedBuf, lastCharTick, recLastHwnd, recLastCrit
    if !recording
        return
    if (typedBuf != "" && A_TickCount - lastCharTick > 1500)
        FlushTypedText()
    hwnd := WinExist("A")
    if (!hwnd || hwnd = recLastHwnd)
        return
    recLastHwnd := hwnd
    info := ClassifyWindow(hwnd)
    if (!IsObject(info) || info.crit = recLastCrit)
        return
    FlushTypedText()
    recLastCrit := info.crit
    RecPush(["focus", info.crit, info.cmd, ""], "Switch to " info.crit)
}

RecClick(btn) {
    global recording, steps, recLastHwnd, recLastCrit, lastClick
    if !recording
        return
    MouseGetPos(&mx, &my, &hwnd)
    info := ClassifyWindow(hwnd)
    if !IsObject(info)
        return
    FlushTypedText()
    if (info.crit != recLastCrit) {
        RecPush(["focus", info.crit, info.cmd, ""], "Switch to " info.crit)
        recLastCrit := info.crit
        recLastHwnd := hwnd
    }
    now := A_TickCount
    if (btn = "L" && lastClick.idx && lastClick.idx <= steps.Length
        && now - lastClick.tick < DllCall("GetDoubleClickTime")
        && Abs(mx - lastClick.x) < 8 && Abs(my - lastClick.y) < 8
        && steps[lastClick.idx][1] = "click") {
        ; second click of a double-click: upgrade the recorded step
        steps[lastClick.idx][1] := "dblclick"
        path := ExplorerSelection(hwnd)
        if (path != "") {
            steps[lastClick.idx] := ["run", path, "", ""]
            UpdateRecBar("Open " path)
        } else {
            UpdateRecBar("Double-click " steps[lastClick.idx][3])
        }
        WriteAutosave()
        lastClick := {tick: 0, x: 0, y: 0, idx: 0}
        return
    }
    elem := ""
    ap := AccFromPoint(mx, my)
    if IsObject(ap)
        elem := AccName(ap.acc, ap.child)
    if (StrLen(elem) > 100)                 ; paragraph-length names aren't stable selectors
        elem := ""
    WinGetPos(&wx, &wy, , , hwnd)
    rel := (mx - wx) "," (my - wy)
    stepType := (btn = "R") ? "rclick" : "click"
    RecPush([stepType, info.crit, elem, rel],
        (btn = "R" ? "Right-click " : "Click ") (elem != "" ? "`"" elem "`"" : "at " rel))
    if (btn = "L")
        lastClick := {tick: now, x: mx, y: my, idx: steps.Length}
}

; Full path of the item selected in an Explorer window, or "".
ExplorerSelection(hwnd) {
    try {
        for w in ComObject("Shell.Application").Windows {
            if (w.HWND = hwnd) {
                items := w.Document.SelectedItems()
                if (items.Count >= 1)
                    return items.Item(0).Path
            }
        }
    }
    return ""
}

; Full path of the folder an Explorer window is showing, or "".
ExplorerPath(hwnd) {
    try {
        for w in ComObject("Shell.Application").Windows {
            if (w.HWND = hwnd)
                return w.Document.Folder.Self.Path
        }
    }
    return ""
}

; ---- keyboard capture ----
StartKeyHook() {
    global ih, recording
    ih := InputHook("V")                    ; V: observe, never block keys
    ih.KeyOpt("{All}", "N")
    ih.OnChar := RecChar
    ih.OnKeyDown := RecKeyDown
    ih.OnEnd := (h) => (recording ? h.Start() : 0)   ; restart if buffer limit ends it
    ih.Start()
}

StopKeyHook() {
    global ih
    if IsObject(ih)
        try ih.Stop()
    ih := ""
}

RecChar(h, char) {
    global recording, typedBuf, lastCharTick
    if (!recording || Ord(char) < 32)
        return
    if !IsObject(ClassifyWindow(WinExist("A")))   ; ignore typing into Start menu / own UI
        return
    typedBuf .= char
    lastCharTick := A_TickCount
    UpdateRecBar("Typing: `"" typedBuf "`"")
}

RecKeyDown(h, vk, sc) {
    global recording, typedBuf
    if !recording
        return
    key := GetKeyName(Format("vk{:x}sc{:x}", vk, sc))
    if (key = "" || key ~= "i)^(L|R)?(Shift|Ctrl|Control|Alt|Win)$")
        return
    if !IsObject(ClassifyWindow(WinExist("A")))
        return
    ctrl := GetKeyState("Ctrl")
    alt := GetKeyState("Alt")
    win := GetKeyState("LWin") || GetKeyState("RWin")
    shift := GetKeyState("Shift")
    if (key = "x" && ctrl && alt && shift)
        return                              ; the stop-recording hotkey, not a workflow step
    mods := (ctrl ? "^" : "") (alt ? "!" : "") (win ? "#" : "")
    if (key = "Backspace" && mods = "") {
        if (typedBuf != "") {               ; natural correction: un-type the last char
            typedBuf := SubStr(typedBuf, 1, -1)
            UpdateRecBar("Typing: `"" typedBuf "`"")
        } else {
            RecPush(["keys", "{Backspace}", "", ""], "Press Backspace")
        }
        return
    }
    isSpecial := key ~= "i)^(Enter|NumpadEnter|Tab|Escape|Backspace|Delete|Del|Insert|Ins|Home|End|PgUp|PgDn|Up|Down|Left|Right|AppsKey|PrintScreen|Pause|F\d\d?)$"
    if (mods = "" && !isSpecial)
        return                              ; plain character — OnChar records it
    if (mods != "" && !isSpecial && StrLen(key) != 1)
        return                              ; modifier + exotic key (volume etc.) — skip
    FlushTypedText()
    combo := mods (shift ? "+" : "") "{" key "}"
    RecPush(["keys", combo, "", ""], "Press " combo)
}

FlushTypedText() {
    global typedBuf
    if (typedBuf = "")
        return
    RecPush(["text", typedBuf, "", ""], "Typed `"" typedBuf "`"")
    typedBuf := ""
}

; Identify a window for focusing later; "" = not usable (our own
; GUI, the taskbar/desktop, Voice Access itself, etc.).
ClassifyWindow(hwnd) {
    if !hwnd
        return ""
    try {
        pid := WinGetPID(hwnd)
        exe := WinGetProcessName(hwnd)
        cls := WinGetClass(hwnd)
        title := WinGetTitle(hwnd)
    } catch
        return ""
    if (pid = DllCall("GetCurrentProcessId"))
        return ""
    if (cls = "" || cls ~= "^(Shell_TrayWnd|Progman|WorkerW|NotifyIconOverflowWindow|Windows\.UI\.Core\.CoreWindow|XamlExplorerHostIslandWindow)$")
        return ""
    if (exe ~= "i)^(VoiceAccess|TextInputHost|SearchHost|StartMenuExperienceHost|ShellExperienceHost)\.exe$")
        return ""
    ; Explorer folders: generic exe, useful title. Grab the folder's
    ; real path too, so playback can reopen it if it's been closed.
    if (cls = "CabinetWClass" && title != "") {
        folder := RegExReplace(title, "\s-\sFile Explorer$", "")
        path := ExplorerPath(hwnd)
        return {crit: folder " ahk_class CabinetWClass"
              , cmd: path != "" ? 'explorer.exe "' path '"' : ""}
    }
    ; UWP apps: also a generic exe; scope the title to the host.
    if (exe = "ApplicationFrameHost.exe" && title != "")
        return {crit: title " ahk_exe ApplicationFrameHost.exe", cmd: ""}
    cmd := ""
    try cmd := WinGetProcessPath(hwnd)
    return {crit: "ahk_exe " exe, cmd: cmd}
}

; ============================================================
;  Test run / save / delete
; ============================================================

; "" if the if/else/endif blocks are balanced, else a message naming the first
; problem. Unbalanced blocks silently skip the rest of a run (a false-positive
; "all steps ran"), so Test and Save refuse until it's fixed.
BlockBalanceError(steps) {
    depth := 0
    for i, s in steps {
        switch s[1] {
            case "if":    depth += 1
            case "else":  if (depth = 0)
                              return "Step " i ": 'Otherwise (else)' has no matching 'If' above it."
            case "endif": if (depth = 0)
                              return "Step " i ": 'End if' has no matching 'If' above it."
                          else
                              depth -= 1
        }
    }
    if (depth > 0)
        return depth " 'If' step" (depth > 1 ? "s are" : " is") " missing a matching 'End if'."
    return ""
}

TestRun(*) {
    global steps, g
    StopRecording()
    if !steps.Length {
        SB("Nothing to run — record or add steps first.")
        return
    }
    if (berr := BlockBalanceError(steps)) {
        MsgBox(berr, "Workflow Studio", "Icon! Owner" g.Hwnd)
        return
    }
    g.Hide()
    Sleep(500)
    ok := RunWorkflowSteps(steps)
    g.Show()
    SB(ok ? "Test run completed — all " steps.Length " steps ran."
          : "Test run stopped — a step failed (details were just shown).")
}

SaveWorkflow(*) {
    global steps, dirty, currentPhrase, root, g
    StopRecording()
    if !steps.Length {
        SB("Nothing to save — record or add steps first.")
        return
    }
    if (berr := BlockBalanceError(steps)) {
        MsgBox(berr, "Workflow Studio", "Icon! Owner" g.Hwnd)
        return
    }
    phrase := SaveNameDialog(currentPhrase)
    if (phrase = "")
        return
    base := StrReplace(phrase, " ")
    if IsReservedName(base) {
        MsgBox("'" base "' is a reserved Windows name and can't be used as a file. Pick another.", "Workflow Studio", "Owner" g.Hwnd)
        return
    }
    macroFile := root "\macros\" base ".ahk"
    if (FileExist(macroFile) && !InStr(FileRead(macroFile, "UTF-8"), "Workflow Studio")) {
        MsgBox("A hand-written macro named '" base "' already exists. Pick another name.", "Workflow Studio", "Owner" g.Hwnd)
        return
    }

    content := "; " phrase " — VoiceKit workflow. Edit it by saying: open workflow studio`n"
    for s in steps
        content .= s[1] "|" WfEncode(s[2]) "|" WfEncode(s[3]) "|" WfEncode(s.Length >= 4 ? s[4] : "") "`n"
    f := FileOpen(root "\workflows\" base ".steps.txt", "w", "UTF-8")
    f.Write(content)
    f.Close()

    stub := "#Requires AutoHotkey v2.0`n"
        . "#SingleInstance Force`n"
        . "; ============================================================`n"
        . ";  " phrase "   (workflow, saved " FormatTime(A_Now, "yyyy-MM-dd") ")`n"
        . ';  Trigger by voice:  "open ' phrase '"`n'
        . ";`n"
        . ";  Generated by Workflow Studio — don't edit steps here.`n"
        . ';  Edit by voice:  "open workflow studio"  ->  pick "' phrase '"`n'
        . ";  Steps live in:  workflows\" base ".steps.txt`n"
        . "; ============================================================`n"
        . '#Include "%A_ScriptDir%\..\lib\_Common.ahk"`n'
        . '#Include "%A_ScriptDir%\..\lib\Workflow.ahk"`n'
        . 'RunWorkflow(A_ScriptDir "\..\workflows\' base '.steps.txt")`n'
    f := FileOpen(macroFile, "w", "UTF-8")
    f.Write(stub)
    f.Close()

    ; Name the shortcut by SpaceOut(base) — the same name the dropdown,
    ; DeleteWorkflow and first-run reinstall all use — so they never drift
    ; apart (they did for names with a digit right after a letter, which
    ; orphaned the .lnk on delete).
    disp := SpaceOut(base)
    vmDir := A_Programs "\Voice Macros"
    EnsureDir(vmDir)
    if !FileExist(vmDir "\" disp ".lnk")
        MakeAhkShortcut(vmDir "\" disp ".lnk", macroFile)
    MakeLoopShortcut(root, base, disp)     ; companion "loop <disp>" entry (repeats until stopped)

    Log(root, "workflow | " phrase " | workflows\" base ".steps.txt")
    currentPhrase := disp
    dirty := false
    ClearAutosave()          ; the take is safely persisted now
    RefreshWorkflowList(disp)
    MsgBox("Saved.`n`nRun it once:   open " disp
        . "`nRepeat it:     open loop " disp "   (then click Stop Looping to end)"
        . "`n`n(First time only: give Windows a few seconds to index the new Start Menu entries.)", "Workflow Studio", "Owner" g.Hwnd)
}

DeleteWorkflow(*) {
    global ddl, ddlMap, root, g
    sel := ddl.Text
    if !ddlMap.Has(sel) {
        SB("Pick a saved workflow in the dropdown first.")
        return
    }
    if (MsgBox("Delete workflow '" sel "'?`n`nRemoves its steps file, its macro, and its Start Menu entries (including the loop one).",
        "Workflow Studio", "YesNo Icon! Owner" g.Hwnd) != "Yes")
        return
    base := ddlMap[sel]
    try FileDelete(root "\workflows\" base ".steps.txt")
    macroFile := root "\macros\" base ".ahk"
    if (FileExist(macroFile) && InStr(FileRead(macroFile, "UTF-8"), "Workflow Studio"))
        try FileDelete(macroFile)
    try FileDelete(A_Programs "\Voice Macros\" sel ".lnk")
    try FileDelete(A_Programs "\Voice Macros\loop " sel ".lnk")
    Log(root, "deleted workflow | " sel)
    NewWorkflowState()
    RefreshWorkflowList()
    SB("Deleted '" sel "'.")
}

; ============================================================
;  Misc
; ============================================================
ShowHelp(*) {
    MsgBox("Recording (the easy way):`n"
        . "  1.  Click Record (or press F9) — the Studio hides, a REC bar floats bottom-left.`n"
        . "  2.  Just do the thing. Window switches, clicks and typing are captured.`n"
        . "       Clicks are remembered by the NAME of what you clicked, so they`n"
        . "       keep working when windows move. Double-clicking a file in`n"
        . "       Explorer records `"Open <that file>`" with its full path.`n"
        . "  3.  Stop with the REC bar's Stop button, by saying `"click stop`",`n"
        . "       or by pressing Ctrl+Alt+Shift+X. Then trim or edit the steps —`n"
        . "       double-click a row to edit, and click Add to insert a pause if`n"
        . "       an app needs time to load.`n"
        . "  4.  Test plays it. Save makes it a voice command: say `"open <name>`".`n`n"
        . "Tip: tick `"Close browser tabs before recording`" to start from a fresh`n"
        . "browser — handy when leftover tabs shift things and break playback.`n`n"
        . "Notes: don't type passwords while recording; drags and scrolling`n"
        . "aren't captured. Every button is voice-clickable — say `"click`" plus`n"
        . "its word: `"click record`", `"click add`", `"click test`", `"click save`".",
        "Workflow Studio — help", "Owner" g.Hwnd)
}

CloseStudio(*) {
    global dirty
    StopRecording()
    if (dirty && !ConfirmDiscard())
        return true
    ClearAutosave()          ; clean exit — nothing to recover
    ExitApp()
}

ConfirmDiscard() {
    global g
    return MsgBox("Discard unsaved changes to this workflow?", "Workflow Studio", "YesNo Icon? Owner" g.Hwnd) = "Yes"
}

; ---- "Close browser tabs before recording" toggle ----
; Close every open window of the common browsers, so a recording starts from
; a clean browser. WinGetList (hidden-window detection off) returns only the
; real, visible top-level windows. WinClose is graceful (WM_CLOSE): a window
; with nothing unsaved closes on its own. If a window is STILL up after a few
; seconds, a browser prompt is holding it open — almost always the "Leave
; site? / Changes you made may not be saved" (beforeunload) dialog. We must
; NOT blindly confirm that: its default button discards the user's unsaved
; work, and session restore only brings back URLs, not typed-but-unsaved
; content. So we leave any such window open and report the count, letting the
; user decide. Returns the number of windows that refused to close.
CloseBrowserTabs() {
    exes := ["chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe", "opera_gx.exe"]
    ToolTip("Closing browser tabs...")
    stuck := 0
    for exe in exes {
        for hwnd in WinGetList("ahk_exe " exe) {
            if !WinExist("ahk_id " hwnd)
                continue
            try WinClose(hwnd)
            if !WinWaitClose("ahk_id " hwnd, , 3)   ; blocked by an unsaved-changes prompt
                stuck++
        }
    }
    ToolTip()
    if stuck
        Notify(stuck " browser window(s) look like they have unsaved changes, so they were "
             . "left open (nothing was discarded). Close them yourself for a clean recording.")
    Sleep(300)                       ; let focus settle before recording
    return stuck
}

; The checkbox state persists across sessions in logs\settings.ini.
SettingsFile() {
    global root
    return root "\logs\settings.ini"
}
LoadSettings() {
    global chkCloseTabs
    chkCloseTabs.Value := (IniRead(SettingsFile(), "Studio", "CloseBrowserTabs", "0") = "1")
}
SaveSettings(*) {
    global chkCloseTabs
    EnsureDir(RegExReplace(SettingsFile(), "\\[^\\]+$"))
    IniWrite(chkCloseTabs.Value ? 1 : 0, SettingsFile(), "Studio", "CloseBrowserTabs")
}

SB(text) {
    global statusBar
    statusBar.Text := text          ; status is a themed Text control, not a StatusBar
}

Abbrev(s, n) {
    return StrLen(s) > n ? SubStr(s, 1, n) "..." : s
}

; Self-heal the Start Menu entry so "open workflow studio" works
; even on installs made before this feature existed.
EnsureStudioShortcut() {
    vmDir := A_Programs "\Voice Macros"
    EnsureDir(vmDir)
    if !FileExist(vmDir "\Workflow Studio.lnk")
        MakeAhkShortcut(vmDir "\Workflow Studio.lnk", A_ScriptFullPath)
}
