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
;  (voice: "click stop looping") or Ctrl+Alt+Shift+X. Stopping is
;  immediate — the engine polls the abort hook (wfRunAbortCheck)
;  between steps and inside its waits, so even a long Wait step or
;  a window-wait ends right away, with no failure popup. A loop
;  also stops on its own if a step fails (so a broken workflow
;  can't spin).
;
;  Workflows with `ask` steps: before looping starts, a chooser
;  offers ways to feed the loop. The lead option is the workflow's
;  own INPUTS SHEET — workflows\<Base>.inputs.csv, created on
;  demand with one column per input and opened in Excel/Notepad;
;  fill one row per run, save, and "Run from my sheet" runs the
;  list (the sheet stays there to edit and re-run later). The
;  chooser also imports any CSV, takes typed-in rows, or falls
;  back to asking each pass, and sets the pause between runs
;  (remembered per workflow in logs\settings.ini [Loop]). With a
;  batch, the loop runs the rows in order and stops by itself.
;
;  Workflows with `collect` steps write what they grabbed back to
;  the sheet after the loop: a batch fed BY the sheet fills the
;  collect columns of each row that ran; any other pass appends a
;  row (inputs used + values collected). If the sheet is locked
;  (open in Excel), results go to <Base>.results.csv instead.
; ============================================================
#Include "%A_LineFile%\..\Workflow.ahk"
#Include "%A_LineFile%\..\Theme.ahk"

global wfLoopStop := false

; Run stepsFile top-to-bottom repeatedly, pausing delayMs between passes,
; until stopped or a step fails. Shows a small always-on-top status bar.
; batchFile (the MCP's run_workflow_batch, via LoopRunner's 2nd argument)
; skips the chooser entirely: the CSV's rows are the batch — one pass per
; row, the workflow's remembered pause, Stop bar still up. Passing the
; workflow's own sheet as batchFile fills collected values into its rows.
RunWorkflowLoop(stepsFile, phrase, delayMs := 1500, batchFile := "") {
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

    ; Workflows that ask for input: batch the answers up front (the
    ; workflow's inputs sheet, any CSV, or typed-in rows — one loop pass
    ; per row), or fall back to asking every pass. rows = "" means no
    ; batch. The chooser also sets the pause between passes.
    rows := ""
    fromSheet := false
    SplitPath(stepsFile, &fname, &fdir)
    base := RegExReplace(fname, "i)\.steps\.txt$")
    sheetPath := fdir "\" base ".inputs.csv"
    labels := WfAskLabels(steps)
    if (batchFile != "") {
        ; Headless batch: the CSV must name every input in its header, same
        ; validation as the chooser's import. No dialogs — this path is for
        ; programmatic callers (Claude via MCP); the Stop bar still shows.
        err := ""
        batchRows := ""
        try batchRows := WfLoopCsvRows(labels, FileRead(batchFile, "UTF-8"), &err)
        catch
            err := "Couldn't read the batch file:`n" batchFile
        if !IsObject(batchRows) {
            MsgBox("Can't run the batch.`n`n" err, "VoiceKit loop", "Iconx 262144")
            return
        }
        rows := batchRows
        fromSheet := (StrLower(batchFile) = StrLower(sheetPath))
        delayMs := Round(Number(WfLoopDelayLoad(base)) * 1000)   ; the remembered pause
    } else if labels.Length {
        plan := WfLoopInputPlan(labels, phrase, base, sheetPath)
        if !IsObject(plan)
            return                               ; cancelled
        if (plan.mode = "rows") {
            rows := plan.rows
            fromSheet := plan.fromSheet          ; sheet rows get results written back beside them
        }
        delayMs := plan.delayMs
    }
    colLabels := WfCollectLabels(steps)
    results := []                                ; {src, ins, out} per completed pass that collected

    ; Make each pass abortable from the inside: the engine polls this
    ; between steps and inside its waits, so Stop cuts in mid-pass (a
    ; captured 20 s Wait step can't hold the loop hostage) instead of
    ; waiting for the pass to finish.
    global wfRunAbortCheck
    wfRunAbortCheck := (*) => wfLoopStop

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
        ; Ask-each-pass mode gathers HERE (not inside the engine) so the
        ; answers can be saved beside anything the pass collects.
        passVals := ""
        if (!IsObject(rows) && labels.Length) {
            passVals := WfGatherInputs(steps)
            if !IsObject(passVals)
                break                      ; cancelled an ask dialog — stop quietly
        }
        collected := Map()
        collected.CaseSense := false
        ok := RunWorkflowSteps(steps, IsObject(rows) ? rows[i] : passVals, collected)
        if (ok && collected.Count)
            results.Push({src: (fromSheet && rows[i].HasProp("srcRec")) ? rows[i].srcRec : 0
                , ins: IsObject(rows) ? rows[i] : (IsObject(passVals) ? passVals : Map())
                , out: collected})
        if !ok                             ; a step failed (its popup already showed) or Stop cut the pass short
            break
        if (IsObject(rows) && i >= rows.Length)
            break                          ; last row done — skip the trailing pause
        WfLoopSleep(delayMs)               ; interruptible pause; also returns at once if stop was requested
    }
    bar.Destroy()
    wfRunAbortCheck := ""                  ; runs outside the loop are not abortable
    ; Save whatever the completed passes collected — even after a stop or a
    ; failed pass, the earlier rows' results are worth keeping.
    resNote := "", resPath := ""
    if results.Length {
        r := WfSheetApplyResults(sheetPath, labels, colLabels, results)
        resNote := (r.err = "") ? "Collected values saved to " r.name "." : r.err
        resPath := r.err = "" ? r.path : ""
    }
    ; A loop that saved collected values ends with a voice-clickable offer
    ; to open the file — completed batches and stopped-midway runs alike.
    if (IsObject(rows) && ok && !wfLoopStop && i >= rows.Length) {
        done := "Done — ran '" phrase "' for all " rows.Length " row" (rows.Length = 1 ? "" : "s") "."
        if (resPath != "") {
            if (MsgBox(done "`n`n" resNote "`n`nOpen it now?", "VoiceKit loop", "YesNo 262144") = "Yes")
                WfLoopOpenFile(resPath)
        } else
            MsgBox(done (resNote != "" ? "`n`n" resNote : ""), "VoiceKit loop", "262144")
    } else if (resPath != "") {
        if (MsgBox(resNote "`n`nOpen it now?", "VoiceKit loop", "YesNo 262144") = "Yes")
            WfLoopOpenFile(resPath)
    } else if (resNote != "")
        TrayTip(resNote, "VoiceKit", "Iconi")
}

; Open a CSV in its default app (Excel if present), falling back to
; Notepad when .csv has no association.
WfLoopOpenFile(path) {
    try Run('"' path '"')
    catch
        try Run('notepad.exe "' path '"')
}

; ------------------------------------------------------------
;  Batched inputs for looping workflows that ask for input
; ------------------------------------------------------------

; Chooser: how should this loop get its inputs, and how long should it
; pause between runs? Leads with the workflow's own inputs sheet
; (<Base>.inputs.csv beside the steps file — created on demand, edited
; in Excel/Notepad, re-read every time, so a list is easy to tweak and
; re-run). Returns
;   {mode:"rows", rows:[Map(label->answer), ...], delayMs}  — batch
;   {mode:"each", delayMs}                                  — ask every pass
;   ""                                                      — cancelled
WfLoopInputPlan(labels, phrase, base, sheetPath) {
    result := ""
    joined := ""
    for l in labels
        joined .= (A_Index > 1 ? "  ·  " : "") l
    d := Gui("+AlwaysOnTop", "Loop " phrase)
    dh := 0                             ; d.Hwnd, captured below pre-Show
    d.SetFont("s10", "Segoe UI")
    d.AddText("xm w460", "Each run of '" phrase "' needs these answers:")
    d.SetFont("s10 bold")
    d.AddText("xm y+4 w460", joined)
    d.SetFont("s10 norm")
    d.AddText("xm y+12 Section", "Pause between runs:")
    edDelay := d.AddEdit("x+8 yp-3 w56 Right", WfLoopDelayLoad(base))
    d.AddText("x+6 ys", "seconds  (remembered for this workflow)")
    hint := d.AddText("xm y+12 w460 r3", "")
    ThemeDim(hint)
    btnSheetRun  := d.AddButton("xm y+8 w460 h34", "▶  Run from my sheet")
    btnSheetEdit := d.AddButton("xm y+8 w460 h34", "✎  Edit my sheet")
    other := d.AddText("xm y+12 w460", "Other ways to feed it:")
    ThemeDim(other)
    btnCsv  := d.AddButton("xm y+4 w460 h30", "Import a CSV file I already have")
    btnType := d.AddButton("xm y+8 w460 h30", "Type the rows in here")
    btnEach := d.AddButton("xm y+8 w460 h30", "Ask me before each run")
    btnCancel := d.AddButton("xm y+12 w120", "Cancel")

    ; Rows currently in the sheet: -1 no sheet yet, 0 sheet but nothing
    ; usable, N ready rows. Cheap and never throws (the watcher calls it).
    SheetRows() {
        if !FileExist(sheetPath)
            return -1
        rows := "", err := ""
        try rows := WfLoopCsvRows(labels, FileRead(sheetPath, "UTF-8"), &err)
        return IsObject(rows) ? rows.Length : 0
    }
    ; Reflect the sheet's state in the two sheet buttons; the ready one
    ; gets the Default accent so Enter (and the eye) lands right.
    Refresh() {
        n := SheetRows()
        if (n > 0) {
            btnSheetRun.Text := "▶  Run from my sheet  (" n " row" (n = 1 ? "" : "s") " ready)"
            btnSheetEdit.Text := "✎  Edit my sheet"
            btnSheetEdit.Opt("-Default"), btnSheetRun.Opt("+Default")
        } else {
            btnSheetRun.Text := "▶  Run from my sheet"
            btnSheetEdit.Text := (n < 0) ? "✎  Create my sheet  (one row per run)" : "✎  Edit my sheet"
            btnSheetRun.Opt("-Default"), btnSheetEdit.Opt("+Default")
        }
    }
    ; The pause box, parsed to ms: -1 means junk (caller explains).
    Delay() {
        t := StrReplace(Trim(edDelay.Value), ",", ".")
        if (t = "")
            return 0
        if (!IsNumber(t) || t < 0)
            return -1
        return Min(Round(t * 1000), 3600000)
    }
    ; Every way of starting the loop funnels through here so the pause
    ; is validated and remembered no matter which button was clicked.
    ; fromSheet marks a batch read from the workflow's own sheet — only
    ; those rows may have collected values written back beside them.
    Start(mode, rowsArr, fromSheet := false) {
        ms := Delay()
        if (ms < 0) {
            hint.Text := "The pause needs to be a number of seconds — e.g. 1.5"
            return false
        }
        WfLoopDelaySave(base, ms)
        result := {mode: mode, delayMs: ms, fromSheet: fromSheet}
        if IsObject(rowsArr)
            result.rows := rowsArr
        d.Destroy()
        return true
    }
    SheetRun(*) {
        if !FileExist(sheetPath) {
            hint.Text := "No sheet yet — click '" btnSheetEdit.Text "' below, fill one row per run, and save it."
            return
        }
        rows := "", err := ""
        try rows := WfLoopCsvRows(labels, FileRead(sheetPath, "UTF-8"), &err)
        catch
            err := "Couldn't read the sheet. If it's open in another program, save and close it there first."
        if !IsObject(rows) {
            MsgBox("The sheet isn't ready to run yet.`n`n" err, "VoiceKit loop", "Icon! Owner" dh)
            return
        }
        Start("rows", rows, true)
    }
    SheetEdit(*) {
        if !FileExist(sheetPath) {
            try WfLoopSheetCreate(sheetPath, labels)
            catch as e {
                MsgBox("Couldn't create the sheet:`n" e.Message, "VoiceKit loop", "Iconx Owner" dh)
                return
            }
        }
        WfLoopOpenFile(sheetPath)
        hint.Text := "The top row is the column names — fill one row per run underneath, save, then come back and click 'Run from my sheet'."
        Refresh()
    }
    Csv(*) {
        rows := WfLoopImportCsv(labels, d)
        if IsObject(rows)
            Start("rows", rows)
    }
    TypeIn(*) {
        d.Hide()
        rows := WfLoopTypeRows(labels)
        if (IsObject(rows) && Start("rows", rows))
            return
        d.Show()
    }
    btnSheetRun.OnEvent("Click", SheetRun)
    btnSheetEdit.OnEvent("Click", SheetEdit)
    btnCsv.OnEvent("Click", Csv)
    btnType.OnEvent("Click", TypeIn)
    btnEach.OnEvent("Click", (*) => Start("each", ""))
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    Refresh()
    hint.Text := SheetRows() > 0
        ? "Each sheet row is one run — the loop stops by itself after the last row."
        : "Easiest: keep the answers in a sheet. Create it once, fill one row per run (Excel or Notepad), and run the whole list."
    ; Watch the sheet while the dialog is up, so saving it in Excel
    ; updates the row count without reopening the dialog. Everything is
    ; try-guarded: the timer can fire between Destroy and the wait below.
    lastStamp := "?"
    Watch() {
        stamp := ""
        try stamp := FileExist(sheetPath) ? FileGetTime(sheetPath, "M") . FileGetSize(sheetPath) : ""
        if (stamp = lastStamp)
            return
        lastStamp := stamp
        try Refresh()
    }
    SetTimer(Watch, 800)
    ThemeApply(d)
    dh := hwnd := d.Hwnd                ; pre-Show: reads on a destroyed Gui throw
    d.Show()
    try WinActivate("ahk_id " hwnd)     ; dialog may be dismissed before this runs
    WinWaitClose("ahk_id " hwnd)
    SetTimer(Watch, 0)
    return result
}

; Pick and read any CSV whose header row names every ask label. Returns
; [Map(label->answer),...] or "" if cancelled / invalid (the problem is
; explained, chooser stays up).
WfLoopImportCsv(labels, owner) {
    f := FileSelect(1, , "Pick the CSV file", "CSV / text (*.csv; *.txt)")
    if (f = "")
        return ""
    text := ""
    try text := FileRead(f, "UTF-8")
    catch {
        MsgBox("Couldn't read that file.", "VoiceKit loop", "Iconx Owner" owner.Hwnd)
        return ""
    }
    err := ""
    rows := WfLoopCsvRows(labels, text, &err)
    if !IsObject(rows)
        MsgBox(err, "VoiceKit loop", "Icon! Owner" owner.Hwnd)
    return rows
}

; Turn CSV text into loop rows. The header row must name every ask label
; (case-insensitive; extra columns are ignored); each later non-empty
; record becomes one Map(label->answer). Returns the rows array, or ""
; with &err set to a user-facing explanation. Shared by the inputs-sheet
; path and the import-a-CSV path so both validate identically.
WfLoopCsvRows(labels, text, &err) {
    err := ""
    recs := ""
    try recs := WfCsvParse(text)
    catch {
        err := "Couldn't read that file."
        return ""
    }
    if (!IsObject(recs) || recs.Length < 2) {
        err := "It needs a header row (the input names) plus at least one row of answers."
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
        err := "It's missing a column for: " missing
             . "`n`nThe header row must name every input (extra columns are fine)."
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
        row.srcRec := A_Index + 1   ; a PROPERTY (not an item): which CSV record
                                    ; this row came from, so collected values can
                                    ; be written back beside it when the batch
                                    ; came from the workflow's own sheet
        for l in labels {
            j := cols[l]
            row[l] := (j <= rec.Length) ? rec[j] : ""
        }
        rows.Push(row)
    }
    if !rows.Length {
        err := "It has a header row but no rows of answers."
        return ""
    }
    return rows
}

; Create a workflow's inputs sheet: just the header row, one column per
; input. UTF-8 BOM + CRLF so Excel opens it cleanly.
WfLoopSheetCreate(path, labels) {
    line := ""
    for l in labels
        line .= (A_Index > 1 ? "," : "") WfCsvField(l)   ; quoting lives in Workflow.ahk now
    f := FileOpen(path, "w", "UTF-8")
    f.Write(line "`r`n")
    f.Close()
}

; ---- the pause between runs, remembered per workflow ----
WfLoopSettingsFile() {
    return RegExReplace(A_LineFile, "\\lib\\[^\\]+$") "\logs\settings.ini"
}
; Stored ms -> the seconds string the dialog's box shows ("1.5", "2").
WfLoopDelayLoad(base) {
    ms := IniRead(WfLoopSettingsFile(), "Loop", base, 1500)
    if !IsNumber(ms)
        ms := 1500
    return RTrim(RTrim(Format("{:.1f}", ms / 1000.0), "0"), ".")
}
WfLoopDelaySave(base, ms) {
    ini := WfLoopSettingsFile()
    dir := RegExReplace(ini, "\\[^\\]+$")
    if !DirExist(dir)
        try DirCreate(dir)
    try IniWrite(ms, ini, "Loop", base)
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

; (WfCsvParse and the CSV field quoting now live in Workflow.ahk — the
; engine needs them too, for writing collected values to the sheet.)

; Ask the running loop to stop. Takes effect immediately: the engine's
; abort hook reads this flag between steps and inside its waits, so the
; current pass ends right where it is (quietly — no failure popup).
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
