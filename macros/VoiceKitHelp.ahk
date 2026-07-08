#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Voice Kit Help — say "open voice kit help" any time you
;  forget a phrase. Lists every automation you've created.
; ============================================================

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")

out := "LAUNCH MACROS — say `"open <name>`":`n`n"
Loop Files root "\macros\*.ahk" {
    name := StrReplace(A_LoopFileName, ".ahk")
    out .= "    open " SpaceOut(name) "`n"
}

out .= "`nHOTKEY MODULES (from bridge-map.txt):`n`n"
mapFile := root "\bridge-map.txt"
if FileExist(mapFile) {
    Loop Parse FileRead(mapFile), "`n", "`r" {
        if (A_LoopField = "" || SubStr(A_LoopField, 1, 1) = ";")
            continue
        out .= "    " A_LoopField "`n"
    }
}

out .= "`nSNIPPETS: see hotkeys\Snippets.ahk"
MsgBox(out, "VoiceKit — what can I say?")

SpaceOut(camel) {
    return Trim(RegExReplace(camel, "([a-z0-9])([A-Z])", "$1 $2"))
}
