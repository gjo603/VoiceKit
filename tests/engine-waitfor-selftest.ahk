#Requires AutoHotkey v2.0
; Self-test for the `waitfor` event waits in lib\Workflow.ahk.
; Drives a THROWAWAY GUI with a unique title — never the user's windows.
; Writes PASS/FAIL to engine-waitfor-selftest.result; a missing result file
; means a step failed and its error MsgBox is blocking.
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("engine-waitfor-selftest")
wfLogFolder := A_Temp "\vk-selftest-logs"   ; keep test runs out of the user's real run history

; ---------- 1. paramC parsing ------------------------------------------
w := WfWaitParts("elementexists")
Check("bare condType defaults to 10s", w.cond = "elementexists" && w.secs = 10)
w := WfWaitParts("textvisible,45")
Check("condType,seconds parsed", w.cond = "textvisible" && w.secs = 45)
w := WfWaitParts("winexists, 2.5")
Check("fractional seconds + spaces", w.cond = "winexists" && w.secs = 2.5)
w := WfWaitParts("winexists,junk")
Check("junk seconds fall back to 10", w.secs = 10)
w := WfWaitParts("winexists,-5")
Check("negative seconds fall back to 10", w.secs = 10)

; ---------- 2. a throwaway window that becomes ready LATE --------------
title := "VKWaitTest_ZZ"
tg := Gui("+AlwaysOnTop", title)
info := tg.AddText("w420", "Loading, please wait")
btn := tg.AddButton("w220", "Please Wait")
tg.Show()
Sleep(300)

; An element "appears" by taking the name we're waiting for. Hiding a control
; is NOT a valid stand-in: MSAA still reports a location for a hidden AHK Gui
; control, so elementexists stays true — probed below.
hiddenProbe := tg.AddButton("w220", "Hidden Probe Zz")
hiddenProbe.Visible := false
Sleep(200)
Check("hidden controls still report an accessible location (why this test renames instead)",
    IsObject(AccFindByName(WinExist(title), "Hidden Probe Zz", 700)) = true,
    "if this ever fails, elementexists could use a visibility check")

BecomeReady() {
    global btn, info
    btn.Text := "Ready Now"
    info.Text := "Found 3 results"
}
SetTimer(BecomeReady, -1200)               ; ready ~1.2 s from now

t0 := A_TickCount
err := WfWaitFor(title, "Ready Now", "elementexists", 15)
waited := A_TickCount - t0
Check("waits for an element to appear", err = "", "err=" err)
Check("returned EARLY, not on the 15s timeout", waited < 8000, waited " ms")
Check("actually waited for it", waited > 700, waited " ms")

; ---------- 3. loose text match (the 'did it find anything?' test) -----
t0 := A_TickCount
err := WfWaitFor(title, "found 3 RESULTS", "textvisible", 10)
Check("text match is case-insensitive", err = "", "err=" err)
Check("already-true condition returns at once", A_TickCount - t0 < 3000, (A_TickCount - t0) " ms")

; ---------- 4. timeouts explain what never happened -------------------
err := WfWaitFor(title, "Never Appears Xyz", "elementexists", 2)
Check("missing element times out", err != "")
Check("timeout names what never appeared", InStr(err, "never appeared") && InStr(err, "Never Appears Xyz"),
    "msg=" err)

err := WfWaitFor(title, "Found 3 results", "textnotvisible", 2)
Check("still-visible text times out", InStr(err, "never went away") > 0, "msg=" err)

err := WfWaitFor("No Such Window Xyz Zz", "", "winexists", 2)
Check("missing window times out with its name", InStr(err, "never opened") && InStr(err, "No Such Window"),
    "msg=" err)

; ---------- 5. an element DISAPPEARING --------------------------------
GoAway() {
    global btn
    btn.Text := "All Done"          ; the name we waited for is gone
}
SetTimer(GoAway, -1000)
t0 := A_TickCount
err := WfWaitFor(title, "Ready Now", "elementnotexists", 15)
Check("waits for an element to disappear", err = "", "err=" err)
Check("disappear returned early", A_TickCount - t0 < 8000, (A_TickCount - t0) " ms")

; ---------- 6. clipboard change (user's clipboard preserved) ----------
saved := ClipboardAll()
A_Clipboard := "before-value"
Sleep(100)
SetClip() {
    A_Clipboard := "after-value"
}
SetTimer(SetClip, -900)
t0 := A_TickCount
err := WfWaitFor("", "", "clipboardchanged", 10)
clipWaited := A_TickCount - t0
Check("detects a clipboard change", err = "", "err=" err)
Check("clipboard wait returned early", clipWaited < 6000, clipWaited " ms")
err := WfWaitFor("", "", "clipboardchanged", 2)          ; nothing changes it now
Check("clipboard wait times out cleanly", InStr(err, "nothing new was copied") > 0, "msg=" err)
A_Clipboard := saved

; ---------- 7. clipboardchanged is refused as an `if` -----------------
r := WfEvalCond(["if", title, "", "clipboardchanged"])
Check("`if clipboard changed` is refused", InStr(r.err, "Wait-until") > 0, "err=" r.err)
r := WfEvalCond(["if", "", "", "winexists"])
Check("empty window still refused", r.err != "")

; ---------- 8. the new text conditions drive a real `if` --------------
steps := [["if", title, "Found 3 results", "textvisible"],
          ["set", "Branch", "SAW-IT", ""],
          ["else", "", "", ""],
          ["set", "Branch", "MISSED-IT", ""],
          ["endif", "", "", ""]]
vars := Map()
vars.CaseSense := false
ok := RunWorkflowSteps(steps, Map(), "", vars)
Check("if textvisible takes the true branch", ok && vars.Get("Branch", "") = "SAW-IT",
    "branch=" vars.Get("Branch", "?"))

steps[1] := ["if", title, "Nothing Like This Xyz", "textvisible"]
vars2 := Map()
vars2.CaseSense := false
ok := RunWorkflowSteps(steps, Map(), "", vars2)
Check("if textvisible takes the else branch", ok && vars2.Get("Branch", "") = "MISSED-IT",
    "branch=" vars2.Get("Branch", "?"))

; ---------- 9. waitfor runs as a real step, with {{values}} -----------
info.Text := "Order ACME-42 confirmed"
askVals := Map()
askVals.CaseSense := false
askVals["Customer"] := "ACME-42"
flow := [["waitfor", title, "Order {{Customer}} confirmed", "textvisible,10"]]
Check("waitfor works as a step, with a {{value}} in it",
    RunWorkflowSteps(flow, askVals) = true)

tg.Destroy()
TestEnd()
