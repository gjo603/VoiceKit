#Requires AutoHotkey v2.0
; Conformance harness: parse a .steps.txt with the REAL VoiceKit engine and
; re-emit it, so the Python conformance test can prove its output round-trips
; through AutoHotkey's actual WorkflowLoad / WfEncode / WfDecode.
;
; Usage:  AutoHotkey64.exe roundtrip.ahk <inputStepsFile> <outputFile>
#Include "%A_ScriptDir%\..\..\lib\Workflow.ahk"

if (A_Args.Length < 2) {
    FileOpen(A_Args.Length >= 1 ? A_Args[1] : A_Temp "\rt_err.txt", "w", "UTF-8").Write("need 2 args")
    ExitApp(2)
}

steps := WorkflowLoad(A_Args[1])          ; reads + WfDecodes exactly as playback does
out := ""
for s in steps
    out .= s[1] "|" WfEncode(s[2]) "|" WfEncode(s[3]) "|" WfEncode(s.Length >= 4 ? s[4] : "") "`n"

f := FileOpen(A_Args[2], "w", "UTF-8")
f.Write(out)
f.Close()
ExitApp(0)
