#Requires AutoHotkey v2.0
; ============================================================
;  WorkflowLoop.ahk — run a saved workflow's steps over and over
;  until the user stops it. Powers the "loop <name>" shortcuts.
;
;  Self-contained: it pulls in its own dependencies so it loads
;  cleanly on its own as well as via LoopRunner.ahk —
;    Workflow.ahk -> WorkflowLoad, RunWorkflowSteps (and Acc.ahk)
;    Theme.ahk    -> ThemeBar, ShowBottomLeft
;  (%A_LineFile% resolves relative to THIS file, so it works no
;  matter which script includes it. Do not also #Include these
;  from the host, or AHK will report duplicate definitions.)
;
;  Stop while looping: the floating "Stop Looping" button
;  (voice: "click stop looping") or Ctrl+Alt+Shift+X. A loop also
;  stops on its own if a step fails (so a broken workflow can't spin).
;
;  Workflows with `ask` steps: before looping starts, a chooser
;  offers to import a CSV (columns = the input labels; one pass
;  per row), type a batch of rows in, or ask each pass. With a
;  batch, the loop runs the rows in order and stops by itself.
; ============================================================
#Include "%A_LineFile%\..\Workflow.ahk"
#Include "%A_LineFile%\..\Theme.ahk"

global wfLoopStop := false

; Run stepsFile top-to-bottom repeatedly, pausing delayMs between passes,
; until stopped or a step fails. Shows a small always-on-top status bar.
RunWorkflowLoop(stepsFile, phrase, delayMs := 1500) {
    global wfLoopStop
    wfLoopStop := false

    if !FileExist(stepsFile) {
        MsgBox("Workflow file not found:`n" stepsFile, "VoiceKit loop", "Iconx 262144")   ; 262144 = always-on-top
        return
    }
    steps := WorkflowLoad(stepsFile)
    if !steps.Length {
        MsgBox("This workflow has no steps to loop.", "VoiceKit loop", "Icon! 262144")
        return
    }

    ; Workflows that ask for input: batch the answers up front (CSV or
    ; typed-in rows — one loop pass per row), or fall back to asking
    ; every pass. rows = "" means no batch (ask each pass, or no asks).
    rows := ""
    labels := WfAskLabels(steps)
    if labels.Length {
        plan := WfLoopInputPlan(labels, phrase)
        if !IsObject(plan)
            return                               ; cancelled
        if (plan.mode = "rows")
            rows := plan.rows
    }

    ; ---- floating status bar (bottom-left, clear of the taskbar) ----
    bar := Gui("+AlwaysOnTop +ToolWindow -Caption +Border")
    bar.MarginX := 14, bar.MarginY := 11
    bar.SetFont("s10 bold", "Segoe UI")
    bar.AddText("ym", "Looping")
    bar.SetFont("s10 norm", "Segoe UI")
    barNote := bar.AddText("x+12 yp w280", phrase)
    barCount := bar.AddText("x+8 yp w80 Right", "run 0")
    bar.SetFont("s11 bold", "Segoe UI")
    barBtn := bar.AddButton("x+12 yp-8 w160 h36 Default", "■  Stop Looping")
    bar.SetFont("s10 norm", "Segoe UI")
    barBtn.OnEvent("Click", (*) => WfLoopRequestStop())
    ThemeBar(bar, barNote, barCount, barBtn)
    ShowBottomLeft(bar)

    i := 0
    ok := true
    loop {
        if wfLoopStop
            break
        if (IsObject(rows) && i >= rows.Length)
            break
        i += 1
        barCount.Text := IsObject(rows) ? ("row " i "/" rows.Length) : ("run " i)
        ok := RunWorkflowSteps(steps, IsObject(rows) ? rows[i] : "")
        if !ok                             ; a failing step already showed its popup — don't keep spinning
            break
        if (IsObject(rows) && i >= rows.Length)
            break                          ; last row done — skip the trailing pause
        WfLoopSleep(delayMs)               ; interruptible pause; also returns at once if stop was requested
    }
    bar.Destroy()
    if (IsObject(rows) && ok && !wfLoopStop && i >= rows.Length)
        MsgBox("Done — ran '" phrase "' for all " rows.Length " row" (rows.Length = 1 ? "" : "s") ".",
            "VoiceKit loop", "262144")
}

; ------------------------------------------------------------
;  Batched inputs for looping workflows that ask for input
; ------------------------------------------------------------

; Chooser: how should this loop get its inputs? Returns
;   {mode:"rows", rows:[Map(label->answer), ...]}  — batch, one pass per row
;   {mode:"each"}                                  — ask dialogs every pass
;   ""                                             — cancelled
WfLoopInputPlan(labels, phrase) {
    result := ""
    joined := ""
    for l in labels
        joined .= (A_Index > 1 ? "  ·  " : "") l
    d := Gui("+AlwaysOnTop", "Loop " phrase " — inputs")
    d.SetFont("s10", "Segoe UI")
    d.AddText("xm w440", "'" phrase "' asks for:")
    d.SetFont("s10 bold")
    d.AddText("xm y+4 w440", joined)
    d.SetFont("s10 norm")
    d.AddText("xm y+10 w440", "Give the answers for every pass now — the loop runs once per row and stops on its own — or answer fresh each time around.")
    btnCsv  := d.AddButton("xm y+14 w440 h34 Default", "Import a CSV file  (columns named like the inputs)")
    btnType := d.AddButton("xm y+8 w440 h34", "Type the rows in")
    btnEach := d.AddButton("xm y+8 w440 h34", "Ask me each time around")
    btnCancel := d.AddButton("xm y+12 w120", "Cancel")
    Csv(*) {
        rows := WfLoopImportCsv(labels, d)
        if IsObject(rows) {
            result := {mode: "rows", rows: rows}
            d.Destroy()
        }
    }
    TypeIn(*) {
        d.Hide()
        rows := WfLoopTypeRows(labels)
        if IsObject(rows) {
            result := {mode: "rows", rows: rows}
            d.Destroy()
        } else
            d.Show()
    }
    btnCsv.OnEvent("Click", Csv)
    btnType.OnEvent("Click", TypeIn)
    btnEach.OnEvent("Click", (*) => (result := {mode: "each"}, d.Destroy()))
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeApply(d)
    hwnd := d.Hwnd                      ; pre-Show: reads on a destroyed Gui throw
    d.Show()
    try WinActivate("ahk_id " hwnd)     ; dialog may be dismissed before this runs
    WinWaitClose("ahk_id " hwnd)
    return result
}

; Pick and read a CSV whose header row names every ask label (case-
; insensitive; extra columns are ignored). Returns [Map(label->answer),...]
; or "" if cancelled / invalid (the problem is explained, chooser stays up).
WfLoopImportCsv(labels, owner) {
    f := FileSelect(1, , "Pick the CSV file", "CSV / text (*.csv; *.txt)")
    if (f = "")
        return ""
    recs := ""
    try recs := WfCsvParse(FileRead(f, "UTF-8"))
    catch {
        MsgBox("Couldn't read that file.", "VoiceKit loop", "Iconx Owner" owner.Hwnd)
        return ""
    }
    if (!IsObject(recs) || recs.Length < 2) {
        MsgBox("That CSV needs a header row (the input names) plus at least one row of answers.",
            "VoiceKit loop", "Icon! Owner" owner.Hwnd)
        return ""
    }
    ; header -> column index per label
    cols := Map()
    cols.CaseSense := false
    for j, h in recs[1]
        if (Trim(h) != "" && !cols.Has(Trim(h)))
            cols[Trim(h)] := j
    missing := ""
    for l in labels
        if !cols.Has(l)
            missing .= (missing != "" ? ", " : "") l
    if (missing != "") {
        MsgBox("The CSV is missing a column for: " missing
            . "`n`nIts header row must name every input (extra columns are fine).",
            "VoiceKit loop", "Icon! Owner" owner.Hwnd)
        return ""
    }
    rows := []
    Loop recs.Length - 1 {
        rec := recs[A_Index + 1]
        blank := true                          ; skip fully-empty lines
        for v in rec
            if (Trim(v) != "") {
                blank := false
                break
            }
        if blank
            continue
        row := Map()
        row.CaseSense := false
        for l in labels {
            j := cols[l]
            row[l] := (j <= rec.Length) ? rec[j] : ""
        }
        rows.Push(row)
    }
    if !rows.Length {
        MsgBox("That CSV has a header but no rows of answers.", "VoiceKit loop", "Icon! Owner" owner.Hwnd)
        return ""
    }
    return rows
}

; Type a batch of rows by hand: one edit per label, "Add Row" stores the
; set and clears the fields, "Start Loop" finishes (adding any half-typed
; row first). Returns [Map(label->answer),...] or "" if cancelled.
WfLoopTypeRows(labels) {
    rows := []
    result := ""
    d := Gui("+AlwaysOnTop", "Loop inputs — type the rows in")
    d.SetFont("s10", "Segoe UI")
    edits := Map()
    for l in labels {
        d.AddText(A_Index = 1 ? "xm w400" : "xm y+8 w400", l ":")
        edits[l] := d.AddEdit("xm y+2 w400")
    }
    cnt := d.AddText("xm y+10 w400", "0 rows added")
    btnAdd := d.AddButton("xm y+8 w190 h32 Default", "＋  Add Row")
    btnGo  := d.AddButton("x+8 w202 h32", "▶  Start Loop")
    btnCancel := d.AddButton("xm y+8 w120", "Cancel")
    Grab() {                                  ; current fields -> a row, if anything is filled in
        any := false
        for l in labels
            if (Trim(edits[l].Value) != "")
                any := true
        if !any
            return false
        row := Map()
        row.CaseSense := false
        for l in labels {
            row[l] := edits[l].Value
            edits[l].Value := ""
        }
        rows.Push(row)
        return true
    }
    Add(*) {
        if !Grab() {
            cnt.Text := rows.Length " rows added — fill in the boxes first"
            return
        }
        cnt.Text := rows.Length " row" (rows.Length = 1 ? "" : "s") " added — keep going, or Start Loop"
        try ControlFocus(edits[labels[1]].Hwnd, "ahk_id " d.Hwnd)
    }
    Go(*) {
        Grab()                                ; a half-typed row counts as the last one
        if !rows.Length {
            cnt.Text := "Nothing yet — fill in the boxes, then Add Row"
            return
        }
        result := rows
        d.Destroy()
    }
    btnAdd.OnEvent("Click", Add)
    btnGo.OnEvent("Click", Go)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeApply(d)
    hwnd := d.Hwnd, edHwnd := edits[labels[1]].Hwnd   ; pre-Show, see WfAskInputDialog
    d.Show()
    try {                               ; dialog may be dismissed before these run
        WinActivate("ahk_id " hwnd)
        ControlFocus(edHwnd, "ahk_id " hwnd)
    }
    WinWaitClose("ahk_id " hwnd)
    return result
}

; Minimal RFC-4180 CSV parser: quoted fields may hold commas, doubled
; quotes and even newlines. Returns an array of records (arrays of strings).
WfCsvParse(text) {
    text := StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n")
    recs := []
    rec := []
    field := ""
    inQ := false
    len := StrLen(text)
    i := 1
    while (i <= len) {
        ch := SubStr(text, i, 1)
        if inQ {
            if (ch = '"') {
                if (SubStr(text, i + 1, 1) = '"') {   ; doubled quote -> literal quote
                    field .= '"'
                    i += 2
                    continue
                }
                inQ := false
                i += 1
                continue
            }
            field .= ch
            i += 1
            continue
        }
        switch ch {
            case '"':
                if (field = "")
                    inQ := true
                else
                    field .= ch                       ; stray quote mid-field: keep it
            case ",":
                rec.Push(field)
                field := ""
            case "`n":
                rec.Push(field)
                field := ""
                recs.Push(rec)
                rec := []
            default:
                field .= ch
        }
        i += 1
    }
    if (field != "" || rec.Length) {                  ; file didn't end with a newline
        rec.Push(field)
        recs.Push(rec)
    }
    return recs
}

; Ask the running loop to stop after the current pass.
WfLoopRequestStop() {
    global wfLoopStop
    wfLoopStop := true
}

; Sleep in small slices so a Stop click/hotkey during the pause is honored promptly.
WfLoopSleep(ms) {
    global wfLoopStop
    left := ms
    while (left > 0 && !wfLoopStop) {
        Sleep(100)
        left -= 100
    }
}

; Backup stop hotkey — the voice-clickable "Stop Looping" button is primary.
^!+x:: WfLoopRequestStop()
