#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Ask AI — say "open ask ai", then speak (or type) a question.
;
;  A slim Wispr-style bar appears at the bottom of the screen;
;  the answer is TYPED into the app you were just using, and the
;  bar disappears. If there's no app to type into, the answer is
;  shown with a Copy button instead.
;
;  Voice: dictate into the box, then say "click ask".
;  Keyboard: type, Enter. Escape closes.
;
;  Needs an OpenRouter key (AI Settings opens itself if missing).
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"
#Include "%A_ScriptDir%\..\lib\AI.ahk"

prevWin := AIUsableTargetWin(WinExist("A"))   ; 0 if it's a shell host / VoiceKit window

if !AIEnsureConfigured()
    ExitApp()

prevDesc := ""
if prevWin {
    try prevDesc := WinGetTitle(prevWin)
    if (prevDesc = "")
        try prevDesc := WinGetProcessName(prevWin)
}

; ---- the bar ----
bar := Gui("+AlwaysOnTop +ToolWindow -Caption +Border", "Ask AI")
bar.MarginX := 16, bar.MarginY := 12
bar.SetFont("s10 bold", "Segoe UI")
bar.AddText("ym+7", "✦  Ask AI")
bar.SetFont("s11 norm", "Segoe UI")
edQ := bar.AddEdit("x+14 ym w520")
bar.SetFont("s10 bold", "Segoe UI")
btnAsk := bar.AddButton("x+10 ym w92 h34 Default", "Ask")
bar.SetFont("s10 norm", "Segoe UI")
btnClose := bar.AddButton("x+6 ym w88 h34", "Close")
bar.SetFont("s9", "Segoe UI")
hint := bar.AddText("xm y+9 w748", prevDesc != ""
    ? "The answer will be typed into:  " Abbrev(prevDesc, 60) "    (Enter asks — Escape closes)"
    : "The answer will be shown with a Copy button.    (Enter asks — Escape closes)")

DoAsk(*) {
    q := Trim(edQ.Value)
    if (q = "")
        return
    edQ.Enabled := false
    btnAsk.Enabled := false
    hint.Text := "Thinking…"
    err := ""
    ans := AIComplete("You are a fast helper summoned by voice on Windows. Reply with plain text only — "
        . "no markdown, no code fences, no headings — because your reply is typed directly into whatever "
        . "application the user was using. Be concise and directly useful: give the answer itself, not commentary."
        , q, &err)
    if (ans = "") {
        hint.Text := err != "" ? Abbrev(err, 110) : "No answer came back — try again."
        edQ.Enabled := true
        btnAsk.Enabled := true
        edQ.Focus()
        return
    }
    delivered := false
    if (prevWin && WinExist("ahk_id " prevWin)) {
        bar.Hide()
        try {
            WinActivate("ahk_id " prevWin)
            WinWaitActive("ahk_id " prevWin, , 2)
        }
        if WinActive("ahk_id " prevWin) {
            SendText(ans)
            delivered := true
        }
    }
    if delivered
        ExitApp()
    ShowAnswer(q, ans)
}

ShowAnswer(q, ans) {
    global bar
    bar.Hide()
    w := Gui("+AlwaysOnTop", "Ask AI")
    w.SetFont("s10", "Segoe UI")
    w.MarginX := 18, w.MarginY := 16
    qLine := w.AddText("xm w560", Abbrev(q, 90))
    w.SetFont("s10")
    w.AddEdit("xm y+8 w560 r12 +ReadOnly +Wrap +VScroll", ans)
    btnCopy := w.AddButton("xm y+12 w130 h34 Default", "Copy")
    btnDone := w.AddButton("x+8 w130 h34", "Close")
    st := w.AddText("x+12 yp+8 w260", "")
    btnCopy.OnEvent("Click", (*) => (A_Clipboard := ans, st.Text := "Copied ✓"))
    btnDone.OnEvent("Click", (*) => ExitApp())
    w.OnEvent("Close", (*) => ExitApp())
    w.OnEvent("Escape", (*) => ExitApp())
    ThemeApply(w, st)
    ThemeDim(qLine)
    w.Show()
    btnCopy.Focus()
}

btnAsk.OnEvent("Click", DoAsk)
btnClose.OnEvent("Click", (*) => ExitApp())
bar.OnEvent("Close", (*) => ExitApp())
bar.OnEvent("Escape", (*) => ExitApp())

ThemeApply(bar)
ThemeDim(hint)
ThemeRound(bar.Hwnd)
ShowBottomCenter(bar)
edQ.Focus()

Abbrev(s, n) {
    return StrLen(s) > n ? SubStr(s, 1, n) "..." : s
}
