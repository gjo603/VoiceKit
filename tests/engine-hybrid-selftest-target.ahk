#Requires AutoHotkey v2.0
#SingleInstance Force
; The windows tests\engine-hybrid-selftest.ahk drives.
;
; A SEPARATE process for the same reason tests\uia-selftest-target.ahk is
; one: the engine's element lookup now falls back to UIA, and UIA against
; your own process deadlocks. A test that drove its own window would either
; exercise nothing (the guard refuses it) or wedge.
;
; Publishes its click counts so the test can prove a click really landed,
; rather than trusting the engine's return value.
;
; Three windows:
;   VKHybridTarget_ZZ  the original: a label, an edit, a button (both trees).
;   VKHybridForm_ZZ    a form for `collect`: one box both trees can see, and a
;                      DEEP panel only UIA can see (see DeepPanel below).
;   VKHybridWeb_ZZ     a top-level window of class Chrome_WidgetWin_1 — the
;                      class Chrome/Edge/Electron use — so the engine's
;                      browser pacing can be exercised without a browser. Its
;                      content is deep too, which is the real shape: a
;                      browser's page content is UIA-only.

#Include "%A_ScriptDir%\_target.ahk"

clicks := 0
webClicks := 0
panels := []                      ; every nested panel, kept alive (see DeepPanel)
g := Gui("+AlwaysOnTop", "VKHybridTarget_ZZ")
g.AddText("w300", "Hybrid Label Zz")
ed := g.AddEdit("w300", "hybrid edit value zz")
btn := g.AddButton("w200", "Hybrid Button Zz")
btn.OnEvent("Click", OnBtn)
g.Show("x40 y40")

; ---- the collect form ---------------------------------------------------
; A UIA-ONLY box, without a browser. For Win32 controls the UIA tree is
; built from MSAA (measured: a UIA Name annotation shows up in BOTH trees),
; so no property can hide a control from one tree only. Depth can: the
; engine's MSAA walk (AccNodeOnce) stops descending at depth 14, and every
; nested child window costs it two levels (window object, then client
; object). Nine nested panels put the innermost controls out of its reach,
; while UIA — which has no such limit — lists them. That is the shape of the
; browser problem: content only the second tree can see.
;
; Inside the deep panel, every box sits right after a Text that SHARES its
; name (Win32 names an edit after the static before it — the label-vs-input
; trap, exactly as measured on real web forms). "Both Box Zz" also exists
; shallow, where MSAA can see it: a UIA-first lookup would read the deep
; decoy (created first, so it leads UIA's tree order); MSAA-first reads the
; shallow box — the proof that Acc still wins when both trees can answer.
f := Gui("+AlwaysOnTop", "VKHybridForm_ZZ")
deepF := DeepPanel(f, 9, "x10 y10 w360 h170")
deepF.AddText("x5 y5 w150", "Both Box Zz")
deepF.AddEdit("x160 y5 w180", "deep decoy zz")
deepF.AddText("x5 y40 w150", "Deep Trap Zz")
deepF.AddEdit("x160 y40 w180", "deep trap value zz")
deepF.AddText("x5 y75 w150", "Deep Empty Zz")
deepF.AddEdit("x160 y75 w180", "")
f.AddText("x10 y200 w150", "Both Box Zz")
f.AddEdit("x170 y200 w200", "acc value zz")
f.Show("x40 y260 w400 h240")

; ---- the pretend browser ------------------------------------------------
; A raw window of class Chrome_WidgetWin_1 (DefWindowProcW as its window
; procedure — nothing to call back into), with a deep AHK panel inside it.
web := WebWindow("VKHybridWeb_ZZ", 460, 40, 420, 260)
deepW := DeepPanel(web, 9, "x10 y10 w380 h190")
wbtn := deepW.AddButton("x5 y5 w200", "Web Button Zz")
wbtn.OnEvent("Click", OnWebBtn)
deepW.AddText("x5 y45 w150", "Web Field Zz")
deepW.AddEdit("x160 y45 w180", "web value zz")

; `levels` nested borderless child Guis inside `host` (a Gui or a raw hwnd);
; returns the innermost, already shown.
DeepPanel(host, levels, opts) {
    parent := IsObject(host) ? host.Hwnd : host
    loop levels {
        p := Gui("-Caption +Parent" parent)
        p.MarginX := 0, p.MarginY := 0
        p.Show(A_Index = 1 ? opts : "x2 y2 w" (380 - A_Index * 4) " h" (190 - A_Index * 4))
        parent := p.Hwnd
        panels.Push(p)                 ; keep every level alive
    }
    return p
}

WebWindow(title, x, y, w, h) {
    static cls := "Chrome_WidgetWin_1"
    hInst := DllCall("GetModuleHandle", "ptr", 0, "ptr")
    wc := Buffer(80, 0)                                  ; WNDCLASSEXW (x64)
    NumPut("uint", 80, wc, 0)                            ; cbSize
    NumPut("ptr", DllCall("GetProcAddress", "ptr", DllCall("GetModuleHandle", "str", "user32", "ptr")
        , "astr", "DefWindowProcW", "ptr"), wc, 8)       ; lpfnWndProc
    NumPut("ptr", hInst, wc, 24)                         ; hInstance
    NumPut("ptr", DllCall("LoadCursor", "ptr", 0, "ptr", 32512, "ptr"), wc, 40)   ; IDC_ARROW
    NumPut("ptr", 16, wc, 48)                            ; COLOR_BTNFACE + 1
    className := Buffer(StrPut(cls, "UTF-16") * 2)
    StrPut(cls, className, "UTF-16")
    NumPut("ptr", className.Ptr, wc, 64)                 ; lpszClassName
    DllCall("RegisterClassExW", "ptr", wc, "ushort")
    ; WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_CLIPCHILDREN; WS_EX_TOPMOST
    return DllCall("CreateWindowExW", "uint", 0x8, "str", cls, "str", title
        , "uint", 0x00CF0000 | 0x10000000 | 0x02000000, "int", x, "int", y, "int", w, "int", h
        , "ptr", 0, "ptr", 0, "ptr", hInst, "ptr", 0, "ptr")
}

; A named function with an explicit `global` — an arrow function's assignment
; would create a local and count nothing (the trap uia-selftest-target hit).
OnBtn(*) {
    global clicks
    clicks += 1
}
OnWebBtn(*) {
    global webClicks
    webClicks += 1
}

StateLines() {
    global clicks, webClicks, ed, btn, web
    return "clicks=" clicks "`nwebclicks=" webClicks "`nedithwnd=" ed.Hwnd
        . "`nbtnhwnd=" btn.Hwnd "`nwebhwnd=" web "`n"
}
TargetServe("engine-hybrid-selftest", StateLines, g)
