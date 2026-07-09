#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Voice Kit Help — kept so the old phrase still works.
;  "open voice kit help" now lands in the home window
;  (macros\VoiceKitHome.ahk); say "open voice kit" directly.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"

RunAhk(A_ScriptDir "\VoiceKitHome.ahk")
