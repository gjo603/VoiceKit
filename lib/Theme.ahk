#Requires AutoHotkey v2.0
; ============================================================
;  Theme.ahk — one modern look for every VoiceKit window.
;
;  Goals:
;    - Follow the Windows light/dark setting automatically, and
;      give every window a matching (light or dark) title bar.
;    - Make native controls look Windows-11-modern WITHOUT
;      replacing them, so every button stays voice-clickable
;      (Voice Access reads a native button's caption; a custom
;      owner-drawn button has no such name). This is a hard
;      VoiceKit design rule — see README / CLAUDE.md.
;
;  Usage (once, right before Gui.Show()):
;      ThemeApply(myGui)                 ; themes the whole window
;      pal := ThemePalette()             ; colors, if you need them
;
;  Everything degrades to a plain (still usable) window if any of
;  the undocumented uxtheme calls fail on an older build.
;
;  Colors are stored as 0xRRGGBB (what AHK's BackColor/SetFont want);
;  the Win32 GDI calls need 0x00BBGGRR, so ThemeBGR() swaps them.
; ============================================================

; --- module state (brushes must outlive the windows that use them) ---
global _themePal := 0
global _themeBrush := 0          ; solid brush for dark edit/list backgrounds
global _themeThemed := Map()     ; control hwnd -> role, for the color hook
global _themeHooked := false

; True when Windows is set to "Dark" for apps.
ThemeIsDark() {
    try return RegRead("HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme") = 0
    return false
}

; The user's Windows accent color as 0xRRGGBB (registry stores 0xAABBGGRR).
ThemeAccent() {
    try {
        v := RegRead("HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM", "AccentColor")
        return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
    }
    return 0x2D7D9A
}

; Swap 0xRRGGBB <-> 0x00BBGGRR (COLORREF, what GDI wants).
ThemeBGR(rgb) {
    return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
}

; Palette for the current mode. Pass true/false to force one (used by
; the render test harness); default -1 = follow Windows.
ThemePalette(forceDark := -1) {
    dark := (forceDark = -1) ? ThemeIsDark() : forceDark
    if dark
        return {dark: true
            , win:    0x202124     ; window background
            , card:   0x2B2D31     ; list / edit background
            , text:   0xF2F2F2     ; primary text
            , dim:    0x9AA0A6     ; secondary / status text
            , accent: ThemeAccent()}
    return {dark: false
        , win:    0xF3F3F3
        , card:   0xFFFFFF
        , text:   0x1A1A1A
        , dim:    0x5F6368
        , accent: ThemeAccent()}
}

; Dark or light title bar to match (Win10 1809+/Win11). No-op on failure.
ThemeTitleBar(hwnd, dark) {
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 20, "int*", dark ? 1 : 0, "int", 4)
}

; Round the window's corners (Win11: DWMWA_WINDOW_CORNER_PREFERENCE=33,
; DWMWCP_ROUND=2). Captioned top-level windows are already round on Win11;
; this matters for the caption-less floating bars, which stay square without
; it. Harmless no-op on Win10.
ThemeRound(hwnd) {
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 33, "int*", 2, "int", 4)
}

; Give a Text control the dim, secondary color (captions, hints, taglines).
ThemeDim(ctrl) {
    pal := ThemePalette()
    ctrl.Opt("c" Format("{:06X}", pal.dim))
}

; Let this process render controls in dark mode. SetPreferredAppMode is
; exported by ordinal only (135), so resolve it by hand. Undocumented but
; stable on Win10 1903+ / Win11; wrapped in try so it's a safe no-op.
ThemeAppMode(dark) {
    static done := false
    try {
        h := DllCall("GetModuleHandle", "str", "uxtheme", "ptr")
        if !h
            h := DllCall("LoadLibrary", "str", "uxtheme", "ptr")
        p := DllCall("GetProcAddress", "ptr", h, "ptr", 135, "ptr")   ; SetPreferredAppMode
        if p
            DllCall(p, "int", dark ? 2 : 0)   ; 2 = ForceDark, 0 = Default
        DllCall("GetProcAddress", "ptr", h, "ptr", 136, "ptr")        ; FlushMenuThemes (best effort)
    }
}

; Apply a control's visual theme class (dark scrollbars/borders/buttons).
ThemeClass(hwnd, cls) {
    try DllCall("uxtheme\SetWindowTheme", "ptr", hwnd, "str", cls, "ptr", 0)
}

; ------------------------------------------------------------
;  Main entry: theme an entire window and its controls.
;  statusCtrl (optional): a Text control used as a status line,
;  which gets the dimmer secondary color.
; ------------------------------------------------------------
ThemeApply(g, statusCtrl := 0, forceDark := -1) {
    global _themePal, _themeBrush, _themeThemed, _themeHooked
    pal := ThemePalette(forceDark)
    _themePal := pal
    ThemeAppMode(pal.dark)

    g.BackColor := pal.win
    ThemeTitleBar(g.Hwnd, pal.dark)
    ThemeRound(g.Hwnd)

    if (pal.dark && !_themeBrush)
        _themeBrush := DllCall("gdi32\CreateSolidBrush", "uint", ThemeBGR(pal.card), "ptr")

    for hwnd, ctrl in g {
        switch ctrl.Type {
            case "Button", "CheckBox", "Radio":
                ThemeClass(ctrl.Hwnd, pal.dark ? "DarkMode_Explorer" : "Explorer")
            case "Edit":
                ThemeClass(ctrl.Hwnd, pal.dark ? "DarkMode_Explorer" : "Explorer")
                _themeThemed[ctrl.Hwnd] := "edit"
            case "DDL", "ComboBox":
                ThemeClass(ctrl.Hwnd, pal.dark ? "DarkMode_CFD" : "Explorer")
            case "ListView", "ListBox":
                ThemeListView(ctrl, pal)
            case "Text", "Link":
                ctrl.Opt("c" Format("{:06X}", ctrl = statusCtrl ? pal.dim : pal.text))
        }
    }

    if !_themeHooked {
        OnMessage(0x0133, ThemeOnColor)   ; WM_CTLCOLOREDIT
        OnMessage(0x0138, ThemeOnColor)   ; WM_CTLCOLORSTATIC (read-only edits)
        _themeHooked := true
    }
}

; ListView: background/text colors + dark-themed rows and header.
ThemeListView(lv, pal) {
    ThemeClass(lv.Hwnd, pal.dark ? "DarkMode_Explorer" : "Explorer")
    SendMessage(0x1001, 0, ThemeBGR(pal.card), , "ahk_id " lv.Hwnd)   ; LVM_SETBKCOLOR
    SendMessage(0x1026, 0, ThemeBGR(pal.card), , "ahk_id " lv.Hwnd)   ; LVM_SETTEXTBKCOLOR
    SendMessage(0x1024, 0, ThemeBGR(pal.text), , "ahk_id " lv.Hwnd)   ; LVM_SETTEXTCOLOR
    hHdr := SendMessage(0x101F, 0, 0, , "ahk_id " lv.Hwnd)            ; LVM_GETHEADER
    if hHdr
        ThemeClass(hHdr, pal.dark ? "DarkMode_Explorer" : "Explorer")
}

; Paint dark backgrounds for edit controls (the theme class alone leaves
; their interior white). Light mode falls through to default painting.
ThemeOnColor(wParam, lParam, msg, hwnd) {
    global _themePal, _themeThemed, _themeBrush
    if (!IsObject(_themePal) || !_themePal.dark || !_themeThemed.Has(lParam) || !_themeBrush)
        return
    DllCall("gdi32\SetTextColor", "ptr", wParam, "uint", ThemeBGR(_themePal.text))
    DllCall("gdi32\SetBkColor",  "ptr", wParam, "uint", ThemeBGR(_themePal.card))
    return _themeBrush
}

; ------------------------------------------------------------
;  Show a themed dialog MODALLY and wait until it closes — the one
;  copy of a tail that used to be hand-typed in every GUI (four of
;  those copies had the dialog-lifetime bug below).
;    owner      Gui (or hwnd) disabled while the dialog is up, then
;               re-enabled and refocused. 0 = none.
;    dims       a control, or an Array, to give the dim caption color —
;               applied AFTER ThemeApply, which recolors every Text
;               control (a ThemeDim before it would be overwritten). A
;               function in the list is called at that point instead,
;               for any other post-theme touch (an accent-colored phrase).
;    focusCtrl  control to put the caret in once shown.
;    showOpts   Gui.Show options — or a function(d) that places and
;               shows the dialog itself (ShowBottomRight).
;    statusCtrl passed to ThemeApply (its dim status line).
;  Every hwnd is read BEFORE Show: a fast Enter or a voice click on the
;  Default button can destroy the Gui the instant it appears, and a
;  property read on a destroyed Gui throws "Gui has no window" (the
;  dialog-lifetime trap in CLAUDE.md). The owner is re-enabled in a
;  finally, so nothing that throws in between leaves it disabled.
; ------------------------------------------------------------
ThemeShowModal(d, owner := 0, dims := "", focusCtrl := 0, showOpts := "", statusCtrl := 0) {
    ThemeApply(d, statusCtrl)
    if IsObject(dims) {
        for c in (dims is Array ? dims : [dims]) {
            if (c is Func)
                c()
            else if IsObject(c)
                ThemeDim(c)
        }
    }
    hwnd := d.Hwnd
    fHwnd := focusCtrl ? focusCtrl.Hwnd : 0
    oHwnd := !owner ? 0 : IsObject(owner) ? owner.Hwnd : owner
    disabled := false
    try {
        if (showOpts is Func)
            showOpts(d)
        else
            d.Show(showOpts)
        if oHwnd {
            try WinSetEnabled(false, "ahk_id " oHwnd)
            disabled := true
        }
        try WinActivate("ahk_id " hwnd)
        if fHwnd
            try ControlFocus(fHwnd, "ahk_id " hwnd)
        WinWaitClose("ahk_id " hwnd)          ; an already-gone hwnd simply returns
    } finally {
        if disabled {
            try WinSetEnabled(true, "ahk_id " oHwnd)
            try WinActivate("ahk_id " oHwnd)
        }
    }
}

; ------------------------------------------------------------
;  Small floating-bar helpers (shared by the REC bar and the
;  loop bar — both are caption-less +AlwaysOnTop ToolWindows).
; ------------------------------------------------------------

; Position a floating bar at the bottom-left of the primary monitor's
; WORK area (i.e. clear of the taskbar — A_ScreenHeight would sit over it).
; The bar is realized hidden first so its auto-sized height is known.
; Measured/moved with WinGetPos/WinMove, which use PHYSICAL pixels like
; MonitorGetWorkArea — Gui.GetPos returns DPI-scaled units, and mixing the
; two sat the bar on top of the taskbar on >100%-DPI displays.
; All three placement helpers read the Gui's HWND once, BEFORE any Show (the
; dialog-lifetime trap in CLAUDE.md), and pass it BARE: a pure HWND finds the
; still-hidden window whatever DetectHiddenWindows says; "ahk_id " would not.
ShowBottomLeft(bar, margin := 12) {
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    hwnd := bar.Hwnd                        ; captured BEFORE Show (dialog-lifetime trap)
    bar.Show("NoActivate Hide")
    try {
        WinGetPos(, , , &h, hwnd)
        WinMove(l + margin, b - h - margin, , , hwnd)
    }
    bar.Show("NoActivate")
}

; Center a floating bar at the bottom of the work area (the Wispr-style
; pill position). Activates the bar, unlike ShowBottomLeft — bars shown
; here take typed/dictated input.
ShowBottomCenter(bar, margin := 16) {
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    hwnd := bar.Hwnd                        ; captured BEFORE Show (dialog-lifetime trap)
    bar.Show("Hide")
    try {
        WinGetPos(, , &w, &h, hwnd)
        WinMove(l + ((r - l - w) // 2), b - h - margin, , , hwnd)
    }
    bar.Show()
}

; Bottom-right corner of the work area — for input dialogs that must not
; cover a document the user is reading (Split Pages). Activates, like
; ShowBottomCenter, because the user types into it.
ShowBottomRight(bar, margin := 16) {
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    hwnd := bar.Hwnd                        ; captured BEFORE Show (dialog-lifetime trap)
    bar.Show("Hide")
    try {
        WinGetPos(, , &w, &h, hwnd)
        WinMove(r - w - margin, b - h - margin, , , hwnd)
    }
    bar.Show()
}

; Theme a caption-less status bar: window background, a primary-color text
; control, a dim text control, and a native button (kept native so it stays
; voice-clickable). ThemeTitleBar is a no-op on a -Caption window.
ThemeBar(bar, textCtrl, dimCtrl, btnCtrl) {
    pal := ThemePalette()
    bar.BackColor := pal.win
    textCtrl.Opt("c" Format("{:06X}", pal.text))
    dimCtrl.Opt("c" Format("{:06X}", pal.dim))
    ThemeClass(btnCtrl.Hwnd, pal.dark ? "DarkMode_Explorer" : "Explorer")
    ThemeTitleBar(bar.Hwnd, pal.dark)
    ThemeRound(bar.Hwnd)
}
