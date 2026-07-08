#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Workflow Studio — build, record, test and save multi-step
;  workflows in a dialog. No code required.
;
;  Open it by voice:  "open workflow studio"
;  (or: New Automation -> Step Workflow)
;
;  Start Recording captures what you actually do:
;    - window switches            -> Focus steps
;    - clicks (double/right too)  -> Click steps, stored by the
;      clicked element's on-screen NAME (button caption, link,
;      file name), with the raw position kept only as fallback
;    - double-clicking a file in Explorer -> "Open <full path>"
;    - typing                     -> editable Type-text steps
;    - special keys / shortcuts   -> Press-keys steps
;  While recording, the Studio hides and a small REC bar floats
;  top-right; finish with its Stop button, by voice ("click
;  stop"), or with Ctrl+Alt+Shift+X.
;
;  Then Test Run plays it, and Save Workflow makes it a voice
;  command: "open <name>". Reopen the Studio any time to edit.
;
;  Don't type passwords while recording — keystrokes become
;  visible steps (that's the point, but remember it).
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"

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

typeIds    := ["focus", "run", "waitwin", "wait", "text", "keys", "click", "dblclick", "rclick", "move", "close"]
typeLabels := ["Focus window (launch it if needed)"
             , "Open app / file / website"
             , "Wait for a window to appear"
             , "Wait (pause for milliseconds)"
             , "Type text"
             , "Press keys (e.g. {Enter}, ^s)"
             , "Click something in a window (by its name)"
             , "Double-click something in a window"
             , "Right-click something in a window"
             , "Position window (left / right / top / bottom / max)"
             , "Close window"]

; ---- click capture + stop hotkey (active only while recording) ----
#HotIf recording
~*LButton:: RecClick("L")
~*RButton:: RecClick("R")
^!+x:: StopRecording()      ; backup stop — works even if the REC bar is covered
#HotIf

; ---- main window ----
g := Gui("+AlwaysOnTop", "Workflow Studio")
g.SetFont("s10", "Segoe UI")
g.AddText("xm ym+4", "Workflow:")
ddl := g.AddDropDownList("x+8 yp-4 w340", [])
btnDel := g.AddButton("x+8 yp-1 w140", "Delete Workflow")
lv := g.AddListView("xm y+12 w700 r14 -Multi Grid NoSortHdr NoSort", ["#", "Step"])
btnAdd  := g.AddButton("xm y+10 w110", "Add Step")
btnEdit := g.AddButton("x+8 w110", "Edit Step")
btnRem  := g.AddButton("x+8 w110", "Remove Step")
btnUp   := g.AddButton("x+8 w110", "Move Up")
btnDown := g.AddButton("x+8 w110", "Move Down")
btnRec  := g.AddButton("xm y+8 w170 h34", "Start Recording")
btnTest := g.AddButton("x+8 w140 h34", "Test Run")
btnSave := g.AddButton("x+8 w170 h34", "Save Workflow")
btnHelp := g.AddButton("x+8 w110 h34", "Studio Help")
statusBar := g.AddStatusBar()

; ---- floating REC bar (shown while recording) ----
recBar := Gui("+AlwaysOnTop +ToolWindow -Caption +Border")
recBar.SetFont("s10", "Segoe UI")
recBar.MarginX := 12
recBar.MarginY := 10
recBar.SetFont("s10 bold cRed")
recBar.AddText("ym", "REC")
recBar.SetFont("s10 norm cDefault")
recNote := recBar.AddText("x+12 yp w360", "Recording...")
recCount := recBar.AddText("x+8 yp w70 Right", "0 steps")
btnStop := recBar.AddButton("x+12 yp-6 w90", "Stop")
btnStop.OnEvent("Click", (*) => StopRecording())

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
g.OnEvent("Close", CloseStudio)

RefreshWorkflowList()
NewWorkflowState()
g.Show()

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
    SB("New workflow — click Start Recording and just do the thing, or build with Add Step.")
}

; ============================================================
;  Step list editing
; ============================================================
RefreshLV() {
    global lv, steps
    lv.Delete()
    for i, s in steps
        lv.Add(, i, WfDesc(s))
    lv.ModifyCol(1, 40)
    lv.ModifyCol(2, 640)
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
    global g, dialogOpen, typeIds, typeLabels
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
    btnGrab := d.AddButton("xm y+12 w220", "Grab a Window (3 sec)")
    btnBrowse := d.AddButton("x+8 w180", "Browse for File...")
    btnOK := d.AddButton("xm y+14 w120 Default", "OK")
    btnCancel := d.AddButton("x+8 w120", "Cancel")

    UpdateFields(*) {
        t := typeIds[dt.Value]
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
        laB.Text := labels[t][2]
        laB.Visible := needB
        edB.Visible := needB
        btnGrab.Visible := (t != "run" && t != "wait" && t != "text" && t != "keys")
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

    Browse(*) {
        f := FileSelect(3, , "Pick the file to open")
        if (f != "")
            edA.Value := f
    }

    OK(*) {
        t := typeIds[dt.Value]
        a := Trim(edA.Value)
        b := Trim(edB.Value)
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
    btnBrowse.OnEvent("Click", Browse)
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())

    if IsObject(existing) {
        idx := 1
        for i, id in typeIds
            if (id = existing[1])
                idx := i
        dt.Choose(idx)
        UpdateFields()
        edA.Value := existing[2]
        edB.Value := existing[3]
    } else {
        dt.Choose(1)
        UpdateFields()
    }

    hwnd := d.Hwnd
    d.Show()                        ; show and activate first...
    g.Opt("+Disabled")              ; ...then disable the Studio behind it
    WinActivate("ahk_id " hwnd)     ; make sure the dialog has focus
    WinWaitClose("ahk_id " hwnd)
    g.Opt("-Disabled")
    WinActivate("ahk_id " g.Hwnd)
    dialogOpen := false
    return result
}

; ============================================================
;  Recorder — captures window switches, clicks and typing.
;  Clicks are stored by accessible element NAME (position kept
;  only as fallback); keystrokes become visible, editable steps.
; ============================================================
StartRecording() {
    global recording, recLastHwnd, recLastCrit, typedBuf, lastClick, g, recBar
    if recording
        return
    recording := true
    typedBuf := ""
    recLastHwnd := 0
    recLastCrit := ""
    lastClick := {tick: 0, x: 0, y: 0, idx: 0}
    StartKeyHook()
    g.Hide()
    UpdateRecBar("Recording — stop: Stop button or Ctrl+Alt+Shift+X")
    recBar.Show("NoActivate x" (A_ScreenWidth - 640) " y10")
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
    SB("Recorded — now trim/edit steps, add waits if needed, Test Run, then Save Workflow.")
}

RecPush(step, note) {
    global steps, dirty
    steps.Push(step)
    dirty := true
    UpdateRecBar(note)
}

UpdateRecBar(note) {
    global recNote, recCount, steps
    recNote.Text := Abbrev(note, 52)
    recCount.Text := steps.Length " steps"
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
TestRun(*) {
    global steps, g
    StopRecording()
    if !steps.Length {
        SB("Nothing to run — record or add steps first.")
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
    ; InputBox can't be owned, so it would land behind the
    ; always-on-top Studio — drop topmost while it's up.
    g.Opt("-AlwaysOnTop")
    ib := InputBox("Name this workflow — the name becomes its voice phrase:`n`n        `"open <name>`"", "Save Workflow", "w440 h170", currentPhrase)
    g.Opt("+AlwaysOnTop")
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    phrase := CleanPhrase(ib.Value)
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

    vmDir := A_Programs "\Voice Macros"
    EnsureDir(vmDir)
    if !FileExist(vmDir "\" phrase ".lnk")
        MakeAhkShortcut(vmDir "\" phrase ".lnk", macroFile)

    Log(root, "workflow | " phrase " | workflows\" base ".steps.txt")
    currentPhrase := phrase
    dirty := false
    RefreshWorkflowList(SpaceOut(base))
    MsgBox("Saved. Run it any time by saying:`n`n        open " phrase
        . "`n`n(First time only: give Windows a few seconds to index the new Start Menu entry.)", "Workflow Studio", "Owner" g.Hwnd)
}

DeleteWorkflow(*) {
    global ddl, ddlMap, root, g
    sel := ddl.Text
    if !ddlMap.Has(sel) {
        SB("Pick a saved workflow in the dropdown first.")
        return
    }
    if (MsgBox("Delete workflow '" sel "'?`n`nRemoves its steps file, its macro, and its Start Menu entry.",
        "Workflow Studio", "YesNo Icon! Owner" g.Hwnd) != "Yes")
        return
    base := ddlMap[sel]
    try FileDelete(root "\workflows\" base ".steps.txt")
    macroFile := root "\macros\" base ".ahk"
    if (FileExist(macroFile) && InStr(FileRead(macroFile, "UTF-8"), "Workflow Studio"))
        try FileDelete(macroFile)
    try FileDelete(A_Programs "\Voice Macros\" sel ".lnk")
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
        . "  1.  Click Start Recording — the Studio hides, a REC bar floats top-right.`n"
        . "  2.  Just do the thing. Window switches, clicks and typing are captured.`n"
        . "       Clicks are remembered by the NAME of what you clicked, so they`n"
        . "       keep working when windows move. Double-clicking a file in`n"
        . "       Explorer records `"Open <that file>`" with its full path.`n"
        . "  3.  Stop with the REC bar's Stop button, by saying `"click stop`",`n"
        . "       or by pressing Ctrl+Alt+Shift+X. Then trim or edit the steps —`n"
        . "       double-click a row to edit, and add pauses with Add Step if an`n"
        . "       app needs time to load.`n"
        . "  4.  Test Run plays it. Save Workflow makes it a voice command:`n"
        . "       say  `"open <name>`".`n`n"
        . "Notes: don't type passwords while recording; drags and scrolling`n"
        . "aren't captured. Every button is voice-clickable (`"click add step`").",
        "Workflow Studio — help", "Owner" g.Hwnd)
}

CloseStudio(*) {
    global dirty
    StopRecording()
    if (dirty && !ConfirmDiscard())
        return true
    ExitApp()
}

ConfirmDiscard() {
    global g
    return MsgBox("Discard unsaved changes to this workflow?", "Workflow Studio", "YesNo Icon? Owner" g.Hwnd) = "Yes"
}

SB(text) {
    global statusBar
    statusBar.SetText("  " text)
}

Abbrev(s, n) {
    return StrLen(s) > n ? SubStr(s, 1, n) "..." : s
}

SpaceOut(camel) {
    return Trim(RegExReplace(camel, "([a-z0-9])([A-Z])", "$1 $2"))
}

; Self-heal the Start Menu entry so "open workflow studio" works
; even on installs made before this feature existed.
EnsureStudioShortcut() {
    vmDir := A_Programs "\Voice Macros"
    EnsureDir(vmDir)
    if !FileExist(vmDir "\Workflow Studio.lnk")
        MakeAhkShortcut(vmDir "\Workflow Studio.lnk", A_ScriptFullPath)
}
