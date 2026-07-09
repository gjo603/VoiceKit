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
;  Small floating-bar helpers (shared by the REC bar and the
;  loop bar — both are caption-less +AlwaysOnTop ToolWindows).
; ------------------------------------------------------------

; Position a floating bar at the bottom-left of the primary monitor's
; WORK area (i.e. clear of the taskbar — A_ScreenHeight would sit over it).
; The bar is realized hidden first so its auto-sized height is known.
ShowBottomLeft(bar, margin := 12) {
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    bar.Show("NoActivate Hide")
    bar.GetPos( , , , &h)
    bar.Show("NoActivate x" (l + margin) " y" (b - h - margin))
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
}
