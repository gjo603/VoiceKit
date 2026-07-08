#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  {{PHRASE}}   (created {{DATE}})
;  Trigger by voice:  "open {{PHRASE}}"
;  Runs top to bottom, then exits.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"

; ==== YOUR STEPS BELOW — delete the MsgBox once it works ====
MsgBox("'{{PHRASE}}' is wired up! Now edit this file:`n" A_ScriptFullPath)

; --- Building blocks (remove the leading ; to use) ---
; Run("https://example.com")                            ; open a website
; Run("notepad.exe")                                    ; launch an app
; RunOrActivate("ahk_exe chrome.exe", "chrome.exe")     ; focus it, or launch it
; Run('explorer.exe "' A_MyDocuments '"')               ; open a folder
; Sleep(800)                                            ; wait 0.8 sec between steps
; SendText("some text")                                 ; type text into the focused box
; WinMove(0, 0, A_ScreenWidth // 2, A_ScreenHeight, "ahk_exe notepad.exe")  ; position a window
