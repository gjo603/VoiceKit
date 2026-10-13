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
; edit on its own. The RELATIVE form (after "Credits Zz" > "Insurance Zz"#2)
; picks the right one of boxes that all share one name, and each way it can
; fail is named; a `>` section that CONTAINS its content (a child-Gui Pane)
; bounds the search — a missing text or #N past its end fails by name
; instead of filling the next section's box — while a bare heading only
; orders it (logged). Plus the pure parts: WfFillLabel and WfFillMatches, whose
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
; the relative form: label -> canonical name | occurrence | explicit | error? |
; anchors joined by "/"   (mirrored in test_conformance's FILL_LABELS too)
for row in [['after "Insurance"', 'after "Insurance"', 1, false, false, "Insurance"]
          , ['AFTER"Insurance"', 'after "Insurance"', 1, false, false, "Insurance"]
          , ['  after  " Insurance "  ', 'after "Insurance"', 1, false, false, "Insurance"]
          , ['after "Deductions">"Insurance" #2', 'after "Deductions" > "Insurance"', 2, true, false, "Deductions/Insurance"]
          , ['after "Line #4 > x"#3', 'after "Line #4 > x"', 3, true, false, "Line #4 > x"]
          , ['after "a"#0', 'after "a"#0', 0, true, true, ""]
          , ['after Insurance', "after Insurance", 1, false, false, ""]      ; no quote: a plain label
          , ['after "Insurance', 'after "Insurance', 1, false, true, ""]
          , ['after "  "', 'after "  "', 1, false, true, ""]
          , ['after "a" >', 'after "a" >', 1, false, true, ""]
          , ['after "a" > b', 'after "a" > b', 1, false, true, ""]
          , ['after "say "hi""', 'after "say "hi""', 1, false, true, ""]
          , ['after "a"##2', 'after "a"##2', 1, false, true, ""]] {
    L := WfFillLabel(row[1])
    an := ""
    for x in L.anchors
        an .= (A_Index > 1 ? "/" : "") x
    Check("label '" row[1] "'", L.name == row[2] && L.occ = row[3] && L.explicit = row[4]
        && (L.err != "") = row[5] && an == row[6], L.name "|" L.occ "|" L.explicit "|" an "|" L.err)
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

; ---------- 11. the relative form: after "<text>" ---------------------------
; Every box in the target's last two "sections" is named "expanded detail
; input" — no label can tell them apart; the text before each one can.
Say("about to: relative fill")
ok := Fill('after "Taxes Zz"', "tax zz")
Check('after "X" fills the box after that text', ok && BoxVal("Ded_Tax", "tax zz") == "tax zz", Reason())
ok := Fill('after "Insurance Zz"', "first ins zz")
Check('...the FIRST text of several, in tree order', ok && BoxVal("Ded_Ins", "first ins zz") == "first ins zz", Reason())
Check("...and the run log says how many said it", InStr(LogText(), '2 elements say "Insurance Zz" — used the first'))
ok := Fill('after "Credits Zz" > "Insurance Zz"', "credit ins zz")
Check("a chain finds the text in the SECOND section", ok
    && BoxVal("Cred_Ins", "credit ins zz") == "credit ins zz" && BoxVal("Ded_Ins") == "first ins zz", Reason())
Check("...and, its section being a bare text, the log says the search was ordered, not bounded",
    InStr(LogText(), '"Credits Zz" has nothing inside it') && InStr(LogText(), "ordered, not bounded"))
ok := Fill('after "Credits Zz" > "Insurance Zz"#2', "other zz")
Check("#2 is the 2nd input after the last text", ok && BoxVal("Cred_Other", "other zz") == "other zz", Reason())
ok := Fill('after "Credit"', "contains zz")
Check("no exact name: the first name CONTAINING the text", ok
    && BoxVal("Cred_Ins", "contains zz") == "contains zz", Reason())
Check("...and the log says the contains rule was used", InStr(LogText(), 'nothing says exactly "Credit"'))
ok := RunWorkflowSteps([["set", "Sec", "Credits Zz", ""]
    , ["fill", win, 'after "{{Sec}}" > "Other Zz"', "{{Who}}"]], Map("Who", "named zz"), Map())
Check("{{Name}} works inside a text", ok && BoxVal("Cred_Other", "named zz") == "named zz", Reason())
Check("...and the log shows the label as written", InStr(LogText(), 'after "{{Sec}}" > "Other Zz"'))
ok := Fill('after "Qty Section Zz"#2', "7")
Check("an up-down buddy is not a second input: #2 is the NEXT box, not the arrows",
    ok && BoxVal("Qty_2", "7") == "7" && BoxVal("Qty_1") == "0", Reason() " qty1=" BoxVal("Qty_1"))
ok := Fill('after "Name Zz"', "plain after zz")
Check("a plain box after a text works too (the label-vs-input trap can't bite)", ok
    && BoxVal("Name_Zz", "plain after zz") == "plain after zz", Reason())
Check("WfDesc shows the relative label", InStr(WfDesc(["fill", "w", 'after "A" > "B"#2', "v"])
    , 'Fill  the box after "A" > "B"#2  with  "v"'), WfDesc(["fill", "w", 'after "A" > "B"#2', "v"]))

Say("about to: relative fill refusals")
wfFillAfterBudgetMs := 800          ; every find below fails: a short retry keeps the suite fast
ok := Fill('after "No Such Text Zz"', "x")
Check("an anchor nothing says fails, naming it", !ok && InStr(Reason(), 'says "No Such Text Zz"'), Reason())
ok := Fill('after "Credits Zz" > "Taxes Zz"', "x")
Check("...a chained anchor names the anchor it looked after", !ok
    && InStr(Reason(), 'No "Taxes Zz" after "Credits Zz"'), Reason())
ok := Fill('after "Trailing Words Zz"', "x")
Check("a text with no input after it says so", !ok && InStr(Reason(), "no input box comes after it"), Reason())
ok := Fill('after "Credits Zz"#3', "x")
Check("#3 of two says only 2 come after it", !ok && InStr(Reason(), 'Only 2 inputs come after "Credits Zz"'), Reason())
ok := Fill('after "Credits Zz" > ', "x")
Check("a dangling > is refused", !ok && InStr(Reason(), 'ends with ">"'), Reason())
wfFillNodeBudget := 5
ok := Fill('after "Credits Zz"', "x")
wfFillNodeBudget := 0
Check("a node budget that runs out says so", !ok && InStr(Reason(), "stopped at this window's first 5 elements"), Reason())
wfFillUiaOff := true
ok := Fill('after "Credits Zz"', "x")
wfFillUiaOff := false
Check("no UI Automation: says it's needed", !ok && InStr(Reason(), "needs UI Automation"), Reason())
Check("...nothing was typed by any refusal", BoxVal("Cred_Other") == "named zz" && BoxVal("Ded_Tax") == "tax zz")

; A {{Name}} in an anchor is a filled-in value (a batch row's client name,
; say): a failure names the anchor AS WRITTEN, never what it became — and
; when the value changes the label's shape, by its position only.
ok := RunWorkflowSteps([["fill", win, 'after "{{Sec}}"', "x"]], Map("Sec", "Hidden Anchor Qz"), Map())
Check("a substituted anchor that matches nothing is named as written", !ok
    && InStr(Reason(), 'says "{{Sec}}"') && !InStr(Reason(), "Hidden Anchor Qz"), Reason())
Check("...and the log never holds the value", !InStr(LogText(), "Hidden Anchor Qz"))
ok := RunWorkflowSteps([["fill", win, 'after "{{Sec}}"', "x"]], Map("Sec", 'Credits Zz" > "Nope Qz'), Map())
Check("a value that adds an anchor is named by position only", !ok
    && InStr(Reason(), "part 2 of the label") && !InStr(Reason(), "Nope Qz"), Reason())
Check("...and the log never holds it", !InStr(LogText(), "Nope Qz"))
wfFillAfterBudgetMs := 0

; ---------- 12. in a browser, only the PAGE is searched -----------------------
; The second target window is shaped like a browser: a "tab" text and an
; "address bar" box before the page, a "side panel" text and box after it.
; Typing into the address bar sends the text to a search provider, so the
; relative form must never reach outside the page — not when the page has
; no Document yet (it used to fall back to the whole window), and not past
; the page's end.
Say("about to: relative fill in a browser-shaped window")
bwin := "VKFillBrowser_ZZ ahk_pid " tpid
FillB(label, value) => RunWorkflowSteps([["fill", bwin, label, value]], Map(), Map())
wfFillAsBrowser := true, wfFillPageType := 50033        ; a Pane plays the page
ok := FillB('after "Section Bz" > "Insurance Bz"', "page ins bz")
Check("in a browser, the page's own box is found", ok && BoxVal("Pg_Ins", "page ins bz") == "page ins bz", Reason())
wfFillAfterBudgetMs := 800
ok := FillB('after "Tab Only Bz"', "x")
Check("a text only in the browser UI BEFORE the page is never an anchor", !ok
    && InStr(Reason(), 'says "Tab Only Bz"'), Reason())
ok := FillB('after "Tail Bz"', "x")
Check("...nor one AFTER the page", !ok && InStr(Reason(), 'says "Tail Bz"'), Reason())
ok := FillB('after "Section Bz"#2', "x")
Check("the count stops at the page's end (the side panel's box is not #2)", !ok
    && InStr(Reason(), 'Only 1 input comes after "Section Bz"'), Reason())
wfFillPageType := UIA_TYPE_DOCUMENT()                    ; this window has no Document
wfFillAfterBudgetMs := 0                                 ; the full retry, measured below
t0 := A_TickCount
ok := FillB('after "Tab Only Bz"', "x")
Check("no page in the tree: refused — never a scan of the whole window", !ok
    && InStr(Reason(), "Couldn't find the page") && InStr(Reason(), "address bar"), Reason())
Check("...after the usual retry (the page may still be building)", A_TickCount - t0 >= 2500,
    (A_TickCount - t0) " ms")
wfFillAsBrowser := "", wfFillPageType := 0
Check("nothing was typed into the browser UI", BoxVal("Omni_Box") == "" && BoxVal("Side_Box") == "",
    BoxVal("Omni_Box") "|" BoxVal("Side_Box"))

; ---------- 13. `>` = within: a section that CONTAINS its content -------------
; Feedback #4 asked for "the input after Insurance, within section X". When a
; section's element holds its content (a web group named after its heading),
; the next text and the box are searched inside it only — a section with no
; "Insurance" must fail by name, never fill the NEXT section's Insurance box.
; The third target window's sections are child Guis; first prove their UIA
; tree really nests (a Win32 GroupBox would not: it is only a sibling).
Say("about to: relative fill inside container sections")
swin := "VKFillSections_ZZ ahk_pid " tpid
FillS(label, value) => RunWorkflowSteps([["fill", swin, label, value]], Map(), Map())
dump := (sh := WinExist(swin)) ? UiaDumpTree(sh, 4) : ""
Check("the sections window nests in UIA (each section a Pane holding its texts and boxes)",
    InStr(dump, 'Pane "Wages Sx"`n    Text "Bonus Sx"') && InStr(dump, 'Pane "Benefits Sx"`n    Text "Insurance Sx"')
    && InStr(dump, 'Pane "Notes Sx"`n    Text "Notes Sx"'), dump)
ok := FillS('after "Benefits Sx" > "Insurance Sx"', "ben ins sx")
Check("a container section holding the text: its own box", ok
    && BoxVal("Bn_Ins", "ben ins sx") == "ben ins sx", Reason())
ok := FillS('after "Wages Sx" > "Bonus Sx"#2', "tips sx")
Check("#2 inside a container section is the next box inside it", ok
    && BoxVal("Wg_Tips", "tips sx") == "tips sx" && BoxVal("Wg_Bonus") == "", Reason())
wfFillAfterBudgetMs := 800
ok := FillS('after "Wages Sx" > "Insurance Sx"', "wrong sx")
Check("a section with no such text FAILS naming both — not the next section's box", !ok
    && InStr(Reason(), 'No "Insurance Sx" inside "Wages Sx"'), Reason())
ok := FillS('after "Wages Sx" > "Bonus Sx"#3', "wrong sx")
Check("#N past the section's last input fails, saying inside what", !ok
    && InStr(Reason(), 'Only 2 inputs come after "Bonus Sx" inside "Wages Sx"'), Reason())
ok := FillS('after "Wages Sx" > "Tips Sx"#2', "wrong sx")
Check("...also with one input left in it", !ok
    && InStr(Reason(), 'Only 1 input comes after "Tips Sx" inside "Wages Sx"'), Reason())
Check("...and none of them typed past the section", BoxVal("Bn_Ins") == "ben ins sx"
    && BoxVal("Nt_Rem") == "" && BoxVal("Wg_Tips") == "tips sx", BoxVal("Bn_Ins") "|" BoxVal("Nt_Rem"))
wfFillAfterBudgetMs := 0
ok := FillS('after "Notes Sx" > "Remarks Sx"', "rem sx")
Check("a heading holding only its own text is not a container: the next text is found AFTER it",
    ok && BoxVal("Nt_Rem", "rem sx") == "rem sx", Reason())
Check("...the log says ordered, not bounded", InStr(LogText(), '"Notes Sx" has nothing inside it'))
Check("...and its own nested text isn't a second match", !InStr(LogText(), 'elements say "Notes Sx"'))

TargetStop()
TestEnd()
