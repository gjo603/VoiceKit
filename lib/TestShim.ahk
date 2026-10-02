#Requires AutoHotkey v2.0
; ============================================================
;  lib\TestShim.ahk -- the quiet-test shim (2026-10-01)
;
;  NEVER #Included. The MCP's run_automation(test=True) loads it
;  AHEAD of a macro with AutoHotkey's /include switch:
;      AutoHotkey64.exe /ErrorStdOut=UTF-8 /include TestShim.ahk Macro.ahk args...
;  Functions defined here REPLACE the built-ins of the same name for
;  the whole script -- the macro and everything it #Includes, the
;  workflow engine's popups among them (measured: a shim MsgBox
;  answered MsgBox(..., "YesNo") with no dialog). A_Args, A_ScriptDir
;  and A_ScriptName stay the macro's own.
;
;  What a test run must not show is written instead, one JSON object
;  per line, to the file named by the VOICEKIT_TEST_LOG environment
;  variable (none set: nothing is written, nothing is shown):
;      {"kind":"MsgBox","title":..,"text":..,"options":..,"returned":"Yes"}
;  kinds: MsgBox, TrayTip, ToolTip, InputBox, FileSelect, DirSelect,
;  and "error" for an uncaught error (then the script exits with 3).
;  What each call returns:
;    MsgBox     the DEFAULT button of its button set -- what pressing
;               Enter would answer (measured on a private desktop,
;               DM_GETDEFID + BM_CLICK, 2026-10-01: names, abbreviations
;               (YN, O/C, Y/N/C) and numbers (4, 0x104, "1 256 16") all
;               parse; Default2/3/256/512 pick the 2nd/3rd button; a
;               DefaultN past the last button means the FIRST one)
;    InputBox   CANCELLED, not Enter: {Result: "Cancel", Value: ""} -- a
;               plain Object with exactly those two own properties, like
;               the real one (measured: Type() "Object", base
;               Object.Prototype). A test supplies its values through
;               A_Args, never by typing; a cancel takes the macro's
;               "nothing entered" branch instead of acting on a guess.
;    FileSelect cancelled: "" (an empty Array with the M option -- measured)
;    DirSelect  cancelled: ""
;    ToolTip    a real window handle, like the real one (measured: the
;               tooltip's HWND, the same one per ToolTip number, and 0
;               when hiding, which destroys it) -- a zero-size, fully
;               transparent stand-in, so "ahk_id " hwnd finds it and
;               WinMove / WinSetTransparent on it work as they do on a
;               voice run. (It returned 0 until review: such a macro
;               failed its test with "Target window not found".)
;    TrayTip    ""
;  (A ToolTip/TrayTip call that only HIDES one is not logged.)
;  Gui windows are NOT covered (a custom dialog is the macro's own
;  window; replacing Gui would change what the macro is), nor is
;  anything the macro Run()s in another process.
;
;  Uncaught errors: the macro's OWN OnError handlers run first, exactly
;  as on a voice run -- one that returns 1/-1 has handled the error and
;  the run goes on. Only an error still uncaught at the end (the moment
;  AutoHotkey would show its error dialog) is logged and ends the run
;  with exit code 3, on the spot: a CBT hook on this thread catches that
;  dialog as it is CREATED (before it can show), writes the record the
;  first OnError callback noted, and calls ExitProcess(3). Measured
;  2026-10-01: an OnError callback can't be moved behind handlers
;  registered later (the chain is fixed when the error is raised), and
;  ExitApp from a handler is vetoed by an OnExit callback that returns
;  true, after which the dialog appeared anyway. So the macro's OnExit
;  callbacks do NOT run after an uncaught error in a test run.
;
;  #Warn: AutoHotkey shows a warning DIALOG at load even with no #Warn
;  directive at all (measured: unreachable code, a never-assigned
;  variable -- the two warnings that are on by default), and
;  /ErrorStdOut doesn't cover warnings. The directives below apply to
;  the whole script, so those two go to stdout instead (run_automation
;  lifts them out as `warnings`); LocalSameAsGlobal stays off, as by
;  default ("All" would flood stdout from lib\_Common.ahk's locals
;  named like a macro's globals -- measured). A #Warn line in the MACRO
;  overrides these and pops its dialog before any code runs
;  (measured), which is why run_automation refuses a test run of a
;  macro carrying one.
;
;  Names: every helper is _VkTest*, so nothing here can collide with
;  lib\_Common.ahk / Theme / UIA / Browser / Workflow or a macro's own
;  code (one case-insensitive namespace for functions and variables).
;  No top-level variables at all. ASCII only.
; ============================================================
#Warn VarUnset, StdOut
#Warn Unreachable, StdOut

; Uncaught errors (see the header). The shim's callback is FIRST in the
; chain (it registers before any of the macro's code runs) and only NOTES
; the error; the macro's handlers and lib\_Common.ahk's LogUncaughtError
; (which stays out of the user's errors.log in a test run) come after it.
; If none of them handles it, AutoHotkey creates its error dialog -- and
; the hook below ends the run before that dialog exists.
OnError(_VkTestOnError, -1)
_VkTestHook()

_VkTestOnError(err, mode) {
    rec := Map("kind", "error", "type", Type(err), "mode", mode)
    if (err is Error) {
        try rec["message"] := err.Message
        try rec["extra"] := err.Extra
        try rec["file"] := err.File
        try rec["line"] := err.Line
        try rec["what"] := err.What
        try rec["stack"] := SubStr(err.Stack, 1, 2000)
    } else {
        msg := ""
        try msg := String(err)
        rec["message"] := msg
    }
    if !_VkTestHook() {
        ; No hook (SetWindowsHookEx refused): the old way, which can't let
        ; the macro's own handlers run first -- but never shows the dialog.
        _VkTestLog(rec)
        DllCall("kernel32\ExitProcess", "UInt", 3)
    }
    _VkTestPending("set", rec)
    ; Handled after all (a later callback returned 1/-1): the run goes on,
    ; and the note is dropped once this thread lets a timer run.
    SetTimer(_VkTestClearPending, -1)
    return 0
}

_VkTestClearPending() {
    _VkTestPending("clear")
}

; The error the OnError chain is deciding about ("" when none).
_VkTestPending(action := "get", rec := "") {
    static held := ""
    if (action = "set")
        held := rec
    else if (action = "clear")
        held := ""
    return held
}

; A WH_CBT hook on this (the script's only) thread, installed once at load;
; returns its handle, 0 when Windows refused one.
_VkTestHook() {
    static hook := -1
    if (hook = -1) {
        hook := 0
        try hook := DllCall("SetWindowsHookExW", "Int", 5, "Ptr", CallbackCreate(_VkTestCbt, "F", 3),
            "Ptr", 0, "UInt", DllCall("GetCurrentThreadId", "UInt"), "Ptr")
    }
    return hook
}

; HCBT_CREATEWND (3) of a #32770 while an error is pending is AutoHotkey's
; error dialog being created: record the error and end the process before
; the dialog exists (measured: nothing reaches the screen, exit code 3).
; Every other window -- the macro's Guis, the ToolTip stand-ins -- passes.
; A dialog the macro shows itself is never a #32770 here: MsgBox, InputBox
; and the pickers are the stand-ins above.
_VkTestCbt(nCode, wParam, lParam) {
    if (nCode = 3) {
        rec := _VkTestPending()
        if IsObject(rec) {
            cls := Buffer(64, 0)
            DllCall("GetClassNameW", "Ptr", wParam, "Ptr", cls, "Int", 32)
            if (StrGet(cls) = "#32770") {
                _VkTestLog(rec)
                DllCall("kernel32\ExitProcess", "UInt", 3)
            }
        }
    }
    return DllCall("CallNextHookEx", "Ptr", 0, "Int", nCode, "Ptr", wParam, "Ptr", lParam, "Ptr")
}

; ---- the overrides -------------------------------------------------------

MsgBox(text?, title?, options := "") {
    shown := IsSet(text) ? _VkTestText(text) : "Press OK to continue."
    answer := _VkTestMsgBoxDefault(options)
    _VkTestLog(Map("kind", "MsgBox", "title", IsSet(title) ? _VkTestText(title) : A_ScriptName,
        "text", shown, "options", _VkTestText(options), "returned", answer))
    return answer
}

InputBox(prompt := "", title?, options := "", defaultText := "") {
    _VkTestLog(Map("kind", "InputBox", "title", IsSet(title) ? _VkTestText(title) : A_ScriptName,
        "text", _VkTestText(prompt), "options", _VkTestText(options),
        "default", _VkTestText(defaultText), "returned", "Cancel"))
    return {Result: "Cancel", Value: ""}
}

TrayTip(text := "", title := "", options := "") {
    if (_VkTestText(text) != "" || _VkTestText(title) != "")
        _VkTestLog(Map("kind", "TrayTip", "title", _VkTestText(title), "text", _VkTestText(text),
            "options", _VkTestText(options)))
    return ""
}

ToolTip(text := "", posX := "", posY := "", which := 1) {
    if (_VkTestText(text) = "")
        return _VkTestTipWindow(which, false)
    _VkTestLog(Map("kind", "ToolTip", "title", "", "text", _VkTestText(text),
        "options", "x=" _VkTestText(posX) " y=" _VkTestText(posY) " n=" _VkTestText(which)))
    return _VkTestTipWindow(which, true, posX, posY)
}

FileSelect(options := "", rootDir := "", title := "", filter := "") {
    multi := InStr(_VkTestText(options), "M") > 0
    _VkTestLog(Map("kind", "FileSelect", "title", _VkTestText(title), "text", _VkTestText(rootDir),
        "options", _VkTestText(options) (filter != "" ? " filter=" _VkTestText(filter) : ""),
        "returned", "Cancel"))
    return multi ? [] : ""
}

DirSelect(startingFolder := "", options := "", prompt := "") {
    _VkTestLog(Map("kind", "DirSelect", "title", "", "text", _VkTestText(prompt),
        "options", _VkTestText(options) " start=" _VkTestText(startingFolder),
        "returned", "Cancel"))
    return ""
}

; ---- helpers --------------------------------------------------------------

; ToolTip's stand-in window for tooltip number `which`: created on first
; show and reused (as the real one is), destroyed on hide -> 0. A real
; tooltips_class32 popup, visible to WinExist("ahk_id ..") but zero-size,
; layered at alpha 0 and click-through, so nothing appears on screen.
; Not a Gui: a visible Gui would keep the script running (persistent).
_VkTestTipWindow(which, show, x := "", y := "") {
    static wins := Map()
    if !show {
        if wins.Has(which) {
            try DllCall("DestroyWindow", "Ptr", wins[which])
            wins.Delete(which)
        }
        return 0
    }
    if wins.Has(which) && DllCall("IsWindow", "Ptr", wins[which])
        return wins[which]
    ; WS_EX_TOPMOST|TRANSPARENT|TOOLWINDOW|LAYERED|NOACTIVATE, WS_POPUP|WS_VISIBLE
    h := DllCall("CreateWindowExW", "UInt", 0x080800A8, "Str", "tooltips_class32", "Ptr", 0,
        "UInt", 0x90000000, "Int", IsNumber(x) ? Integer(x) : 0, "Int", IsNumber(y) ? Integer(y) : 0,
        "Int", 0, "Int", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr")
    if !h
        return 0
    DllCall("SetLayeredWindowAttributes", "Ptr", h, "UInt", 0, "UChar", 0, "UInt", 2)
    wins[which] := h
    return h
}

; The button a user pressing Enter gets (see the measured table above).
_VkTestMsgBoxDefault(options) {
    static sets := [["OK"], ["OK", "Cancel"], ["Abort", "Retry", "Ignore"],
        ["Yes", "No", "Cancel"], ["Yes", "No"], ["Retry", "Cancel"],
        ["Cancel", "TryAgain", "Continue"]]
    static names := Map("ok", 0, "okcancel", 1, "o/c", 1, "oc", 1,
        "abortretryignore", 2, "a/r/i", 2, "ari", 2,
        "yesnocancel", 3, "y/n/c", 3, "ync", 3,
        "yesno", 4, "y/n", 4, "yn", 4,
        "retrycancel", 5, "r/c", 5, "rc", 5,
        "canceltryagaincontinue", 6, "canceltrycontinue", 6, "c/t/c", 6, "ctc", 6)
    num := 0, btnSet := -1, defIdx := 0
    for tok in StrSplit(RegExReplace(Trim(_VkTestText(options)), "\s+", " "), " ") {
        low := StrLower(tok)
        if (low = "")
            continue
        if RegExMatch(low, "^(0x[0-9a-f]+|\d+)$")
            num |= Integer(low)
        else if names.Has(low)
            btnSet := names[low]
        else if RegExMatch(low, "^default(\d)$", &m)
            defIdx := Integer(m[1])
    }
    if (btnSet < 0)
        btnSet := num & 0xF
    if !defIdx
        defIdx := ((num >> 8) & 0xF) + 1
    buttons := (btnSet >= 0 && btnSet < sets.Length) ? sets[btnSet + 1] : sets[1]
    return (defIdx >= 1 && defIdx <= buttons.Length) ? buttons[defIdx] : buttons[1]
}

; Anything as text: what the real call would have displayed.
_VkTestText(v) {
    try return String(v)
    return "<" Type(v) ">"
}

; One record, one line -- JSON, so a newline in a message can't split it.
_VkTestLog(rec) {
    path := EnvGet("VOICEKIT_TEST_LOG")
    if (path = "")
        return
    line := "{"
    for k, v in rec
        line .= (A_Index > 1 ? "," : "") _VkTestJson(k) ":"
            . ((v is Integer) ? String(v) : _VkTestJson(_VkTestText(v)))
    line .= "}`n"
    ; Retried: a reader holding the file for an instant (the MCP polling it,
    ; an indexer, AV) makes FileAppend throw a sharing violation -- and an
    ; uncaught throw from HERE would be exactly the dialog this file exists
    ; to prevent.
    loop 20 {
        try {
            FileAppend(line, path, "UTF-8-RAW")
            return
        }
        Sleep(25)
    }
}

_VkTestJson(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    while RegExMatch(s, "[\x01-\x1F]", &m)
        s := StrReplace(s, m[0], Format("\u{:04X}", Ord(m[0])))
    return '"' s '"'
}
