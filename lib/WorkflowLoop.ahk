#Requires AutoHotkey v2.0
; ============================================================
;  WorkflowLoop.ahk — run a saved workflow's steps over and over
;  until the user stops it. Powers the "loop <name>" shortcuts.
;
;  Self-contained: it pulls in its own dependencies so it loads
;  cleanly on its own as well as via LoopRunner.ahk —
;    Workflow.ahk -> WorkflowLoad, RunWorkflowSteps (and Acc.ahk)
;    Theme.ahk    -> ThemeBar, ShowBottomLeft
;  (%A_LineFile% resolves relative to THIS file, so it works no
;  matter which script includes it. Do not also #Include these
;  from the host, or AHK will report duplicate definitions.)
;
;  Stop while looping: the floating "Stop Looping" button
;  (voice: "click stop looping") or Ctrl+Alt+Shift+X. A loop also
;  stops on its own if a step fails (so a broken workflow can't spin).
; ============================================================
#Include "%A_LineFile%\..\Workflow.ahk"
#Include "%A_LineFile%\..\Theme.ahk"

global wfLoopStop := false

; Run stepsFile top-to-bottom repeatedly, pausing delayMs between passes,
; until stopped or a step fails. Shows a small always-on-top status bar.
RunWorkflowLoop(stepsFile, phrase, delayMs := 1500) {
    global wfLoopStop
    wfLoopStop := false

    if !FileExist(stepsFile) {
        MsgBox("Workflow file not found:`n" stepsFile, "VoiceKit loop", "Iconx 262144")   ; 262144 = always-on-top
        return
    }
    steps := WorkflowLoad(stepsFile)
    if !steps.Length {
        MsgBox("This workflow has no steps to loop.", "VoiceKit loop", "Icon! 262144")
        return
    }

    ; ---- floating status bar (bottom-left, clear of the taskbar) ----
    bar := Gui("+AlwaysOnTop +ToolWindow -Caption +Border")
    bar.MarginX := 14, bar.MarginY := 11
    bar.SetFont("s10 bold", "Segoe UI")
    bar.AddText("ym", "Looping")
    bar.SetFont("s10 norm", "Segoe UI")
    barNote := bar.AddText("x+12 yp w280", phrase)
    barCount := bar.AddText("x+8 yp w80 Right", "run 0")
    bar.SetFont("s11 bold", "Segoe UI")
    barBtn := bar.AddButton("x+12 yp-8 w160 h36 Default", "■  Stop Looping")
    bar.SetFont("s10 norm", "Segoe UI")
    barBtn.OnEvent("Click", (*) => WfLoopRequestStop())
    ThemeBar(bar, barNote, barCount, barBtn)
    ShowBottomLeft(bar)

    i := 0
    loop {
        if wfLoopStop
            break
        i += 1
        barCount.Text := "run " i
        if !RunWorkflowSteps(steps)        ; a failing step already showed its popup — don't keep spinning
            break
        WfLoopSleep(delayMs)               ; interruptible pause; also returns at once if stop was requested
    }
    bar.Destroy()
}

; Ask the running loop to stop after the current pass.
WfLoopRequestStop() {
    global wfLoopStop
    wfLoopStop := true
}

; Sleep in small slices so a Stop click/hotkey during the pause is honored promptly.
WfLoopSleep(ms) {
    global wfLoopStop
    left := ms
    while (left > 0 && !wfLoopStop) {
        Sleep(100)
        left -= 100
    }
}

; Backup stop hotkey — the voice-clickable "Stop Looping" button is primary.
^!+x:: WfLoopRequestStop()
