#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Self-test for a hotkey BODY that hits an uncaught error after a key
;  press (lib\_Common.ahk VkBodyErrorNote / VkBodyErrorEnd, the
;  BodySingleInstance hand-off, lib\BodyErrorNotice.ahk) -- the Karbon File
;  feedback, 2026-10-14: AutoHotkey's error dialog held the body open, its
;  mutex held, and every later press was quietly refused.
;
;  Everything runs in a SANDBOX tree in %TEMP%: a copy of lib\_Common.ahk
;  and lib\BodyErrorNotice.ahk (so the bodies' A_LineFile-derived root --
;  errors.log, body-status files, bridge-map.txt -- is the sandbox, never
;  the user's), throwaway bodies with Zz-prefixed names (their own mutexes),
;  and the notice redirected to a file (%VOICEKIT_BODY_NOTICE_OUT%, scoped
;  to the body by %VOICEKIT_BODY_NOTICE_SCRIPT%), so nothing reaches the
;  screen. Every launch is bounded and its tree killed on a timeout.
;  ASCII only.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("body-error-selftest")

sbox := A_Temp "\vk-body-error-selftest"
try DirDelete(sbox, true)
DirCreate(sbox "\hotkeys\bodies")
DirCreate(sbox "\lib")
DirCreate(sbox "\logs")
FileCopy(A_ScriptDir "\..\lib\_Common.ahk", sbox "\lib\_Common.ahk")
FileCopy(A_ScriptDir "\..\lib\BodyErrorNotice.ahk", sbox "\lib\BodyErrorNotice.ahk")
noticeOut := sbox "\notice.txt"
FileAppend("; sandbox bridge map`n"
    . "Ctrl+Alt+Shift+K|karbon probe|hotkeys\ZzCrash.ahk|2026-10-14`n", sbox "\bridge-map.txt", "UTF-8")

head := "#Requires AutoHotkey v2.0`n#SingleInstance Ignore`n"
    . '#Include "%A_ScriptDir%\..\..\lib\_Common.ahk"' "`n"
MakeBody(base, code) {          ; line 4 is BodySingleInstance, the code starts on line 5
    global sbox, head
    FileAppend(head 'BodySingleInstance("' base '")' "`n" code "`n", sbox "\hotkeys\bodies\" base ".body.ahk", "UTF-8")
}
mk(name) => 'A_ScriptDir "\..\..\' name '"'
; A body's own CBT hook that VETOES every #32770 it creates -- but only after
; passing it down the chain first (CallNextHookEx), so _Common's hook still
; sees each one and could end the body on it. Nothing reaches the screen.
VetoSrc(marker) => 'Veto(n, w, l) {`n'
    . '    r := DllCall("CallNextHookEx", "Ptr", 0, "Int", n, "Ptr", w, "Ptr", l, "Ptr")`n'
    . '    if (n = 3) {`n'
    . '        cls := Buffer(64, 0)`n'
    . '        DllCall("GetClassNameW", "Ptr", w, "Ptr", cls, "Int", 32)`n'
    . '        if (StrGet(cls) = "#32770") {`n'
    . '            FileAppend("vetoed ", ' mk(marker) ', "UTF-8")`n'
    . '            return 1`n'
    . '        }`n'
    . '    }`n'
    . '    return r`n}`n'
VetoOn := 'hk := DllCall("SetWindowsHookExW", "Int", 5, "Ptr", CallbackCreate(Veto, "F", 3), "Ptr", 0, "UInt", DllCall("GetCurrentThreadId", "UInt"), "Ptr")'
MakeBody("ZzCrash", 'FileAppend("run``n", ' mk("crash.runs") ', "UTF-8")`n'
    . 'x := 1`n'
    . 'x.NoSuchMethodQq()`n'                       ; line 7
    . 'FileAppend("continued", ' mk("crash.after") ', "UTF-8")`nExitApp(0)')
MakeBody("ZzHandled", 'OnError((e, m) => 1)`nx := 1`nx.NoSuchMethodQq()`nExitApp(0)')
; A handler that shows its OWN MsgBox while it decides (vetoed by its own CBT
; hook, so nothing reaches the screen -- the same fixture as
; engine-module-selftest's ModHandledBox) must not be taken for AutoHotkey's
; error dialog. %ret% = what the handler then returns.
BoxBody(base, ret) {
    global VetoOn
    MakeBody(base, 'OnError(Handler)`n'
        . 'Handler(e, m) {`n'
        . '    ' VetoOn '`n'
        . '    try MsgBox("Could not finish: " e.Message)`n'
        . '    DllCall("UnhookWindowsHookEx", "Ptr", hk)`n'
        . '    FileAppend("survived", ' mk(base ".marker") ', "UTF-8")`n'
        . '    return ' ret '`n}`n'
        . VetoSrc(base ".marker")
        . 'x := 1`nx.NoSuchMethodQq()`nExitApp(0)')
}
BoxBody("ZzHandledBox", 1)
BoxBody("ZzBoxThenCrash", 0)
; A handler that returns -1 CONTINUES the thread (review 2026-10-14: an
; earlier fix left that thread "NoTimers" for good, so the body's own timers
; never ran again, and a later FileSelect -- a comdlg32 #32770 -- was taken
; for the error dialog and ended the body). After carrying on: its timer
; must tick, and a FileSelect + DirSelect of its own must not end it.
MakeBody("ZzContinue", 'OnError((e, m) => (FileAppend("mode=" m " ", ' mk("ZzContinue.marker") ', "UTF-8"), -1))`n'
    . 'global ticks := 0`n'
    . 'SetTimer(Tick, 20)`n'
    . 'Tick() {`n    global ticks`n    ticks += 1`n}`n'
    . 'x := FileRead(A_Temp "\vk-no-such-dir-qq\none.txt")`n'
    . 'deadline := A_TickCount + 3000`n'      ; not a fixed Sleep(400): under a loaded
    . 'while (ticks <= 3 && A_TickCount < deadline)`n'   ; full-suite run that gave 1 tick
    . '    Sleep(20)`n'                       ; (2026-10-14); blocked timers still fail
    . 'FileAppend("ticks=" (ticks > 3 ? "yes" : "no:" ticks) " ", ' mk("ZzContinue.marker") ', "UTF-8")`n'
    . VetoOn '`n'
    . 'try FileSelect()`n'
    . 'try DirSelect()`n'
    . 'DllCall("UnhookWindowsHookEx", "Ptr", hk)`n'
    . 'FileAppend("survived", ' mk("ZzContinue.marker") ', "UTF-8")`n'
    . 'ExitApp(0)`n'
    . VetoSrc("ZzContinue.marker"))
; An uncaught error in a TIMER thread, not the auto-execute one.
MakeBody("ZzTimerCrash", 'SetTimer(Boom, -10)`n'
    . 'Boom() {`n'
    . '    x := 1`n'
    . '    x.NoSuchMethodQq()`n'                     ; line 8
    . '}`n'
    . 'Sleep(4000)`n'
    . 'FileAppend("continued", ' mk("timer.after") ', "UTF-8")`nExitApp(0)')
MakeBody("ZzScope", 'FileAppend("out=[" VkBodyNoticeOut() "] env=[" EnvGet("VOICEKIT_BODY_NOTICE_OUT") "|" EnvGet("VOICEKIT_BODY_NOTICE_SCRIPT") "]", ' mk("scope.marker") ', "UTF-8")`nExitApp(0)')

; Launch a body the way the launcher does (a plain Run), with the notice
; redirect scoped to it (or to `scopeTo`), bounded. -> {code, ms, pid}
; code is the exit code, or "timeout" (the tree was killed) / "nohandle", or
; "dialog": a VISIBLE dialog of the body's -- AutoHotkey's error dialog the
; hook failed to stop -- was killed with its tree at once, so a failing run
; shows it for a poll's length, not the whole bound.
LaunchBody(base, scopeTo := "", ms := 8000) {
    global sbox, noticeOut
    body := sbox "\hotkeys\bodies\" base ".body.ahk"
    EnvSet("VOICEKIT_BODY_NOTICE_SCRIPT", scopeTo != "" ? scopeTo : body)
    EnvSet("VOICEKIT_BODY_NOTICE_OUT", noticeOut)
    pid := 0, t0 := A_TickCount
    try Run('"' A_AhkPath '" "' body '"', sbox, , &pid)
    EnvSet("VOICEKIT_BODY_NOTICE_SCRIPT")
    EnvSet("VOICEKIT_BODY_NOTICE_OUT")
    h := pid ? DllCall("OpenProcess", "uint", 0x101000, "int", 0, "uint", pid, "ptr") : 0
    if !h
        return {code: "nohandle", ms: A_TickCount - t0, pid: pid}
    code := ""
    while (DllCall("WaitForSingleObject", "ptr", h, "uint", 30, "uint") = 258) {   ; WAIT_TIMEOUT
        shown := false
        try for hw in WinGetList("ahk_class #32770 ahk_pid " pid)
            if DllCall("IsWindowVisible", "ptr", hw)
                shown := true
        if (shown || A_TickCount - t0 > ms) {
            RunWait('"' A_WinDir '\System32\taskkill.exe" /T /F /PID ' pid, , "Hide")
            code := shown ? "dialog" : "timeout"
            break
        }
    }
    if (code = "") {
        rc := 0
        DllCall("GetExitCodeProcess", "ptr", h, "uint*", &rc)
        code := rc
    }
    DllCall("CloseHandle", "ptr", h)
    return {code: code, ms: A_TickCount - t0, pid: pid}
}

; The redirected notice: the notice runs in its own process after the body
; is gone, so wait (bounded) for its text to land.
ReadNotice(waitMs := 6000) {
    global noticeOut
    t0 := A_TickCount, txt := ""
    loop {
        try txt := FileRead(noticeOut, "UTF-8")
        if (txt != "" || A_TickCount - t0 > waitMs)
            break
        Sleep(100)
    }
    try FileDelete(noticeOut)
    return txt
}
ReadSbox(name) {
    global sbox
    t := ""
    try t := FileRead(sbox "\" name, "UTF-8")
    return t
}
NoticeProcs() {
    global sbox
    n := 0
    for p in ComObjGet("winmgmts:").ExecQuery("Select CommandLine from Win32_Process where Name = 'AutoHotkey64.exe'")
        if InStr(p.CommandLine, "BodyErrorNotice.ahk") && InStr(p.CommandLine, sbox)
            n += 1
    return n
}

; ---------- 1. a pressed body with an uncaught error ends ------------------
r := LaunchBody("ZzCrash")
Check("an uncaught error ends the body (exit 3, no dialog holding it open)", r.code = 3, "code=" r.code)
Check("...within a few seconds", r.ms < 8000, r.ms " ms")
Check("...nothing after the error ran", ReadSbox("crash.after") = "")
Check("...and its mutex is released", !BodyMutexHeld("ZzCrash"))
elog := ReadSbox("logs\errors.log")
Check("errors.log got its line, as before", InStr(elog, "ZzCrash.body.ahk") && InStr(elog, "NoSuchMethodQq"), elog)
st := BodyStatusRead("ZzCrash", sbox)
Check("a final status line says it stopped with an error, and where",
    IsObject(st) && InStr(st.text, "Stopped by an error at line 7 of ZzCrash.body.ahk - ") = 1
        && InStr(st.text, "errors.log"),
    IsObject(st) ? st.text : "no status")
nt := ReadNotice()
Check("the timed notice was requested", nt != "")
Check("...titled with the module's phrase", InStr(nt, "VoiceKit: karbon probe stopped`n") = 1, SubStr(nt, 1, 60))
Check("...naming its key", InStr(nt, "'karbon probe' (Ctrl+Alt+Shift+K) stopped because of an error"), nt)
Check("...the error and its line", InStr(nt, "NoSuchMethodQq") && InStr(nt, "Line 7 of ZzCrash.body.ahk"), nt)
Check("...pointing at errors.log and saying a press retries",
    InStr(nt, "logs\errors.log") && InStr(nt, "Press Ctrl+Alt+Shift+K again"), nt)
Check("...and that it closes itself", InStr(nt, "closes itself in 30 seconds"), nt)
left := ""
Loop Files A_Temp "\voicekit-body-error-" r.pid "-*.txt"
    left .= A_LoopFileName " "
Check("the notice consumed its text file", left = "", left)
Sleep(300)
Check("...and the notice process is gone", NoticeProcs() = 0)

; ---------- 2. the next press runs ------------------------------------------
r2 := LaunchBody("ZzCrash")
runs := StrSplit(Trim(ReadSbox("crash.runs"), "`n"), "`n")
Check("a second press runs the body again (not refused)", runs.Length = 2 && r2.code = 3,
    "runs=" runs.Length " code=" r2.code)
Check("...and gets its own notice", InStr(ReadNotice(), "NoSuchMethodQq"))

; ---------- 3. the body's own handlers still decide --------------------------
BodyStatusClear("ZzHandled", sbox)
r := LaunchBody("ZzHandled")
Check("an error the body's own OnError handles: exit 0", r.code = 0, "code=" r.code)
Check("...no notice", ReadNotice(1500) = "")
Check("...no stopped status", BodyStatusRead("ZzHandled", sbox) = "")

r := LaunchBody("ZzHandledBox")
Check("a handler showing its OWN MsgBox, then handling the error: exit 0", r.code = 0, "code=" r.code)
Check("...its MsgBox was created (vetoed by itself) and the handler finished",
    ReadSbox("ZzHandledBox.marker") = "vetoed survived", ReadSbox("ZzHandledBox.marker"))
Check("...no notice", ReadNotice(1500) = "")

r := LaunchBody("ZzBoxThenCrash")
Check("a handler showing its own MsgBox, then NOT handling it: exit 3", r.code = 3, "code=" r.code)
Check("...its MsgBox wasn't mistaken for the error dialog (the handler finished first)",
    ReadSbox("ZzBoxThenCrash.marker") = "vetoed survived", ReadSbox("ZzBoxThenCrash.marker"))
Check("...and the notice came after it", InStr(ReadNotice(), "NoSuchMethodQq"))

BodyStatusClear("ZzContinue", sbox)
r := LaunchBody("ZzContinue")
Check("a handler returning -1 (carry on): the body runs to its end, exit 0", r.code = 0, "code=" r.code)
Check("...its own timers keep running, and its FileSelect / DirSelect don't end it",
    ReadSbox("ZzContinue.marker") = "mode=Return ticks=yes vetoed vetoed survived", ReadSbox("ZzContinue.marker"))
Check("...no notice", ReadNotice(1500) = "")
Check("...no stopped status", BodyStatusRead("ZzContinue", sbox) = "")

r := LaunchBody("ZzTimerCrash")
Check("an uncaught error in a timer thread ends the body too (exit 3)", r.code = 3, "code=" r.code)
Check("...before the rest of the body ran", ReadSbox("timer.after") = "")
st := BodyStatusRead("ZzTimerCrash", sbox)
Check("...with its status line", IsObject(st) && InStr(st.text, "Stopped by an error at line 8 of ZzTimerCrash.body.ahk") = 1,
    IsObject(st) ? st.text : "no status")
Check("...and its notice", InStr(ReadNotice(), "Line 8 of ZzTimerCrash.body.ahk"))

; ---------- 4. the redirect is scoped and never inherited --------------------
r := LaunchBody("ZzScope")
Check("the redirect applies to the body it names, and leaves its environment",
    ReadSbox("scope.marker") = "out=[" noticeOut "] env=[|]", ReadSbox("scope.marker"))
FileDelete(sbox "\scope.marker")
r := LaunchBody("ZzScope", sbox "\hotkeys\bodies\SomeOther.body.ahk")
Check("...and not to any other script", ReadSbox("scope.marker") = "out=[] env=[|]", ReadSbox("scope.marker"))

; ---------- 5. outside a body nothing changes --------------------------------
Check("a script that never called BodySingleInstance is no body", VkBodyBase() = "")

try DirDelete(sbox, true)
TestEnd()
