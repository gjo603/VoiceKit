#Requires AutoHotkey v2.0
; Conformance harness: make the REAL engine run and fail, writing its run
; record and log into a temp folder, so the Python conformance test can prove
; it reads back what AutoHotkey actually wrote.
;
; This is the AHK-writes / Python-reads seam, and it has broken before —
; IniWrite creates the file as UTF-16LE with a BOM, which nothing but a real
; round trip catches.
;
; Usage:  AutoHotkey64.exe runrecord.ahk <outDir> <runName>
#Include "%A_ScriptDir%\..\..\lib\Workflow.ahk"

if (A_Args.Length < 2)
    ExitApp(2)

wfLogFolder := A_Args[1]                     ; never the user's real logs\ folder
wfRunName := A_Args[2]
wfRunQuiet := true                        ; headless: record the failure, no modal
wfTrayOff := true                         ; ...and no toast: on an idle desktop one outlives
                                          ; this process and steals the next test's foreground

; Step 2 fails immediately (unknown condition) — no window waits, so the
; harness stays fast and needs nothing on screen.
RunWorkflowSteps([["text", "", "", ""]
    , ["if", "ahk_id 1", "", "notacondition"]
    , ["text", "never runs", "", ""]])
WfRunRecordUpdate(Map("passes_done", 2, "passes_total", 5))   ; as the loop adds them

; Second section: a LOOP record followed by a plain run of the same workflow.
; The plain run's record must replace the loop's whole — no passes_* or
; loop_started* left behind for the reader to report as this run's.
wfRunName := A_Args[2] "Stale"
RunWorkflowSteps([["text", "", "", ""]])
WfRunRecordUpdate(Map("passes_done", 4, "passes_total", 9, "collected_rows", 4
    , "loop_started", "20010101000000", "loop_started_text", "2001-01-01 00:00:00"))
RunWorkflowSteps([["text", "", "", ""]])
ExitApp(0)

