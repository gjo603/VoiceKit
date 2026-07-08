#Requires AutoHotkey v2.0
; ============================================================
;  {{PHRASE}}   (created {{DATE}})
;  Loaded by VoiceKit.ahk — do not run this file directly.
;
;  Trigger key:  Ctrl+Alt+Shift+{{KEY}}
;
;  To trigger it by voice (one-time setup, ~30 seconds):
;    1. Say: "show voice shortcuts"
;    2. Create new shortcut  ->  When I say:  {{PHRASE}}
;    3. Action: Press keys   ->  Ctrl + Alt + Shift + {{KEY}}
;  This pairing is recorded in bridge-map.txt.
; ============================================================

^!+{{KEY}}:: {
    ; ==== YOUR STEPS BELOW — delete the MsgBox once it works ====
    MsgBox("'{{PHRASE}}' is wired up! Now edit this file:`n" A_LineFile)
}
