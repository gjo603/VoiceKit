#Requires AutoHotkey v2.0
; Self-test for {{Name}} values in lib\Workflow.ahk.
; Drives a THROWAWAY GUI with a unique title — never the user's windows.
; Writes PASS/FAIL to engine-vars-selftest.result; a missing result file
; means a step failed and its error MsgBox is blocking.
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("engine-vars-selftest")
wfLogFolder := A_Temp "\vk-selftest-logs"   ; keep test runs out of the user's real run history

; ---------- 1. WfSubst in isolation -------------------------------------
v := Map()
v.CaseSense := false
v["Customer"] := "Ada"
v["Order Id"] := "A-99"

Check("plain substitution", WfSubst("Dear {{Customer}},", v) = "Dear Ada,",
    WfSubst("Dear {{Customer}},", v))
Check("same name twice", WfSubst("{{Customer}} & {{Customer}}", v) = "Ada & Ada")
Check("name with a space", WfSubst("[{{Order Id}}]", v) = "[A-99]")
Check("case-insensitive", WfSubst("{{customer}}", v) = "Ada")
Check("padded braces", WfSubst("{{  Customer  }}", v) = "Ada")
Check("unknown left literal", WfSubst("x{{Nope}}y", v) = "x{{Nope}}y",
    WfSubst("x{{Nope}}y", v))
Check("no braces untouched", WfSubst("plain text", v) = "plain text")
Check("empty stays empty", WfSubst("", v) = "")
Check("lone braces untouched", WfSubst("a {{ b", v) = "a {{ b")
Check("built-in date", WfSubst("{{date}}", v) = FormatTime(A_Now, "yyyy-MM-dd"))
v2 := Map()
v2.CaseSense := false
v2["Date"] := "MINE"
Check("user value beats built-in", WfSubst("{{date}}", v2) = "MINE")

; ---------- 2. which fields get substituted ------------------------------
sub := WfSubstStep(["text", "Hi {{Customer}}", "", ""], v)
Check("text paramA substituted", sub[2] = "Hi Ada")
sub := WfSubstStep(["wait", "{{Customer}}", "", ""], v)
Check("wait ms NOT substituted", sub[2] = "{{Customer}}")
sub := WfSubstStep(["ask", "{{Customer}}", "{{Customer}}", ""], v)
Check("ask label NOT substituted", sub[2] = "{{Customer}}" && sub[3] = "{{Customer}}")
sub := WfSubstStep(["click", "ahk_exe {{Customer}}.exe", "{{Customer}} button", "10,20"], v)
Check("click window+element substituted", sub[2] = "ahk_exe Ada.exe" && sub[3] = "Ada button")
Check("click coords NOT substituted", sub[4] = "10,20")
sub := WfSubstStep(["collect", "{{Customer}}", "{{Customer}} box", ""], v)
Check("collect label NOT substituted", sub[2] = "{{Customer}}")
Check("collect element substituted", sub[3] = "Ada box")
; fill: the FIRST step whose paramC (the value) is substituted — alongside
; the window and the label.
sub := WfSubstStep(["fill", "ahk_exe {{Customer}}.exe", "{{Customer}} name", "Dear {{Customer}}, 1,234.50 | 100%"], v)
Check("fill window+label substituted", sub[2] = "ahk_exe Ada.exe" && sub[3] = "Ada name")
Check("fill VALUE (paramC) substituted", sub[4] = "Dear Ada, 1,234.50 | 100%", sub[4])
Check("fill's text for the authoring check covers all three fields",
    WfStepSubstText(["fill", "w{{A}}", "l{{B}}", "v{{C}}"]) = "w{{A}}`nl{{B}}`nv{{C}}")
; A name a fill VALUE uses that nothing defines is an INPUT of the workflow
; (asked up front, a sheet column, a batch column) — that is how a batch
; row reaches fill steps without an `ask` step typing it somewhere.
fsteps := [["ask", "Customer", "", ""], ["set", "Later", "x", ""],
           ["fill", "ahk_exe x.exe", "{{Label Only}}", "{{Customer}} {{Invoice Amount}} {{Later}} {{date}} {{invoice amount}}"],
           ["fill", "ahk_exe x.exe", "Other", "{{Box 2}}"], ["text", "{{Typo}}", "", ""]]
fin := WfFillInputNames(fsteps)
Check("a fill value's undefined names are its inputs (not ask/set names, built-ins or repeats)",
    fin.Length = 2 && fin[1] = "Invoice Amount" && fin[2] = "Box 2", fin.Length ": " (fin.Length ? fin[1] : ""))
al := WfAskLabels(fsteps)
Check("...listed after the ask labels as the workflow's inputs",
    al.Length = 3 && al[1] = "Customer" && al[2] = "Invoice Amount" && al[3] = "Box 2", al.Length)
fundef := WfUndefinedVars(fsteps)
Check("...and never flagged as undefined (a label's or a text step's name still is)",
    fundef.Length = 2 && fundef[1] = "Label Only" && fundef[2] = "Typo",
    fundef.Length ": " (fundef.Length ? fundef[1] : ""))

; ---------- 3. authoring-time helpers ------------------------------------
steps := [["ask", "Customer", "", ""], ["collect", "Price", "", ""],
          ["set", "Greeting", "Hi {{Customer}}", ""],
          ["text", "{{Greeting}} {{Price}} {{Missing}} {{date}}", "", ""]]
names := WfVarNames(steps)
Check("WfVarNames finds all three", names.Length = 3 && names[1] = "Customer"
    && names[2] = "Price" && names[3] = "Greeting", "got " names.Length)
undef := WfUndefinedVars(steps)
Check("only the undefined one is flagged", undef.Length = 1 && undef[1] = "Missing",
    "got " (undef.Length ? undef[1] : "none") " (n=" undef.Length ")")

; ---------- 4. end to end, through the real engine -----------------------
; A throwaway window with a unique title; the Edit is the only control, so
; SendText from the engine lands in it.
title := "VKVarTest_ZZ"
tg := Gui("+AlwaysOnTop", title)
ed := tg.AddEdit("w520 r6")
tg.Show()
WinActivate("ahk_id " tg.Hwnd)
ControlFocus(ed.Hwnd, "ahk_id " tg.Hwnd)
Sleep(400)

runSteps := [                      ; not "run" — that's the built-in Run()
    ["focus", title, "", ""],
    ["text", "Dear {{Customer}},", "", ""],
    ["text", " again {{Customer}}", "", ""],
    ["set", "Greeting", "Hi {{Customer}}", ""],
    ["text", " [{{Greeting}}]", "", ""],
    ["text", " [{{Nope}}]", "", ""],
    ["keys", "^a", "", ""],
    ["collect", "Grabbed", "", ""],
    ["keys", "{End}", "", ""],
    ["text", " <<{{Grabbed}}>>", "", ""]]

askVals := Map()
askVals.CaseSense := false
askVals["Customer"] := "Ada"
collected := Map()
collected.CaseSense := false

ok := RunWorkflowSteps(runSteps, askVals, collected)
Sleep(200)
got := ed.Value
tg.Destroy()

Check("run completed", ok = true)
expectBody := "Dear Ada, again Ada [Hi Ada] [{{Nope}}]"
Check("ask value typed at BOTH spots", InStr(got, "Dear Ada, again Ada") > 0, "got: " got)
Check("set composed from another value", InStr(got, "[Hi Ada]") > 0, "got: " got)
Check("unknown name typed literally", InStr(got, "[{{Nope}}]") > 0, "got: " got)
Check("collect captured the text", collected.Has("Grabbed")
    && Trim(collected["Grabbed"], " `t`r`n") = expectBody,
    "collected: " (collected.Has("Grabbed") ? collected["Grabbed"] : "MISSING"))
Check("collected value reusable as {{Grabbed}}",
    InStr(got, "<<" expectBody ">>") > 0, "got: " got)

; ---------- 5. {{selected_file}} / {{selected_files}} ---------------------
; Every check SEEDS wfSelection, so File Explorer is never consulted (the
; tab-correct lookup itself is explorer-selftest's job). Runs are quiet: a
; refusal must record + tray, never pop a modal that would wedge the suite.
wfTrayOff := true
wfRunQuiet := true
none := Map()
none.CaseSense := false
p1 := "C:\Clients\Ada & Co\Invoice 2025.pdf", p2 := "C:\Clients\b.pdf"

wfSelection := ""
steps5 := [["text", "{{selected_file}} {{selected_files}}", "", ""]]
undef5 := WfUndefinedVars(steps5)
Check("the two names are built-ins (never flagged undefined)", undef5.Length = 0,
    undef5.Length ? undef5[1] : "")
Check("...and the authoring check never takes a snapshot", !IsObject(wfSelection))

wfSelection := [p1]
Check("selected_file = the one path, unquoted", WfSubst("{{selected_file}}", none) = p1,
    WfSubst("{{selected_file}}", none))
Check("selected_files = quoted", WfSubst("{{Selected_Files}}", none) = '"' p1 '"',
    WfSubst("{{Selected_Files}}", none))
wfSelection := [p1, p2]
Check("selected_files = every path quoted, space-joined",
    WfSubst("{{selected_files}}", none) = '"' p1 '" "' p2 '"', WfSubst("{{selected_files}}", none))
Check("selected_file with two selected never guesses", WfSubst("{{selected_file}}", none) = "")
mine := Map()
mine.CaseSense := false
mine["selected_file"] := "MINE"
Check("a user value named selected_file wins", WfSubst("{{selected_file}}", mine) = "MINE")

Check("needs: none", WfSelectionNeeds([["text", "{{date}}", "", ""]]) = 0)
Check("needs: plural only", WfSelectionNeeds([["run", "x {{selected_files}}", "", ""]]) = 1)
Check("needs: singular", WfSelectionNeeds([["set", "F", "{{ selected_file }}", ""],
    ["text", "{{selected_files}}", "", ""]]) = 2)
Check("needs: not when the workflow defines the name itself",
    WfSelectionNeeds([["set", "selected_file", "x", ""], ["text", "{{selected_file}}", "", ""]]) = 0)
Check("needs: an ask suggestion isn't substituted, so it doesn't count",
    WfSelectionNeeds([["ask", "Q", "{{selected_file}}", ""]]) = 0)

; End to end through the engine: set steps only — nothing touches the desktop.
wfRunName := "VKVarTestSel"
wfSelection := []
v5 := Map()
ok5 := RunWorkflowSteps([["set", "F", "{{selected_file}}", ""]], none, , v5)
Check("nothing selected: the run refuses to start", ok5 = false)
Check("...outcome error, before any step",
    WfRunOutcome() = "error" && wfRun["failed_step"] = 0 && !v5.Has("F"), WfRunOutcome())
Check("...reason names File Explorer and the count",
    InStr(wfRun["reason"], "File Explorer") && InStr(wfRun["reason"], "found 0"), wfRun["reason"])
Check("...and the reason never carries a path", !InStr(wfRun["reason"], "C:\"), wfRun["reason"])

wfSelection := [p1, p2]
ok5 := RunWorkflowSteps([["set", "F", "{{selected_file}}", ""]], none)
Check("two selected + the singular: refused", ok5 = false && InStr(wfRun["reason"], "found 2"),
    wfRun["reason"])

v5 := Map()
ok5 := RunWorkflowSteps([["set", "All", "{{selected_files}}", ""]], none, , v5)
Check("two selected + the plural: runs", ok5 = true && v5.Get("All", "") = '"' p1 '" "' p2 '"',
    v5.Get("All", "?"))

wfSelection := []
ok5 := RunWorkflowSteps([["set", "All", "{{selected_files}}", ""]], none)
Check("nothing selected + the plural: refused too", ok5 = false && WfRunOutcome() = "error")

; The snapshot is taken once and pinned: a second pass (what a loop does)
; sees the same files and never re-reads Explorer.
wfSelection := [p1]
pinned := wfSelection
va := Map(), vb := Map()
RunWorkflowSteps([["set", "F", "{{selected_file}}", ""]], none, , va)
RunWorkflowSteps([["set", "F", "{{selected_file}}", ""]], none, , vb)
Check("a second pass sees the same snapshot", va.Get("F", "") = p1 && vb.Get("F", "") = p1
    && ObjPtr(wfSelection) = ObjPtr(pinned))

; A step that doesn't use either name never needs a selection.
wfSelection := ""
ok5 := RunWorkflowSteps([["set", "X", "{{date}}", ""]], none)
Check("no selection names: runs without taking a snapshot", ok5 = true && !IsObject(wfSelection))

; Command-line arguments stand in for the selection (RunWorkflow reads the
; stub's A_Args) — full paths, relative ones resolved against the cwd.
Check("WfFullPath resolves a relative path", WfFullPath("a b.pdf") = A_WorkingDir "\a b.pdf",
    WfFullPath("a b.pdf"))
Check("WfFullPath keeps a full path", WfFullPath(p1) = p1)
wfRunQuiet := false

TestEnd()
