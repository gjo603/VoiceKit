#Requires AutoHotkey v2.0
; Exercises lib\Browser.ahk against a pretend browser in ANOTHER process
; (browser-selftest-target.ahk) — never a real one. Each check restages a
; real incident from the web-scraping session: the stranded-omnibox
; grab, the query-into-Google keystroke leak, the blind type-then-Enter.
#Include "%A_ScriptDir%\..\lib\Browser.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("browser-selftest")

; ---- bring up the pretend browser, pinned to its fresh PID ------------
if !(hwnd := TargetLaunch("browser-selftest-target.ahk", "VKBrowserTarget_ZZ"))
    ExitApp(1)
Say("target up, hwnd=" hwnd)

; ---- BrowserUrl -------------------------------------------------------
A_Clipboard := "sentinel-clip-zz"
Say("about to: BrowserUrl")
url := BrowserUrl(hwnd)
Check("BrowserUrl reads the omnibox", url = "https://example.com/things", "got '" url "'")
Check("...and restores the clipboard", A_Clipboard = "sentinel-clip-zz")
Check("BrowserUrl of a dead hwnd is empty", BrowserUrl(0) = "")

; ---- BrowserGrabPage: plain, then the stranded-omnibox incident -------
Say("about to: BrowserGrabPage (focus on the page)")
txt := BrowserGrabPage(hwnd)
Check("grab returns the page text", InStr(txt, "line 3 of the pretend page") > 0)
Check("grab is longer than the URL threshold", StrLen(txt) >= 400, StrLen(txt) " chars")
Check("...and restores the clipboard", A_Clipboard = "sentinel-clip-zz")

Say("about to: BrowserGrabPage with focus STRANDED in the omnibox")
; Strand it the way real life does — ^l, the URL-reading keystroke, which
; leaves keyboard focus sitting in the omnibox. (Not ControlFocus: passing
; a control HWND there throws on a miss, and an uncaught throw in a test
; pops a modal dialog that reads as a timeout rather than a failure.)
if BrowserActivate(hwnd) {
    BrowserSend("^l")
    Sleep(300)
}
txt := BrowserGrabPage(hwnd)
Check("the strand is detected and retried past", InStr(txt, "line 3 of the pretend page") > 0,
    "got '" SubStr(txt, 1, 60) "...'")

Check("BrowserLooksLikeUrlOnly flags a bare URL",
    BrowserLooksLikeUrlOnly("https://example.com/x?y=1", 400) = true)
Check("BrowserLooksLikeUrlOnly passes real text",
    BrowserLooksLikeUrlOnly(txt, 400) = false)

; ---- BrowserEnsureDomain ---------------------------------------------
Say("about to: BrowserEnsureDomain (already there)")
t0 := A_TickCount
Check("already-on-domain is true", BrowserEnsureDomain(hwnd, "example.com") = true)
Check("...and quick about it", A_TickCount - t0 < 6000, (A_TickCount - t0) " ms")

Say("about to: BrowserEnsureDomain (must navigate)")
Check("navigation reaches the domain", BrowserEnsureDomain(hwnd, "other.org/page", 8000) = true)
Check("the pretend browser really navigated", InStr(TargetState("omni"), "other.org") > 0,
    "omni='" TargetState("omni") "'")

Say("about to: BrowserEnsureDomain (site can't be reached)")
Check("an unreachable domain comes back false",
    BrowserEnsureDomain(hwnd, "unreachable.zzz", 3000) = false)
Check("empty fragment is refused", BrowserEnsureDomain(hwnd, "  ") = false)

; ---- BrowserTypeVerified ---------------------------------------------
Say("about to: BrowserTypeVerified into the Search field")
Check("typing into a real field verifies true",
    BrowserTypeVerified(hwnd, "Search", "hello world search") = true)
Check("the field really holds the text", TargetState("search", "hello world search") = "hello world search",
    "got '" TargetState("search") "'")
Check("...and restores the clipboard", A_Clipboard = "sentinel-clip-zz")

Say("about to: BrowserTypeVerified into a read-only field (must fail honestly)")
Check("a field that ignores typing verifies false",
    BrowserTypeVerified(hwnd, "Locked", "nope") = false)

Say("about to: BrowserTypeVerified where the text lands in ANOTHER control")
Check("text that landed elsewhere verifies false, even though the target is empty",
    BrowserTypeVerified(hwnd, "Decoy", "misdirected zz") = false)
Check("...it really did land elsewhere (the staging worked)",
    TargetState("sink", "misdirected zz") = "misdirected zz", "sink='" TargetState("sink") "'")
Check("...and the clipboard survived that too", A_Clipboard = "sentinel-clip-zz")

Say("about to: BrowserTypeVerified on a missing field")
Check("a missing field is false, not an error",
    BrowserTypeVerified(hwnd, "No Such Field Zz", "x", 800) = false)

TargetStop()
TestEnd()
