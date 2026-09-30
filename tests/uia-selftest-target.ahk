#Requires AutoHotkey v2.0
#SingleInstance Force
; The window the UIA test drives. A SEPARATE process on purpose: UIA against
; your own process can deadlock, and automating another app is the real case.
; Publishes its state (and its control HWNDs) so the tester can verify what
; UIA actually did to it.

#Include "%A_ScriptDir%\_target.ahk"

clicks := 0
selected := ""
g := Gui("+AlwaysOnTop", "VKUiaTarget_ZZ")
g.AddText("w300", "Name Field")
ed := g.AddEdit("w300", "original value")
btn := g.AddButton("w200", "Press Me Zz")
btn.OnEvent("Click", OnBtn)
; A list taller than its box: rows past the fold are findable over UIA but
; report NO rectangle until scrolled into view — the deterministic stand-in
; for a virtualizing web page, which the rect-less-click tests drive.
lv := g.AddListView("w300 h100 -Multi", ["Item"])
Loop 40
    lv.Add(, "Lv Row " A_Index)
lv.OnEvent("ItemSelect", OnSel)
; A password box (ES_PASSWORD) for UiaIsPassword — added LAST so nothing
; above shifts in tree order.
g.AddText("w300", "Secret Field")
pw := g.AddEdit("w300 Password", "")
g.Show()

; A named function with an explicit `global`, NOT `(*) => clicks += 1`:
; in AHK v2 an assignment inside a function creates a LOCAL unless the
; global is declared, so the arrow version silently counted nothing.
OnBtn(*) {
    global clicks
    clicks += 1
}

OnSel(ctrl, item, sel) {
    global selected
    if sel
        selected := ctrl.GetText(item)
}

StateLines() {
    global clicks, ed, btn, selected, pw
    return "clicks=" clicks "`nedit=" ed.Value
        . "`nedithwnd=" ed.Hwnd "`nbtnhwnd=" btn.Hwnd
        . "`npwhwnd=" pw.Hwnd
        . "`nselected=" selected "`n"
}
TargetServe("uia-selftest", StateLines, g)
