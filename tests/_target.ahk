#Requires AutoHotkey v2.0
; ============================================================
;  Shared plumbing for the tests\*-target.ahk helpers: the
;  separate processes a suite drives (UIA against your OWN
;  process deadlocks, so the window under test lives elsewhere).
;
;  Named so the runner never executes it. ASCII only.
;
;  A target does (keeping its own #SingleInstance Force):
;      #Include "%A_ScriptDir%\_target.ahk"
;      ... build the Gui ...
;      TargetServe("uia-selftest", () => "clicks=" clicks "`n", g)
;
;  TargetServe publishes stateFn()'s key=value lines to
;  <suite>.state every 250 ms (delete + rewrite -- the suite's
;  TargetState retries across the gap), closes when the suite
;  drops <suite>.stop, and exits on its own after 120 s so a
;  target can never outlive the test run.
; ============================================================

TargetServe(suite, stateFn, g := "") {
    state := A_ScriptDir "\" suite ".state"
    stop  := A_ScriptDir "\" suite ".stop"
    try FileDelete(stop)             ; a leftover from an earlier run is not a request
    Publish() {
        try FileDelete(state)
        try FileAppend(stateFn(), state, "UTF-8")
        if FileExist(stop) {
            if IsObject(g)
                try g.Destroy()
            ExitApp(0)
        }
    }
    Publish()
    SetTimer(Publish, 250)
    SetTimer(() => ExitApp(0), -120000)      ; never outlive the test run
}
