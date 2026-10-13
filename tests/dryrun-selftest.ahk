#Requires AutoHotkey v2.0
#SingleInstance Off
; Self-test for lib\DryRunShim.ahk (run_automation(dry_run=True)) and the
; dry-run hooks in lib\UIA.ahk / lib\_Common.ahk.
;
;  1. Without the shim (this script): the hooks are no-ops -- UiaDryRun and
;     VkDryRun say false, and a REAL UiaSetValue on the target still sets it.
;  2. Under the shim: dryrun-selftest-fixture-target.ahk makes every replaced
;     call against dryrun-selftest-target.ahk's window. Each is logged as an
;     "input" record, returns what the real one returns, and NOTHING arrives
;     -- the target's edit stays empty, its button unclicked, its checkbox
;     unchecked, its list unchosen, and the mouse is not where it was sent.
;     A missing control still throws the real TargetError at the caller's
;     line. TestShim comes along (a MsgBox answers without showing).
;
; Drives its own throwaway target only. The fixture's Send("^v") reads the
; clipboard (never writes it); the log holding that is deleted at the end.
; Writes PASS/FAIL to dryrun-selftest.result, ending ALL PASSED / N FAILURE(S).
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\UIA.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("dryrun-selftest")

; ---------- 1. no shim: the hooks do nothing -------------------------------
Check("VkDryRun() is false without the shim", VkDryRun() = false)
Check("UiaDryRun is a no-op without the shim", UiaDryRun("UiaFocus", "") = false)

hwnd := TargetLaunch("dryrun-selftest-target.ahk", "VKDryRunTarget_ZZ", &tpid)
if !hwnd
    TestEnd()

el := UiaFindCond(hwnd, UiaIntCondition(UIA_PROP_CONTROLTYPE(), UIA_TYPE_EDIT()), 3000, 1, &why)
Check("found the target's edit box", el != "", why)
Check("a real UiaSetValue still acts (no shim)", UiaSetValue(el, "real") && TargetState("edit", "[real]") = "[real]",
    TargetState("edit"))
ControlSetText("", "Edit1", "ahk_id " hwnd)
Check("target edit reset", TargetState("edit", "[]") = "[]", TargetState("edit"))

; ---------- 2. the fixture under the shim ----------------------------------
logFile := A_Temp "\vk-dryrun-selftest-log.txt"
outFile := A_Temp "\vk-dryrun-selftest-out.txt"
errFile := A_Temp "\vk-dryrun-selftest-err.txt"
for f in [logFile, outFile, errFile]
    try FileDelete(f)
EnvSet("VOICEKIT_TEST_LOG", logFile)
shim := A_ScriptDir "\..\lib\DryRunShim.ahk"
fixture := A_ScriptDir "\dryrun-selftest-fixture-target.ahk"
; Through cmd for the stderr redirect: /ErrorStdOut needs a real handle.
cmd := '"' ComSpecPath() '" /c ""' A_AhkPath '" /ErrorStdOut=UTF-8 /include "' shim '" "' fixture '" '
    . hwnd ' "' outFile '" 2> "' errFile '""'
Say("about to: run the fixture under the shim")
Run(cmd, A_ScriptDir, "Hide", &cpid)
if ProcessWaitClose(cpid, 60) {          ; the PID = still running at the timeout
    RunWait('taskkill /T /F /PID ' cpid, , "Hide")
    Check("the fixture finished", false, "killed after 60 s")
}
EnvSet("VOICEKIT_TEST_LOG")

FxOut(k) {
    global outFile
    txt := ""
    try txt := FileRead(outFile, "UTF-8")
    return RegExMatch(txt, "m)^" k "=(.*)$", &m) ? Trim(m[1], "`r") : "<none>"
}
errText := ""
try errText := FileRead(errFile, "UTF-8")
Check("the fixture loaded with every library under the shim", FxOut("loaded") = "1", errText)
Check("the fixture ran to the end", FxOut("done") = "1", errText)
Check("VkDryRun() is true under the shim", FxOut("dryrun") = "1")
Check("every replaced name has stopped being the built-in", FxOut("builtin") = "none", FxOut("builtin"))
Check("Send returns empty, like the real one", FxOut("send") = "empty", FxOut("send"))
Check("ControlChooseString returns the item's index", FxOut("choose") = "2", FxOut("choose"))
Check("...matching a LEADING part, as the real one does", FxOut("choosepre") = "2", FxOut("choosepre"))
Check("...case-insensitively", FxOut("choosecase") = "3", FxOut("choosecase"))
Check("...and a string no item starts with throws", FxOut("choosemiss") = "Error", FxOut("choosemiss"))
Check("ControlAddItem returns the new item's index", FxOut("additem") = "4", FxOut("additem"))
Check("the mouse never moved", FxOut("mousemoved") = "0")
miss := StrSplit(FxOut("miss"), "|")
Check("a missing control throws the real TargetError", miss.Length >= 4 && miss[1] = "TargetError"
    && InStr(miss[4], "control"), FxOut("miss"))
Check("... named for the replaced call, at the caller's line", miss.Length >= 3 && miss[2] = "ControlSend"
    && miss[3] = FxOut("missline"), FxOut("miss") " want line " FxOut("missline"))
Check("a missing window throws the real TargetError", InStr(FxOut("misswin"), "TargetError|") = 1,
    FxOut("misswin"))
Check("the fixture found the edit over UIA", FxOut("uiafound") = "1")
Check("UiaSetValue reports success", FxOut("setvalue") = "1")
Check("UiaFocus reports success", FxOut("focus") = "1")
Check("UiaInvoke reports success", FxOut("invoke") = "1")
Check("TestShim came along (MsgBox answered its default)", FxOut("msgbox") = "Yes", FxOut("msgbox"))

; The log: one input record per call.
logText := ""
try logText := FileRead(logFile, "UTF-8")
Rec(fn) {
    global logText
    n := 0, pos := 1
    while pos := InStr(logText, '"fn":"' fn '"', true, pos)
        n += 1, pos += 1
    return n
}
for fn in ["Send", "SendInput", "SendEvent", "SendPlay", "SendText", "Click", "MouseClick",
    "MouseClickDrag", "MouseMove", "ControlSendText", "ControlClick", "ControlSetText", "EditPaste",
    "ControlFocus", "ControlSetChecked", "ControlChooseIndex", "ControlChooseString",
    "ControlAddItem", "ControlDeleteItem", "ControlSetEnabled", "ControlShow", "ControlHide",
    "ControlMove", "ControlSetStyle", "ControlSetExStyle", "ControlShowDropDown",
    "ControlHideDropDown", "MenuSelect", "UiaSetValue", "UiaFocus", "UiaInvoke"]
    Check("logged: " fn, Rec(fn) >= 1)
Check("logged: ControlSend (once; the missing control is not logged)", Rec("ControlSend") = 1, Rec("ControlSend"))
Check("a paste records the clipboard length", RegExMatch(logText, '"clipboard_len":\d+,"fn":"Send","keys":"\^v","kind":"input"'))
Check("Ctrl+Shift+V is a paste too", RegExMatch(logText, '"clipboard_len":\d+,"fn":"Send","keys":"\^\+v","kind":"input"'))
Check("{Text}^v types characters: logged, but no clipboard",
    InStr(logText, '{"fn":"Send","keys":"{Text}^v","kind":"input"}'))
Check("a v while an earlier {Ctrl down} is held is a paste",
    RegExMatch(logText, '"clipboard_len":\d+,"fn":"Send","keys":"v","kind":"input"'))
Check("MouseClickDrag without X1/Y1 is logged (from the pointer)",
    RegExMatch(logText, '"fn":"MouseClickDrag","kind":"input","x":-?\d+,"x2":-?\d+'))
Check("MenuSelect logs its menu path", InStr(logText, '"menu":"File > Submit"'))
Check("a typed value is in the record", InStr(logText, '"text":"typed text"'))
Check("a UIA record names its element", InStr(logText, '"element":"Dry Press Zz","fn":"UiaInvoke","kind":"input"'))
Check("UiaSetValue records its value", InStr(logText, '"fn":"UiaSetValue"') && InStr(logText, '"text":"uia text"'))
Check("a mouse record carries its coordinates", RegExMatch(logText, '"fn":"MouseMove","kind":"input","x":\d+,"y":\d+'))
Check("Control* records name their process", InStr(logText, '"process":"AutoHotkey64.exe"'))
Check("the MsgBox is logged as a dialog", InStr(logText, '"kind":"MsgBox"'))

; Nothing arrived at the target.
Sleep(400)
Check("target edit still empty", TargetState("edit") = "[]", TargetState("edit"))
Check("target button never clicked", TargetState("clicks") = "0", TargetState("clicks"))
Check("target checkbox never checked", TargetState("checked") = "0", TargetState("checked"))
Check("target list never chosen", TargetState("choice") = "[]", TargetState("choice"))
Check("target list never added to or deleted from", TargetState("items") = "3", TargetState("items"))
Check("target edit never disabled, hidden or resized",
    TargetState("enabled") = "1" && TargetState("visible") = "1" && TargetState("editw") != "20",
    TargetState("enabled") "/" TargetState("visible") "/" TargetState("editw"))

TargetStop()
for f in [logFile, outFile, errFile]
    try FileDelete(f)
TestEnd()
