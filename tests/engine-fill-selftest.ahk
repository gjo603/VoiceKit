#Requires AutoHotkey v2.0
; Self-test for the `fill` step (lib\Workflow.ahk WfFill):
;     fill|<window>|<label>[#N]|<value>
; find an input by its label, click it for real, refuse to type unless the
; keyboard focus landed on it, type, and read it back.
;
; What it proves, against a SEPARATE target process (UIA against your own
; process deadlocks): the value lands in the INPUT, not the label sharing its
; name; "#2" picks the second of two same-named inputs and no #N fills the
; first with a log note; boxes that reformat (as you type, on blur, an SSN
; mask) still verify; a disabled box and a missing label fail without
; typing; a password box is filled but not read back; a box that throws
; input away fails the readback — and the value appears NOWHERE in the run
; record or log; a box that hands the focus away is refused by the focus
; gate with nothing typed anywhere; {{Name}} fills paramC; a line break is
; refused; Stop cuts the find short; and the MSAA fallback fills a classic
; edit on its own. Plus the pure parts: WfFillLabel and WfFillMatches, whose
; tables mcp\test_conformance.py mirrors for the Python guard.
;
; Quiet mode throughout (a failure TrayTips instead of blocking on a MsgBox),
; and the run log/record go to a temp folder, never the user's history.
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("engine-fill-selftest")
wfLogFolder := A_Temp "\vk-fill-selftest-logs"
try DirDelete(wfLogFolder, true)
wfRunQuiet := true, wfTrayOff := true, wfRunName := "VKFillTest"
wfClickJitterPx := 0

; ---------- 1. the pure parts ---------------------------------------------
Say("about to: WfFillLabel / WfFillMatches tables")
; label -> name | occurrence | explicit | error?   (mirrored in test_conformance)
for row in [["Amount", "Amount", 1, false, false], ["Amount#2", "Amount", 2, true, false]
          , ["Amount #2", "Amount", 2, true, false], ["Line ##4", "Line #4", 1, false, false]
          , ["Line ###4", "Line #", 4, true, false], ["Box #A", "Box #A", 1, false, false]
          , ["A##B", "A#B", 1, false, false], ["  Name  ", "Name", 1, false, false]
          , ["#3", "", 3, true, true], ["Amount#0", "Amount", 0, true, true]] {
    L := WfFillLabel(row[1])
    Check("label '" row[1] "'", L.name == row[2] && L.occ = row[3] && L.explicit = row[4]
        && (L.err != "") = row[5], L.name "|" L.occ "|" L.explicit "|" L.err)
}
for pair in [["1234.5", "1,234.50"], ["1234.5", "$1,234.50"], ["1234", "1,234.00"]
           , ["-12", "(12)"], ["-12", "12-"], ["123456789", "123-45-6789"]
           , ["acme inc", "ACME INC"], [" x ", "x"], ["", ""], ["0.5", ".50"]
           , ["50", "50.000000"], ["50%", "50.00"], ["01152025", "01/15/2025"]
           , ["-1234567.5", "(1,234,567.50)"], ["1234", "$ 1,234"]]
    Check("matches: '" pair[1] "' ~ '" pair[2] "'", WfFillMatches(pair[1], pair[2]))
for pair in [["1.5", "15"], ["123", "132"], ["01234", "1234"], ["12", "12.01"]
           , ["SENTINEL98765", "SE"], ["abc", ""], ["", "x"], ["1,5", "1.5"]
           , ["123-45-6789", "123-45-6780"], ["12", "-12"]
           , ["1,5", "15"], ["12,34", "1234"], ["1234", "12,34"], ["1234.5", "12,345"]]
    Check("no match: '" pair[1] "' vs '" pair[2] "'", !WfFillMatches(pair[1], pair[2]))

; ---------- 2. the target --------------------------------------------------
title := "VKFillTarget_ZZ"
if !(hwnd := TargetLaunch("engine-fill-selftest-target.ahk", title, &tpid))
    ExitApp(1)
win := title " ahk_pid " tpid

; A box's value as the target publishes it (bracketed, so "" is readable).
; want: wait up to 2 s for that value (the state file is a 250 ms snapshot).
BoxVal(key, want?) {
    v := IsSet(want) ? TargetState(key, "[" want "]") : TargetState(key)
    return RegExReplace(v, "^\[(.*)\]$", "$1")
}
Fill(label, value, vals := "") {
    global win
    return RunWorkflowSteps([["fill", win, label, value]], IsObject(vals) ? vals : Map(), Map())
}
Reason() => wfRun.Has("reason") ? wfRun["reason"] : ""
LogText() {
    try return FileRead(WfLogFile(), "UTF-8")
    return ""
}
RecordText() {
    try return FileRead(WfRecordFile())          ; IniWrite's UTF-16 — FileRead sniffs the BOM
    return ""
}

; ---------- 3. the plain case, and the label-vs-input trap ----------------
Say("about to: fill Name Zz (label and input share the name)")
ok := Fill("Name Zz", "Alice Zz")
Check("a fill succeeds", ok = true, WfRunOutcome() " " Reason())
Check("...and the value landed in the INPUT", BoxVal("Name_Zz", "Alice Zz") == "Alice Zz", BoxVal("Name_Zz"))

; {{Name}} in paramC — the first paramC the engine substitutes.
ok := RunWorkflowSteps([["set", "Who", "Bob", ""], ["fill", win, "Name Zz", "{{Who}} Zz"]], Map(), Map())
Check("{{Name}} in the value is filled in", ok && BoxVal("Name_Zz", "Bob Zz") == "Bob Zz", BoxVal("Name_Zz"))
Check("...and the log shows the step as written", InStr(LogText(), "`"{{Who}} Zz`""))

ok := Fill("Name Zz", "")
Check("an empty value clears the box", ok && BoxVal("Name_Zz", "") == "", BoxVal("Name_Zz"))

; ---------- 4. two inputs, one label ---------------------------------------
Say("about to: duplicate labels")
ok := Fill("Amount Zz#2", "222")
Check("#2 fills the SECOND input", ok && BoxVal("Amount_Zz", "222") == "222", BoxVal("Amount_Zz"))
Check("...and leaves the first alone", BoxVal("Amount_Zz_1") == "", BoxVal("Amount_Zz_1"))
ok := Fill("Amount Zz", "111")
Check("no #N fills the FIRST", ok && BoxVal("Amount_Zz_1", "111") == "111", BoxVal("Amount_Zz_1"))
lg := LogText()
Check("...and the run log says it was ambiguous", InStr(lg, "2 inputs are labelled `"Amount Zz`" — filled the FIRST"))
ok := Fill("Amount Zz#3", "333")
Check("#3 of two fails", !ok && InStr(Reason(), "Only 2 inputs are labelled"), Reason())

; ---------- 5. boxes that change what you typed ----------------------------
Say("about to: reformatting boxes")
ok := Fill("Money Live Zz", "1234.5")
Check("a box that reformats as you type verifies (1234.5 ~ 1,234.50)", ok, Reason())
Check("...it really reformatted", BoxVal("Money_Live_Zz", "1,234.50") == "1,234.50", BoxVal("Money_Live_Zz"))
ok := Fill("Ssn Zz", "123456789")
Check("an input mask verifies (123456789 ~ 123-45-6789)", ok, Reason())
Check("...it really masked", BoxVal("Ssn_Zz", "123-45-6789") == "123-45-6789", BoxVal("Ssn_Zz"))
ok := RunWorkflowSteps([["fill", win, "Money Blur Zz", "1234.5"], ["fill", win, "Name Zz", "blurred"]
    , ["collect", "Blur", "Money Blur Zz", ""]], Map(), got := Map())
Check("a box that reformats on BLUR verifies (read back before the blur)", ok, Reason())
Check("...then reformats once the next fill takes the focus",
    BoxVal("Money_Blur_Zz", "1,234.50") == "1,234.50", BoxVal("Money_Blur_Zz"))
Check("...and a collect reads the reformatted value", got.Get("Blur", "?") == "1,234.50", got.Get("Blur", "?"))

; ---------- 6. refusals ----------------------------------------------------
Say("about to: disabled / password / missing / label-only / newline")
ok := Fill("Disabled Zz", "nope")
Check("a disabled box fails", !ok && InStr(Reason(), "is disabled"), Reason())
Check("...with nothing typed", BoxVal("Disabled_Zz") == "", BoxVal("Disabled_Zz"))

ok := Fill("Secret Zz", "{{Pw}}", Map("Pw", "hunter2 zz"))
Check("a password box is filled", ok && BoxVal("Secret_Zz", "hunter2 zz") == "hunter2 zz", Reason())
Check("...not verified, and the log says so", InStr(LogText(), "is a password box — filled, not verified"))
Check("...and the password is nowhere in the log or record", !InStr(LogText(), "hunter2") && !InStr(RecordText(), "hunter2"))

t0 := A_TickCount
ok := Fill("No Such Box Zz", "x")
elapsed := A_TickCount - t0
Check("a missing label fails", !ok && InStr(Reason(), "No input labelled `"No Such Box Zz`""), Reason())
Check("...inside its budget", elapsed < 6000, elapsed " ms")
ok := Fill("Only Label Zz", "x")
Check("a label with no box says it isn't a box", !ok && InStr(Reason(), "isn't a box you can type into"), Reason())
ok := Fill("Name Zz", "two`nlines")
Check("a value with a line break is refused", !ok && InStr(Reason(), "line break"), Reason())
Check("...before anything is typed", BoxVal("Name_Zz") == "blurred", BoxVal("Name_Zz"))

; ---------- 7. a box that throws input away: the value stays private -------
Say("about to: readback mismatch")
secret := "SENTINEL98765"
ok := Fill("Short Zz", "{{Acct}}", Map("Acct", secret))
Check("a box that keeps only 2 characters fails the readback", !ok && InStr(Reason(), "did not match after typing"), Reason())
Check("...the box really cut it short", BoxVal("Short_Zz", "SE") == "SE", BoxVal("Short_Zz"))
Check("...the reason has no value in it", !InStr(Reason(), "SENTINEL") && !InStr(Reason(), "98765"), Reason())
Check("...nor does the run record", !InStr(RecordText(), "98765"))
Check("...nor the run log", !InStr(LogText(), "98765"))

; ---------- 8. the focus gate ----------------------------------------------
Say("about to: stolen focus")
ok := Fill("Thief Zz", "stolen zz")
Check("a box that gives the focus away is refused", !ok && InStr(Reason(), "keyboard focus went somewhere else"), Reason())
Check("...nothing landed in it", BoxVal("Thief_Zz") == "", BoxVal("Thief_Zz"))
Check("...nor in the box that took the focus", BoxVal("Decoy_Zz") == "", BoxVal("Decoy_Zz"))

; ---------- 9. Stop cuts a find short --------------------------------------
Say("about to: abort during the find")
stopAt := A_TickCount + 900
wfRunAbortCheck := () => A_TickCount >= stopAt
t0 := A_TickCount
ok := Fill("No Such Box Zz", "x")
elapsed := A_TickCount - t0
wfRunAbortCheck := ""
Check("Stop during the find ends the run as stopped", !ok && WfRunOutcome() = "stopped", WfRunOutcome())
Check("...promptly", elapsed < 2500, elapsed " ms")

; ---------- 10. the MSAA fallback ------------------------------------------
; Win32 controls appear in BOTH trees, so no ordinary box is MSAA-only; the
; self-test switch turns the UIA half off to prove the MSAA half on its own.
Say("about to: MSAA-only fill")
wfFillUiaOff := true
ok := Fill("Classic Zz", "via msaa zz")
Check("the MSAA fallback fills a classic edit", ok && BoxVal("Classic_Zz", "via msaa zz") == "via msaa zz", Reason())
ok := Fill("Disabled Zz", "nope")
Check("...refuses a disabled one", !ok && InStr(Reason(), "is disabled"), Reason())
ok := Fill("Thief Zz", "stolen zz")
Check("...and has a focus gate too", !ok && InStr(Reason(), "keyboard focus went somewhere else")
    && BoxVal("Thief_Zz") == "" && BoxVal("Decoy_Zz") == "", Reason())
ok := Fill("Amount Zz#2", "msaa two")
Check("...and counts duplicate labels in tree order", ok && BoxVal("Amount_Zz", "msaa two") == "msaa two", BoxVal("Amount_Zz"))
wfFillUiaOff := false
; The MSAA gate's window test may only vouch for a node that IS its own
; window: a real Win32 edit is, the form hosting every box is not (else a
; focused SIBLING box would pass the gate for a windowless input).
nodes := AccInputNodes(hwnd, "Classic Zz", A_TickCount + 2000)
eh := nodes.Length ? AccWindowOf(nodes[1].acc) : 0
Check("the MSAA gate's window test matches a Win32 edit to its own window",
    nodes.Length = 1 && eh && eh != hwnd && WfWinRectNear(eh, nodes[1].loc), nodes.Length " " eh)
Check("...and never the host window around it", nodes.Length = 1 && !WfWinRectNear(hwnd, nodes[1].loc))

TargetStop()
TestEnd()
