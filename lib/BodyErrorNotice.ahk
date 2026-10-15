#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
; ============================================================
;  lib\BodyErrorNotice.ahk — the timed notice a hotkey body leaves when an
;  uncaught error ends it (lib\_Common.ahk VkBodyErrorEnd, 2026-10-14).
;
;      AutoHotkey64.exe BodyErrorNotice.ahk <text file> [<out file>]
;
;  The text file (UTF-8, deleted here) holds the title on its first line
;  and the message after it. The body starts this from inside a window
;  hook and ends a moment later, so the notice can't be the body's own
;  dialog: it lives here, in a process of its own, always on top, and
;  closes itself after 30 s so it never waits on anyone.
;
;  <out file> (tests only): append the text there instead of showing it.
;  Deliberately standalone — no lib\_Common.ahk, nothing that can error.
; ============================================================
if (A_Args.Length < 1)
    ExitApp(1)
noticeTxt := ""
try noticeTxt := FileRead(A_Args[1], "UTF-8")
try FileDelete(A_Args[1])
if (noticeTxt = "")
    ExitApp(1)
nl := InStr(noticeTxt, "`n")
noticeTitle := nl ? SubStr(noticeTxt, 1, nl - 1) : "VoiceKit"
noticeMsg := nl ? SubStr(noticeTxt, nl + 1) : noticeTxt
if (A_Args.Length >= 2 && A_Args[2] != "") {
    try FileAppend(noticeTitle "`n" noticeMsg "`n", A_Args[2], "UTF-8")
    ExitApp(0)
}
MsgBox(noticeMsg, noticeTitle, "Iconx 262144 T30")    ; 262144 = always-on-top
ExitApp(0)
