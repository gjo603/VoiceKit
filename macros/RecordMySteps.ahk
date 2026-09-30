#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Record My Steps — jump straight into recording a workflow.
;  Trigger by voice:  "open record my steps"
;  (or its companion hotkey — see bridge-map.txt)
;
;  Launches Workflow Studio already recording (its /record
;  argument), so one phrase / one key press takes you from
;  "I want to automate this" to the floating REC bar.
;
;  Studio-safety: WorkflowStudio.ahk is #SingleInstance Force, so
;  a raw relaunch would silently kill an open session and any
;  unsaved recorded steps. If a Studio window exists we act on it
;  instead: visible -> activate it and press its Record key (F9;
;  its own append-confirm guard protects loaded steps); hidden
;  (recording or mid-test) -> just say so, never relaunch.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"

; StudioWindow (lib\_Common.ahk) sees a hidden Studio too — the same check
; New Automation and the home window use before they open one.
studio := StudioWindow()
if (studio.hwnd && !studio.visible) {
    TrayTip("Workflow Studio is busy (recording or testing). Stop with Ctrl+Alt+Shift+X first.", "VoiceKit")
    ExitApp()
}
if studio.hwnd {
    WinActivate("ahk_id " studio.hwnd)
    if WinWaitActive("ahk_id " studio.hwnd, , 2) {
        SendLevel(1)             ; F9 is a hook hotkey in the Studio — let it hear this
        Send("{F9}")
    }
    ExitApp()
}

OpenStudioSafely(RegExReplace(A_ScriptDir, "\\[^\\]+$"), "/record")   ; parent of \macros
