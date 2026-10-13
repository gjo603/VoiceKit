#Requires AutoHotkey v2.0
; ============================================================
;  lib\DryRunShim.ahk -- the dry-run shim (2026-10-12)
;
;  NEVER #Included by product code. The MCP's
;  run_automation(dry_run=True) loads it AHEAD of a macro or an
;  isolated module's body with AutoHotkey's /include switch:
;      AutoHotkey64.exe /ErrorStdOut=UTF-8 /include DryRunShim.ahk Body.ahk
;  It includes lib\TestShim.ahk itself (below), so a dry run is
;  always a quiet test run too. Measured 2026-10-12: AutoHotkey
;  takes ONE /include switch -- two exit 2 with no output and run
;  nothing -- so the pairing lives here, not on the command line.
;
;  Functions defined here REPLACE the input built-ins of the same
;  name for the whole script, the libraries it #Includes among them
;  (the workflow engine, Browser.ahk, UIA.ahk's UiaClickEl). Each
;  call is written to %VOICEKIT_TEST_LOG% as one JSON line with
;  kind "input" and NOTHING is sent: no keystroke, no click, the
;  mouse does not move, no control changes.
;      {"kind":"input","fn":"Send","keys":"^v","clipboard_len":12,
;       "clipboard":"first 200 chars"}
;  Replaced: Send SendInput SendEvent SendPlay SendText, Click
;  MouseClick MouseClickDrag MouseMove, ControlSend ControlSendText
;  ControlClick ControlSetText EditPaste ControlFocus
;  ControlSetChecked ControlChooseIndex ControlChooseString
;  ControlAddItem ControlDeleteItem ControlSetEnabled ControlShow
;  ControlHide ControlMove ControlSetStyle ControlSetExStyle
;  ControlShowDropDown ControlHideDropDown, MenuSelect.
;  Each returns what the real one returns ("" -- ControlChooseString
;  the item's index, ControlAddItem the new item's), and the
;  Control* ones and MenuSelect still RESOLVE their target: a
;  control or window that isn't there throws the same TargetError,
;  at the caller's line, as a real run would -- a dry run that
;  sailed past a missing control would prove nothing.
;
;  Paste-like keys (^v, ^+v, +{Insert}, {Ctrl down}v -- also a v
;  sent while an earlier call's {Ctrl down} is still held) also
;  record the clipboard as it stands -- length and its first 200
;  characters -- because that is what a real run would have pasted.
;  {Text}/{Raw} keys type the characters, so they never count.
;
;  Library actions that go through COM rather than a built-in
;  (lib\UIA.ahk: UiaSetValue, UiaInvoke's InvokePattern, UiaFocus)
;  look up _VkDryRunNote by name before acting; with this file
;  loaded they log and return success instead of acting. Without
;  it (every normal run) the lookup throws "Variable not found",
;  caught there -- measured: no #Warn VarUnset warning either, even
;  under TestShim's '#Warn VarUnset, StdOut'.
;
;  NOT covered -- the script's own: Run / RunWait (other processes),
;  file writes, clipboard WRITES (A_Clipboard := ...), window
;  commands (WinActivate, WinClose, WinMove...), PostMessage /
;  SendMessage, ComCall / DllCall / ComObject calls it makes itself,
;  hotkeys and hotstrings it registers.
;  tests\dryrun-selftest.ahk checks every replaced name really has
;  stopped being the built-in (Func.IsBuiltIn) -- a new one goes in
;  its list AND in the fixture's guard. VkDryRun() (lib\_Common.ahk)
;  is true under this shim, so a script can skip those itself.
;
;  Names: every helper is _VkDry* (plus TestShim's _VkTest*), so
;  nothing here can collide with lib\_Common.ahk / Theme / UIA /
;  Browser / Acc / Workflow / ExplorerSel / Clip / Json or a macro's
;  own code. No top-level variables at all. ASCII only.
; ============================================================
#Include "%A_LineFile%\..\TestShim.ahk"

; ---- the hook the libraries call -----------------------------------------

; A library action that bypasses the built-ins (see the header): log it as
; an input record. detail: a Map of extra fields. Returns true.
_VkDryRunNote(fn, detail := "") {
    rec := Map("kind", "input", "fn", _VkTestText(fn))
    if (detail is Map)
        for k, v in detail
            rec[k] := (v is Integer) ? v : _VkTestText(v)
    _VkTestLog(rec)
    return true
}

; ---- keyboard ------------------------------------------------------------

Send(keys) {
    _VkDryKeys("Send", keys)
}

SendInput(keys) {
    _VkDryKeys("SendInput", keys)
}

SendEvent(keys) {
    _VkDryKeys("SendEvent", keys)
}

SendPlay(keys) {
    _VkDryKeys("SendPlay", keys)
}

SendText(text) {
    _VkTestLog(Map("kind", "input", "fn", "SendText", "text", _VkTestText(text)))
}

; ---- mouse ---------------------------------------------------------------

Click(options*) {
    s := ""
    for o in options
        s .= (A_Index > 1 ? " " : "") (IsSet(o) ? _VkTestText(o) : "")
    _VkTestLog(Map("kind", "input", "fn", "Click", "options", s, "coordmode", A_CoordModeMouse))
}

MouseClick(whichButton := "Left", x?, y?, clickCount := 1, speed?, downOrUp?, relative?) {
    rec := Map("kind", "input", "fn", "MouseClick", "button", _VkTestText(whichButton))
    if IsSet(x)
        rec["x"] := _VkDryNum(x)
    if IsSet(y)
        rec["y"] := _VkDryNum(y)
    rec["count"] := _VkDryNum(clickCount)
    if IsSet(downOrUp) && downOrUp != ""
        rec["updown"] := _VkTestText(downOrUp)
    if IsSet(relative) && relative != ""
        rec["relative"] := 1
    rec["coordmode"] := A_CoordModeMouse
    _VkTestLog(rec)
}

; X1/Y1 are optional, as in the real one: the drag starts at the pointer.
MouseClickDrag(whichButton := "Left", x1?, y1?, x2 := "", y2 := "", speed?, relative?) {
    if !IsSet(x1) || !IsSet(y1) {
        MouseGetPos(&px, &py)
        x1 := x1 ?? px, y1 := y1 ?? py
    }
    rec := Map("kind", "input", "fn", "MouseClickDrag", "button", _VkTestText(whichButton),
        "x", _VkDryNum(x1), "y", _VkDryNum(y1), "x2", _VkDryNum(x2), "y2", _VkDryNum(y2))
    if IsSet(relative) && relative != ""
        rec["relative"] := 1
    rec["coordmode"] := A_CoordModeMouse
    _VkTestLog(rec)
}

MouseMove(x, y, speed?, relative?) {
    rec := Map("kind", "input", "fn", "MouseMove", "x", _VkDryNum(x), "y", _VkDryNum(y))
    if IsSet(relative) && relative != ""
        rec["relative"] := 1
    rec["coordmode"] := A_CoordModeMouse
    _VkTestLog(rec)
}

; ---- controls ------------------------------------------------------------

ControlSend(keys, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlSend", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["keys"] := _VkTestText(keys)
    _VkTestLog(rec)
}

ControlSendText(keys, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlSendText", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["text"] := _VkTestText(keys)
    _VkTestLog(rec)
}

ControlSetText(newText, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlSetText", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["text"] := _VkTestText(newText)
    _VkTestLog(rec)
}

EditPaste(text, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("EditPaste", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["text"] := _VkTestText(text)
    _VkTestLog(rec)
}

ControlFocus(control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    _VkTestLog(_VkDryTarget("ControlFocus", control?, winTitle?, winText?, excludeTitle?, excludeText?))
}

ControlSetChecked(newSetting, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlSetChecked", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["setting"] := _VkDryNum(newSetting)
    _VkTestLog(rec)
}

ControlChooseIndex(n, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlChooseIndex", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["index"] := _VkDryNum(n)
    _VkTestLog(rec)
}

; Returns the index the real one would select. The real rule is the list's
; own (CB_SELECTSTRING / LB_SELECTSTRING): the first item whose LEADING part
; matches, case-insensitively -- "Be" chooses "Beta". Read with
; ControlGetItems (read-only); no match throws, as the real one does.
ControlChooseString(str, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlChooseString", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["text"] := _VkTestText(str)
    try items := ControlGetItems(control?, winTitle?, winText?, excludeTitle?, excludeText?)
    catch as e
        throw (e is TargetError ? TargetError : Error)(e.Message, -1, e.Extra)
    idx := 0, str := String(str)
    for it in items
        if (SubStr(it, 1, StrLen(str)) = str) {
            idx := A_Index
            break
        }
    if !idx
        throw Error("Failed", -1, str)
    rec["index"] := idx
    _VkTestLog(rec)
    return idx
}

; Returns the new item's index, as the real one does (the end of the list --
; a sorted list would place it elsewhere, which a dry run can't know).
ControlAddItem(str, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlAddItem", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["text"] := _VkTestText(str)
    n := 0
    try n := ControlGetItems(control?, winTitle?, winText?, excludeTitle?, excludeText?).Length
    rec["index"] := n + 1
    _VkTestLog(rec)
    return n + 1
}

ControlDeleteItem(n, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlDeleteItem", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["index"] := _VkDryNum(n)
    _VkTestLog(rec)
}

ControlSetEnabled(newSetting, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlSetEnabled", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["setting"] := _VkDryNum(newSetting)
    _VkTestLog(rec)
}

ControlShow(control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    _VkTestLog(_VkDryTarget("ControlShow", control?, winTitle?, winText?, excludeTitle?, excludeText?))
}

ControlHide(control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    _VkTestLog(_VkDryTarget("ControlHide", control?, winTitle?, winText?, excludeTitle?, excludeText?))
}

ControlShowDropDown(control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    _VkTestLog(_VkDryTarget("ControlShowDropDown", control?, winTitle?, winText?, excludeTitle?, excludeText?))
}

ControlHideDropDown(control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    _VkTestLog(_VkDryTarget("ControlHideDropDown", control?, winTitle?, winText?, excludeTitle?, excludeText?))
}

ControlMove(x?, y?, width?, height?, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlMove", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    for k, v in Map("x", x ?? "", "y", y ?? "", "w", width ?? "", "h", height ?? "")
        if (v != "")
            rec[k] := _VkDryNum(v)
    _VkTestLog(rec)
}

ControlSetStyle(value, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlSetStyle", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["value"] := _VkDryNum(value)
    _VkTestLog(rec)
}

ControlSetExStyle(value, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := _VkDryTarget("ControlSetExStyle", control?, winTitle?, winText?, excludeTitle?, excludeText?)
    rec["value"] := _VkDryNum(value)
    _VkTestLog(rec)
}

; ---- menus ---------------------------------------------------------------

; Resolves the window (a missing one throws the real TargetError); the menu
; path is logged, not walked.
MenuSelect(winTitle?, winText?, menu?, sub1?, sub2?, sub3?, sub4?, sub5?, sub6?,
    excludeTitle?, excludeText?) {
    rec := _VkDryTarget("MenuSelect", , winTitle?, winText?, excludeTitle?, excludeText?)
    path := ""
    for part in [menu ?? "", sub1 ?? "", sub2 ?? "", sub3 ?? "", sub4 ?? "", sub5 ?? "", sub6 ?? ""]
        if (part != "")
            path .= (path = "" ? "" : " > ") _VkTestText(part)
    rec["menu"] := path
    _VkTestLog(rec)
}

ControlClick(controlOrPos?, winTitle?, winText?, whichButton := "Left", clickCount := 1,
    options := "", excludeTitle?, excludeText?) {
    pos := IsSet(controlOrPos) && (controlOrPos is String)
        && RegExMatch(controlOrPos, "i)^\s*x-?\d+\s+y-?\d+\s*$")
    if pos {
        rec := _VkDryTarget("ControlClick", , winTitle?, winText?, excludeTitle?, excludeText?)
        rec["pos"] := Trim(controlOrPos)
    } else {
        rec := _VkDryTarget("ControlClick", controlOrPos?, winTitle?, winText?, excludeTitle?, excludeText?)
    }
    rec["button"] := _VkTestText(whichButton)
    rec["count"] := _VkDryNum(clickCount)
    if (options != "")
        rec["options"] := _VkTestText(options)
    _VkTestLog(rec)
}

; ---- helpers --------------------------------------------------------------

; One keys record; paste-like keys add what the clipboard holds. A paste is
; Ctrl+V with any other modifiers (^v, ^+v -- Chrome's plain-text paste --,
; +^v), {Ctrl down}v, Shift+Insert, or a v sent while an EARLIER call's
; {Ctrl down} is still held (ctrlHeld). {Text}/{Raw} keys type the
; characters literally, so they never paste.
_VkDryKeys(fn, keys) {
    static ctrlHeld := false
    keys := _VkTestText(keys)
    rec := Map("kind", "input", "fn", fn, "keys", keys)
    paste := false
    if !RegExMatch(keys, "i)^\{(Text|Raw)\}") {
        paste := RegExMatch(keys, "i)[+!#<>]*\^[+!#<>]*v|\{[lr]?(ctrl|control) down\}v|\+\{ins(ert)?\}")
            || (ctrlHeld && RegExMatch(keys, "i)^(\{v\}|v)"))
        down := 0, up := 0, pos := 1
        while pos := RegExMatch(keys, "i)\{[lr]?(ctrl|control) down\}", , pos)
            down := pos, pos += 1
        pos := 1
        while pos := RegExMatch(keys, "i)\{[lr]?(ctrl|control) up\}", , pos)
            up := pos, pos += 1
        if (down || up)
            ctrlHeld := down > up
    }
    if paste {
        clip := ""
        try clip := A_Clipboard
        rec["clipboard_len"] := StrLen(clip)
        rec["clipboard"] := SubStr(clip, 1, 200)
    }
    _VkTestLog(rec)
}

; A number stays a number in the record; anything else is its text.
_VkDryNum(v) {
    return (v is Integer) ? v : _VkTestText(v)
}

; The record for a Control* call, after resolving its target the way the
; real call would: a missing control or window throws the real TargetError,
; reported at the macro's line (-2: the replaced built-in's caller).
_VkDryTarget(fn, control?, winTitle?, winText?, excludeTitle?, excludeText?) {
    rec := Map("kind", "input", "fn", fn)
    if IsSet(control)
        rec["control"] := _VkDryWho(control)
    if IsSet(winTitle)
        rec["window"] := _VkDryWho(winTitle)
    try {
        if IsSet(control)
            hwnd := ControlGetHwnd(control, winTitle?, winText?, excludeTitle?, excludeText?)
        else if !(hwnd := WinExist(winTitle?, winText?, excludeTitle?, excludeText?))
            throw TargetError("Target window not found.")
    } catch as e {
        throw (e is TargetError ? TargetError : Error)(e.Message, -2, e.Extra)
    }
    try rec["process"] := WinGetProcessName("ahk_id " hwnd)
    return rec
}

; A control / window argument as text: a Gui object or an hwnd by its hwnd.
_VkDryWho(v) {
    if IsObject(v) {
        try return "ahk_id " v.Hwnd
        return "<" Type(v) ">"
    }
    return (v is Integer) ? "ahk_id " v : _VkTestText(v)
}
