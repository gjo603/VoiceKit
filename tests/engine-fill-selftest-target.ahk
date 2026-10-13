#Requires AutoHotkey v2.0
#SingleInstance Force
; The form tests\engine-fill-selftest.ahk fills. A SEPARATE process for the
; usual reason: the fill step finds boxes over UI Automation, and UIA against
; your own process deadlocks.
;
; Every box is a plain Win32 edit placed right after a Text that SHARES its
; name (Win32 names an edit after the static before it) — so every box is
; also the label-vs-input trap. What each one is for:
;   Name Zz          the plain case (and the trap: the label comes first)
;   Amount Zz  x2    two inputs sharing one label — "Amount Zz#2"
;   Money Live Zz    reformats itself ~150 ms after you type: 1234.5 -> 1,234.50
;   Money Blur Zz    reformats when it LOSES focus (the readback runs before)
;   Ssn Zz           an input mask: 123456789 -> 123-45-6789
;   Disabled Zz      disabled — must be refused before anything is typed
;   Secret Zz        a password box — filled, never read back
;   Short Zz         keeps only 2 characters — the readback must catch it
;   Thief Zz         hands the focus to Decoy Zz the moment it gets it — the
;                    focus gate must refuse, and NOTHING may be typed anywhere
;   Only Label Zz    a label with no box at all
;   Classic Zz       the box the MSAA-fallback check fills (with UIA off)
;
; Then the RELATIVE form (fill|w|after "Credits Zz" > "Insurance Zz"|v): two
; "sections" whose boxes ALL share one accessible name, "expanded detail
; input" (a tax app's page, measured), each after its own visible text —
; so only the text before a box can tell them apart:
;   Deductions Zz    Insurance Zz -> Ded_Ins      Taxes Zz -> Ded_Tax
;   Credits Zz       Insurance Zz -> Cred_Ins     Other Zz -> Cred_Other
;   Trailing Words Zz  (no box after it)
;
; Publishes every box's value so the test checks what LANDED, not what the
; engine claims.

#Include "%A_ScriptDir%\_target.ahk"

liveBusy := false
g := Gui("+AlwaysOnTop", "VKFillTarget_ZZ")
g.SetFont("s9", "Segoe UI")
boxes := Map()
Box(label, opts := "") {
    global g, boxes
    g.AddText("xm w120", label)
    e := g.AddEdit("x+8 yp-3 w200 " opts)
    boxes[label] := e
    return e
}
Box("Name Zz")
Box("Amount Zz")
Box("Amount Zz")
boxes["Amount Zz 1"] := g["Edit2"]          ; the first "Amount Zz" (the Map kept the second)
live := Box("Money Live Zz")
blur := Box("Money Blur Zz")
ssn := Box("Ssn Zz")
Box("Disabled Zz", "Disabled")
Box("Secret Zz", "Password")
Box("Short Zz", "Limit2")
thief := Box("Thief Zz")
decoy := Box("Decoy Zz")
g.AddText("xm w200", "Only Label Zz")
Box("Classic Zz")
; Win32 names an edit after the static just before it, so the small
; "expanded detail input" text gives every box below the same name.
Rel(label, key) {
    global g, boxes
    g.AddText("xm+16 w90", label)
    g.AddText("x+4 w120", "expanded detail input")
    boxes[key] := g.AddEdit("x+4 yp-3 w120")
}
; A numeric box with an up-down BUDDY (UIA: a Spinner right after its Edit):
; counted once, so #2 after the text is the NEXT box, never the arrows.
g.AddText("xm w200", "Qty Section Zz")
boxes["Qty_1"] := g.AddEdit("xm+16 w80")
g.AddUpDown("Range0-100", 0)
boxes["Qty_2"] := g.AddEdit("x+24 yp w80")
g.AddText("xm w200", "Deductions Zz")
Rel("Insurance Zz", "Ded_Ins")
Rel("Taxes Zz", "Ded_Tax")
g.AddText("xm w200", "Credits Zz")
Rel("Insurance Zz", "Cred_Ins")
Rel("Other Zz", "Cred_Other")
g.AddText("xm w200", "Trailing Words Zz")
live.OnEvent("Change", (*) => SetTimer(LiveFormat, -150))
ssn.OnEvent("Change", (*) => SetTimer(SsnFormat, -150))
blur.OnEvent("LoseFocus", BlurFormat)
thief.OnEvent("Focus", (*) => decoy.Focus())
g.Show("x40 y40")

; A second window shaped like a BROWSER for the relative form's page rule
; (the suite treats it as one with wfFillAsBrowser, and a Pane as the
; page with wfFillPageType — no Win32 control is a Document). In UIA tree
; order: browser UI before the page (a "tab" text + the "address bar"),
; the page (a child Gui = one Pane holding a section), browser UI after it
; (a "side panel" text + box). Measured: a child Gui comes after the
; controls created before it, and before those created after it.
b := Gui("+AlwaysOnTop", "VKFillBrowser_ZZ")
b.SetFont("s9", "Segoe UI")
b.AddText("xm w120", "Tab Only Bz")
boxes["Omni_Box"] := b.AddEdit("x+4 yp-3 w140")
pg := Gui("+Parent" b.Hwnd " -Caption", "Page Bz")
pg.SetFont("s9", "Segoe UI")
pg.AddText("xm w120", "Section Bz")
pg.AddText("xm w120", "Insurance Bz")
boxes["Pg_Ins"] := pg.AddEdit("x+4 yp-3 w140")
b.AddText("xm y+90 w120", "Tail Bz")
boxes["Side_Box"] := b.AddEdit("x+4 yp-3 w140")
b.Show("x480 y40 w320 h170")
pg.Show("x10 y34 w300 h80")

; A third window for SECTIONS that really contain their content (a `>`
; chain is bounded to a section that is a container). A Win32 GroupBox is
; only a sibling of the controls drawn inside it, so each container section
; is a child Gui: one Pane NAMED by its title (as aria-labelledby names a
; web page's group after its heading) holding its texts and boxes. Measured
; with UiaDumpTree before relying on it -- see the suite.
;   Wages Sx (Pane)     Bonus Sx -> Wg_Bonus, Tips Sx -> Wg_Tips
;                       (no "Insurance Sx" inside -- the next section has one)
;   Benefits Sx (Pane)  Insurance Sx -> Bn_Ins
;   Notes Sx (Pane)     holds only its own text "Notes Sx" (a browser's
;                       heading does: its text is a child node) -- a heading,
;                       not a container; then, AFTER it in the window,
;                       Remarks Sx -> Nt_Rem
s := Gui("+AlwaysOnTop", "VKFillSections_ZZ")
s.SetFont("s9", "Segoe UI")
Section(title, y, h) {
    global s
    c := Gui("+Parent" s.Hwnd " -Caption", title)
    c.SetFont("s9", "Segoe UI")
    return {gui: c, y: y, h: h}
}
SecBox(sec, label, key) {
    global boxes
    sec.gui.AddText("xm w90", label)
    boxes[key] := sec.gui.AddEdit("x+4 yp-3 w140")
}
wages := Section("Wages Sx", 4, 64)
SecBox(wages, "Bonus Sx", "Wg_Bonus")
SecBox(wages, "Tips Sx", "Wg_Tips")
benefits := Section("Benefits Sx", 72, 36)
SecBox(benefits, "Insurance Sx", "Bn_Ins")
notes := Section("Notes Sx", 112, 26)
notes.gui.AddText("xm w120", "Notes Sx")
s.AddText("xm y146 w90", "Remarks Sx")
boxes["Nt_Rem"] := s.AddEdit("x+4 yp-3 w140")
s.Show("x480 y230 w320 h180")
for sec in [wages, benefits, notes]
    ; Measured: a child Gui's Show x/y are raw PIXELS in its parent while
    ; w/h are DPI-scaled -- unscaled, at 150% the panes overlapped and a
    ; click on Benefits' box landed on the Wages pane above it.
    sec.gui.Show("x" Round(4 * A_ScreenDPI / 96) " y" Round(sec.y * A_ScreenDPI / 96)
        . " w300 h" sec.h)

; 1234.5 -> 1,234.50 (what a finance app's amount box does to what you type).
Money(s) {
    s := RegExReplace(s, "[^\d.\-]")
    if !IsNumber(s)
        return ""
    t := Format("{:.2f}", Number(s))
    neg := SubStr(t, 1, 1) = "-"
    t := LTrim(t, "-")
    parts := StrSplit(t, ".")
    w := parts[1], out := ""
    while (StrLen(w) > 3) {
        out := "," SubStr(w, -3) out
        w := SubStr(w, 1, -3)
    }
    return (neg ? "-" : "") w out "." parts[2]
}
LiveFormat() {
    global live, liveBusy
    f := Money(live.Value)
    if (f != "" && f != live.Value) {
        liveBusy := true
        live.Value := f
        liveBusy := false
    }
}
BlurFormat(*) {
    global blur
    f := Money(blur.Value)
    if (f != "")
        blur.Value := f
}
SsnFormat() {
    global ssn
    d := RegExReplace(ssn.Value, "\D")
    if (StrLen(d) = 9 && ssn.Value != SubStr(d, 1, 3) "-" SubStr(d, 4, 2) "-" SubStr(d, 6))
        ssn.Value := SubStr(d, 1, 3) "-" SubStr(d, 4, 2) "-" SubStr(d, 6)
}

StateLines() {
    global boxes
    out := ""
    for k, e in boxes          ; [bracketed], so an EMPTY box still reads as a value
        out .= StrReplace(k, " ", "_") "=[" e.Value "]`n"
    return out "ready=1`n"
}
TargetServe("engine-fill-selftest", StateLines, g)
