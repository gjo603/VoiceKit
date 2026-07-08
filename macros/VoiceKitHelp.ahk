#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Voice Kit Help — say "open voice kit help" any time you
;  forget a phrase. Lists every automation you've created.
; ============================================================

#Include "%A_ScriptDir%\..\lib\Theme.ahk"

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")

macros := ""
Loop Files root "\macros\*.ahk" {
    name := StrReplace(A_LoopFileName, ".ahk")
    macros .= "    open " SpaceOut(name) "`n"
}

hotkeys := ""
mapFile := root "\bridge-map.txt"
if FileExist(mapFile) {
    Loop Parse FileRead(mapFile), "`n", "`r" {
        if (A_LoopField = "" || SubStr(A_LoopField, 1, 1) = ";")
            continue
        hotkeys .= "    " A_LoopField "`n"
    }
}
if (hotkeys = "")
    hotkeys := "    (none yet)`n"

body := "LAUNCH MACROS — say `"open <name>`":`n`n" macros
      . "`nHOTKEY MODULES (from bridge-map.txt):`n`n" hotkeys
      . "`nSNIPPETS:`n    see hotkeys\Snippets.ahk"

; ---- themed window (replaces the old MsgBox) ----
g := Gui("+AlwaysOnTop", "VoiceKit — what can I say?")
g.SetFont("s11", "Segoe UI")
g.MarginX := 16, g.MarginY := 14
g.AddText("xm", "Everything you can trigger right now:")
g.SetFont("s10", "Consolas")
g.AddEdit("xm y+10 w560 r22 +ReadOnly +VScroll", body)
g.SetFont("s10", "Segoe UI")
btnClose := g.AddButton("xm y+12 w120 h32 Default", "Close")
btnClose.OnEvent("Click", (*) => ExitApp())
g.OnEvent("Close", (*) => ExitApp())
g.OnEvent("Escape", (*) => ExitApp())
ThemeApply(g)
g.Show()
btnClose.Focus()          ; else the read-only Edit takes focus and shows all text selected

SpaceOut(camel) {
    return Trim(RegExReplace(camel, "([a-z0-9])([A-Z])", "$1 $2"))
}
