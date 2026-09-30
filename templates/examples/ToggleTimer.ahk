#Requires AutoHotkey v2.0
; ============================================================
;  Toggle Timer   (created 2026-07-07)
;  Loaded by VoiceKit.ahk — do not run this file directly.
;
;  Trigger key:  Ctrl+Alt+Shift+A
;
;  To trigger it by voice (one-time setup, ~30 seconds):
;    1. Say: "show voice shortcuts"
;    2. Create new shortcut  ->  When I say:  Toggle Timer
;    3. Action: Press keys   ->  Ctrl + Alt + Shift + A
;  This pairing is recorded in bridge-map.txt.
; ============================================================

^!+A:: {
    ; ==== YOUR STEPS BELOW — delete the MsgBox once it works ====
    MsgBox("'Toggle Timer' is wired up! Now edit this file:`n" A_LineFile)
}
