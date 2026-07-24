#Requires AutoHotkey v2.0
; ============================================================
;  Hotkey for "open record my steps"   (created 2026-07-23)
;  Loaded by VoiceKit.ahk — do not run this file directly.
;
;  Trigger key:  Ctrl+Alt+Shift+W
;  Runs:  macros\RecordMySteps.ahk — the same automation as saying
;  "open record my steps".
;
;  Companion hotkey, managed in Voice Kit (say "open voice kit",
;  select the automation, click Hotkey). No Voice Access pairing
;  needed — this key is for when you can't use your voice.
; ============================================================

^!+W:: {
    target := A_ScriptDir "\macros\RecordMySteps.ahk"
    if !FileExist(target) {
        TrayTip("The automation for Ctrl+Alt+Shift+W is gone — remove its hotkey in Voice Kit.", "VoiceKit")
        return
    }
    q := Chr(34)                     ; association-proof: run via the interpreter
    Run(q A_AhkPath q ' ' q target q)
}
