#Requires AutoHotkey v2.0
#SingleInstance Off
; Conformance harness: run the REAL AutoHotkey generators and ports on a
; table of inputs, so test_generators_match_ahk can byte-compare them with
; their Python mirrors in voicekit_writer.py.
;
; The mirrors exist because the MCP writes the same files the GUI does. Two
; hand-kept copies drift, and the AHK half already shipped broken once (the
; backtick trap in HotkeyLauncherContent) while the Python half worked -- a
; break only an AHK-side run can catch. Covered:
;   launcher  HotkeyLauncherContent  <-> _hotkey_launcher_content
;   body      HotkeyBodyContent      <-> _hotkey_body_content
;   opens     VkOpensMacroContent    <-> _opens_content
;   stub      WfStubContent          <-> workflow_stub
;   clean     CleanPhrase            <-> clean_phrase
;   spaceout  SpaceOut               <-> space_out
;   snipenc   SnipEncode             <-> snip_encode
;   errmod    MasterErrorModule      <-> _error_module
;
; Usage:  AutoHotkey64.exe generators.ahk <cases.txt> <out.txt>
; cases: records separated by Chr(29), fields by Chr(30); the first field
; names the generator, the rest are its arguments (dates are pinned by the
; caller). out: one result per record, separated by Chr(29), UTF-8, no BOM.
#Include "%A_ScriptDir%\..\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\..\lib\Workflow.ahk"

if (A_Args.Length < 2)
    ExitApp(2)

out := ""
for rec in StrSplit(FileRead(A_Args[1], "UTF-8"), Chr(29)) {
    a := StrSplit(rec, Chr(30))
    switch a[1] {
        case "launcher": r := HotkeyLauncherContent(a[2], a[3], a[4], a[5])
        case "body":     r := HotkeyBodyContent(a[2], a[3], a[4], a[5], a[6])
        case "opens":    r := VkOpensMacroContent(a[2], a[3], a[4])
        case "stub":     r := WfStubContent(a[2], a[3], a[4])
        case "clean":    r := CleanPhrase(a[2])
        case "spaceout": r := SpaceOut(a[2])
        case "snipenc":  r := SnipEncode(a[2])
        case "errmod":   r := MasterErrorModule(a[2])
        default:         r := "UNKNOWN GENERATOR " a[1]
    }
    out .= (A_Index > 1 ? Chr(29) : "") r
}
f := FileOpen(A_Args[2], "w", "UTF-8-RAW")
f.Write(out)
f.Close()
ExitApp(0)
