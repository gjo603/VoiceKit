#Requires AutoHotkey v2.0
#SingleInstance Force
; The pretend browser the Browser.ahk test drives. A SEPARATE process
; (same rule as the UIA target), emulating exactly the browser behaviors
; the helpers are built around:
;   ^l     -> focuses the "omnibox" edit and selects its content
;   Esc    -> returns focus to the "page"
;   Enter  -> (only while the omnibox is focused) "navigates": keeps the
;             typed URL, or swaps in an error-page URL when it contains
;             "unreachable" — so BrowserEnsureDomain's failure path is
;             stageable
; Its hotkeys are hook hotkeys (#HotIf), which only hear synthetic input
; at SendLevel >= 1 — that is why the helpers send at level 1.

#Include "%A_ScriptDir%\_target.ahk"

pageText := ""
Loop 20
    pageText .= "This is line " A_Index " of the pretend page content, padding the grab well past the URL-shaped threshold.`r`n"

g := Gui("+AlwaysOnTop", "VKBrowserTarget_ZZ")
g.AddText("w520", "Address")
omni := g.AddEdit("w520", "https://example.com/things")
g.AddText("w520", "Search")
searchEd := g.AddEdit("w520")
g.AddText("w520", "Locked")
lockedEd := g.AddEdit("w520 ReadOnly", "cannot type here")
; A field that throws focus elsewhere the moment it gets it — the "click
; landed, Esc moved focus, the text went into the wrong control" incident,
; staged: whatever is typed "into" Decoy ends up in Sink, and Decoy stays
; EMPTY. A verifier that reads an empty target as "can't tell" and falls
; back to copying the focused control would call that a success.
g.AddText("w520", "Decoy")
decoyEd := g.AddEdit("w520")
g.AddText("w520", "Sink")
sinkEd := g.AddEdit("w520")
decoyEd.OnEvent("Focus", (*) => sinkEd.Focus())
g.AddText("w520", "Page")
pageEd := g.AddEdit("w520 h180 Multi", pageText)
g.Show()
pageEd.Focus()

OmniFocused() {
    try {
        cn := ControlGetFocus("ahk_id " g.Hwnd)
        return cn != "" && ControlGetHwnd(cn, "ahk_id " g.Hwnd) = omni.Hwnd
    }
    return false
}

Navigate() {
    global
    url := omni.Value
    if InStr(url, "unreachable")
        omni.Value := "https://error.local/cant-reach"
    pageEd.Focus()
}

#HotIf WinActive("VKBrowserTarget_ZZ")
^l:: {
    omni.Focus()
    SendMessage(0xB1, 0, -1, omni)         ; EM_SETSEL: select all, no Send
}
; Esc and Enter act ONLY while the address bar has focus — as in a real
; browser, where Esc reverts the omnibox and hands the page back, but Esc
; inside a page input does not move focus. (An earlier version fired Esc
; unconditionally: BrowserTypeVerified's dismiss-the-dropdown Esc then
; bounced focus to the page, the typing landed there, and a
; clipboard-only readback happily reported success — which is how
; UiaValueOnly verification got added to the helper.)
#HotIf WinActive("VKBrowserTarget_ZZ") && OmniFocused()
Esc:: pageEd.Focus()
Enter:: Navigate()
#HotIf

StateLines() {
    global omni, searchEd, sinkEd, decoyEd
    return "omni=" omni.Value "`nsearch=" searchEd.Value "`nsink=" sinkEd.Value "`ndecoy=" decoyEd.Value
        . "`nomnihwnd=" omni.Hwnd "`n"
}
TargetServe("browser-selftest", StateLines, g)
