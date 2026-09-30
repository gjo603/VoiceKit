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
;  A second argument makes it a HEADLESS BATCH (the MCP add-on's
;  run_workflow_batch): "<Base>" "<batch.csv>" — the CSV's rows are
;  the inputs, one pass per row, no chooser dialog.
;
;  Stop: the floating "Stop Looping" button (voice: "click stop
;  looping") or Ctrl+Alt+Shift+X.
;
;  EXIT CODE says how it went, so a programmatic caller isn't
;  reduced to guessing (this used to exit 0 unconditionally, and
;  a batch that died at step 7 reported "finished cleanly"):
;      0  ok         every planned pass finished
;      1  failed     a step failed — see logs\workflow-runs.ini
;      2  stopped    the user stopped it, or cancelled a dialog
;      3  error      it never got as far as running (bad file/batch)
;  The full story is in logs\workflow-runs.ini under the
;  workflow's name, with a step-by-step trace in
;  logs\workflow-runs.log.
;
;  #SingleInstance Force means only one loop runs at a time —
;  starting another "loop <name>" replaces the current one.
; ============================================================
; _Common.ahk first: it registers the uncaught-error logger (logs\errors.log)
; during its include, and loops / headless MCP batches are exactly the long
; unattended runs where that log matters. It also supplies SpaceOut.
; WorkflowLoop.ahk pulls in Workflow.ahk (+ Acc.ahk) and Theme.ahk itself —
; adding those again would double-define.
#Include "%A_LineFile%\..\_Common.ahk"
#Include "%A_LineFile%\..\WorkflowLoop.ahk"

base := A_Args.Length >= 1 ? A_Args[1] : ""
batch := A_Args.Length >= 2 ? A_Args[2] : ""
if (base = "") {
    MsgBox("No workflow was specified to loop.", "VoiceKit loop", "Iconx 262144")
    ExitApp()
}
outcome := RunWorkflowLoop(A_ScriptDir "\..\workflows\" base ".steps.txt", SpaceOut(base), , batch)
ExitApp(LoopExitCode(outcome))

; Outcome string -> exit code (see the header).
LoopExitCode(outcome) {
    switch outcome {
        case "ok":                    return 0
        case "failed":                return 1
        case "stopped", "cancelled":  return 2
    }
    return 3
}
