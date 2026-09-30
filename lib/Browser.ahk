#Requires AutoHotkey v2.0
; ============================================================
;  lib\Browser.ahk — driving a web browser through its keyboard UI
;  without the four ways that reliably goes wrong.
;
;  Every helper here is a distilled incident from a real scraping
;  session (docs\feedback-web-scrape.md, theme 4):
;    - queries typed into the omnibox became GOOGLE searches, because
;      nothing checked what window/tab the keys were landing in
;      -> BrowserEnsureDomain
;    - a "page grab" captured the address bar, because ^l strands
;      keyboard focus in the omnibox and the next ^a^c copies the URL
;      -> BrowserGrabPage (retry after Esc when the grab looks like a
;         bare URL), and BrowserUrl documents the ordering trap
;    - typing into a field found by rect missed after a layout shift,
;      and the Enter that followed searched the wrong site
;      -> BrowserTypeVerified (click, type, READ IT BACK, only then
;         report true)
;
;  WHERE TO USE IT
;  In a hotkey module BODY (or a run_ahk_snippet probe) — the same
;  out-of-process rule as UIA.ahk, which this file includes itself:
;      #Include "%A_ScriptDir%\..\..\lib\Browser.ahk"
;
;  KEYBOARD OWNERSHIP
;  These helpers activate the target window and send real keystrokes
;  (^l, ^a, ^c, Esc, Enter). While one runs, the browser owns the
;  keyboard — don't interleave them with the user typing. Sends go out
;  at SendLevel 1, which real browsers can't tell apart from level 0
;  but AHK-implemented windows (the self-test's pretend browser) can
;  hear — the same reason press_hotkey sends at level 1.
;
;  THE CLIPBOARD IS ALWAYS RESTORED. Helpers that copy go through
;  lib\Clip.ahk's ClipCapture, which saves ClipboardAll first and
;  puts it back in a finally.
; ============================================================
#Include "%A_LineFile%\..\UIA.ahk"
#Include "%A_LineFile%\..\Clip.ahk"

; Send at level 1, restoring the caller's level. See header.
BrowserSend(keys) {
    prev := A_SendLevel
    SendLevel(1)
    try Send(keys)
    finally SendLevel(prev)
}

BrowserSendText(text) {
    prev := A_SendLevel
    SendLevel(1)
    try SendText(text)
    finally SendLevel(prev)
}

; Bring the browser window forward; false if it can't be. Every
; keystroke helper starts here — sending into whatever happens to be
; active is exactly the incident this lib exists to prevent.
BrowserActivate(hwnd) {
    if !WinExist("ahk_id " hwnd)
        return false
    try WinActivate("ahk_id " hwnd)
    return WinWaitActive("ahk_id " hwnd, , 2) != 0
}

; The omnibox URL, via the proven ^l ^c Esc sequence (browser-agnostic;
; UIA can't do this portably — omnibox names differ per browser and
; locale). Empty string when it can't be read. ORDERING TRAP this lib
; is built around: ^l leaves keyboard focus in the omnibox, so grab the
; PAGE first when you need both — or use BrowserGrabPage, which
; recovers on its own.
BrowserUrl(hwnd, timeoutMs := 2000) {
    if !BrowserActivate(hwnd)
        return ""
    url := ""
    try url := Trim(ClipCapture(() => (BrowserSend("^l"), Sleep(150), BrowserSend("^c"))
        , timeoutMs / 1000.0), " `t`r`n")
    finally {
        BrowserSend("{Esc}")               ; hand focus back to the page
        Sleep(100)
    }
    return url
}

; True when a grab is suspicious: empty, too short, or shaped like a
; bare URL — the signature of ^a^c fired while focus sat in the omnibox.
BrowserLooksLikeUrlOnly(text, minChars := 400) {
    t := Trim(text, " `t`r`n")
    return t = "" || StrLen(t) < minChars || RegExMatch(t, "^https?://\S+$") != 0
}

; The page's text via select-all + copy, hardened: when the first grab
; looks like a stranded-omnibox result (see above), Esc back to the
; page and try once more, then return whatever the second attempt got —
; a genuinely short page stays reportable. Clipboard restored.
BrowserGrabPage(hwnd, minChars := 400, timeoutMs := 3000) {
    if !BrowserActivate(hwnd)
        return ""
    text := ""
    Loop 2 {
        text := ClipCapture(() => (BrowserSend("^a"), Sleep(120), BrowserSend("^c"))
            , timeoutMs / 1000.0)
        if !BrowserLooksLikeUrlOnly(text, minChars)
            break
        BrowserSend("{Esc}")
        Sleep(250)
    }
    return text
}

; Make sure the window is ON a domain before any keystrokes are trusted
; to it: read the omnibox; if the fragment (case-insensitive substring,
; e.g. "example.com/listings") isn't there, navigate to it and poll
; until it is. False if the omnibox never shows it. This is the "are you
; sure?" keystroke automation doesn't naturally have.
;
; What true does NOT prove: that the page has LOADED, or loaded at all. A
; real Chromium omnibox shows the navigated URL as soon as Enter is pressed,
; and keeps the attempted URL on a "This site can't be reached" page — so
; the first poll can succeed mid-load, and an unreachable site can pass.
; (The self-test's pretend browser swaps in an error URL instead, which a
; real browser doesn't.) When it matters, follow this with a check for
; landmark text only the real page carries — UiaTextPresent(hwnd, ...).
BrowserEnsureDomain(hwnd, fragment, timeoutMs := 15000) {
    fragment := Trim(fragment)
    if (fragment = "")
        return false
    if InStr(BrowserUrl(hwnd), fragment)
        return true
    if !BrowserActivate(hwnd)
        return false
    BrowserSend("{Esc}")                   ; close anything that eats keys
    Sleep(100)
    BrowserSend("^l")
    Sleep(150)
    BrowserSendText(RegExMatch(fragment, "^https?://") ? fragment : "https://" fragment)
    Sleep(100)
    BrowserSend("{Enter}")
    deadline := A_TickCount + timeoutMs
    loop {
        Sleep(500)
        if InStr(BrowserUrl(hwnd), fragment)
            return true
        if (A_TickCount >= deadline)
            return false
    }
}

; Type into a NAMED field and prove it landed. Finds the field over UIA
; (UiaFindEdit first — the label and its input share one accessible
; name, and the label must not win), clicks it for real (rect-Invoke
; misses after layout shifts, and Invoke focuses nothing), Esc to close
; any password-manager dropdown (they eat Enter/Tab), select-all, type,
; then READS THE FIELD BACK — true only when it holds `text` exactly.
; On false, fall back rather than pressing Enter blind: a blind Enter
; after a missed click is how queries end up on Google.
;
; Verification asks the ELEMENT, not the keyboard: UiaValueOnly reads the
; control we aimed at, so a click that missed (or an Esc that moved focus
; in this particular app) fails instead of passing on the strength of
; text that landed somewhere else. Measured — the clipboard-only version
; of this check reported success while typing into the wrong control.
; Controls with no ValuePattern (plenty of web inputs) still fall back to
; select-all + copy, which is the field-proven recipe. The clipboard is
; restored; the field is left with its text selected.
;
; A field that HAS a ValuePattern is judged by it even when it reads EMPTY:
; an empty target is precisely what a missed click leaves behind, and the
; old "empty -> try the clipboard" fallback then copied whatever control
; had focus — the one the text really landed in — and reported success.
; One short re-read allows for controls that publish their value a beat
; after the keystrokes.
BrowserTypeVerified(hwnd, elementName, text, timeoutMs := 3000) {
    el := UiaFindEdit(hwnd, elementName, timeoutMs)
    if (el = "")
        el := UiaFind(hwnd, elementName, 800)
    if (el = "")
        return false
    if !BrowserActivate(hwnd)
        return false
    if !UiaClickEl(el)
        return false
    Sleep(150)
    BrowserSend("{Esc}")
    Sleep(100)
    BrowserSend("^a")
    Sleep(80)
    BrowserSendText(text)
    Sleep(200)
    v := UiaValueOnly(el, &hasValue)
    if hasValue {
        if (v == text)
            return true
        Sleep(250)
        return UiaValueOnly(el) == text
    }
    got := ClipCapture(() => (BrowserSend("^a"), Sleep(80), BrowserSend("^c")), 2)
    return Trim(got, "`r`n") == text
}
