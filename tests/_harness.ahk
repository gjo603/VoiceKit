#Requires AutoHotkey v2.0
; ============================================================
;  Shared plumbing for the tests\*-selftest.ahk suites.
;
;  Named so the runner never executes it (it runs *-selftest.ahk
;  and skips *-target.ahk). ASCII only, like the runner.
;
;  A suite does:
;      #Include "%A_ScriptDir%\_harness.ahk"
;      TestBegin("uia-selftest")            ; res + fails, old result gone
;      Check("thing works", cond, detail)
;      Say("about to: the risky call")      ; hang diagnostic
;      TestEnd()                            ; footer + ExitApp(0)
;
;  The runner's contract (see Run-Tests.ps1): PASS/FAIL lines in
;  <name>.result beside the suite, ending ALL PASSED / N FAILURE(S).
;  The result file is the verdict, never the process exit.
;
;  Globals it owns: res (the result file) and fails (the count).
; ============================================================

; Start a suite: name is the suite's file base ("uia-selftest"); the result,
; state and stop files all derive from it.
TestBegin(name) {
    global res, fails, testName
    testName := name
    res := A_ScriptDir "\" name ".result"
    try FileDelete(res)
    fails := 0
}

; Append raw text to the result file. RETRIED: a transient reader of the
; result file (the runner's poll, an indexer, AV) makes FileAppend throw a
; sharing violation, and an unhandled throw pops a dialog that wedges the
; suite into a phantom 120 s timeout blamed on an innocent test.
; open/write/close per call = flushed on the spot, so a hang still leaves
; every line written before it.
Emit(text) {
    global res
    loop 20 {
        try {
            FileAppend(text, res, "UTF-8")
            return
        }
        Sleep(50)
    }
}

; One line (Emit plus the newline).
Say(text) {
    Emit(text "`n")
}

; One check: PASS/FAIL line, detail in brackets, folded onto one line so a
; multi-line detail can't read as extra result lines.
Check(name, cond, detail := "") {
    global fails
    if !cond
        fails += 1
    detail := StrReplace(StrReplace(detail, "`r", " "), "`n", " ")
    Say((cond ? "PASS  " : "FAIL  ") name (detail != "" ? "   [" detail "]" : ""))
}

; The footer the runner waits for, then exit.
TestEnd() {
    global fails
    Say(fails ? "`n" fails " FAILURE(S)" : "`nALL PASSED")
    ExitApp(0)
}

; ---- separate target processes (see _target.ahk) ------------------------

; Launch tests\<script> (a *-target.ahk helper) and wait for ITS window.
; Pinned to the PID this Run just returned, never a bare title: a leftover
; target from an earlier run can donate its window to a bare WinWait for the
; instant before the fresh target's #SingleInstance Force kills it, leaving
; the hwnd pointing at a window that dies mid-test (measured: 5 of 6 rapid
; re-runs). Returns the hwnd, or 0 after writing the FAIL line (the caller
; then exits). settleMs lets the target finish drawing before it is driven.
TargetLaunch(script, title, &tpid := 0, timeoutS := 10, settleMs := 800) {
    Run('"' A_AhkPath '" "' A_ScriptDir '\' script '"', , , &tpid)
    if !WinWait(title " ahk_pid " tpid, , timeoutS) {
        Say("FAIL  target window never appeared")
        return 0
    }
    hwnd := WinExist(title " ahk_pid " tpid)
    Sleep(settleMs)
    return hwnd
}

; What the target says about itself (key=value lines in <suite>.state).
; RETRIES: the target republishes by deleting and rewriting, so a read can
; land in the gap and see nothing -- without this an "is it different?"
; check passes on an empty read, which is passing for the wrong reason.
; Pass want to wait (up to timeoutMs) for that value: the state file is a
; 250 ms-old snapshot, so reading it straight after an action can catch the
; target mid-change (measured: 'hello world' read back while typing
; 'hello world search' had already finished). Returns the last value seen, so
; a value that never arrives still fails the caller's comparison.
TargetState(key, want?, timeoutMs := 2000) {
    global testName
    val := "", start := A_TickCount
    loop {
        loop 20 {
            txt := ""
            try txt := FileRead(A_ScriptDir "\" testName ".state", "UTF-8")
            if RegExMatch(txt, "m)^" key "=(.+)$", &m) {
                val := Trim(m[1], " `t`r`n")
                break
            }
            Sleep(100)
        }
        if !IsSet(want) || val = want || A_TickCount - start >= timeoutMs
            return val
        Sleep(100)
    }
}

; Ask the target to close (it polls for <suite>.stop).
TargetStop() {
    global testName
    try FileAppend("stop", A_ScriptDir "\" testName ".stop", "UTF-8")
}
