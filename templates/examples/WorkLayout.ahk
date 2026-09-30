#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Work Layout — say "open work layout"
;  EXAMPLE: puts Notepad on the left half, Downloads on the
;  right half. Edit both blocks for the apps YOU actually use.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"

halfW := A_ScreenWidth // 2

; --- Left: Notepad (swap in your editor / notes app) ---
RunOrActivate("ahk_exe notepad.exe", "notepad.exe")
WinMove(0, 0, halfW, A_ScreenHeight, "ahk_exe notepad.exe")

; --- Right: File Explorer on Downloads ---
Run('explorer.exe "' A_MyDocuments '\..\Downloads"')
if WinWait("Downloads", , 5)
    WinMove(halfW, 0, halfW, A_ScreenHeight, "Downloads")

; Tip: to find any app's ahk_exe name, right-click the VoiceKit
; tray icon -> Window Spy, then click the target window.
