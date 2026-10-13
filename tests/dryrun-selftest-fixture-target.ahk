#Requires AutoHotkey v2.0
#SingleInstance Off
; The script tests\dryrun-selftest.ahk runs UNDER lib\DryRunShim.ahk
; (/include), aimed at dryrun-selftest-target.ahk's window. It makes every
; replaced call once and writes what each RETURNED to the file in A_Args[2]
; (key=value lines); the suite then checks the shim's log and the target's
; state -- nothing may have arrived there. Named *-target.ahk so the runner
; never runs it on its own (and reaps it if it is ever left behind).
;
; It includes every library a script can, so a name the shim defines that
; clashes with any of them fails this load (one namespace).
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"
#Include "%A_ScriptDir%\..\lib\AI.ahk"
#Include "%A_ScriptDir%\..\lib\Browser.ahk"
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"
#Include "%A_ScriptDir%\..\lib\ExplorerSel.ahk"

hwnd := Integer(A_Args[1])
outFile := A_Args[2]
win := "ahk_id " hwnd

Put(k, v) {
    global outFile
    FileAppend(k "=" v "`n", outFile, "UTF-8")
}
Put("loaded", 1)
Put("dryrun", VkDryRun() ? 1 : 0)
; Everything below sends REAL input without the shim -- never run it bare.
if !VkDryRun()
    ExitApp(1)
; ...and VkDryRun() only proves the shim's hook exists, not that each
; built-in is replaced: one dropped or renamed override would type into
; whatever window is active. Every name used below must have stopped being
; the built-in, or nothing runs. (Keep in step with DryRunShim's list.)
for n in ["Send", "SendInput", "SendEvent", "SendPlay", "SendText", "Click", "MouseClick",
    "MouseClickDrag", "MouseMove", "ControlSend", "ControlSendText", "ControlClick",
    "ControlSetText", "EditPaste", "ControlFocus", "ControlSetChecked", "ControlChooseIndex",
    "ControlChooseString", "ControlAddItem", "ControlDeleteItem", "ControlSetEnabled",
    "ControlShow", "ControlHide", "ControlMove", "ControlSetStyle", "ControlSetExStyle",
    "ControlShowDropDown", "ControlHideDropDown", "MenuSelect"]
    if %n%.IsBuiltIn {
        Put("builtin", n)
        ExitApp(1)
    }
Put("builtin", "none")

; Where the button is, in screen coordinates, for the mouse calls.
ControlGetPos(&bx, &by, &bw, &bh, "Button1", win)
WinGetPos(&wx, &wy, , , win)
cx := wx + bx + bw // 2, cy := wy + by + bh // 2
CoordMode("Mouse", "Screen")
MouseGetPos(&mx0, &my0)

Put("send", Send("abc") = "" ? "empty" : "value")
SendInput("{Tab}")
SendEvent("x")
SendPlay("y")
SendText("typed text")
Send("^v")
Send("^+v")                 ; Chrome's paste-as-plain-text is a paste too
Send("{Text}^v")            ; ...but {Text} types the characters: not a paste
Send("{Ctrl down}")         ; a Ctrl held across calls, then v: a paste
Send("v")
Send("{Ctrl up}")
Click(cx, cy)
MouseClick("Left", cx, cy, 2)
MouseClickDrag("Left", cx, cy, cx + 5, cy + 5)
MouseClickDrag("Left", , , cx + 7, cy + 7)   ; X1/Y1 omitted: from the pointer (loads, as real)
; Somewhere the pointer is NOT (it may be anywhere when this starts).
tx := mx0 > 100 ? mx0 - 41 : mx0 + 41, ty := my0 > 100 ? my0 - 23 : my0 + 23
MouseMove(tx, ty)
ControlSend("zz", "Edit1", win)
ControlSendText("tt", "Edit1", win)
ControlClick("Button1", win)
ControlSetText("set text", "Edit1", win)
EditPaste("pasted", "Edit1", win)
ControlFocus("Edit1", win)
ControlSetChecked(1, "Button2", win)
ControlChooseIndex(3, "ComboBox1", win)
Put("choose", ControlChooseString("Beta", "ComboBox1", win))
Put("choosepre", ControlChooseString("Be", "ComboBox1", win))     ; a leading part, as the real one
Put("choosecase", ControlChooseString("gAm", "ComboBox1", win))   ; case-insensitive
try
    ControlChooseString("Zeta", "ComboBox1", win)
catch as e
    Put("choosemiss", Type(e))
Put("additem", ControlAddItem("Delta", "ComboBox1", win))
ControlDeleteItem(1, "ComboBox1", win)
ControlSetEnabled(0, "Edit1", win)
ControlHide("Edit1", win)
ControlShow("Edit1", win)
ControlMove(1, 1, 20, 20, "Edit1", win)
ControlSetStyle("-0x10000000", "Edit1", win)
ControlSetExStyle("+0x200", "Edit1", win)
ControlShowDropDown("ComboBox1", win)
ControlHideDropDown("ComboBox1", win)
MenuSelect(win, , "File", "Submit")
MouseGetPos(&mx1, &my1)
Put("mousemoved", (mx1 = tx && my1 = ty) ? 1 : 0)

; A missing control throws the real TargetError, at THIS line.
Put("missline", A_LineNumber + 2)
try
    ControlSend("q", "NoSuchControl99", win)
catch as e
    Put("miss", Type(e) "|" e.What "|" e.Line "|" e.Message)
try
    ControlSetText("q", "Edit1", "ahk_id 1")
catch as e
    Put("misswin", Type(e) "|" e.Message)

; UIA actions: logged, reported as done, not performed.
el := UiaFindCond(hwnd, UiaIntCondition(UIA_PROP_CONTROLTYPE(), UIA_TYPE_EDIT()), 3000)
Put("uiafound", el ? 1 : 0)
Put("setvalue", UiaSetValue(el, "uia text") ? 1 : 0)
Put("focus", UiaFocus(el) ? 1 : 0)
b := UiaFind(hwnd, "Dry Press Zz", 3000)
Put("invoke", UiaInvoke(b) ? 1 : 0)

; TestShim came along: a MsgBox answers without showing.
Put("msgbox", MsgBox("dry hello", "Dry", "YesNo"))
Put("done", 1)
ExitApp(0)
