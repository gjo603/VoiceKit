#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  LoopRunner.ahk — entry point for "loop <name>" shortcuts.
;  Runs a saved workflow's steps repeatedly until stopped.
;
;  A "loop <name>" Start Menu shortcut launches this as:
;      AutoHotkey64.exe "lib\LoopRunner.ahk" "<Base>"
;  where <Base> is the workflow's file base (e.g. MorningTabs).
;  Voice: "open loop <name>".
;
;  Stop: the floating "Stop Looping" button (voice: "click stop
;  looping") or Ctrl+Alt+Shift+X.
;
;  #SingleInstance Force means only one loop runs at a time —
;  starting another "loop <name>" replaces the current one.
; ============================================================
; WorkflowLoop.ahk pulls in Workflow.ahk (+ Acc.ahk) and Theme.ahk itself,
; so this is the only include needed — adding the others would double-define.
#Include "%A_LineFile%\..\WorkflowLoop.ahk"

base := A_Args.Length >= 1 ? A_Args[1] : ""
if (base = "") {
    MsgBox("No workflow was specified to loop.", "VoiceKit loop", "Iconx 262144")
    ExitApp()
}
RunWorkflowLoop(A_ScriptDir "\..\workflows\" base ".steps.txt", SpaceOut(base))
ExitApp()

; "MorningTabs" -> "Morning Tabs" for the status bar (matches the spoken phrase).
SpaceOut(camel) {
    return Trim(RegExReplace(camel, "([a-z0-9])([A-Z])", "$1 $2"))
}
