#Requires AutoHotkey v2.0
; ============================================================
;  Text snippets (hotstrings). Type the abbreviation anywhere
;  and it expands. The "/" prefix prevents accidental firing.
;  Loaded by VoiceKit.ahk — do not run this file directly.
;
;  "New Automation" -> "Type Text For Me" appends to this file.
;  Multi-line snippets are fine: each is stored on ONE line with its
;  newlines encoded as `n, so edit them in Voice Kit (say "open voice
;  kit", pick the snippet, Edit) rather than adding raw line breaks here.
; ============================================================

; Types today's date, e.g. 2026-07-06
:*:/date:: {
    SendText(FormatTime(A_Now, "yyyy-MM-dd"))
}

; EDIT ME: your email signature

; EDIT ME: your address
::/addr::123 Your Street, Your City

; ==== AUTO-ADDED SNIPPETS BELOW THIS LINE ====

:*:/signature::Best,`nYOUR NAME HERE
