#Requires AutoHotkey v2.0
#SingleInstance Force
; The window the dry-run test aims at. A SEPARATE process: the fixture
; script (run under lib\DryRunShim.ahk) types, clicks and sets values here,
; and the suite reads this window's state to prove NOTHING arrived. UIA
; against your own process can deadlock, so it also has to live elsewhere.

#Include "%A_ScriptDir%\_target.ahk"

clicks := 0
g := Gui("+AlwaysOnTop", "VKDryRunTarget_ZZ")
g.AddText("w300", "Dry Field")
ed := g.AddEdit("w300", "")
btn := g.AddButton("w200", "Dry Press Zz")
btn.OnEvent("Click", OnBtn)
cb := g.AddCheckbox("w200", "Dry Check Zz")
dd := g.AddDropDownList("w200", ["Alpha", "Beta", "Gamma"])
g.Show()

OnBtn(*) {
    global clicks
    clicks += 1
}

; Values in brackets: TargetState's pattern needs a non-empty value, and an
; empty edit box is exactly the state under test.
StateLines() {
    global clicks, ed, cb, dd
    items := 0
    try items := ControlGetItems(dd).Length
    ed.GetPos(&ex, &ey, &ew, &eh)
    return "clicks=" clicks "`nedit=[" ed.Value "]`nchecked=" cb.Value
        . "`nchoice=[" dd.Text "]`nitems=" items "`nenabled=" ed.Enabled
        . "`nvisible=" ed.Visible "`neditw=" ew "`n"
}
TargetServe("dryrun-selftest", StateLines, g)
