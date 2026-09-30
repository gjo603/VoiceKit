#Requires AutoHotkey v2.0
#SingleInstance Off
; Self-test for the workflow SHEET code: the CSV reader/writer the loop and
; the collect step share (lib\Workflow.ahk), the loop's row reader and its
; results journal (lib\WorkflowLoop.ahk), and the headless-batch early exits.
;
; Everything here touches files, and every file lives in a %TEMP% sandbox —
; never a real workflow's sheet. The run log/record and the results journal
; are redirected there too (wfLogFolder). No windows are driven.
;
; The early-error checks run a HEADLESS batch (wfRunQuiet) on purpose: if an
; early error ever pops a modal again, this test HANGS instead of failing,
; which the runner reports at its 120 s timeout — the same convention as the
; run-log suite's quiet-failure checks.
;
; Writes PASS/FAIL to sheet-selftest.result, ending ALL PASSED / N FAILURE(S).
#Include "%A_ScriptDir%\..\lib\WorkflowLoop.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("sheet-selftest")

Rec(sect, key) => IniRead(WfRecordFile(), sect, key, "")
; A record as one line, for readable failure details.
Show(rec) {
    s := ""
    for v in rec
        s .= (A_Index > 1 ? " | " : "") v
    return s
}
; Read a CSV the way the engine does.
ReadSheet(path) => WfCsvParse(FileRead(path, "UTF-8"))
Cell(recs, r, c) => (r <= recs.Length && c <= recs[r].Length) ? recs[r][c] : "<none>"
MapOf(pairs*) {
    m := Map()
    m.CaseSense := false
    i := 1
    while (i < pairs.Length) {
        m[pairs[i]] := pairs[i + 1]
        i += 2
    }
    return m
}

box := A_Temp "\vk-sheet-selftest"
try DirDelete(box, true)
DirCreate(box)
wfLogFolder := box "\logs"                  ; run record + loop journal, sandboxed
wfTrayOff := true                           ; no real toasts (see the run-log suite)
DirCreate(wfLogFolder)

; ---------- 1. WfCsvParse ------------------------------------------------
recs := WfCsvParse('a,b,c`r`n"x, y","say ""hi""","two`nlines"`r`nlast,,')
Check("parses three records", recs.Length = 3, recs.Length)
Check("plain fields", Show(recs[1]) = "a | b | c", Show(recs[1]))
Check("a quoted comma stays in its field", Cell(recs, 2, 1) = "x, y", Cell(recs, 2, 1))
Check("doubled quotes become one", Cell(recs, 2, 2) = 'say "hi"', Cell(recs, 2, 2))
Check("a quoted newline stays in its field", Cell(recs, 2, 3) = "two`nlines", Cell(recs, 2, 3))
Check("trailing empty fields are kept", recs[3].Length = 3 && Cell(recs, 3, 3) = "",
    recs[3].Length)
recs := WfCsvParse("h1,h2`nv1,v2")
Check("a file without a final newline still yields its last record",
    recs.Length = 2 && Cell(recs, 2, 2) = "v2", recs.Length)
recs := WfCsvParse(Chr(0xFEFF) "Name,Qty`r`nAcme,3`r`n")
Check("a leading BOM doesn't glue itself to the first header", Cell(recs, 1, 1) = "Name",
    "len=" StrLen(Cell(recs, 1, 1)))
recs := WfCsvParse("one`rtwo`r")
Check("bare CR line ends count as line ends", recs.Length = 2 && Cell(recs, 2, 1) = "two")

; ---------- 2. WfCsvField + WfSheetWrite round trip ----------------------
Check("plain text is not quoted", WfCsvField("plain") = "plain")
Check("a comma forces quotes", WfCsvField("a,b") = '"a,b"', WfCsvField("a,b"))
Check("quotes are doubled inside quotes", WfCsvField('say "x"') = '"say ""x"""',
    WfCsvField('say "x"'))
Check("a newline forces quotes", WfCsvField("l1`nl2") = '"l1`nl2"')

rt := box "\roundtrip.csv"
orig := [["Name", "Note"], ["Acme, Inc", 'He said "go"'], ["Multi", "line one`nline two"]]
WfSheetWrite(rt, orig)
raw := FileRead(rt, "RAW")
Check("the sheet is written with a UTF-8 BOM (Excel)",
    NumGet(raw, 0, "UChar") = 0xEF && NumGet(raw, 1, "UChar") = 0xBB && NumGet(raw, 2, "UChar") = 0xBF)
Check("...and CRLF record ends", InStr(FileRead(rt, "UTF-8"), "Note`r`n") > 0)
back := ReadSheet(rt)
same := back.Length = 3
for i, r in orig
    for j, v in r
        if (Cell(back, i, j) != v)
            same := false
Check("write then parse gives the same cells back", same, back.Length " records")

; The chooser's "Create my sheet": the header row alone.
hdrOnly := box "\hdr.csv"
WfSheetWrite(hdrOnly, [["Customer", "Order, no."]])
Check("a header-only sheet is one CSV line", FileRead(hdrOnly, "UTF-8") = 'Customer,"Order, no."`r`n',
    FileRead(hdrOnly, "UTF-8"))

; ---------- 3. WfLoopCsvRows ---------------------------------------------
err := ""
rows := WfLoopCsvRows(["Customer", "Qty"], "CUSTOMER,extra,qty`r`nAcme,x,3`r`n,,`r`nBeta,y,`r`n", &err)
Check("header matching is case-insensitive, extra columns ignored", IsObject(rows), err)
if IsObject(rows) {
    Check("fully blank lines are skipped", rows.Length = 2, rows.Length)
    Check("values land under the workflow's labels", rows[1]["Customer"] = "Acme" && rows[1]["Qty"] = "3")
    Check("a row's source record index rides along (srcRec)", rows[1].srcRec = 2 && rows[2].srcRec = 4,
        rows[1].srcRec "," rows[2].srcRec)
    Check("row Maps are case-insensitive", rows[2].Get("qty", "?") = "")
}
rows := WfLoopCsvRows(["Customer", "Qty"], "Customer,Amount`nAcme,3`n", &err)
Check("a missing label is refused", rows = "")
Check("...and the error names it", InStr(err, "missing a column for: Qty") > 0, err)
rows := WfLoopCsvRows(["Customer"], "Customer`r`n", &err)
Check("a header with no rows is refused", rows = "" && InStr(err, "needs a header row") > 0, err)
rows := WfLoopCsvRows(["Customer"], "Customer`r`n,`r`n", &err)
Check("a header plus only blank rows is refused", rows = "" && InStr(err, "no rows of answers") > 0, err)

; ---------- 4. WfSheetApplyResults ---------------------------------------
sheet := box "\Demo.inputs.csv"
WfSheetWrite(sheet, [["Customer", "Note"], ["Acme", "keep me"], ["Beta", ""], ["Gamma", ""]])
r := WfSheetApplyResults(sheet, ["Customer"], ["Order"]
    , [{src: 3, ins: MapOf("Customer", "Beta"), out: MapOf("Order", "B-1")}
     , {src: 0, ins: MapOf("Customer", "Delta"), out: MapOf("Order", "D-9")}])
s := ReadSheet(sheet)
Check("results land in the sheet itself", r.err = "" && r.name = "Demo.inputs.csv", r.name " " r.err)
Check("a collect column is appended to the header", Show(s[1]) = "Customer | Note | Order", Show(s[1]))
Check("src > 1 fills that row's collect cell", Cell(s, 3, 3) = "B-1", Show(s[3]))
Check("...and leaves other rows alone", Cell(s, 2, 2) = "keep me"
    && (Cell(s, 2, 3) = "" || Cell(s, 2, 3) = "<none>"), Show(s[2]))   ; short rows stay short
Check("src = 0 appends a row of inputs + values", s.Length = 5 && Cell(s, 5, 1) = "Delta"
    && Cell(s, 5, 3) = "D-9", s.Length " / " (s.Length >= 5 ? Show(s[5]) : ""))

; Row drift: the sheet was edited mid-run — a row inserted above Beta, so
; record 3 (captured at the start) now belongs to someone else.
WfSheetWrite(sheet, [["Customer", "Order"], ["Acme", ""], ["Inserted", ""], ["Beta", ""]])
WfSheetApplyResults(sheet, ["Customer"], ["Order"]
    , [{src: 3, ins: MapOf("Customer", "Beta"), out: MapOf("Order", "B-2")}])
s := ReadSheet(sheet)
Check("a moved row's result follows its inputs, not its old row number",
    Cell(s, 4, 2) = "B-2" && Cell(s, 3, 2) = "", Show(s[3]) " // " Show(s[4]))
WfSheetApplyResults(sheet, ["Customer"], ["Order"]
    , [{src: 2, ins: MapOf("Customer", "Deleted"), out: MapOf("Order", "X-1")}])
s := ReadSheet(sheet)
Check("a result whose row is gone is appended, never written into another's",
    Cell(s, 2, 2) = "" && s.Length = 5 && Cell(s, 5, 1) = "Deleted" && Cell(s, 5, 2) = "X-1",
    s.Length " / " Show(s[s.Length]))
; Duplicate inputs: two results from two identical rows fill both rows.
WfSheetWrite(sheet, [["Customer", "Order"], ["Same", ""], ["Same", ""]])
WfSheetApplyResults(sheet, ["Customer"], ["Order"]
    , [{src: 2, ins: MapOf("Customer", "Same"), out: MapOf("Order", "first")}
     , {src: 3, ins: MapOf("Customer", "Same"), out: MapOf("Order", "second")}])
s := ReadSheet(sheet)
Check("identical rows each keep their own result", Cell(s, 2, 2) = "first" && Cell(s, 3, 2) = "second",
    Show(s[2]) " // " Show(s[3]))

; Formula escape: collected values only, non-numbers only.
Check("a formula-looking value gets an apostrophe", WfSheetSafeCell("=HYPERLINK(1)") = "'=HYPERLINK(1)")
Check("...as do + and @", WfSheetSafeCell("+cmd") = "'+cmd" && WfSheetSafeCell("@SUM(1)") = "'@SUM(1)")
Check("...and a dash that isn't a number", WfSheetSafeCell("-2+3+cmd") = "'-2+3+cmd")
Check("a negative amount survives as a number", WfSheetSafeCell("-12.50") = "-12.50"
    && WfSheetSafeCell("-$1,234.56") = "-$1,234.56")
Check("ordinary text is untouched", WfSheetSafeCell("Acme = best") = "Acme = best"
    && WfSheetSafeCell("") = "")
WfSheetWrite(sheet, [["Customer", "Order"]])
WfSheetApplyResults(sheet, ["Customer"], ["Order"]
    , [{src: 0, ins: MapOf("Customer", "=not escaped input"), out: MapOf("Order", "=1+1")}])
s := ReadSheet(sheet)
Check("collected cells are escaped in the sheet", Cell(s, 2, 2) = "'=1+1", Cell(s, 2, 2))
Check("the user's own input cells are written as-is", Cell(s, 2, 1) = "=not escaped input",
    Cell(s, 2, 1))

; Locked sheet (open in Excel): results go beside it, nothing is lost and the
; sheet is never overwritten.
WfSheetWrite(sheet, [["Customer", "Order"], ["Acme", ""]])
before := FileRead(sheet, "UTF-8")
alt := box "\Demo.results.csv"
try FileDelete(alt)
lock := FileOpen(sheet, "r -rwd")               ; deny everyone else read/write/delete
r := WfSheetApplyResults(sheet, ["Customer"], ["Order"]
    , [{src: 2, ins: MapOf("Customer", "Acme"), out: MapOf("Order", "@risky")}])
lock.Close()
Check("a locked sheet diverts results to <Base>.results.csv", r.err = "" && r.name = "Demo.results.csv",
    r.name " " r.err)
a := FileExist(alt) ? ReadSheet(alt) : []
Check("...holding inputs + values, escaped", a.Length = 2 && Cell(a, 2, 1) = "Acme"
    && Cell(a, 2, 2) = "'@risky", a.Length ? Show(a[a.Length]) : "no file")
Check("...and the locked sheet itself is untouched", FileRead(sheet, "UTF-8") = before)

; ---------- 5. the results journal (#9) ----------------------------------
jn := WfLoopJournalNew("Other")                 ; another workflow's journal
Check("journals live under the (redirected) logs folder", InStr(jn, wfLogFolder "\loop-journal\Other.") = 1, jn)
tricky := MapOf("Order | no.", "100% of`r`nit")
WfLoopJournalAppend(jn, {src: 7, ins: MapOf("Customer", "Acme|Co"), out: tricky})
WfLoopJournalAppend(jn, {src: 0, ins: Map(), out: MapOf("Order", "=x")})
FileAppend("3|1|1|trunc", jn, "UTF-8")          ; a line cut short by a hard kill
back := WfLoopJournalRead(jn)
Check("journal round trip keeps every good line, drops the torn one", back.Length = 2, back.Length)
if (back.Length = 2) {
    Check("...src survives", back[1].src = 7 && back[2].src = 0)
    Check("...| % and newlines survive in labels and values",
        back[1].ins.Get("Customer", "") = "Acme|Co" && back[1].out.Get("Order | no.", "") = "100% of`r`nit")
    Check("...and the maps are case-insensitive", back[1].ins.Get("customer", "?") = "Acme|Co")
}

; A dead loop's journal is merged into the next save, then removed.
steps := box "\Demo.steps.txt"
WfSheetWrite(sheet, [["Customer", "Order"], ["Acme", ""], ["Beta", ""]])
orphan := WfLoopJournalDir() "\Demo.20200101000000-999999.jnl"   ; pid 999999: not running
try FileDelete(orphan)
WfLoopJournalAppend(orphan, {src: 2, ins: MapOf("Customer", "Acme"), out: MapOf("Order", "from crash")})
; A LIVE process's journal must be left alone (a running explorer.exe stands
; in for another loop that is still going).
livePid := ProcessExist("explorer.exe")
live := WfLoopJournalDir() "\Demo.20200101000002-" livePid ".jnl"
if livePid
    WfLoopJournalAppend(live, {src: 0, ins: MapOf("Customer", "Live"), out: MapOf("Order", "not yet")})
own := WfLoopJournalNew("Demo")
WfLoopJournalAppend(own, {src: 3, ins: MapOf("Customer", "Beta"), out: MapOf("Order", "this run")})
note := WfLoopSaveResults(sheet, ["Customer"], ["Order"]
    , [{src: 3, ins: MapOf("Customer", "Beta"), out: MapOf("Order", "this run")}], "Demo", own)
s := ReadSheet(sheet)
Check("an interrupted loop's rows are saved by the next loop", Cell(s, 2, 2) = "from crash", Show(s[2]))
Check("...alongside this run's", Cell(s, 3, 2) = "this run", Show(s[3]))
Check("...and the note says so", InStr(note, "interrupted earlier loop") > 0, note)
Check("merged and own journals are removed once saved", !FileExist(orphan) && !FileExist(own))
Check("other workflows' journals are never touched", FileExist(jn) != "")
if livePid {
    Check("a still-running loop's journal is left alone", FileExist(live) != ""
        && !InStr(FileRead(sheet, "UTF-8"), "Live"))
    try FileDelete(live)
}
try FileDelete(jn)

; Crash, then re-run from the sheet: the leftover and this run cover the SAME
; row. The newer value must win and no row may be duplicated (a duplicated
; input row would run twice on the next "Run from my sheet").
WfSheetWrite(sheet, [["Name", "Price"], ["ada", ""], ["bob", ""]])
orphanA := WfLoopJournalDir() "\Demo.20200101000003-999997.jnl"
WfLoopJournalAppend(orphanA, {src: 2, ins: MapOf("Name", "ada"), out: MapOf("Price", "old")})
note := WfLoopSaveResults(sheet, ["Name"], ["Price"]
    , [{src: 2, ins: MapOf("Name", "ada"), out: MapOf("Price", "new")}
     , {src: 3, ins: MapOf("Name", "bob"), out: MapOf("Price", "b")}], "Demo", WfLoopJournalNew("Demo"))
s := ReadSheet(sheet)
Check("a re-run's value beats an interrupted run's for the same row", s.Length = 3
    && Cell(s, 2, 2) = "new" && Cell(s, 3, 2) = "b", s.Length " / " Show(s[s.Length]))
Check("...the superseded leftover is dropped, its journal removed, and the note says so",
    !FileExist(orphanA) && InStr(note, "replaced by this run") > 0 && !InStr(note, "left behind"), note)
; Same, but the sheet was edited in between (a row inserted above ada): the
; leftover must not grab ada's new position and push this run's value out.
WfSheetWrite(sheet, [["Name", "Price"], ["inserted", ""], ["ada", ""]])
WfLoopJournalAppend(orphanA, {src: 2, ins: MapOf("Name", "ada"), out: MapOf("Price", "old")})
WfLoopSaveResults(sheet, ["Name"], ["Price"]
    , [{src: 3, ins: MapOf("Name", "ada"), out: MapOf("Price", "new")}], "Demo", WfLoopJournalNew("Demo"))
s := ReadSheet(sheet)
Check("...also when the row moved in between", s.Length = 3 && Cell(s, 3, 2) = "new"
    && Cell(s, 2, 2) = "", s.Length " / " Show(s[s.Length]))
; Two leftovers for one row: the newer journal wins; a leftover whose row is
; still open (not re-run) is kept.
WfSheetWrite(sheet, [["Name", "Price"], ["ada", ""], ["bob", ""]])
WfLoopJournalAppend(WfLoopJournalDir() "\Demo.20200101000004-999996.jnl"
    , {src: 2, ins: MapOf("Name", "ada"), out: MapOf("Price", "older")})
WfLoopJournalAppend(WfLoopJournalDir() "\Demo.20200101000005-999995.jnl"
    , {src: 2, ins: MapOf("Name", "ada"), out: MapOf("Price", "newer")})
WfLoopJournalAppend(WfLoopJournalDir() "\Demo.20200101000005-999995.jnl"
    , {src: 3, ins: MapOf("Name", "bob"), out: MapOf("Price", "kept")})
WfLoopSaveResults(sheet, ["Name"], ["Price"], [], "Demo", WfLoopJournalNew("Demo"))
s := ReadSheet(sheet)
Check("between two leftovers the newer wins, and an untouched row keeps its leftover",
    s.Length = 3 && Cell(s, 2, 2) = "newer" && Cell(s, 3, 2) = "kept", s.Length " / " Show(s[2]))
; A write-back never leaves its temp file behind.
tmpLeft := ""
Loop Files box "\*.tmp-*"
    tmpLeft .= A_LoopFileName " "
Check("the sheet write leaves no temp file", tmpLeft = "", tmpLeft)

; An orphan whose rows can't be saved anywhere stays for next time.
orphan2 := WfLoopJournalDir() "\Demo.20200101000001-999998.jnl"
WfLoopJournalAppend(orphan2, {src: 0, ins: MapOf("Customer", "Zed"), out: MapOf("Order", "keep")})
lock1 := FileOpen(sheet, "r -rwd")
FileAppend("", alt)
lock2 := FileOpen(alt, "r -rwd")
note := WfLoopSaveResults(sheet, ["Customer"], ["Order"], [], "Demo", WfLoopJournalNew("Demo"))
lock1.Close(), lock2.Close()
Check("with sheet AND results file locked, the journal is kept", FileExist(orphan2) != ""
    && InStr(note, "loop-journal") > 0, note)
WfLoopSaveResults(sheet, ["Customer"], ["Order"], [], "Demo", WfLoopJournalNew("Demo"))
Check("...and saved on the next try", !FileExist(orphan2) && InStr(FileRead(sheet, "UTF-8"), "Zed,keep") > 0)
tmpLeft := ""
Loop Files box "\*.tmp-*"
    tmpLeft .= A_LoopFileName " "
Check("a write that failed on a locked sheet leaves no temp file either", tmpLeft = "", tmpLeft)

; ---------- 6. headless batch early errors (#10) --------------------------
; No modal, record first. A MsgBox here would block and time the suite out.
r1 := RunWorkflowLoop(box "\NoSuchWorkflowZz.steps.txt", "no such", , box "\batch.csv")
Check("a missing workflow in a batch is an error, quietly", r1 = "error", r1)
Check("...recorded before anything else", Rec("NoSuchWorkflowZz", "outcome") = "error"
    && InStr(Rec("NoSuchWorkflowZz", "reason"), "not found") > 0, Rec("NoSuchWorkflowZz", "reason"))
FileAppend("ask|Customer||`ntext|{{Customer}}||`n", steps, "UTF-8")
emptyBatch := box "\empty-batch.csv"
FileAppend("Customer`r`n,`r`n", emptyBatch, "UTF-8")
r2 := RunWorkflowLoop(steps, "demo", , emptyBatch)
Check("a batch with no usable rows is an error, quietly", r2 = "error", r2)
Check("...with the reason recorded", InStr(Rec("Demo", "reason"), "no rows of answers") > 0,
    Rec("Demo", "reason"))
Check("an early error leaves no pass counts behind", Rec("Demo", "passes_total") = "")
wfRunQuiet := false
Check("the quiet error went to the tray, not a modal", InStr(wfTrayLast, "no rows") > 0, wfTrayLast)

; ---------- 7. {{selected_file}} with nothing selected, in a loop ---------
; The loop takes ONE selection snapshot before anything else. Seeded here
; (an empty selection) so File Explorer is never consulted; quiet, so the
; refusal can't pop a modal.
wfRunQuiet := true
wfSelection := []
selSteps := box "\SelDemo.steps.txt"
FileAppend("set|F|{{selected_file}}|`n", selSteps, "UTF-8")
r3 := RunWorkflowLoop(selSteps, "sel demo", , emptyBatch)
Check("a loop needing a selected file refuses to start without one", r3 = "error", r3)
Check("...recorded as error, naming File Explorer", Rec("SelDemo", "outcome") = "error"
    && InStr(Rec("SelDemo", "reason"), "File Explorer") && InStr(Rec("SelDemo", "reason"), "found 0"),
    Rec("SelDemo", "reason"))
Check("...checked before the batch was even read", !InStr(Rec("SelDemo", "reason"), "no rows"))
Check("...the seeded selection was kept, not re-read", (wfSelection is Array) && wfSelection.Length = 0)
wfRunQuiet := false

try DirDelete(box, true)
TestEnd()
