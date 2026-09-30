#Requires AutoHotkey v2.0
; Conformance harness: publish a body status line with the REAL AHK helper,
; so the Python conformance test can prove voicekit_writer.body_status reads
; back what AutoHotkey actually wrote.
;
; This is an AHK-writes / Python-reads seam like the run record. The two
; things a round trip catches and nothing else does: the file's encoding
; (AHK writes UTF-8, and _read_text_any has to sniff it) and the
; "<stamp>|<text>" line format, which both sides parse independently.
;
; Usage:  AutoHotkey64.exe bodystatus.ahk <repoRootStandIn> <base> <text>
#Include "%A_ScriptDir%\..\..\lib\_Common.ahk"

if (A_Args.Length < 3)
    ExitApp(2)

; A stand-in root, so the harness writes into a temp folder and never the
; user's real logs\ — the same rule the run-record harness follows.
BodyStatus(A_Args[2], A_Args[3], A_Args[1])
ExitApp(0)
