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
; report NO rectangle until scrolled into view - the deterministic stand-in
; for a virtualizing web page, which the rect-less-click tests drive.
lv := g.AddListView("w300 h100 -Multi", ["Item"])
Loop 40
    lv.Add(, "Lv Row " A_Index)
lv.OnEvent("ItemSelect", OnSel)
; A password box (ES_PASSWORD) for UiaIsPassword - added LAST so nothing
; above shifts in tree order.
g.AddText("w300", "Secret Field")
pw := g.AddEdit("w300 Password", "")
; Scoped-search fixtures, OUTSIDE the list (and last, for the same reason):
; a Text sharing a list row's name, and a button only the window has. A
; search started at the list must never come back with either.
g.AddText("w300", "Lv Row 3")
g.AddButton("w200", "Outside Only Zz")
g.Show()

; ---- visibility fixtures (2026-10-14) -----------------------------------
; In SEPARATE top-level windows, so nothing in the first window's tree moves.
; VKUiaVis_ZZ: a child pane with scroll bars (WS_VSCROLL|WS_HSCROLL 0x300000
; - over UIA that makes it a scroll container, measured) holding a button
; inside it, one two-thirds past its right edge and one wholly past it but
; still inside the window: the Win32 stand-in for Chrome reporting a
; rectangle for content scrolled out of an inner panel (measured: the
; hidden one keeps a rect and IsOffscreen stays false). Plus a button a
; separate overlay covers, and one whose name is an icon-font glyph.
counts := Map("in", 0, "clip", 0, "hid", 0, "cov", 0, "cover", 0, "far", 0, "icon", 0)
Counter(key) => (*) => counts[key] += 1
vis := Gui("+AlwaysOnTop", "VKUiaVis_ZZ")
vis.AddText("w300", "Visibility fixtures")
pane := Gui("-Caption +Parent" vis.Hwnd " +0x300000", "VKUiaPane_ZZ")
pane.AddButton("x10 y10 w80 h30", "Inside Btn Zz").OnEvent("Click", Counter("in"))
pane.AddButton("x150 y50 w120 h30", "Clipped Btn Zz").OnEvent("Click", Counter("clip"))
pane.AddButton("x260 y10 w80 h30", "Hidden Btn Zz").OnEvent("Click", Counter("hid"))
pane.Show("x10 y40 w200 h120")
covBtn := vis.AddButton("x10 y180 w160 h30", "Covered Btn Zz")
covBtn.OnEvent("Click", Counter("cov"))
vis.AddButton("x200 y180 w60 h30", Chr(0xE611)).OnEvent("Click", Counter("icon"))
vis.Show("x40 y60 w420 h240 NoActivate")

; The overlay: a captionless always-on-top window exactly over the covered
; button (pixels, not DPI-scaled), whose text counts the clicks it takes -
; so a click that wrongly went ahead would show up here, not vanish.
rc := Buffer(16, 0)
DllCall("GetWindowRect", "ptr", covBtn.Hwnd, "ptr", rc)
cl := NumGet(rc, 0, "int"), ct := NumGet(rc, 4, "int")
cw := NumGet(rc, 8, "int") - cl, ch := NumGet(rc, 12, "int") - ct
cover := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale", "VKUiaCover_ZZ")
cover.MarginX := 0, cover.MarginY := 0
cover.AddText("x0 y0 w" cw " h" ch " Center Border", "Cover Zz").OnEvent("Click", Counter("cover"))
cover.Show("x" cl " y" ct " w" cw " h" ch " NoActivate")

; VKUiaFar_ZZ: shown to the RIGHT of the whole virtual screen - on no
; monitor at all (SM_XVIRTUALSCREEN 76 + SM_CXVIRTUALSCREEN 78).
far := Gui("+AlwaysOnTop", "VKUiaFar_ZZ")
far.AddButton("w160 h30", "Far Btn Zz").OnEvent("Click", Counter("far"))
far.Show("x" (SysGet(76) + SysGet(78) + 400) " y" (SysGet(77) + 100) " NoActivate")

; VKUiaRescue_ZZ (review, 2026-10-14): the hit test's ScrollIntoView retry,
; both ways. A ListView sized to show five and a half rows (-DPIScale:
; pixels throughout), and two overlay windows that count their clicks:
;   VKUiaStrip_ZZ covers the half row at the bottom. The row there has a
;     rectangle (measured: the ListView proxy clips a partial row's
;     rectangle to what shows) that the strip covers, so the hit test says
;     "in the way"; ScrollIntoView then scrolls it up one row, out from
;     under the strip, and the retry clicks it - the rescue.
;   VKUiaPin_ZZ covers the first row slot under the column header - a
;     header pinned over the content. ScrollIntoView can't move the top
;     row anywhere else, so the click must be refused "still, after".
; Every ListView click is counted (rsn) with the row it hit (rslast).
rsn := 0, rslast := "(none)"
rs := Gui("+AlwaysOnTop -DPIScale", "VKUiaRescue_ZZ")
rlv := rs.AddListView("x10 y10 w300 h200 -Multi", ["Item"])
Loop 30
    rlv.Add(, "Rs Row " A_Index)
rlv.OnEvent("Click", OnRsClick)
rs.Show("x40 y560 w340 h280 NoActivate")
LvItemRect(lvc, i) {                         ; client coords (LVM_GETITEMRECT, LVIR_BOUNDS)
    b := Buffer(16, 0)
    SendMessage(0x100E, i, b.Ptr, lvc)
    return {l: NumGet(b, 0, "int"), t: NumGet(b, 4, "int"), r: NumGet(b, 8, "int"), b: NumGet(b, 12, "int")}
}
WinRectOf(h) {
    b := Buffer(16, 0)
    DllCall("GetWindowRect", "ptr", h, "ptr", b)
    return {l: NumGet(b, 0, "int"), t: NumGet(b, 4, "int"), r: NumGet(b, 8, "int"), b: NumGet(b, 12, "int")}
}
ClientBox(h) {                               ; the client area in SCREEN pixels
    b := Buffer(16, 0), pt := Buffer(8, 0)
    DllCall("GetClientRect", "ptr", h, "ptr", b)
    DllCall("ClientToScreen", "ptr", h, "ptr", pt)
    x := NumGet(pt, 0, "int"), y := NumGet(pt, 4, "int")
    return {l: x, t: y, r: x + NumGet(b, 8, "int"), b: y + NumGet(b, 12, "int")}
}
hdrH := WinRectOf(SendMessage(0x101F, 0, 0, rlv)).b - WinRectOf(SendMessage(0x101F, 0, 0, rlv)).t   ; LVM_GETHEADER
row0 := LvItemRect(rlv, 0), rowH := row0.b - row0.t
cb := ClientBox(rlv.Hwnd), wr := WinRectOf(rlv.Hwnd)
border := (wr.b - wr.t) - (cb.b - cb.t)
rlv.Move(, , , hdrH + 5 * rowH + rowH // 2 + border)
cb := ClientBox(rlv.Hwnd)
OverlayOver(title, key, l, t, w, h) {
    o := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale", title)
    o.MarginX := 0, o.MarginY := 0
    o.AddText("x0 y0 w" w " h" h " Center Border", title).OnEvent("Click", Counter(key))
    o.Show("x" l " y" t " w" w " h" h " NoActivate")
    return o
}
counts["strip"] := 0, counts["pin"] := 0
partTop := cb.t + LvItemRect(rlv, 5).t       ; the sixth row: only partly shown
strip := OverlayOver("VKUiaStrip_ZZ", "strip", cb.l, partTop, cb.r - cb.l, cb.b - partTop)
pin := OverlayOver("VKUiaPin_ZZ", "pin", cb.l, cb.t + row0.t, cb.r - cb.l, rowH)

; VKUiaOwner_ZZ / VKUiaOwned_ZZ (code review, 2026-10-14): an OWNED window
; (a dialog) reaching past its small owner, with a button wholly outside
; the owner's box. UIA may list an owned window under its owner; clipping
; by "the ancestor below the desktop root" then hid the button. -DPIScale:
; pixels throughout.
counts["owned"] := 0
own := Gui("+AlwaysOnTop -DPIScale", "VKUiaOwner_ZZ")
own.AddText("w150", "Owner")
own.Show("x500 y60 w200 h120 NoActivate")
owned := Gui("+AlwaysOnTop -DPIScale +Owner" own.Hwnd, "VKUiaOwned_ZZ")
owned.AddButton("x240 y20 w100 h30", "Owned Btn Zz").OnEvent("Click", Counter("owned"))
owned.Show("x520 y100 w380 h160 NoActivate")

OnRsClick(ctrl, item) {
    global rsn, rslast
    rsn += 1
    rslast := item ? ctrl.GetText(item) : "(no row)"
}

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
    global clicks, ed, btn, selected, pw, lv, counts, pane, rsn, rslast, rlv
    s := "clicks=" clicks "`nedit=" ed.Value
        . "`nedithwnd=" ed.Hwnd "`nbtnhwnd=" btn.Hwnd
        . "`npwhwnd=" pw.Hwnd "`nlvhwnd=" lv.Hwnd
        . "`npanehwnd=" pane.Hwnd
        . "`nrlvhwnd=" rlv.Hwnd "`nrsn=" rsn "`nrslast=" rslast
        . "`nrstop=" SendMessage(0x1027, 0, 0, rlv)          ; LVM_GETTOPINDEX
        . "`nselected=" selected "`n"
    for k, v in counts
        s .= k "clicks=" v "`n"
    return s
}
TargetServe("uia-selftest", StateLines, g)
