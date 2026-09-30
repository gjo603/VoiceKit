#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Workflow Studio — build, record, test and save multi-step
;  workflows in a dialog. No code required.
;
;  Open it by voice:  "open workflow studio"
;  (or: New Automation -> Record My Steps)
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
; Self-heal the Start Menu entry so "open workflow studio" works even on
; installs made before this feature existed.
EnsureVoiceShortcut(VoiceShortcutName("WorkflowStudio"), A_ScriptFullPath)

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
recDragPend := 0        ; set on left-button-down (the just-recorded click step +
                        ; press point); button-up turns it into a drag step if
                        ; the mouse travelled far enough — see RecDragEnd
recMaxed := Map()       ; window crits already maximize-handled this take
recStartCount := 0      ; steps.Length when recording started (for the stop summary)
recLastAct := 0         ; tick of the last captured input — the pause-capture anchor
recSuppress := false    ; true while the recorder itself is typing (an ask step's
                        ; practice answer) — RecChar/RecKeyDown ignore that input

; Advanced if/else/endif entries live at the END so they're never the default
; and don't clutter ordinary recording. The four "if" rows all save as type
; "if"; typeConds carries the condition kind (paramC of the step).
; The "Wait until …" rows all save as type "waitfor" and share their condition
; vocabulary with the "if" rows below — anything testable is also waitable.
; They sit next to the dumb millisecond Wait on purpose: someone hunting for
; "wait" should see the versions that don't need a guessed number.
typeIds    := ["focus", "run", "waitwin", "wait"
             , "waitfor", "waitfor", "waitfor", "waitfor", "waitfor"
             , "text", "fill", "ask", "keys", "click", "dblclick", "rclick", "hover", "drag", "move", "close"
             , "collect", "collect", "set", "capture"
             , "if", "if", "if", "if", "if", "if", "else", "endif"]
typeConds  := ["", "", "", ""
             , "elementexists", "elementnotexists", "winnotexists", "textvisible", "clipboardchanged"
             , "", "", "", "", "", "", "", "", "", "", ""
             , "", "elem", "", ""
             , "winexists", "winnotexists", "elementexists", "elementnotexists"
             , "textvisible", "textnotvisible", "", ""]
typeLabels := ["Focus window (launch it if needed)"
             , "Open app / file / website"
             , "Wait for a window to appear"
             , "Wait (pause for milliseconds, or a random range like 600-1400)"
             , "Wait until something appears on screen"
             , "Wait until something disappears from screen"
             , "Wait until a window closes"
             , "Wait until some text appears on screen"
             , "Wait until something new is copied (clipboard)"
             , "Type text"
             , "Fill in a box by its label (types the value, then checks it took)"
             , "Ask me for input (asks before the run; types the answer here)"
             , "Press keys (e.g. {Enter}, ^s)"
             , "Left-click something in a window (by its name)"
             , "Double-click something in a window"
             , "Right-click something in a window"
             , "Hover over something in a window (reveals menus / tooltips)"
             , "Drag the mouse (press, move, release — e.g. select part of the screen)"
             , "Position window (left / right / top / bottom / max)"
             , "Close window"
             , "Collect the selected text (saves it to the workflow's sheet)"
             , "Collect what's in a named box (saves it to the workflow's sheet)"
             , "Set a value (reuse it anywhere later as {{name}})"
             , "Run a command and save its output"
             , "— If a window IS open …"
             , "— If a window is NOT open …"
             , "— If something IS on screen …"
             , "— If something is NOT on screen …"
             , "— If some text IS on screen …"
             , "— If some text is NOT on screen …"
             , "— Otherwise (else) …"
             , "— End if"]

; ---- click capture + stop hotkey (active only while recording) ----
#HotIf recording
~*LButton:: RecClick("L")
~*LButton up:: RecDragEnd()  ; a press that travels before releasing becomes a Drag step
~*RButton:: RecClick("R")
^!+h:: RecHover()           ; mark a hover point (menus/tooltips can't be clicked)
^!+i:: RecAskInput()        ; mark an ask-for-input point (label it; playback asks up front)
^!+c:: RecCollect()         ; mark a collect point (select text first; playback copies it to the sheet)
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
chkMaxWins := g.AddCheckBox("xm y+6", "Maximize windows while recording  (steadier playback)")
chkCoordsOnly := g.AddCheckBox("xm y+6", "Record clicks by position only  (skip element names — for maps, canvases, games)")
chkRawInput := g.AddCheckBox("xm y+6", "Record raw input only  (no auto Waits, window switches, or maximizing — just what you do)")
; The one PLAYBACK setting on this panel: every other box above changes what
; gets recorded. It lives here because this is where workflows are authored,
; and it is stored under [Workflow] (not [Studio]) because the engine reads
; it — every run, not just the ones started from the Studio.
chkJitter := g.AddCheckBox("xm y+6", "Vary click positions slightly when running  (clicking the same pixel every pass looks automated)")

g.SetFont("s11")
btnRec  := g.AddButton("xm y+8 w200 h44 Default", "●  Record (F9)")   ; Default: Enter starts recording
btnTest := g.AddButton("x+10 w120 h44",   "▶  Test")
btnSave := g.AddButton("x+10 w160 h44",   "🖫  Save")
; "and Close" spelled out, not "&" — an ampersand in a button caption is a
; keyboard-mnemonic marker, and the caption IS what Voice Access matches on.
btnSaveClose := g.AddButton("x+10 w210 h44", "🖫  Save and Close")

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
btnSave.OnEvent("Click", (*) => SaveWorkflow())
btnSaveClose.OnEvent("Click", (*) => SaveWorkflow(true))
btnHelp.OnEvent("Click", ShowHelp)
chkCloseTabs.OnEvent("Click", SaveSettings)
chkMaxWins.OnEvent("Click", SaveSettings)
chkCoordsOnly.OnEvent("Click", SaveSettings)
chkRawInput.OnEvent("Click", SaveSettings)
chkJitter.OnEvent("Click", SaveSettings)
g.OnEvent("Close", CloseStudio)

; ---- keys while the main Studio window is active ----
; (scoped by hwnd so they never fire on a dialog, MsgBox, or edit field;
; note the main window itself has no text inputs — if one is ever added,
; Del must move to an LVN_KEYDOWN notify so it can't eat typed input)
#HotIf WinActive("ahk_id " g.Hwnd)
F9:: StartRecording()
Del:: RemoveStep()       ; same as the Remove button — acts on the selected row
NumpadDel:: RemoveStep()
#HotIf

RefreshWorkflowList()
NewWorkflowState()
LoadSettings()
ThemeApply(g, statusBar)
g.Show()
btnRec.Focus()           ; land on Record so pressing Enter starts recording
recovered := OfferRecovery()   ; restore an interrupted recording, if any
if (A_Args.Length >= 1) {
    if (StrLower(A_Args[1]) = "/record") {
        ; "Record My Steps" (macro / hotkey): jump straight into recording a
        ; new workflow. Recovery still wins — auto-recording on top of just-
        ; recovered steps would append to them behind the user's back.
        if recovered
            SB("Recovered steps kept — click Record when you're ready to add more.")
        else
            StartRecording()
    } else if recovered
        SB("Recovered steps kept — the file passed on the command line was not loaded.")
    else
        LoadStartupFile(A_Args[1])
}

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

; Open the Studio "on" a file passed as a command-line argument:
;   - a saved workflow's own steps file -> load it as that workflow
;     (the Voice Kit home window's Edit button does this);
;   - any other steps file (the AI draft that New Automation writes to
;     logs\ai-draft.steps.txt) -> load as an unsaved draft for review.
; Never auto-saves either way — Save stays a deliberate act.
LoadStartupFile(path) {
    global root, steps, currentPhrase, dirty
    if !FileExist(path)
        return
    if (RegExMatch(path, "i)\\workflows\\([^\\]+)\.steps\.txt$", &m)
        && FileExist(root "\workflows\" m[1] ".steps.txt")) {
        RefreshWorkflowList(SpaceOut(m[1]))
        LoadWorkflow(m[1])
        return
    }
    loaded := WorkflowLoad(path)
    if !loaded.Length
        return
    steps := loaded
    currentPhrase := ""
    dirty := true
    RefreshLV()
    SB("AI draft loaded (" steps.Length " steps) — review each one, click Test, then Save to make it a voice command.")
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
        desc := WfDesc(s)
        if ((t = "click" || t = "dblclick" || t = "rclick" || t = "hover" || t = "drag") && s[3] = "" && s[4] != "")
            desc .= "      ⚠ by position only — may break if the window moves"
        lv.Add(, i, indent desc)
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
    laT := d.AddText("xm y+10 w480", "")        ; timeout — "Wait until …" rows only
    edT := d.AddEdit("xm w120")
    btnGrab := d.AddButton("xm y+12 w210", "Grab a Window (3 sec)")
    btnPick := d.AddButton("x+8 w210", "Pick element (3 sec)")
    btnBrowse := d.AddButton("xm yp w180", "Browse for File...")   ; same row; shown only for 'run'
    btnSpot := d.AddButton("xm y+8 w210", "Pick a spot (3 sec)")   ; click a POSITION, no name needed
    laC := d.AddText("xm y+6 w480", "")                            ; the picked spot, dimmed
    laVars := d.AddText("xm y+2 w480 r2", "")                      ; values usable here, dimmed
    btnOK := d.AddButton("xm y+14 w120 Default", "OK")
    btnCancel := d.AddButton("x+8 w120", "Cancel")

    ; The named values this workflow already defines, so the user can see what
    ; {{...}} they can type rather than having to remember. Hidden for step
    ; types where no field is substituted.
    ShowVarHint(t) {
        global steps
        if (t = "else" || t = "endif" || t = "ask" || t = "wait") {
            laVars.Text := ""
            return
        }
        names := WfVarNames(steps)
        ; Line 2: the built-ins (Workflow.ahk WfBuiltinVar) — {{selected_file}}
        ; is the one file selected in File Explorer when the run starts.
        laVars.Text := (names.Length
            ? "Values you can use here:  {{" JoinList(names, "}}   {{") "}}"
            : "Tip: an Ask, Collect, Set or Run-a-command step names a value you can reuse here as {{name}}.")
            . ((t = "capture" || t = "run")      ; command lines: WfSubst quotes the selection
                ? "`nBuilt in:  {{selected_file}}  {{selected_files}}  (quoted for you here)  {{date}}"
                : "`nBuilt in:  {{selected_file}}  {{selected_files}}  {{clipboard}}  {{date}}")
    }

    ; Element/text conditions need something to look FOR; the window ones don't.
    CondNeedsElem(cond) {
        return cond = "elementexists" || cond = "elementnotexists"
            || cond = "textvisible" || cond = "textnotvisible"
    }
    CondIsText(cond) {
        return cond = "textvisible" || cond = "textnotvisible"
    }

    UpdateFields(*) {
        t := typeIds[dt.Value], cond := typeConds[dt.Value]
        ShowVarHint(t)
        laT.Visible := edT.Visible := false      ; only the "Wait until" rows use it
        edT.Move(, , 120)                        ; fill widens it for its value
        ; else / endif are block markers — no fields at all.
        if (t = "else" || t = "endif") {
            laA.Visible := edA.Visible := laB.Visible := edB.Visible := false
            btnGrab.Visible := btnPick.Visible := btnBrowse.Visible := false
            btnSpot.Visible := laC.Visible := false
            return
        }
        ; set: name a value here, use it as {{name}} in any later step.
        if (t = "set") {
            laA.Text := "Name this value — you'll use it later as {{name}}:"
            laA.Visible := edA.Visible := true
            laB.Text := "Value — can include other values, e.g. Hi {{First Name}}, or {{clipboard}}:"
            laB.Visible := edB.Visible := true
            btnGrab.Visible := btnPick.Visible := btnBrowse.Visible := false
            btnSpot.Visible := laC.Visible := false
            return
        }
        ; capture: a name, the command line, and a timeout (paramC, in the
        ; timeout box — like waitfor's seconds, not the second box).
        if (t = "capture") {
            laA.Text := "Name the output — you'll use it later as {{name}}:"
            laA.Visible := edA.Visible := true
            laB.Text := "Command line, e.g.  python `"C:\tools\invoice.py`" {{selected_file}}"
            laB.Visible := edB.Visible := true
            laT.Text := "Give up after this many seconds (blank = 30):"
            laT.Visible := edT.Visible := true
            btnGrab.Visible := btnPick.Visible := btnBrowse.Visible := false
            btnSpot.Visible := laC.Visible := false
            return
        }
        ; fill: window, the box's label (Pick element fills it — point at the
        ; BOX, not the text beside it), and the value, which rides in paramC
        ; and so uses the third box, widened.
        if (t = "fill") {
            laA.Text := "Window:"
            laA.Visible := edA.Visible := true
            laB.Text := "The box's label, exactly as shown — Amount#2 = the 2nd box with that label (## = a real #):"
            laB.Visible := edB.Visible := true
            laT.Text := "Value to put in it — can use {{name}} (blank clears the box):"
            laT.Visible := edT.Visible := true
            edT.Move(, , 480)
            btnGrab.Visible := btnPick.Visible := true
            btnBrowse.Visible := false
            btnSpot.Visible := laC.Visible := false
            return
        }
        ; collect: a label (the sheet column); the "named box" variant also
        ; takes the element to read.
        if (t = "collect") {
            needElem := (cond = "elem")
            laA.Text := "Save the value as — the column name in your sheet, e.g. 'Price':"
            laA.Visible := edA.Visible := true
            laB.Text := "Name of the box to read, exactly as shown on screen:"
            laB.Visible := edB.Visible := needElem
            btnGrab.Visible := false
            btnPick.Visible := needElem
            btnBrowse.Visible := false
            btnSpot.Visible := laC.Visible := false
            return
        }
        ; waitfor: block until something is actually true, instead of betting on
        ; a number of milliseconds. Same conditions as `if`, plus a timeout.
        if (t = "waitfor") {
            needWin := (cond != "clipboardchanged")
            needElem := CondNeedsElem(cond)
            laA.Text := "Window to watch — 'ahk_exe app.exe' or part of its title:"
            laA.Visible := edA.Visible := needWin
            laB.Text := CondIsText(cond)
                ? "Text to wait for, as it appears on screen:"
                : "Name of the thing to wait for, exactly as shown on screen:"
            laB.Visible := edB.Visible := needElem
            laT.Text := "Give up after this many seconds (blank = 10):"
            laT.Visible := edT.Visible := true
            btnGrab.Visible := needWin
            btnPick.Visible := (cond = "elementexists" || cond = "elementnotexists")
            btnBrowse.Visible := false
            btnSpot.Visible := laC.Visible := false
            return
        }
        ; if: a window to check for, plus an element name / text for the
        ; "on screen" tests.
        if (t = "if") {
            needElem := CondNeedsElem(cond)
            laA.Text := "Window to check for — 'ahk_exe app.exe' or part of its title:"
            laA.Visible := edA.Visible := true
            laB.Text := CondIsText(cond)
                ? "Text to check for, as it appears on screen:"
                : "Name of the thing to check for, exactly as shown on screen:"
            laB.Visible := edB.Visible := needElem
            btnGrab.Visible := true          ; Grab fills in the window for you
            btnPick.Visible := (cond = "elementexists" || cond = "elementnotexists")
            btnBrowse.Visible := false
            btnSpot.Visible := laC.Visible := false
            return
        }
        labels := Map(
            "focus",    ["Window to focus — 'ahk_exe app.exe' or part of its title:",
                         "If it isn't running, launch this (path or command) — optional:"],
            "run",      ["What to open — a program, file, folder path, or https:// address:", ""],
            "waitwin",  ["Window to wait for (it gets focused when it appears):",
                         "Give up after this many seconds (blank = 10):"],
            "wait",     ["How long to pause, in milliseconds (1000 = 1 second) — or a range like 600-1400 for a random pause:", ""],
            "text",     ["Text to type into the focused window:", ""],
            "ask",      ["What should I ask you for? — the input's label, e.g. 'Customer name':",
                         "Suggested answer, prefilled in the ask box — optional:"],
            "keys",     ["Keys to press — AHK v2 syntax, e.g. {Enter}, {Tab 2}, ^s:", ""],
            "click",    ["Window:", "What to click — its name exactly as shown on screen:"],
            "dblclick", ["Window:", "What to double-click — its name exactly as shown on screen:"],
            "rclick",   ["Window:", "What to right-click — its name exactly as shown on screen:"],
            "hover",    ["Window:", "What to hover over — its name exactly as shown on screen:"],
            "drag",     ["Window:", "Drag path — start then end, window-relative pixels: x1,y1,x2,y2"],
            "move",     ["Window to position:", "Where: left / right / top / bottom / max"],
            "close",    ["Window to close:", ""])
        needB := (labels[t][2] != "")
        laA.Text := labels[t][1]
        laA.Visible := edA.Visible := true
        laB.Text := labels[t][2]
        laB.Visible := needB
        edB.Visible := needB
        btnGrab.Visible := (t != "run" && t != "wait" && t != "text" && t != "ask" && t != "keys")
        isPtr := (t = "click" || t = "dblclick" || t = "rclick" || t = "hover")
        btnPick.Visible := isPtr                 ; capture by element name...
        btnSpot.Visible := laC.Visible := isPtr  ; ...or by position (no name needed)
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
        name := PickNameAt(mx, my, winHwnd)        ; query while the windows are hidden
        info := ClassifyWindow(winHwnd)            ; "" for VoiceKit's own window / desktop / shell
        g.Show()
        d.Show()
        WinActivate("ahk_id " d.Hwnd)
        if !IsObject(info) {
            MsgBox("Point at your app's window — not VoiceKit or the desktop. Try again.", "Pick element", "Owner" d.Hwnd)
            return
        }
        if (name = "") {
            MsgBox("Couldn't read a name there. Point at a button, link, menu item or other labeled control — or type its name.", "Pick element", "Owner" d.Hwnd)
            return
        }
        ; A fill label reads "#<digits>" at its end as "the Nth box" and "##"
        ; as a literal "#" (WfFillLabel) — so a picked name is written with
        ; every "#" doubled, or "Unit #2" would silently mean "the 2nd box
        ; labelled Unit".
        edB.Value := (typeIds[dt.Value] = "fill") ? StrReplace(name, "#", "##") : name
        ; Also capture the window it's in, if not set yet — but not for
        ; collect, whose first box is the value's label, not a window.
        if (edA.Value = "" && typeIds[dt.Value] != "collect")
            edA.Value := info.crit
        ; The recorder drops names this long (CaptureTarget) — paragraph-length
        ; text changes between runs, so it isn't a stable thing to click by.
        ; Here the user picked it on purpose, so keep it but say so.
        if (StrLen(name) > 100)
            MsgBox("That name is " StrLen(name) " characters long — text that long usually changes "
                . "between runs, so a click by name may miss. Keep just a distinctive part of it, "
                . "or use Pick a spot instead.", "Pick element", "Icon! Owner" d.Hwnd)
    }

    ; The dim caption under the buttons: the window-relative spot (paramC)
    ; this step carries. Also surfaces a recorded click's fallback spot when
    ; editing — the name, when one is set, is still tried first at playback.
    SpotCaption() {
        laC.Text := (preservedC = "") ? ""
            : "Spot: " preservedC " (window-relative) ⚠ — used when the name box is empty."
    }

    ; Point at an exact SPOT and capture its window-relative position — for
    ; targets without a readable name (maps, canvases, custom toolbars).
    ; Saves a position-only step (the ⚠ kind), with the recorder's exact
    ; capture math so playback lands on the same pixel.
    PickSpot(*) {
        d.Hide()
        g.Hide()                                   ; the always-on-top Studio would cover the target
        Loop 3 {
            ToolTip("Point the mouse at the exact spot, then wait...  " (4 - A_Index))
            Sleep(1000)
        }
        ToolTip()
        MouseGetPos(&mx, &my, &winHwnd)
        info := ClassifyWindow(winHwnd)
        ; "" when the window vanished mid-countdown
        rel := IsObject(info) ? WinRelPoint(winHwnd, mx, my) : ""
        g.Show()
        d.Show()
        WinActivate("ahk_id " d.Hwnd)
        if (rel = "") {
            MsgBox("Point at a spot inside your app's window — not VoiceKit or the desktop. Try again.", "Pick a spot", "Owner" d.Hwnd)
            return
        }
        preservedC := rel
        if (edA.Value = "")
            edA.Value := info.crit
        SpotCaption()
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
        ; set: a name plus the value it stands for. Handled before the generic
        ; path below, which would otherwise blank paramB.
        if (t = "set") {
            if (a = "") {
                MsgBox("Give the value a name — that's what you'll type as {{name}} later.", "Add Step", "Owner" d.Hwnd)
                return
            }
            if (InStr(a, "{") || InStr(a, "}")) {
                MsgBox("Just the name here — no braces. Write  Greeting , then use  {{Greeting}}  in later steps.", "Add Step", "Owner" d.Hwnd)
                return
            }
            result := ["set", a, b, ""]
            d.Destroy()
            return
        }
        ; capture: name + command required; the timeout box is paramC (blank =
        ; the engine's 30 s). Handled here because the generic path below
        ; would blank paramC.
        if (t = "capture") {
            if (a = "") {
                MsgBox("Give the output a name — that's what you'll type as {{name}} later.", "Add Step", "Owner" d.Hwnd)
                return
            }
            if (InStr(a, "{") || InStr(a, "}")) {
                MsgBox("Just the name here — no braces. Write  Invoice Data , then use  {{Invoice Data}}  in later steps.", "Add Step", "Owner" d.Hwnd)
                return
            }
            if (b = "") {
                MsgBox("Give the command to run.", "Add Step", "Owner" d.Hwnd)
                return
            }
            secs := Trim(edT.Value)
            if (secs != "" && (!IsNumber(secs) || Number(secs) <= 0)) {
                MsgBox("The timeout must be a number of seconds, e.g. 120 — or blank for 30.", "Add Step", "Owner" d.Hwnd)
                return
            }
            result := ["capture", a, b, secs]
            d.Destroy()
            return
        }
        ; fill: window + label required; the value (paramC) is kept exactly as
        ; typed — spaces included — and may be blank (clears the box). A line
        ; break is refused, as the engine would at run time.
        if (t = "fill") {
            if (a = "") {
                MsgBox("Give the window the box is in — Grab a Window fills it in.", "Add Step", "Owner" d.Hwnd)
                return
            }
            if (b = "") {
                MsgBox("Give the box's label as shown on screen — or point Pick element at the box.", "Add Step", "Owner" d.Hwnd)
                return
            }
            if ((lerr := WfFillLabel(b).err) != "") {
                MsgBox(lerr, "Add Step", "Owner" d.Hwnd)
                return
            }
            if RegExMatch(edT.Value, "[\r\n]") {
                MsgBox("The value can't contain a line break (it would press Enter and could submit the form). Use a Type text step for multi-line text.", "Add Step", "Owner" d.Hwnd)
                return
            }
            result := ["fill", a, b, edT.Value]
            d.Destroy()
            return
        }
        ; collect: label required; the named-box variant needs its element too.
        if (t = "collect") {
            if (a = "") {
                MsgBox("Give the value a name — it becomes a column in your sheet.", "Add Step", "Owner" d.Hwnd)
                return
            }
            if (cond = "elem" && b = "") {
                MsgBox("Give the name of the box to read, as shown on screen.", "Add Step", "Owner" d.Hwnd)
                return
            }
            result := ["collect", a, (cond = "elem" ? b : ""), ""]
            d.Destroy()
            return
        }
        ; waitfor: window + what to watch for + a timeout. The condType and the
        ; seconds share paramC ("<condType>[,<seconds>]"), so this has to run
        ; before the generic path below — a clipboard wait has no window at all.
        if (t = "waitfor") {
            needWin := (cond != "clipboardchanged")
            needElem := CondNeedsElem(cond)
            if (needWin && a = "") {
                MsgBox("Give the window to watch.", "Add Step", "Owner" d.Hwnd)
                return
            }
            if (needElem && b = "") {
                MsgBox(CondIsText(cond)
                    ? "Give the text to wait for, as it appears on screen."
                    : "Give the name of the thing to wait for, as shown on screen.",
                    "Add Step", "Owner" d.Hwnd)
                return
            }
            secs := Trim(edT.Value)
            if (secs != "" && (!IsNumber(secs) || Number(secs) <= 0)) {
                MsgBox("The timeout must be a number of seconds, e.g. 30 — or blank for 10.", "Add Step", "Owner" d.Hwnd)
                return
            }
            result := ["waitfor", (needWin ? a : ""), (needElem ? b : ""),
                cond (secs != "" ? "," secs : "")]
            d.Destroy()
            return
        }
        ; if: window required; element/text required for the "on screen" conditions.
        if (t = "if") {
            if (a = "") {
                MsgBox("Give the window to check for.", "Add Step", "Owner" d.Hwnd)
                return
            }
            needElem := CondNeedsElem(cond)
            if (needElem && b = "") {
                MsgBox(CondIsText(cond)
                    ? "Give the text to check for, as it appears on screen."
                    : "Give the name of the thing to check for, as shown on screen.",
                    "Add Step", "Owner" d.Hwnd)
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
        ; A range (600-1400) pauses a random amount inside it — the same
        ; parser the engine uses, so what the box accepts is what runs.
        if (t = "wait" && WfWaitMs(a).err != "") {
            MsgBox("Milliseconds must be a whole number, e.g. 1500 — or a range like 600-1400 "
                . "to pause a random amount in between (useful when a workflow loops against a "
                . "website: identical pauses every pass look automated).", "Add Step", "Owner" d.Hwnd)
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
        ; drag: the edB box carries the coordinate path, which lives in paramC
        ; on disk (paramB stays empty — a drag has no element name).
        if (t = "drag") {
            path := (b != "") ? b : preservedC
            xy := StrSplit(path, ",")
            bad := (xy.Length != 4)
            if !bad {
                for part in xy
                    if !IsInteger(Trim(part))
                        bad := true
            }
            if bad {
                MsgBox("Give the drag path as four numbers — start then end, window-relative: x1,y1,x2,y2 (e.g. 100,200,400,200) — or record it by dragging.", "Add Step", "Owner" d.Hwnd)
                return
            }
            result := ["drag", a, "", Trim(xy[1]) "," Trim(xy[2]) "," Trim(xy[3]) "," Trim(xy[4])]
            d.Destroy()
            return
        }
        isPointer := (t = "click" || t = "dblclick" || t = "rclick" || t = "hover")
        if (isPointer && b = "" && preservedC = "") {
            MsgBox("Give the element's name as shown on screen — or use `"Pick a spot`" to click a position instead.", "Add Step", "Owner" d.Hwnd)
            return
        }
        if !(t = "focus" || t = "waitwin" || t = "move" || t = "ask" || isPointer)
            b := ""
        result := [t, a, b, isPointer ? preservedC : ""]
        d.Destroy()
    }

    dt.OnEvent("Change", UpdateFields)
    btnGrab.OnEvent("Click", Grab)
    btnPick.OnEvent("Click", Pick)
    btnSpot.OnEvent("Click", PickSpot)
    btnBrowse.OnEvent("Click", Browse)
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())

    if IsObject(existing) {
        idx := 1
        exCond := (existing.Length >= 4) ? existing[4] : ""
        if (existing[1] = "waitfor")         ; paramC is "<condType>[,<seconds>]"
            exCond := WfWaitParts(exCond).cond
        for i, id in typeIds {
            if (id != existing[1])
                continue
            if (id = "if" || id = "waitfor") {   ; pick the row whose condition matches
                if (typeConds[i] = exCond)
                    idx := i
            } else if (id = "collect") {     ; selection vs named-box variant
                if ((typeConds[i] = "elem") = (existing[3] != ""))
                    idx := i
            } else
                idx := i
        }
        dt.Choose(idx)
        UpdateFields()
        edA.Value := existing[2]
        edB.Value := (existing[1] = "drag")     ; drag edits its paramC path in edB
            ? ((existing.Length >= 4) ? existing[4] : "")
            : existing[3]
        if (existing[1] = "waitfor")            ; the seconds half of paramC
            edT.Value := WfWaitParts((existing.Length >= 4) ? existing[4] : "").secs
        if (existing[1] = "capture" || existing[1] = "fill")   ; paramC whole: the timeout / the value
            edT.Value := (existing.Length >= 4) ? existing[4] : ""
        SpotCaption()                           ; show a pointer step's saved spot
    } else {
        dt.Choose(1)
        UpdateFields()
    }

    ThemeShowModal(d, g, [laC, laVars])  ; modal over the Studio, then refocus it
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

    ThemeShowModal(d, g)
    return result
}

; A brand-new name that's already a saved workflow: ask before replacing it
; (it used to be overwritten without a word). Owned by the Studio and themed
; like its other dialogs; Cancel is the Default button, so a reflexive Enter
; can't destroy anything. True = replace.
ConfirmReplaceDialog(disp, count) {
    global g
    doReplace := false
    d := Gui("+AlwaysOnTop +Owner" g.Hwnd, "Replace Workflow?")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 18, d.MarginY := 14
    d.SetFont("s11 bold")
    d.AddText("xm w440", "A workflow named '" disp "' already exists.")
    d.SetFont("s10 norm")
    note := d.AddText("xm y+6 w440", "Replacing it overwrites its saved steps with the " count
        . " step" (count = 1 ? "" : "s") " here — its voice phrase stays the same. This can't be undone.")
    btnReplace := d.AddButton("xm y+14 w150 h32", "Replace It")
    btnCancel := d.AddButton("x+8 w120 h32 Default", "Cancel")
    btnReplace.OnEvent("Click", (*) => (doReplace := true, d.Destroy()))
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d, g, note, btnCancel)
    return doReplace
}

; The exact on-disk name of a saved workflow with this base, or "". NTFS is
; caseless, so "Morningtabs" finds MorningTabs.steps.txt — and a replace
; keeps that spelling, so its voice phrase and Start Menu entries don't move.
SavedWorkflowBase(base) {
    global root
    Loop Files root "\workflows\" base ".steps.txt"
        return StrReplace(A_LoopFileName, ".steps.txt")
    return ""
}

; ============================================================
;  Recorder — captures window switches, clicks and typing.
;  Clicks are stored by accessible element NAME (position kept
;  only as fallback); keystrokes become visible, editable steps.
; ============================================================
StartRecording() {
    global recording, recLastHwnd, recLastCrit, typedBuf, lastClick, g, recBar, chkCloseTabs, steps
    global recMaxed, recStartCount, recLastAct, recSuppress, recDragPend
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
    recDragPend := 0                ; never inherit a half-finished gesture
    recMaxed := Map()
    recStartCount := steps.Length
    recLastAct := 0                 ; no pause before a take's first action
    recSuppress := false            ; never inherit a stuck suppression flag
    StartKeyHook()
    g.Hide()
    UpdateRecBar("Ctrl+Alt+Shift:  H hover  ·  I ask input  ·  C collect  ·  X stop")
    ShowBottomLeft(recBar)                    ; bottom-left, clear of the taskbar
    SetTimer(RecTick, 250)
}

StopRecording() {
    global recording, steps, lv, g, recBar, btnRec, recStartCount, chkCoordsOnly, chkRawInput
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
    posOnly := 0, pauses := 0
    Loop Max(0, steps.Length - recStartCount) {      ; count THIS take only
        s := steps[recStartCount + A_Index]
        if ((s[1] = "click" || s[1] = "dblclick" || s[1] = "rclick" || s[1] = "hover") && s[3] = "" && s[4] != "")
            posOnly += 1
        else if (s[1] = "wait")                      ; in-take waits are all auto-captured pauses
            pauses += 1
    }
    pNote := !pauses ? ""
        : "  Kept " pauses " pause" (pauses = 1 ? "" : "s") " as Wait step" (pauses = 1 ? "" : "s")
        . " so playback matches your pace — edit or delete any."
    if (steps.Length = recStartCount)
        SB("Nothing was captured — recording sees window switches, clicks and typing in normal app windows (the Start menu and taskbar don't count). Try again.")
    else if (posOnly && chkCoordsOnly.Value)
        SB("Recorded — " posOnly " step" (posOnly = 1 ? "" : "s") " captured by position (⚠), as chosen. They replay by screen location, so keep the same window layout — the Maximize option helps." pNote)
    else if posOnly
        SB("Recorded — " posOnly " click" (posOnly = 1 ? " was" : "s were") " captured by position only (⚠ in the list) because nothing readable was under the mouse. They replay less reliably — prefer clicking labeled controls." pNote)
    else if chkRawInput.Value
        SB("Recorded raw — no Wait or window-switch steps were added, so playback sends the keys and clicks straight to whatever window is active then.")
    else
        SB("Recorded — trim or edit steps if needed, then click Test and Save." pNote)
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

; Reproduce the user's own pacing. Called right before a captured action is
; pushed: if a meaningful pause separated it from the previous captured input,
; save that pause as an ordinary (visible, editable, deletable) Wait step, so
; playback waits roughly as long as the recording did — for the page to load,
; the autocomplete list to appear, the menu to open. The anchor (recLastAct)
; is the time of the previous INPUT event, never of a step push: flushing the
; typed-text buffer pushes its Type step long after the typing happened, and
; must not count as fresh activity. Below the floor the engine's built-in
; pacing already covers the gap — click/hover/focus steps window-wait and
; settle (~0.4–1.5 s) before acting, while keystroke steps get only a 150 ms
; beat, so keyboard boundaries use the lower floor. Long distractions (a
; phone call mid-recording) are capped; the first action of a take gets no
; Wait at all — that gap is just the user getting ready, not the app.
RecMarkPause(kind := "mouse", atTick := 0) {
    global recLastAct, chkRawInput
    if (chkRawInput.Value || !recLastAct)   ; raw-input mode: no auto Wait steps at all
        return
    if !atTick
        atTick := A_TickCount
    gap := atTick - recLastAct
    if (gap < (kind = "key" ? 700 : 1500))
        return
    gap := Round(Min(gap, 30000) / 100) * 100        ; ~0.1 s grain, 30 s cap
    RecPush(["wait", String(gap), "", ""], "Paused " WfDurDesc(gap) " — kept as a Wait step")
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
        return false
    recovered := WorkflowLoad(AutosaveFile())   ; reuse the engine's parser
    if !recovered.Length {
        ClearAutosave()
        return false
    }
    if (MsgBox("A recording from an interrupted session was found ("
        recovered.Length " steps). Recover it?", "Workflow Studio", "YesNo Icon? Owner" g.Hwnd) = "Yes") {
        steps := recovered
        dirty := true
        RefreshLV()
        SB("Recovered " steps.Length " steps — review them, then click Save.")
        return true
    }
    ClearAutosave()
    return false
}

RecTick() {
    global recording, typedBuf, lastCharTick, recLastHwnd, recLastCrit, recLastAct, chkRawInput
    if !recording
        return
    if (typedBuf != "" && A_TickCount - lastCharTick > 1500)
        FlushTypedText()
    if chkRawInput.Value            ; raw-input mode: no window-switch Focus steps,
        return                      ; no maximizing — the idle flush above still runs
    hwnd := WinExist("A")
    if (!hwnd || hwnd = recLastHwnd)
        return
    recLastHwnd := hwnd
    info := ClassifyWindow(hwnd)
    if (!IsObject(info) || info.crit = recLastCrit)
        return
    FlushTypedText()
    RecMarkPause()                  ; e.g. idle until an app popped this window itself
    recLastCrit := info.crit
    RecPush(["focus", info.crit, info.cmd, ""], "Switch to " info.crit)
    recLastAct := A_TickCount
    RecEnsureMax(hwnd, info.crit)
}

; If a window newly entering the recording is maximizable, maximize it now
; and record a "move max" step, so playback reproduces the exact geometry
; the recording saw — coordinate fallbacks stay valid and apps that open
; half-screen (snap layouts) stop breaking takes. Once per window identity
; per take. A window with no maximize box (a dialog) is left alone AND
; leaves the slot open: dialogs share their app's "ahk_exe" identity, so
; marking them handled would block the app's real main window later.
RecEnsureMax(hwnd, crit) {
    global chkMaxWins, recMaxed, chkRawInput
    if (chkRawInput.Value || !chkMaxWins.Value || recMaxed.Has(crit))
        return
    try {
        if !(WinGetStyle(hwnd) & 0x10000)          ; WS_MAXIMIZEBOX
            return
        recMaxed[crit] := true
        if (WinGetMinMax(hwnd) != 1)
            WinMaximize(hwnd)
        RecPush(["move", crit, "max", ""], "Maximize " crit)
    }
}

; Deferred entry for the CLICK path. Maximizing synchronously inside the
; button-down hook would reflow the window mid-gesture: the second half of
; a live double-click lands on shifted content (and the Explorer rewrite
; could then record the WRONG file), and even a single click can be
; cancelled when the pressed control moves out from under the held button.
; So clicks schedule this to run after the double-click window has passed.
RecDeferredMax(hwnd, crit) {
    global recording
    if (!recording || !WinExist("ahk_id " hwnd))
        return
    RecEnsureMax(hwnd, crit)
}

; A Focus step for the window a capture happened in, when it isn't the one
; the take is already in — so playback lands the next action in the right
; app. Skipped in raw-input mode (no window-switch steps there). Does NOT
; touch recLastAct: the pause anchor tracks input events, never step pushes.
; (RecTick keeps its own copy: it flushes and marks the pause in between.)
RecFocusIfNew(info, hwnd) {
    global recLastCrit, recLastHwnd, chkRawInput
    if (chkRawInput.Value || !IsObject(info) || info.crit = recLastCrit)
        return
    RecPush(["focus", info.crit, info.cmd, ""], "Switch to " info.crit)
    recLastCrit := info.crit
    recLastHwnd := hwnd
}

; The accessible name under a screen point, for Pick element: MSAA first (the
; names recorded workflows were built against, and what playback tries first),
; then UI Automation. Chrome publishes no page content over MSAA, so without
; the fallback Pick read nothing — or just the browser pane — on a web form
; (a web form app's input screen, say), and a `fill` step's label had to be typed
; by hand. Safe from the own-process hang: UiaFromPoint refuses a point over
; one of the Studio's windows (and the caller hides them first anyway).
; Recording (CaptureTarget) is deliberately unchanged: it runs on button-down
; inside the click hotkey, where an extra cross-process lookup is felt.
PickNameAt(mx, my, winHwnd) {
    name := ""
    ap := AccFromPoint(mx, my)
    if IsObject(ap)
        name := AccName(ap.acc, ap.child)
    ; What MSAA says over a browser's page is the pane itself ("Chrome Legacy
    ; Window") or the window title — not a name anything can be found by.
    title := ""
    try title := WinGetTitle("ahk_id " winHwnd)
    if (name = "" || name = "Chrome Legacy Window" || name = title) {
        u := ""
        try u := Trim(UiaName(UiaFromPoint(mx, my)))
        if (u != "")
            name := u
    }
    return name
}

; What a pointer capture points at: {elem, rel} — the accessible name under
; (mx, my) when nameToo (position-only mode passes false; names over 100
; characters are dropped, as paragraph-length text isn't a stable selector)
; and the window-relative position kept as the fallback.
CaptureTarget(mx, my, hwnd, nameToo) {
    elem := ""
    if nameToo {
        ap := AccFromPoint(mx, my)
        if IsObject(ap)
            elem := AccName(ap.acc, ap.child)
        if (StrLen(elem) > 100)
            elem := ""
    }
    return {elem: elem, rel: WinRelPoint(hwnd, mx, my)}
}

; Screen point -> "x,y" relative to hwnd's window (the recorder's one piece
; of offset math), or "" when the window is gone.
WinRelPoint(hwnd, mx, my) {
    try {
        WinGetPos(&wx, &wy, , , hwnd)
        return (mx - wx) "," (my - wy)
    }
    return ""
}

RecClick(btn) {
    global recording, steps, recLastHwnd, recLastCrit, lastClick, chkCoordsOnly, recLastAct, recDragPend, chkRawInput
    if !recording
        return
    MouseGetPos(&mx, &my, &hwnd)
    info := ClassifyWindow(hwnd)
    if !IsObject(info)
        return
    FlushTypedText()
    ; The second press of a live double-click also lands here; its gap since
    ; the first press is under the double-click time, far below the floor,
    ; so RecMarkPause stays silent and can't split the pair.
    RecMarkPause()
    RecFocusIfNew(info, hwnd)
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
        recLastAct := now
        lastClick := {tick: 0, x: 0, y: 0, idx: 0}
        recDragPend := 0        ; the step is a dblclick/run now — button-up must not touch it
        return
    }
    ; position-only mode records the spot, not the name
    t := CaptureTarget(mx, my, hwnd, !chkCoordsOnly.Value)
    elem := t.elem, rel := t.rel
    if (elem = "" && rel = "") {             ; the window closed under the click
        UpdateRecBar("Click ignored — its window closed")
        return
    }
    stepType := (btn = "R") ? "rclick" : "click"
    RecPush([stepType, info.crit, elem, rel],
        (btn = "R" ? "Right-click " : "Click ") (elem != "" ? "`"" elem "`"" : "at " rel))
    if (btn = "L") {
        lastClick := {tick: now, x: mx, y: my, idx: steps.Length}
        ; Arm the drag watcher: if the button releases far from here, the
        ; click step just pushed is rewritten into a Drag step (RecDragEnd).
        recDragPend := {idx: steps.Length, x: mx, y: my, hwnd: hwnd, crit: info.crit}
    }
    recLastAct := now
    ; Maximize LATER, not now: this hotkey runs on button-DOWN, and moving
    ; the window mid-gesture would break the user's own click/double-click
    ; (see RecDeferredMax). The captured element/coords above deliberately
    ; reflect the geometry the user actually clicked in.
    SetTimer((*) => RecDeferredMax(hwnd, info.crit), -(DllCall("GetDoubleClickTime") + 150))
}

; Left-button-UP: finish click-vs-drag disambiguation. RecClick records every
; left press as a click step immediately (it can't know yet); if the button
; releases beyond the travel threshold, that step is rewritten in place into
; drag|<window>||x1,y1,x2,y2 — press and release points, window-relative, so
; playback re-selects the same region (text selections, marquee selections,
; sliders). Both points use the window's position at RELEASE time: one
; consistent frame, and if the window moved mid-drag the user's own gesture
; was landing in the moved window anyway. Like every coordinate step it's
; positional (⚠ in the list) — same window layout required.
RecDragEnd() {
    global recording, steps, recDragPend, lastClick, recLastAct
    if (!recording || !IsObject(recDragPend))
        return
    p := recDragPend
    recDragPend := 0
    MouseGetPos(&ux, &uy)
    ; Travel threshold: well past double-click slop (8 px), so hand jitter on
    ; a normal click never fabricates a drag, but a one-word text selection
    ; (~15+ px) still counts.
    if (Abs(ux - p.x) < 12 && Abs(uy - p.y) < 12)
        return                                       ; a click — leave the step as recorded
    if (p.idx > steps.Length || steps[p.idx][1] != "click")
        return                                       ; something else rewrote it (e.g. Explorer run)
    if !WinExist("ahk_id " p.hwnd)
        return
    WinGetPos(&wx, &wy, , , "ahk_id " p.hwnd)
    path := (p.x - wx) "," (p.y - wy) "," (ux - wx) "," (uy - wy)
    steps[p.idx] := ["drag", p.crit, "", path]
    lastClick := {tick: 0, x: 0, y: 0, idx: 0}       ; a drag can't be half of a double-click
    UpdateRecBar("Drag from (" (p.x - wx) "," (p.y - wy) ") to (" (ux - wx) "," (uy - wy) ")")
    WriteAutosave()
    recLastAct := A_TickCount
}

; Mark a HOVER at the current mouse position — Ctrl+Alt+Shift+H while recording.
; Hovers (revealing a menu or tooltip) aren't clicks, so they can't be captured
; automatically; this is the deliberate "do it here" gesture. Same capture as a
; click: the element's accessible name (unless position-only mode is on) with the
; window-relative position kept as the fallback. The engine's hover step moves
; the pointer there and pauses so the menu/tooltip appears.
RecHover() {
    global recording, recLastHwnd, recLastCrit, chkCoordsOnly, recLastAct, chkRawInput
    if !recording
        return
    MouseGetPos(&mx, &my, &hwnd)
    info := ClassifyWindow(hwnd)
    if !IsObject(info) {
        UpdateRecBar("Hover ignored — point at an app window first")
        return
    }
    FlushTypedText()
    RecMarkPause()
    RecFocusIfNew(info, hwnd)
    t := CaptureTarget(mx, my, hwnd, !chkCoordsOnly.Value)
    elem := t.elem, rel := t.rel
    if (elem = "" && rel = "") {
        UpdateRecBar("Hover ignored — its window closed")
        return
    }
    RecPush(["hover", info.crit, elem, rel],
        "Hover " (elem != "" ? "`"" elem "`"" : "at " rel))
    recLastAct := A_TickCount
    ; Maximize AFTER capturing (like the click path) so the recorded coords/name
    ; reflect the geometry the mouse was actually over; the deferred timer avoids
    ; reflowing the window synchronously under the just-pressed hotkey.
    SetTimer((*) => RecDeferredMax(hwnd, info.crit), -(DllCall("GetDoubleClickTime") + 150))
}

; Mark an ASK-FOR-INPUT at the current focus — Ctrl+Alt+Shift+I while recording.
; A small dialog labels the input (typing into it isn't captured — RecChar and
; RecKeyDown ignore the Studio's own windows via ClassifyWindow) and takes an
; optional PRACTICE ANSWER: the recorder itself types it into the app right
; away — unrecorded, via the recSuppress flag — so the app gets real input to
; react to (autocomplete, validation, enabled buttons) without the sample also
; replaying at run time on top of the asked answer. The practice answer is
; saved as the step's suggestion, so run dialogs come pre-filled with it.
; Playback asks for every labeled input BEFORE the run starts and types the
; answer at this step's position, so a recorded workflow takes a fresh value
; each run. If the focused window is new to the take, a Focus step is pushed
; first so the answer lands in the same app the user was in at the hotkey.
RecAskInput() {
    global recording, recLastHwnd, recLastCrit, recLastAct, recSuppress, chkRawInput
    if !recording
        return
    pressTick := A_TickCount        ; any pause ends at the hotkey press — time
                                    ; spent in the label dialog is not app time
    hwnd := WinExist("A")
    info := ClassifyWindow(hwnd)
    FlushTypedText()
    ans := AskLabelDialog()
    if (hwnd && WinExist("ahk_id " hwnd))       ; hand focus back either way, so
        WinActivate("ahk_id " hwnd)             ; the recording continues seamlessly
    if !IsObject(ans) {
        recLastAct := A_TickCount   ; dialog time must not leak into the next gap
        UpdateRecBar("Ask-for-input cancelled")
        return
    }
    RecMarkPause("key", pressTick)  ; before the anchor reset — it reads recLastAct
    recLastAct := A_TickCount
    RecFocusIfNew(info, hwnd)
    RecPush(["ask", ans.label, ans.sample, ""], "Ask for `"" ans.label "`"")
    ; Type the practice answer into the app for the user — suppressed, so the
    ; keyboard hook never turns it into a Type step (playback types the asked
    ; answer at exactly this spot instead).
    if (ans.sample != "" && hwnd && WinExist("ahk_id " hwnd)) {
        recSuppress := true
        try {
            WinActivate("ahk_id " hwnd)
            Sleep(300)              ; same settle beat playback's focus step takes
            SendText(ans.sample)
        } finally {
            recSuppress := false
        }
        UpdateRecBar("Ask for `"" ans.label "`" — typed the practice answer")
    }
    recLastAct := A_TickCount       ; the auto-typing isn't part of the next gap
}

; Mark a COLLECT point at the current focus — Ctrl+Alt+Shift+C while
; recording, pressed AFTER selecting the text to grab. The selecting
; itself is recorded (double-click a word, Ctrl+A, ...), so playback
; re-selects the same way and the collect step copies the selection into
; the workflow's sheet under this label. The dialog previews what is
; selected right now — grabbed under recSuppress, so the preview's own
; Ctrl+C is never recorded. A Focus step is pushed first if the window
; is new to the take, like ask.
RecCollect() {
    global recording, recLastHwnd, recLastCrit, recLastAct, recSuppress, chkRawInput
    if !recording
        return
    pressTick := A_TickCount        ; any pause ends at the hotkey press
    hwnd := WinExist("A")
    info := ClassifyWindow(hwnd)
    FlushTypedText()
    preview := ""
    if IsObject(info) {
        recSuppress := true
        try {
            KeyWait("Ctrl", "T2"), KeyWait("Alt", "T2"), KeyWait("Shift", "T2")
            e := ""
            preview := WfCopySelection(&e)      ; same grab playback will do
        } finally {
            recSuppress := false
        }
    }
    label := CollectLabelDialog(preview)
    if (hwnd && WinExist("ahk_id " hwnd))       ; hand focus back either way
        WinActivate("ahk_id " hwnd)
    if (label = "") {
        recLastAct := A_TickCount   ; dialog time must not leak into the next gap
        UpdateRecBar("Collect cancelled")
        return
    }
    RecMarkPause("key", pressTick)  ; before the anchor reset — it reads recLastAct
    recLastAct := A_TickCount
    RecFocusIfNew(info, hwnd)
    RecPush(["collect", label, "", ""], "Collect `"" label "`"")
}

; Themed dialog naming a collect step's value — the column it becomes in
; the workflow's sheet. Shows what's selected right now so the user knows
; the grab will work. Returns the trimmed label, or "" if cancelled.
CollectLabelDialog(preview) {
    result := ""
    d := Gui("+AlwaysOnTop", "Collect this value")
    d.SetFont("s10", "Segoe UI")
    d.AddText("xm w400", "Save the selected text as — the column name in your sheet:")
    hint := d.AddText("xm y+4 w400", "e.g.  Price   ·   Tracking number   ·   Status")
    ed := d.AddEdit("xm y+10 w400")
    pv := d.AddText("xm y+10 w400 r3", preview != ""
        ? "Selected right now:  " Abbrev(StrReplace(StrReplace(preview, "`r", ""), "`n", "  "), 90)
        : "Nothing seems to be selected right now — usually you select the text FIRST, then press Ctrl+Alt+Shift+C. You can still add the step: playback copies whatever the steps before it leave selected.")
    btnOK := d.AddButton("xm y+12 w120 Default", "OK")
    btnCancel := d.AddButton("x+8 w120", "Cancel")
    OK(*) {
        v := Trim(ed.Value)
        if (v = "")
            return
        result := v
        d.Destroy()
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d, 0, [hint, pv], ed)    ; no owner: the Studio is hidden while recording
    return result
}

; Themed always-on-top dialog for an ask-for-input step: the label (required)
; and an optional practice answer. Returns {label, sample} or "" if cancelled.
; No owner — the Studio window is hidden while recording.
AskLabelDialog() {
    result := ""
    d := Gui("+AlwaysOnTop", "Ask me for input")
    d.SetFont("s10", "Segoe UI")
    d.AddText("xm w400", "Label this input — what should playback ask you for?")
    hint := d.AddText("xm y+4 w400", "e.g.  Customer name   ·   Order number   ·   Today's notes")
    ed := d.AddEdit("xm y+10 w400")
    d.AddText("xm y+14 w400", "Answer to use while recording  (optional):")
    hint2 := d.AddText("xm y+4 w400 r3", "VoiceKit types this into the app for you now, WITHOUT recording it — so the app reacts normally while you record, and only the real answer is typed when the workflow runs. It's also offered as the suggested answer.")
    edSample := d.AddEdit("xm y+6 w400")
    btnOK := d.AddButton("xm y+14 w120 Default", "OK")
    btnCancel := d.AddButton("x+8 w120", "Cancel")
    OK(*) {
        v := Trim(ed.Value)
        if (v = "")
            return
        result := {label: v, sample: edSample.Value}
        d.Destroy()
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d, 0, [hint, hint2], ed)
    return result
}

; Full path of THE item selected in an Explorer window's active tab, or ""
; (nothing, several, or a virtual item such as a file inside a .zip — the
; double-click then stays a plain double-click step). lib\ExplorerSel.ahk
; is the one copy of the tab-correct lookup; this used to read whichever tab
; Shell.Application listed first, so a recorded double-click could become a
; `run` of a file in a BACKGROUND tab.
ExplorerSelection(hwnd) {
    sel := ExplorerSelectedFiles(hwnd)
    return sel.Length = 1 ? sel[1] : ""
}

; Full path of the folder an Explorer window's active tab is showing, or "".
ExplorerPath(hwnd) => ExplorerFolderPath(hwnd)

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
    global recording, typedBuf, lastCharTick, recLastAct, recSuppress
    if (!recording || recSuppress || Ord(char) < 32)
        return
    if !IsObject(ClassifyWindow(WinExist("A")))   ; ignore typing into Start menu / own UI
        return
    ; A new burst of typing starts here; whatever it later flushes into a Type
    ; step, the pause the user took BEFORE typing belongs in front of it — and
    ; every flush trigger pushes the Type step next, so the Wait lands right
    ; before it. Pauses WITHIN a burst don't split it (the buffer only flushes
    ; after 1.5 s idle, and a fresh burst after that gets its own Wait).
    if (typedBuf = "")
        RecMarkPause("key")
    typedBuf .= char
    lastCharTick := A_TickCount
    recLastAct := lastCharTick
    UpdateRecBar("Typing: `"" typedBuf "`"")
}

RecKeyDown(h, vk, sc) {
    global recording, typedBuf, recLastAct, recSuppress
    if (!recording || recSuppress)
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
    if (key = "h" && ctrl && alt && shift)
        return                              ; the mark-hover hotkey, not a workflow step
    if (key = "i" && ctrl && alt && shift)
        return                              ; the ask-for-input hotkey, not a workflow step
    if (key = "c" && ctrl && alt && shift)
        return                              ; the mark-collect hotkey, not a workflow step
    mods := (ctrl ? "^" : "") (alt ? "!" : "") (win ? "#" : "")
    if (key = "Backspace" && mods = "") {
        if (typedBuf != "") {               ; natural correction: un-type the last char
            typedBuf := SubStr(typedBuf, 1, -1)
            recLastAct := A_TickCount       ; a correction is activity too
            UpdateRecBar("Typing: `"" typedBuf "`"")
        } else {
            RecMarkPause("key")
            RecPush(["keys", "{Backspace}", "", ""], "Press Backspace")
            recLastAct := A_TickCount
        }
        return
    }
    isSpecial := key ~= "i)^(Enter|NumpadEnter|Tab|Escape|Backspace|Delete|Del|Insert|Ins|Home|End|PgUp|PgDn|Up|Down|Left|Right|AppsKey|PrintScreen|Pause|F\d\d?)$"
    if (mods = "" && !isSpecial)
        return                              ; plain character — OnChar records it
    if (mods != "" && !isSpecial && StrLen(key) != 1)
        return                              ; modifier + exotic key (volume etc.) — skip
    FlushTypedText()
    RecMarkPause("key")             ; e.g. typed a name, waited for the
                                    ; suggestion list, THEN pressed Down
    combo := mods (shift ? "+" : "") "{" key "}"
    RecPush(["keys", combo, "", ""], "Press " combo)
    recLastAct := A_TickCount
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

; {{names}} nothing in this workflow sets. A WARNING, never a block: the step
; still runs (it types the name exactly as written), and a Set inside an
; if-branch is perfectly legitimate — so this asks rather than refuses.
; Silent in the normal case, when every reference resolves.
UndefinedVarsOk(steps) {
    global g
    u := WfUndefinedVars(steps)
    if !u.Length
        return true
    return MsgBox("These values are used but never set by this workflow:`n`n    {{"
        . JoinList(u, "}}`n    {{") "}}`n`n"
        . "They'll be typed exactly as written. Add an Ask, Collect or Set step "
        . "if you meant them to hold something.`n`nCarry on anyway?",
        "Workflow Studio", "YesNo Icon! Owner" g.Hwnd) = "Yes"
}

TestRun(*) {
    global steps, g, currentPhrase, wfRunName, wfSelection
    StopRecording()
    if !steps.Length {
        SB("Nothing to run — record or add steps first.")
        return
    }
    if (berr := BlockBalanceError(steps)) {
        MsgBox(berr, "Workflow Studio", "Icon! Owner" g.Hwnd)
        return
    }
    if !UndefinedVarsOk(steps)
        return
    g.Hide()
    Sleep(500)
    ; Collect steps run for real during a test (so their grabbing is
    ; verified), but the values are only SHOWN — a test never writes to
    ; the workflow's sheet.
    collected := Map()
    collected.CaseSense := false
    vars := Map()                       ; every named value, so a test shows
    vars.CaseSense := false             ; what each {{Name}} actually became
    ; Name the run so its log lines and record say which workflow this was
    ; (an unnamed one lands under "Unnamed" and tells you nothing later).
    wfRunName := currentPhrase != "" ? StrReplace(currentPhrase, " ") : "StudioDraft"
    ; A fresh Explorer-selection snapshot per test ({{selected_file}}): the
    ; Studio lives on between tests, and the user may pick another file.
    wfSelection := ""
    ok := RunWorkflowSteps(steps, , collected, vars)
    g.Show()
    if (ok && vars.Count) {
        got := ""
        for l, v in vars
            got .= (got != "" ? "`n" : "") "{{" l "}}:  "
                . Abbrev(StrReplace(StrReplace(v, "`r", ""), "`n", "  "), 80)
                . (collected.Has(l) ? "     (a real run saves this to your sheet)" : "")
        MsgBox("Test run completed — all " steps.Length " steps ran.`n`n"
            . "Values:`n" got, "Workflow Studio", "Owner" g.Hwnd)
        SB("Test run completed — all " steps.Length " steps ran.")
        return
    }
    SB(ok ? "Test run completed — all " steps.Length " steps ran."
        : WfRunOutcome() = "error" ? "Test run didn't start (details were just shown)."
          : "Test run stopped — a step failed (details were just shown).")
}

; Write the workflow's three artifacts (+ its Start Menu entries).
;
; A workflow that already has a name saves straight over itself: no name
; prompt, no "here's your phrase" popup. Nothing about a re-save needs
; deciding or announcing — the name can't have changed and the phrase is
; already known — so the dialogs were pure friction on the edit-test-save
; loop. Only a brand-new workflow is asked for a name, and only it gets the
; popup teaching the two phrases it just gained.
;
; closeAfter (the "Save and Close" button): exit once saved. Recording is
; stopped and the autosave cleared by then, so this is the same clean exit
; CloseStudio does — minus its discard prompt, which can't fire on a list
; that was just saved.
SaveWorkflow(closeAfter := false) {
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
    if !UndefinedVarsOk(steps)
        return
    resave := (currentPhrase != "")     ; loaded from the dropdown, or saved earlier
    phrase := resave ? currentPhrase : SaveNameDialog()
    if (phrase = "")
        return
    base := StrReplace(phrase, " ")
    if IsReservedName(base) {
        MsgBox("'" base "' is a reserved Windows name and can't be used as a file. Pick another.", "Workflow Studio", "Owner" g.Hwnd)
        return
    }
    ; VoiceKit's own tools, caselessly: a workflow stub under one of their
    ; names would overwrite the tool's own script — the Studio's included,
    ; whose source carries the stub marker text itself. Refused even on a
    ; re-save (a workflow saved under such a name before this check); the
    ; next Save then asks for a new name.
    if VkDeleteProtected(base) {
        MsgBox("'" phrase "' is the name of one of VoiceKit's own tools, so a workflow can't use it."
            . (resave ? " Click Save again to give this workflow a different name." : " Pick another name."),
            "Workflow Studio", "Icon! Owner" g.Hwnd)
        if resave
            currentPhrase := ""
        return
    }
    ; A NEW name that's already a saved workflow used to replace it without
    ; a word. Ask first. (Re-saving the loaded workflow is what Save is for,
    ; and stays silent.)
    if (!resave && (existing := SavedWorkflowBase(base)) != "") {
        if !ConfirmReplaceDialog(SpaceOut(existing), steps.Length)
            return
        base := existing
    }
    macroFile := root "\macros\" base ".ahk"
    if (FileExist(macroFile) && !IsWorkflowStub(macroFile)) {
        MsgBox("A hand-written macro named '" base "' already exists. Pick another name.", "Workflow Studio", "Owner" g.Hwnd)
        return
    }

    content := "; " phrase " — VoiceKit workflow. Edit it by saying: open workflow studio`n"
    for s in steps
        content .= s[1] "|" WfEncode(s[2]) "|" WfEncode(s[3]) "|" WfEncode(s.Length >= 4 ? s[4] : "") "`n"
    f := FileOpen(root "\workflows\" base ".steps.txt", "w", "UTF-8")
    f.Write(content)
    f.Close()

    f := FileOpen(macroFile, "w", "UTF-8")
    f.Write(WfStubContent(phrase, base))
    f.Close()

    ; Name the shortcut by SpaceOut(base) — the same name the dropdown,
    ; DeleteWorkflow and first-run reinstall all use — so they never drift
    ; apart (they did for names with a digit right after a letter, which
    ; orphaned the .lnk on delete).
    disp := SpaceOut(base)
    EnsureVoiceShortcut(disp, macroFile)
    MakeLoopShortcut(root, base, disp)     ; companion "loop <disp>" entry (repeats until stopped)

    Log(root, "workflow | " phrase " | workflows\" base ".steps.txt")
    currentPhrase := disp
    dirty := false
    ClearAutosave()          ; the take is safely persisted now
    RefreshWorkflowList(disp)
    if !resave                       ; first save: teach the phrases it just gained
        MsgBox("Saved.`n`nRun it once:   open " disp
            . "`nRepeat it:     open loop " disp "   (then click Stop Looping to end)"
            . "`n`n(First time only: give Windows a few seconds to index the new Start Menu entries.)", "Workflow Studio", "Owner" g.Hwnd)
    else if !closeAfter
        SB("Saved '" disp "' — " steps.Length " steps. Say `"open " disp "`" to run it.")
    if !closeAfter
        return
    g.Hide()                         ; go away instantly; the tray confirms the save
    if resave
        Notify("Saved '" disp "' — " steps.Length " steps.")
    ExitApp()
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
    DeleteWorkflowArtifacts(root, base, sel)     ; steps, stub, .lnks, companion hotkey
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
        . "  2.  Just do the thing. Window switches, clicks, drags and typing are captured.`n"
        . "       Clicks are remembered by the NAME of what you clicked, so they`n"
        . "       keep working when windows move. Double-clicking a file in`n"
        . "       Explorer records `"Open <that file>`" with its full path.`n"
        . "       To capture a HOVER (e.g. to open a menu that only appears`n"
        . "       when the mouse rests on something), point at it and press`n"
        . "       Ctrl+Alt+Shift+H — a Hover step is added where the mouse is.`n"
        . "       To make playback ASK YOU for a value that changes each run`n"
        . "       (a name, a number, today's notes), press Ctrl+Alt+Shift+I`n"
        . "       and label the input — the run asks for every labeled input`n"
        . "       up front, then types your answer at that spot. Looping a`n"
        . "       workflow with inputs can even take a whole list at once`n"
        . "       (typed in, or a CSV whose columns are the labels).`n"
        . "  3.  Stop with the REC bar's Stop button, by saying `"click stop`",`n"
        . "       or by pressing Ctrl+Alt+Shift+X. Then trim or edit the steps —`n"
        . "       double-click a row to edit, and click Add to insert a pause if`n"
        . "       an app needs time to load.`n"
        . "  4.  Test plays it. Save makes it a voice command: say `"open <name>`".`n"
        . "       You're only asked for a name the first time — saving a workflow`n"
        . "       you already named just overwrites it, no questions asked. `"Save`n"
        . "       and Close`" does the same and shuts the Studio.`n`n"
        . "Playback matches your pace: pauses you take while recording (for`n"
        . "a page to load, a menu to appear) are saved as editable Wait steps`n"
        . "— delete any you don't want. It's patient beyond that too, waiting`n"
        . "up to 10 seconds for each window to appear.`n`n"
        . "Tips: `"Close browser tabs before recording`" starts from a fresh`n"
        . "browser (leftover tabs shift things). `"Maximize windows while`n"
        . "recording`" locks in one window layout — playback re-maximizes the`n"
        . "same windows, so nothing has moved. `"Record clicks by position`n"
        . "only`" ignores element names and stores just the X,Y spot — for`n"
        . "maps, canvases and games where names aren't reliable. `"Record raw`n"
        . "input only`" turns the smart extras off — no automatic Wait steps,`n"
        . "no window-switch steps, no maximizing — for quick key sequences`n"
        . "that should replay exactly what you pressed, into whatever window`n"
        . "is active. Steps marked`n"
        . "⚠ were captured by position only and are the first thing to fix if`n"
        . "playback misses.`n`n"
        . "Notes: don't type passwords while recording; dragging (press, move,`n"
        . "release — selecting text or a region) is captured as a Drag step`n"
        . "(by position, so it's marked ⚠), but scrolling isn't. Every`n"
        . "button is voice-clickable — say `"click`" plus its word: `"click`n"
        . "record`", `"click add`", `"click test`", `"click save`", `"click save`n"
        . "and close`".`n`n"
        . "See everything you've made in one place: say `"open voice kit`".",
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
    global chkCloseTabs, chkMaxWins, chkCoordsOnly, chkRawInput, chkJitter, wfClickJitterPx
    chkCloseTabs.Value := (IniRead(SettingsFile(), "Studio", "CloseBrowserTabs", "0") = "1")
    chkMaxWins.Value := (IniRead(SettingsFile(), "Studio", "MaximizeWhileRecording", "1") = "1")
    chkCoordsOnly.Value := (IniRead(SettingsFile(), "Studio", "CoordsOnly", "0") = "1")
    chkRawInput.Value := (IniRead(SettingsFile(), "Studio", "RawInput", "0") = "1")
    ; [Workflow] ClickJitter is pixels, not a flag — the checkbox is the
    ; on/off face of it, and someone who wants a different amount can put a
    ; number in the file without the box overwriting it on load. Try-wrapped:
    ; this runs at startup, and a hand-edited non-number must not kill the
    ; Studio launch (every other read here compares strings and can't throw).
    jit := 3
    try jit := Integer(IniRead(SettingsFile(), "Workflow", "ClickJitter", "3"))
    chkJitter.Value := (jit > 0)
    ; Also prime the engine's in-process override: Test runs the engine in
    ; THIS process, and WfClickJitter() caches its ini read — without this,
    ; toggling the box wouldn't affect Test until the Studio restarted.
    wfClickJitterPx := jit
    SyncRawUI()
}
SaveSettings(*) {
    global chkCloseTabs, chkMaxWins, chkCoordsOnly, chkRawInput, chkJitter, wfClickJitterPx
    EnsureDir(RegExReplace(SettingsFile(), "\\[^\\]+$"))
    IniWrite(chkCloseTabs.Value ? 1 : 0, SettingsFile(), "Studio", "CloseBrowserTabs")
    IniWrite(chkMaxWins.Value ? 1 : 0, SettingsFile(), "Studio", "MaximizeWhileRecording")
    IniWrite(chkCoordsOnly.Value ? 1 : 0, SettingsFile(), "Studio", "CoordsOnly")
    IniWrite(chkRawInput.Value ? 1 : 0, SettingsFile(), "Studio", "RawInput")
    ; Ticking restores the default 3 px only when it was off; a custom amount
    ; already in the file survives a tick of any other box on this panel.
    cur := 3
    try cur := Integer(IniRead(SettingsFile(), "Workflow", "ClickJitter", "3"))
    jit := chkJitter.Value ? (cur > 0 ? cur : 3) : 0
    IniWrite(jit, SettingsFile(), "Workflow", "ClickJitter")
    wfClickJitterPx := jit          ; keep this process's Test in step (see LoadSettings)
    SyncRawUI()
}
; Raw-input mode records only what the user actually does, so the Maximize
; option (which both resizes windows and records move|max steps) is moot
; while it's on — gray it out to say so. Its saved value is untouched, so
; unticking raw restores whatever the user had.
SyncRawUI() {
    global chkMaxWins, chkRawInput
    chkMaxWins.Enabled := !chkRawInput.Value
}

SB(text) {
    global statusBar
    statusBar.Text := text          ; status is a themed Text control, not a StatusBar
}
