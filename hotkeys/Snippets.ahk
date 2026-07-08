#Requires AutoHotkey v2.0
; ============================================================
;  Text snippets (hotstrings). Type the abbreviation anywhere
;  and it expands. The "/" prefix prevents accidental firing.
;  Loaded by VoiceKit.ahk — do not run this file directly.
;
;  "New Automation" -> "Text Snippet" appends to this file.
;  Keep snippets to simple single-line text.
; ============================================================

; Types today's date, e.g. 2026-07-06
:*:/date:: {
    SendText(FormatTime(A_Now, "yyyy-MM-dd"))
}

; EDIT ME: your email signature
::/sig::Best regards,`nYOUR NAME HERE

; EDIT ME: your address
::/addr::123 Your Street, Your City

; ==== AUTO-ADDED SNIPPETS BELOW THIS LINE ====
