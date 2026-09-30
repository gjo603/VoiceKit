#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Morning Tabs — say "open morning tabs"
;  EXAMPLE: opens your daily sites in the default browser.
;  Replace the URLs with your real ones.
;
;  Honest note: AutoHotkey is great at OPENING and ARRANGING
;  web pages. For clicking things INSIDE a page, Voice Access
;  ("click <element>" / "show numbers") is the better tool —
;  coordinate-click macros rot the first time a site changes.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"

Run("https://mail.google.com")
Sleep(600)
Run("https://calendar.google.com")
Sleep(600)
Run("https://news.ycombinator.com")

Notify("Morning tabs opened.")
