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
live.OnEvent("Change", (*) => SetTimer(LiveFormat, -150))
ssn.OnEvent("Change", (*) => SetTimer(SsnFormat, -150))
blur.OnEvent("LoseFocus", BlurFormat)
thief.OnEvent("Focus", (*) => decoy.Focus())
g.Show("x40 y40")

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
