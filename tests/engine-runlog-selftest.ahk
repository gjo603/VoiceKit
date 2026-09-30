#Requires AutoHotkey v2.0
; Self-test for the run log and run record in lib\Workflow.ahk — the evidence
; a run leaves behind (logs\workflow-runs.log + logs\workflow-runs.ini).
;
; The failing-step checks run in QUIET mode on purpose: that is the mode a
; headless batch uses, and if quiet mode ever stops suppressing the modal
; popup this test HANGS rather than fails — which the runner reports as a
; failure at its 120 s timeout, exactly like every other blocked-MsgBox case.
;
; Writes PASS/FAIL to engine-runlog-selftest.result. Both artifacts are
; redirected to %TEMP% (wfLogFolder) so running the suite never touches the
; user's real run history.
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("engine-runlog-selftest")

; Read one key of a workflow's record.
Rec(sect, key) {
    return IniRead(WfRecordFile(), sect, key, "")
}

; ---------- 0. default location, then get out of the user's way ----------
Check("default log lives in the repo's logs folder",
    InStr(WfLogFile(), "\logs\workflow-runs.log") > 0, WfLogFile())
Check("default record sits beside it",
    InStr(WfRecordFile(), "\logs\workflow-runs.ini") > 0, WfRecordFile())

wfLogFolder := A_Temp "\vk-runlog-selftest"
; No real toasts: Windows keeps one on screen while the desktop is idle, and
; it takes the foreground from the NEXT suite (engine-vars' ^a/^c landed in
; it). Hiding the tray icon does not pull it on Windows 11 — measured.
; wfTrayLast still records what would have been shown.
wfTrayOff := true
try DirDelete(wfLogFolder, true)
DirCreate(wfLogFolder)
Check("redirect takes effect", WfLogFile() = wfLogFolder "\workflow-runs.log", WfLogFile())

; ---------- 1. helpers in isolation --------------------------------------
Check("WfOneLine folds newlines", WfOneLine("a`r`nb`tc   d") = "a b c d",
    WfOneLine("a`r`nb`tc   d"))
Check("WfOneLine truncates", StrLen(WfOneLine(StrReplace(Format("{:100}", ""), " ", "x"), 20)) = 23,
    WfOneLine(StrReplace(Format("{:100}", ""), " ", "x"), 20))
Check("WfOneLine leaves short text alone", WfOneLine("hi") = "hi")
Check("WfRunNameFromFile strips the suffix",
    WfRunNameFromFile("C:\x\workflows\MorningTabs.steps.txt") = "MorningTabs",
    WfRunNameFromFile("C:\x\workflows\MorningTabs.steps.txt"))

; Log trimming, on a throwaway file in %TEMP% — never the real log.
tmp := A_Temp "\vk-runlog-trim.txt"
try FileDelete(tmp)
body := ""
loop 500
    body .= "line " A_Index "`n"
FileAppend(body, tmp, "UTF-8")
WfLogTrim(tmp)
kept := FileRead(tmp, "UTF-8")
Check("trim keeps the newest half", InStr(kept, "line 500") > 0 && !InStr(kept, "line 1`n"),
    "first 12 chars: " SubStr(kept, 1, 12))
Check("trim cuts at a line boundary", SubStr(kept, 1, 5) = "line ", SubStr(kept, 1, 12))
Check("trim leaves no temp file", !FileExist(tmp ".tmp-" DllCall("GetCurrentProcessId", "uint")))
; Crash-safe: temp file + move, never delete-then-append. A log held
; without delete-sharing refuses the move, and must be left whole.
try FileDelete(tmp)
FileAppend(body, tmp, "UTF-8")
before := FileRead(tmp, "UTF-8")
holder := FileOpen(tmp, "r -d")
WfLogTrim(tmp)
holder.Close()
Check("a refused trim leaves the log whole", FileRead(tmp, "UTF-8") == before)
Check("...and no temp file behind", !FileExist(tmp ".tmp-" DllCall("GetCurrentProcessId", "uint")))
try FileDelete(tmp)

; ---------- 2. a run that finishes ---------------------------------------
; A throwaway window with a unique title — never the user's windows.
title := "VKRunLogTest_ZZ"
tg := Gui("+AlwaysOnTop", title)
ed := tg.AddEdit("w420 r4")
tg.Show()
WinActivate("ahk_id " tg.Hwnd)
ControlFocus(ed.Hwnd, "ahk_id " tg.Hwnd)
Sleep(400)

okName := "VKRunLogTestOk"
wfRunName := okName
logBefore := FileExist(WfLogFile()) ? FileGetSize(WfLogFile()) : 0

good := [["focus", title, "", ""], ["text", "hello", "", ""]]
ranOk := RunWorkflowSteps(good)
Check("successful run returns true", ranOk = true)
Check("outcome recorded as ok", Rec(okName, "outcome") = "ok", Rec(okName, "outcome"))
Check("step count recorded", Rec(okName, "steps_total") = "2", Rec(okName, "steps_total"))
Check("no failed step on success", Rec(okName, "failed_step") = "0", Rec(okName, "failed_step"))
Check("start and end both stamped",
    StrLen(Rec(okName, "started")) = 14 && StrLen(Rec(okName, "ended")) = 14,
    Rec(okName, "started") " / " Rec(okName, "ended"))

logText := FileRead(WfLogFile(), "UTF-8")
Check("log has a per-step line", InStr(logText, okName "  step 1/2") > 0)
Check("log names the step type", InStr(logText, okName "  step 2/2  Type") > 0)
Check("log brackets the run", InStr(logText, okName "  ---- run started: 2 steps") > 0
    && InStr(logText, okName "  ---- run ok") > 0)
Check("log actually grew", FileGetSize(WfLogFile()) > logBefore)

; ---------- 3. a run that fails, headless --------------------------------
; wfRunQuiet is what a batch sets: record + TrayTip, never a modal — a modal
; here would hold the process open and this test would never write a result.
failName := "VKRunLogTestFail"
wfRunName := failName
wfRunQuiet := true
bad := [["text", "one", "", ""], ["if", "ahk_id 1", "", "notacondition"], ["text", "two", "", ""]]
ranBad := RunWorkflowSteps(bad)
wfRunQuiet := false
Check("the quiet failure went to the tray, not a modal", InStr(wfTrayLast, "Stopped at step 2") > 0,
    wfTrayLast)

Check("failing run returns false", ranBad = false)
Check("outcome recorded as failed", Rec(failName, "outcome") = "failed", Rec(failName, "outcome"))
Check("the failing step number is recorded", Rec(failName, "failed_step") = "2",
    Rec(failName, "failed_step"))
Check("the step description is recorded", InStr(Rec(failName, "step"), "notacondition") > 0,
    Rec(failName, "step"))
Check("the reason is kept, not thrown away", Rec(failName, "reason") != "",
    Rec(failName, "reason"))
Check("steps_total survives the failure", Rec(failName, "steps_total") = "3")
logText := FileRead(WfLogFile(), "UTF-8")
Check("log records the failure", InStr(logText, failName "  FAILED at step 2/3") > 0)
Check("the third step never ran", !InStr(logText, failName "  step 3/3"))

; The engine must not have typed step 3 into the window either.
Sleep(150)
Check("run really stopped at the failure", !InStr(ed.Value, "two"), "edit: " ed.Value)

; ---------- 4. a run stopped from outside --------------------------------
stopName := "VKRunLogTestStop"
wfRunName := stopName
wfRunAbortCheck := (*) => true              ; what the loop's Stop button installs
ranStop := RunWorkflowSteps([["text", "x", "", ""]])
wfRunAbortCheck := ""
Check("aborted run returns false", ranStop = false)
Check("a stop is recorded as stopped, not failed", Rec(stopName, "outcome") = "stopped",
    Rec(stopName, "outcome"))
Check("a stop records no failing step", Rec(stopName, "failed_step") = "0")

; ---------- 5. a run that never started ----------------------------------
neverName := "VKRunLogTestNever"
WfRunRecordSimple(neverName, "error", "Workflow file not found: nope.steps.txt")
Check("never-ran is its own outcome", Rec(neverName, "outcome") = "error",
    Rec(neverName, "outcome"))
Check("never-ran keeps its reason", InStr(Rec(neverName, "reason"), "not found") > 0,
    Rec(neverName, "reason"))
Check("never-ran ran zero steps", Rec(neverName, "steps_total") = "0")

; ---------- 6. loop-style fields -----------------------------------------
wfRunName := okName
WfRunRecordUpdate(Map("passes_done", 3, "passes_total", 5))
Check("pass counts can be added after the fact",
    Rec(okName, "passes_done") = "3" && Rec(okName, "passes_total") = "5")

; A later PLAIN run of the same workflow must not inherit them: the record is
; the last run's, whole — per-key writes used to leave a loop's pass counts
; and start time behind, and a fresh run was reported as "3 of 5 passes".
WfRunRecordUpdate(Map("loop_started_text", "2001-01-01 00:00:00"))
wfRunName := okName
RunWorkflowSteps([["wait", "10", "", ""]])
Check("a plain run replaces the whole record (no stale pass counts)",
    Rec(okName, "passes_done") = "" && Rec(okName, "passes_total") = "",
    "passes_done='" Rec(okName, "passes_done") "'")
Check("...nor a stale loop start time", Rec(okName, "loop_started_text") = "",
    Rec(okName, "loop_started_text"))
Check("...and still records the new run", Rec(okName, "outcome") = "ok"
    && Rec(okName, "steps_total") = "1", Rec(okName, "outcome") "/" Rec(okName, "steps_total"))
Check("other workflows' sections are untouched", Rec(failName, "outcome") = "failed",
    Rec(failName, "outcome"))

; ---------- 7. a caller's pre-seeded varsOut ------------------------------
; CaseSense can only be set on an EMPTY Map; the engine used to set it
; unconditionally and threw on a Map the caller had already filled.
seeded := Map("Preset", "x")
wfRunName := "VKRunLogTestVars"
threw := false
try RunWorkflowSteps([["set", "Later", "{{Preset}}-y", ""]], , , seeded)
catch
    threw := true
Check("a non-empty varsOut Map is accepted", !threw)
Check("...and is the working namespace", seeded.Get("Later", "") = "x-y", seeded.Get("Later", "?"))

; ---------- 8. a cancelled ask dialog still leaves a record --------------
; RunWorkflow gathers inputs itself, so a cancel there used to return before
; the engine recorded anything — and a caller polling the record waited for
; an outcome that never came. The abort hook closes the dialog the way a
; Stop does, which is a cancel from RunWorkflow's point of view.
askFile := wfLogFolder "\VKRunLogTestAsk.steps.txt"
FileAppend("ask|Customer||`ntext|{{Customer}}||`n", askFile, "UTF-8")
wfRunAbortCheck := (*) => true
ranAsk := RunWorkflow(askFile)
wfRunAbortCheck := ""
Check("a cancelled ask returns false", ranAsk = false)
Check("...and is recorded as cancelled", Rec("VKRunLogTestAsk", "outcome") = "cancelled",
    Rec("VKRunLogTestAsk", "outcome"))

; ---------- 9. a failure reason never carries a filled-in value ---------
; What a {{Name}} resolved to can be a client's name, and the record / log
; travel (run_automation, read_log -> MCP -> a cloud model). They get the
; step AS WRITTEN; only the local popup / tray note shows what was tried.
secName := "VKRunLogTestSecret"
wfRunName := secName
wfRunQuiet := true
; The value arrives the way a batch row or an ask answer does (askVals) —
; a set step would carry it in the steps as written.
ranSec := RunWorkflowSteps([["move", "{{Client}} ZZNoSuchWindow_vk", "max", ""]]
    , Map("Client", "SECRETCLIENT"))
wfRunQuiet := false
recR := Rec(secName, "reason"), recS := Rec(secName, "step")
Check("a window {{Name}} failure is recorded", ranSec = false && InStr(recR, "Window not found") > 0, recR)
Check("...its reason names the window as written", InStr(recR, "{{Client}} ZZNoSuchWindow_vk") > 0, recR)
Check("...never the value it resolved to", !InStr(recR, "SECRETCLIENT") && !InStr(recS, "SECRETCLIENT"),
    recR " / " recS)
Check("...while the local tray note shows what was tried", InStr(wfTrayLast, "SECRETCLIENT") > 0, wfTrayLast)

; An element name filled in from a value (collect's named box — the same
; path click / hover / if report through).
WinActivate("ahk_id " tg.Hwnd)
WinWaitActive("ahk_id " tg.Hwnd, , 2)
wfRunName := secName "Elem"
wfRunQuiet := true
ranSec2 := RunWorkflowSteps([["collect", "Got", "{{Client}} box", ""]]
    , Map("Client", "SECRETCLIENT"))
wfRunQuiet := false
recR2 := Rec(secName "Elem", "reason")
Check("an element {{Name}} failure is recorded", ranSec2 = false && recR2 != "", recR2)
Check("...its reason names the element as written", InStr(recR2, "{{Client}} box") > 0, recR2)
Check("...never the value", !InStr(recR2, "SECRETCLIENT"), recR2)
logText := FileRead(WfLogFile(), "UTF-8")
Check("the run log never carries the resolved value", !InStr(logText, "SECRETCLIENT"))

; WfUnsubst on its own: longest field first, trimmed forms, untouched fields.
Check("WfUnsubst puts a field back", WfUnsubst("Window not found: Acme Co - Excel"
    , ["focus", "{{C}} - Excel", "", ""], ["focus", "Acme Co - Excel", "", ""])
    = "Window not found: {{C}} - Excel")
Check("WfUnsubst leaves an unsubstituted step alone", WfUnsubst("x: Notepad"
    , ["close", "Notepad", "", ""], ["close", "Notepad", "", ""]) = "x: Notepad")

tg.Destroy()
try DirDelete(wfLogFolder, true)

TestEnd()

