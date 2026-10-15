#Requires AutoHotkey v2.0
; Exercises EVERY vtable offset in lib\UIA.ahk against a window in ANOTHER
; process (uia-selftest-target.ahk).
;
; Two reasons for the separate process:
;   1. UIA against your OWN process can deadlock — measured, and the reason
;      an earlier single-process version of this test hung.
;   2. Automating a different app is what modules actually do.
;
; A wrong offset is an access violation, not a catchable error, so this logs
; "about to <call>" BEFORE each one: if the process dies, the last line names
; the call that killed it.
#Include "%A_ScriptDir%\..\lib\UIA.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("uia-selftest")

Say("about to: create IUIAutomation")
Check("UIA is available", UiaAvailable() = true)
if !UiaAvailable() {
    Say("`nUIA UNAVAILABLE — nothing else can run")
    ExitApp(0)
}

; ---- bring up the target process (pinned to its fresh PID) ------------
if !(hwnd := TargetLaunch("uia-selftest-target.ahk", "VKUiaTarget_ZZ", &tpid))
    ExitApp(1)
Say("target up, hwnd=" hwnd)

; ---- IUIAutomation slots ---------------------------------------------
Say("about to: ElementFromHandle (IUIAutomation slot 6)")
root := UiaFromWindow(hwnd)
Check("ElementFromHandle returns an element", root != "")

Say("about to: get_CurrentName (Element slot 23)")
rootName := UiaName(root)
Check("window element reports its Name", InStr(rootName, "VKUiaTarget_ZZ") > 0, "name=" rootName)

Say("about to: CreatePropertyCondition (IUIAutomation slot 23)")
cond := UiaPropCondition(UIA_PROP_NAME(), "Press Me Zz")
Check("CreatePropertyCondition returns a condition", cond != "")

Say("about to: FindFirst (Element slot 5)")
el := UiaFindFirst(root, cond, UIA_SCOPE_SUBTREE())
Check("FindFirst locates the button", el != "")
Check("found element has the right Name", UiaName(el) = "Press Me Zz", "got=" UiaName(el))

Say("about to: UiaFind (find-by-name with retry)")
Check("UiaFind locates the button", UiaFind(hwnd, "Press Me Zz", 3000) != "")

Say("about to: get_CurrentBoundingRectangle (Element slot 43)")
r := UiaRect(el)
WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
Check("BoundingRectangle is a sane on-screen rect",
    IsObject(r) && r.w > 10 && r.h > 5 && r.x >= wx - 40 && r.x < wx + ww + 40,
    IsObject(r) ? "x=" r.x " y=" r.y " w=" r.w " h=" r.h : "no rect")

Say("about to: get_CurrentIsEnabled (Element slot 28)")
Check("button reports enabled", UiaEnabled(el) = true)

Say("about to: get_CurrentAutomationId (Element slot 29)")
aid := UiaAutomationId(el)
Check("AutomationId readable (blank is fine for Win32)", aid = aid, "id='" aid "'")

Say("about to: ElementFromPoint (IUIAutomation slot 7)")
pt := UiaFromPoint(r.x + r.w // 2, r.y + r.h // 2)
Check("ElementFromPoint hits the button", pt != "" && UiaName(pt) = "Press Me Zz",
    "got=" (pt != "" ? UiaName(pt) : "nothing"))

Say("about to: SetFocus (Element slot 3)")
Check("SetFocus succeeds", UiaFocus(el) = true)
Sleep(300)

Say("about to: GetFocusedElement (IUIAutomation slot 8)")
foc := UiaFocused()
Check("GetFocusedElement returns something", foc != "", "name=" (foc != "" ? UiaName(foc) : "-"))

; ---- patterns ---------------------------------------------------------
Say("about to: GetCurrentPattern + Invoke (Element 16, InvokePattern 3)")
before := Integer(TargetState("clicks"))
Check("UiaInvoke reports success", UiaInvoke(el) = true)
Sleep(700)
after := Integer(TargetState("clicks"))
Check("the target's click handler actually ran", after = before + 1,
    "clicks " before " -> " after)

; Address the edit by its own HWND rather than by name: UIA gives the static
; label and the edit beside it the same name, and finding the label instead
; is a real trap worth not papering over.
Say("about to: ElementFromHandle on a CHILD control, then ValuePattern (slot 4)")
edEl := UiaFromWindow(Integer(TargetState("edithwnd")))
Check("ElementFromHandle works on a child control", edEl != "")
val := UiaValue(edEl)
Check("ValuePattern reads the edit's text", val = "original value", "got='" val "'")

; UiaValueOnly is the VERIFYING read: no Name fallback, so a check can
; never be satisfied by an element's label (lib\Browser.ahk relies on it).
Check("UiaValueOnly reads the edit's real value", UiaValueOnly(edEl) = "original value",
    "got '" UiaValueOnly(edEl) "'")
Check("UiaValueOnly of a pattern-less element is empty, NOT its name",
    UiaValueOnly(el) = "", "got '" UiaValueOnly(el) "'")
Check("UiaValueOnly of nothing is empty", UiaValueOnly("") = "")
; The &has out-param separates "empty box" from "no ValuePattern at all" —
; BrowserTypeVerified must judge an empty target by its pattern, not by
; copying whatever control happens to have focus.
UiaValueOnly(edEl, &hasEd)
Check("UiaValueOnly's &has is true for an element with a ValuePattern", hasEd = true)
UiaValueOnly(el, &hasBtn)
Check("...and false for one without", hasBtn = false)

; IsPassword (Element slot 35) — the fill step skips reading a password box
; back, so a wrong answer here either leaks a readback attempt or skips a
; real verification. Proved both ways against a real ES_PASSWORD edit.
Say("about to: get_CurrentIsPassword (Element slot 35)")
pwEl := UiaFromWindow(Integer(TargetState("pwhwnd")))
Check("the password edit is reachable", pwEl != "")
Check("IsPassword is true for a password edit", UiaIsPassword(pwEl) = true)
Check("...and false for a plain edit", UiaIsPassword(edEl) = false)
Check("...and false for a button", UiaIsPassword(el) = false)
Check("UiaIsPassword of nothing is false", UiaIsPassword("") = false)

; CompareElements (IUIAutomation slot 3) — the fill step's focus gate asks
; "is the focused element the box I clicked?", and two finds of one control
; are two different wrapper objects.
Say("about to: CompareElements (IUIAutomation slot 3)")
edAgain := UiaFindEdit(hwnd, "Name Field", 2000)
Check("two finds of one edit are the SAME element", UiaSameElement(edEl, edAgain) = true)
Check("...an edit and a button are not", UiaSameElement(edEl, el) = false)
Check("...the edit and the password box are not", UiaSameElement(edEl, pwEl) = false)
Check("UiaSameElement with nothing is false", UiaSameElement(edEl, "") = false)
Check("the focused element compares equal after SetFocus",
    UiaFocus(edEl) && (Sleep(300), UiaSameElement(UiaFocused(), edEl)) = true)

Say("about to: ValuePattern SetValue (slot 3)")
Check("SetValue reports success", UiaSetValue(edEl, "set by uia") = true)
Sleep(700)
Check("the target's edit really changed", TargetState("edit", "set by uia") = "set by uia",
    "target says '" TargetState("edit") "'")

; ---- misses must be quiet, not fatal ---------------------------------
Say("about to: UiaFind for something that does not exist")
t0 := A_TickCount
Check("a miss returns empty rather than throwing", UiaFind(hwnd, "No Such Xyz Zz", 1200) = "")
Check("a miss respects its timeout", A_TickCount - t0 < 5000, (A_TickCount - t0) " ms")
Check("UiaName of nothing is empty", UiaName("") = "")
Check("UiaRect of nothing is empty", UiaRect("") = "")
Check("UiaInvoke of nothing is false", UiaInvoke("") = false)
Check("UiaValue of nothing is empty", UiaValue("") = "")
Check("UiaSetValue of nothing is false", UiaSetValue("", "x") = false)
Check("UiaFromWindow(0) is empty", UiaFromWindow(0) = "")
Check("UiaFindById on a missing id is empty", UiaFindById(hwnd, "no.such.id.zz", 800) = "")

Say("about to: UiaClickName convenience wrapper")
before := Integer(TargetState("clicks"))
Check("UiaClickName presses by name", UiaClickName(hwnd, "Press Me Zz", 2000) = true)
Sleep(700)
after := Integer(TargetState("clicks"))
Check("UiaClickName's press reached the target", after = before + 1,
    "clicks " before " -> " after)

; ---- FindAll + the label-vs-input trap --------------------------------
; The target is laid out as a Text above an Edit, which is how every real
; form is laid out — and both report the SAME accessible name. FindFirst
; hands back the label, and UiaValue on a label falls back to its name, so
; nothing about the returned element says "you got the wrong one". That is
; what UiaFindAll / occurrence / UiaFindEdit exist to fix.
Say("about to: CreateTrueCondition (IUIAutomation slot 21)")
tcond := UiaTrueCondition()
Check("CreateTrueCondition returns a condition", tcond != "")

Say("about to: FindAll (Element slot 6) + ElementArray get_Length/GetElement (3, 4)")
everything := UiaFindElements(root, tcond, UIA_SCOPE_SUBTREE(), 200)
Check("FindAll walks the whole subtree", everything.Length >= 4, "got " everything.Length)

Say("about to: get_CurrentControlType (Element slot 21)")
Check("ControlType of the button is Button", UiaControlType(el) = UIA_TYPE_BUTTON(),
    "got " UiaControlType(el))

Say("about to: UiaFindAll by name")
both := UiaFindAll(hwnd, "Name Field", 2000)
Check("one name matches BOTH the label and the edit", both.Length = 2, "got " both.Length)

Say("about to: UiaFind occurrence 1 vs 2")
first := UiaFind(hwnd, "Name Field", 2000)
second := UiaFind(hwnd, "Name Field", 2000, 2)
Check("occurrence 1 is the label, not the box", UiaControlType(first) = UIA_TYPE_TEXT(),
    "type=" UiaControlType(first))
Check("occurrence 2 reaches the second match", UiaControlType(second) = UIA_TYPE_EDIT(),
    "type=" UiaControlType(second))
Check("the label's VALUE hides the mistake (falls back to its name)",
    UiaValue(first) = "Name Field", "got '" UiaValue(first) "'")
Check("an occurrence past the end is empty, not an error",
    UiaFind(hwnd, "Name Field", 600, 99) = "")

Say("about to: UiaIntCondition + UiaAndCondition (IUIAutomation slot 25) via UiaFindEdit")
edByName := UiaFindEdit(hwnd, "Name Field", 2000)
Check("UiaFindEdit returns the Edit, not the label",
    edByName != "" && UiaControlType(edByName) = UIA_TYPE_EDIT(),
    "type=" (edByName != "" ? UiaControlType(edByName) : "nothing"))
Check("and it is the box with the real content", UiaValue(edByName) = "set by uia",
    "got '" UiaValue(edByName) "'")     ; SetValue above changed it
Check("UiaFindOfType with a type nothing matches is empty",
    UiaFindOfType(hwnd, "Name Field", UIA_TYPE_CHECKBOX(), 600) = "")

; ---- reading the window's text ----------------------------------------
Say("about to: UiaTextPresent")
Check("UiaTextPresent finds a substring of a Value", UiaTextPresent(hwnd, "set by ui", 2000) = true)
Check("UiaTextPresent is case-insensitive", UiaTextPresent(hwnd, "PRESS ME ZZ", 2000) = true)
t0 := A_TickCount
Check("UiaTextPresent says false for absent text", UiaTextPresent(hwnd, "no such text zz", 800) = false)
Check("...and respects its timeout", A_TickCount - t0 < 5000, (A_TickCount - t0) " ms")

Say("about to: UiaDumpText")
dump := UiaDumpText(hwnd)
Check("UiaDumpText contains the button caption", InStr(dump, "Press Me Zz") > 0)
Check("UiaDumpText contains the edit's content", InStr(dump, "set by uia") > 0)
Check("UiaDumpText honours maxChars", StrLen(UiaDumpText(hwnd, 12)) <= 12,
    "len=" StrLen(UiaDumpText(hwnd, 12)))

; ---- a real mouse click, not Invoke -----------------------------------
Say("about to: UiaClickCenter (mouse click at the element, with jitter)")
before := Integer(TargetState("clicks"))
Check("UiaClickCenter reports success", UiaClickCenter(hwnd, "Press Me Zz", 2000, 3) = true)
Sleep(700)
after := Integer(TargetState("clicks"))
Check("the jittered click landed on the button", after = before + 1,
    "clicks " before " -> " after)
Check("jitter is clamped to a third of the extent", Abs(UiaJitter(9, 6)) <= 2)
Check("jitter of a zero-size extent is zero", UiaJitter(4, 0) = 0)
ctr := UiaJitteredCenter({x: 10, y: 20, w: 30, h: 40}, 0)
Check("UiaJitteredCenter without jitter is the exact centre", ctr.x = 25 && ctr.y = 40,
    ctr.x "," ctr.y)
ok := true
loop 200 {
    ctr := UiaJitteredCenter({x: 10, y: 20, w: 30, h: 40}, 50)
    if (Abs(ctr.x - 25) > 10 || Abs(ctr.y - 40) > 13)
        ok := false
}
Check("...and with jitter stays inside a third of the rect", ok)

; ---- rect-less elements: fail loudly, rescue by scrolling -------------
; 2026-08-03 feedback: a click on an offscreen/virtualized element did
; nothing SILENTLY — "worked" (no error), went nowhere — and cost a real
; session most of an hour. A ListView row past the fold is the deterministic
; stand-in: findable, but no rectangle until scrolled into view.
Say("about to: UiaRect of a scrolled-out row (expect none)")
row35 := UiaFind(hwnd, "Lv Row 35", 3000)
Check("a scrolled-out row is findable", row35 != "")
Check("...but reports no rectangle", UiaRect(row35) = "")

Say("about to: GetCurrentPattern + ScrollIntoView (ScrollItemPattern slot 3)")
Check("UiaScrollIntoView brings the row into view", UiaScrollIntoView(row35) = true)
Sleep(300)
Check("...and now it has a rectangle", IsObject(UiaRect(row35)))
Check("UiaScrollIntoView is false for a pattern-less element", UiaScrollIntoView(el) = false)
Check("UiaScrollIntoView of nothing is false", UiaScrollIntoView("") = false)

Say("about to: UiaClickCenter on a row scrolled OUT of view (auto-rescue)")
whyClick := "unset"
Check("UiaClickCenter rescues a scrolled-out row and clicks it",
    UiaClickCenter(hwnd, "Lv Row 5", 3000, 0, &whyClick) = true, "why=" whyClick)
Sleep(700)
Check("the click really selected the row", TargetState("selected", "Lv Row 5") = "Lv Row 5",
    "target says '" TargetState("selected") "'")

Say("about to: the fail-loudly paths (why names the reason)")
why1 := ""
Check("UiaClickEl of nothing is false", UiaClickEl("", 0, "Left", 1, &why1) = false)
Check("...and why says the find came back empty", InStr(why1, "no element") > 0, why1)
; Occurrence 2 of a scrolled-out row's name is its inner Text child —
; no rectangle AND no ScrollItemPattern (measured), so nothing can rescue
; it and the click must refuse with the reason, not shrug.
whyText := ""
textChild := UiaFind(hwnd, "Lv Row 30", 2000, 2)
Check("the row's Text child is findable", textChild != "")
Check("a rect-less unrescuable element refuses the click",
    UiaClickEl(textChild, 0, "Left", 1, &whyText) = false)
Check("...and why names the missing rectangle", InStr(whyText, "no bounding rectangle") > 0, whyText)
whyMiss := ""
Check("UiaClickCenter on a missing name is false",
    UiaClickCenter(hwnd, "No Such Row Zz", 600, 0, &whyMiss) = false)
Check("...and why carries the name it looked for", InStr(whyMiss, "No Such Row Zz") > 0, whyMiss)

Say("about to: FindAll element lifetime across loops (feedback said 'stale')")
rows := UiaFindAllCond(hwnd, UiaIntCondition(UIA_PROP_CONTROLTYPE(), UIA_TYPE_LISTITEM()), 2000, 50)
Check("FindAll returns every row", rows.Length = 40, "got " rows.Length)
okNames := 0
for rEl in rows
    okNames += (InStr(UiaName(rEl), "Lv Row") ? 1 : 0)
Check("every element stays readable through a first pass", okNames = 40, okNames " of 40")
okNames2 := 0
for rEl in rows
    okNames2 += (UiaRect(rEl) != "" || UiaName(rEl) != "" ? 1 : 0)
Check("...and through a second pass (nothing went stale)", okNames2 = 40, okNames2 " of 40")

; ---- structural walking: TreeWalker + the tree dump -------------------
Say("about to: get_RawViewWalker (IUIAutomation slot 16)")
Check("RawViewWalker is available", UiaRawWalker() != "")

Say("about to: TreeWalker GetParentElement (slot 3)")
Check("the button has a parent", UiaParent(el) != "")
climb := el
reachedTop := false
Loop 6 {
    climb := UiaParent(climb)
    if (climb = "")
        break
    if InStr(UiaName(climb), "VKUiaTarget_ZZ") {
        reachedTop := true
        break
    }
}
Check("parent chain reaches the window element", reachedTop)

Say("about to: TreeWalker GetFirstChildElement (slot 4) / GetNextSiblingElement (slot 6)")
kid := UiaFirstChild(root)
Check("the window has a first child", kid != "")
Check("...and that child has a sibling", kid != "" && UiaNextSibling(kid) != "")
Check("UiaParent of nothing is empty", UiaParent("") = "")
Check("UiaFirstChild of nothing is empty", UiaFirstChild("") = "")
Check("UiaNextSibling of nothing is empty", UiaNextSibling("") = "")

Say("about to: UiaControlTypeName")
Check("50000 names Button", UiaControlTypeName(50000) = "Button")
Check("50004 names Edit", UiaControlTypeName(50004) = "Edit")
Check("an unknown id falls back to its number", UiaControlTypeName(12345) = "12345")

Say("about to: UiaDumpTree")
tree := UiaDumpTree(hwnd)
Check("tree dump lists the button with its type", InStr(tree, 'Button "Press Me Zz"') > 0)
Check("tree dump lists an Edit", InStr(tree, 'Edit "') > 0)
Check("tree dump indents children under the root", RegExMatch(tree, "m)^  \S") > 0)
capped := UiaDumpTree(hwnd, 8, "", 3)
cnt := capped = "" ? 0 : StrSplit(capped, "`n").Length
Check("maxLines caps the dump", cnt >= 1 && cnt <= 3, "got " cnt " lines")
filt := UiaDumpTree(hwnd, 8, "Press Me", 50)
Check("nameFilter keeps the match", InStr(filt, 'Button "Press Me Zz"') > 0)
Check("nameFilter drops everything else", !InStr(filt, 'Edit "'), "got: " filt)
Check("UiaDumpTree of hwnd 0 is empty", UiaDumpTree(0) = "")

; ---- the dump says how complete it was (2026-10-12) -------------------
; A dump capped at depth 25 showed a web form's inputs as empty groups and a
; filtered dump came back empty with no warning. &stats reports the walk.
Say("about to: UiaCrc32 (ntdll RtlComputeCrc32)")
crcAscii := DllCall("ntdll\RtlComputeCrc32", "uint", 0, "astr", "123456789", "int", 9, "uint")
Check("RtlComputeCrc32 is the standard CRC-32 (check value CBF43926)", crcAscii = 0xCBF43926,
    Format("{:08X}", crcAscii))
Check("UiaCrc32 chains (two halves = the whole)",
    UiaCrc32("ef", UiaCrc32("abcd")) = UiaCrc32("abcdef"))
Check("UiaCrc32 of different text differs", UiaCrc32("abc") != UiaCrc32("abd"))

Say("about to: UiaDumpTree &stats")
full := UiaDumpTree(hwnd, 8, "", 300, &stFull)
Check("stats count the visited nodes", stFull.visited >= 6, "visited=" stFull.visited)
Check("nothing is cut at depth 8 in a flat window", stFull.cutAtDepth = 0, "cut=" stFull.cutAtDepth)
Check("...and no budget, time or line cap was hit",
    !stFull.budgetHit && !stFull.timeHit && !stFull.linesHit)
Check("the fingerprint is 8 hex digits", RegExMatch(stFull.fingerprint, "^[0-9a-f]{8}$") > 0,
    stFull.fingerprint)
UiaDumpTree(hwnd, 8, "Press Me", 50, &stFilt)
Check("a filtered dump has the SAME fingerprint and node count",
    stFilt.fingerprint = stFull.fingerprint && stFilt.visited = stFull.visited,
    stFilt.fingerprint " vs " stFull.fingerprint)
UiaDumpTree(hwnd, 8, "", 3, &stCap)
Check("a line-capped dump says linesHit", stCap.linesHit = true)
Check("...but keeps walking (same fingerprint, same count)",
    stCap.fingerprint = stFull.fingerprint && stCap.visited = stFull.visited,
    stCap.visited " vs " stFull.visited)
shallowDump := UiaDumpTree(hwnd, 1, "Lv Row 12", 50, &stShallow)
Check("a filter below maxDepth matches nothing...", shallowDump = "")
Check("...and stats say subtrees were cut there (the list's rows)", stShallow.cutAtDepth >= 1,
    "cut=" stShallow.cutAtDepth)
Check("UiaTreeFingerprint agrees with UiaDumpTree", UiaTreeFingerprint(hwnd, 8, &stFp) = stFull.fingerprint)
Check("...and its stats don't claim a line cap (it collects no lines)",
    !stFp.linesHit && !stFp.timeHit && stFp.visited = stFull.visited)
UiaDumpTree(0, 8, "", 300, &stNone)
Check("an unreadable window: nothing visited, why says so",
    stNone.visited = 0 && InStr(stNone.why, "hwnd 0") > 0, stNone.why)
Check("...and no fingerprint", stNone.fingerprint = "" && UiaTreeFingerprint(0) = "")
; The point of the fingerprint: same title, different content. Rename the
; button in the target (WM_SETTEXT from here), then put it back.
btnHwnd := Integer(TargetState("btnhwnd"))
ControlSetText("Renamed Zz", btnHwnd)
Sleep(300)
fpChanged := UiaTreeFingerprint(hwnd)
ControlSetText("Press Me Zz", btnHwnd)
Sleep(300)
Check("the fingerprint changes when the content changes under the same title",
    fpChanged != "" && fpChanged != stFull.fingerprint, fpChanged " vs " stFull.fingerprint)
Check("...and comes back when the content does", UiaTreeFingerprint(hwnd) = stFull.fingerprint)

; ---- &why: an empty answer says WHY (2026-10-12) ----------------------
; "No match", "couldn't get the window root" and "the lookup threw" used to
; look identical; one session blamed a flaky browser for a page change.
Say("about to: the &why texts")
whyW := "unset"
Check("UiaFromWindow(0) is refused with a reason", UiaFromWindow(0, &whyW) = "" && InStr(whyW, "hwnd 0") > 0, whyW)
Check("...and a good window has an empty why", UiaFromWindow(hwnd, &whyW) != "" && whyW = "", whyW)
goneGui := Gui(, "VKUiaGone_ZZ")
goneHwnd := goneGui.Hwnd
goneGui.Destroy()
Check("a closed window's why says it has closed",
    UiaFromWindow(goneHwnd, &whyW) = "" && InStr(whyW, "has closed") > 0, whyW)
Check("a hit has an empty why", UiaFind(hwnd, "Press Me Zz", 2000, 1, &whyW) != "" && whyW = "", whyW)
UiaFind(hwnd, "No Such Xyz Zz", 600, 1, &whyW)
Check("a miss says 'no match' with elapsed ms and attempts",
    RegExMatch(whyW, "^no match after \d+ ms \(\d+ attempts?\)$") > 0, whyW)
UiaFindAll(hwnd, "No Such Xyz Zz", 300, 0, &whyW)
Check("UiaFindAll's miss says the same", RegExMatch(whyW, "^no match after \d+ ms") > 0, whyW)
UiaFind(hwnd, "Name Field", 400, 99, &whyW)
Check("too few matches for the occurrence says how many there were",
    InStr(whyW, "only 2 matches, wanted occurrence 99") = 1, whyW)
t0 := A_TickCount
UiaFindEdit(0, "Name Field", 2000, 1, &whyW)
Check("a find on hwnd 0 says so at once (not after the timeout)",
    InStr(whyW, "hwnd 0") > 0 && A_TickCount - t0 < 1000, whyW)
UiaFindById(hwnd, "no.such.id.zz", 300, 1, &whyW)
Check("UiaFindById passes why through", InStr(whyW, "no match") = 1, whyW)
UiaFindOfType(hwnd, "Name Field", UIA_TYPE_CHECKBOX(), 300, 1, &whyW)
Check("UiaFindOfType passes why through", InStr(whyW, "no match") = 1, whyW)
UiaWaitFor(hwnd, "No Such Xyz Zz", 300, &whyW)
Check("UiaWaitFor passes why through", InStr(whyW, "no match") = 1, whyW)
UiaFindAllCond(hwnd, "", 300, 0, &whyW)
Check("a missing condition is named", InStr(whyW, "condition") > 0, whyW)
Check("UiaFindFirst with no start element says so",
    UiaFindFirst("", cond, 4, &whyW) = "" && InStr(whyW, "no start element") = 1, whyW)
Check("UiaFindFirst with no condition says so",
    UiaFindFirst(root, "", 4, &whyW) = "" && InStr(whyW, "no search condition") = 1, whyW)
Check("UiaFindElements of nothing says so",
    UiaFindElements("", cond, 4, 0, &whyW).Length = 0 && InStr(whyW, "no start element") = 1, whyW)
UiaClickName(0, "Zz Nothing", 300, &whyW)
Check("a click helper says the SEARCH failed, not that the name is absent",
    InStr(whyW, "couldn't search the window for 'Zz Nothing'") = 1 && InStr(whyW, "hwnd 0"), whyW)
UiaClickName(hwnd, "Zz Nothing", 300, &whyW)
Check("...while a plain miss keeps the virtualization advice",
    InStr(whyW, "no element named 'Zz Nothing'") = 1 && InStr(whyW, "VIRTUALIZE"), whyW)

; ---- scoped searches can't come back from outside (2026-10-12) --------
; Chrome's FindFirst, started at three different label groups, returned the
; SAME (wrong) box all three times. The Win32 provider here is correct, so
; this pins the containment helper both ways, the scoped finds, the walk
; fallback, and — by handing UiaKeepInScope an out-of-scope hit directly —
; what happens when a provider does misbehave.
Say("about to: UiaIsWithin / UiaIsTopLevel")
listEl := UiaFromWindow(Integer(TargetState("lvhwnd")))
Check("the list is reachable", listEl != "")
nameCond := UiaPropCondition(UIA_PROP_NAME(), "Lv Row 3")
allRow3 := UiaFindElements(root, nameCond, UIA_SCOPE_SUBTREE())
Check("the window has 3 elements named 'Lv Row 3' (row, its text, the outside text)",
    allRow3.Length = 3, "got " allRow3.Length)
rowIn := allRow3[1], outsideTxt := allRow3[allRow3.Length]
outsideBtn := UiaFind(hwnd, "Outside Only Zz", 2000)
Check("the row is within the list", UiaIsWithin(rowIn, listEl) = true)
Check("the list is within itself", UiaIsWithin(listEl, listEl) = true)
Check("the outside text is NOT within the list", UiaIsWithin(outsideTxt, listEl) = false)
Check("the outside button is NOT within the list", UiaIsWithin(outsideBtn, listEl) = false)
Check("containment is not symmetric (the list is not within its row)",
    UiaIsWithin(listEl, rowIn) = false)
Check("UiaIsWithin of nothing is false", UiaIsWithin("", listEl) = false)
Check("the window element is top-level", UiaIsTopLevel(root) = true)
Check("...the list is not", UiaIsTopLevel(listEl) = false)

Say("about to: UiaFindFirst / UiaFindElements from a sub-element")
hitIn := UiaFindFirst(listEl, nameCond, UIA_SCOPE_DESCENDANTS(), &whyW)
Check("a search from the list finds the row inside it",
    hitIn != "" && UiaControlType(hitIn) = UIA_TYPE_LISTITEM() && whyW = "", whyW)
Check("a search from the list for a name only OUTSIDE it finds nothing",
    UiaFindFirst(listEl, UiaPropCondition(UIA_PROP_NAME(), "Outside Only Zz"), 4, &whyW) = ""
    && whyW = "no match", whyW)
inList := UiaFindElements(listEl, nameCond, UIA_SCOPE_DESCENDANTS(), 0, &whyW)
okIn := inList.Length = 2 && whyW = ""
for e in inList
    okIn := okIn && UiaIsWithin(e, listEl)
Check("FindAll from the list returns only the 2 inside it", okIn, "got " inList.Length " why=" whyW)

Say("about to: UiaFindFirstWalk (the reliable fallback)")
walked := UiaFindFirstWalk(listEl, nameCond, UIA_SCOPE_DESCENDANTS(), &whyW)
Check("the walk finds the same row FindFirst did", UiaSameElement(walked, hitIn) && whyW = "", whyW)
textCond := UiaAndCondition(nameCond, UiaIntCondition(UIA_PROP_CONTROLTYPE(), UIA_TYPE_TEXT()))
walkedTxt := UiaFindFirstWalk(listEl, textCond, UIA_SCOPE_DESCENDANTS())
Check("a walk for the Text named 'Lv Row 3' returns the one INSIDE the list",
    walkedTxt != "" && UiaIsWithin(walkedTxt, listEl) && !UiaSameElement(walkedTxt, outsideTxt))
Check("a walk for a name only outside finds nothing",
    UiaFindFirstWalk(listEl, UiaPropCondition(UIA_PROP_NAME(), "Outside Only Zz"), 4, &whyW) = ""
    && whyW = "no match", whyW)
Check("a children-only walk reaches a row", UiaFindFirstWalk(listEl, nameCond, 2) != "")
Check("an element-only walk tests just the start", UiaFindFirstWalk(listEl, nameCond, 1) = "")
; The walk is bounded by time too: a miss over a big subtree must give up
; and say so. A 1 ms limit over the whole window either finishes first
; (a fast machine) or stops with the "stopped after" reason — never a hit.
missCond := UiaPropCondition(UIA_PROP_NAME(), "Nowhere At All Zz")
tWalk := A_TickCount
wMiss := UiaFindFirstWalk(root, missCond, 4, &whyT, 1)
Check("a time-limited walk that misses returns nothing with a reason",
    wMiss = "" && (whyT = "no match" || RegExMatch(whyT, "^no match .* stopped after \d+ nodes / \d+ ms")),
    whyT)
Check("...and gives up quickly", A_TickCount - tWalk < 3000, (A_TickCount - tWalk) " ms")

Say("about to: UiaKeepInScope / UiaScopedHits (a provider answering from outside)")
kept := UiaKeepInScope(outsideTxt, listEl, nameCond, UIA_SCOPE_DESCENDANTS(), &whyW)
Check("an out-of-scope hit is replaced by the walk's in-scope match",
    kept != "" && UiaSameElement(kept, hitIn), "type=" (kept != "" ? UiaControlType(kept) : "none"))
Check("...and why says the provider answered from OUTSIDE", InStr(whyW, "OUTSIDE") > 0, whyW)
keptNone := UiaKeepInScope(outsideBtn, listEl, UiaPropCondition(UIA_PROP_NAME(), "Outside Only Zz"), 4, &whyW)
Check("...and when nothing inside matches, it is empty with both reasons",
    keptNone = "" && InStr(whyW, "OUTSIDE") && InStr(whyW, "no match"), whyW)
Check("an in-scope hit passes straight through",
    UiaSameElement(UiaKeepInScope(hitIn, listEl, nameCond, 4, &whyW), hitIn) && whyW = "", whyW)
Check("a window-root start is never second-guessed",
    UiaSameElement(UiaKeepInScope(outsideTxt, root, nameCond, 4), outsideTxt))
scoped := UiaScopedHits([rowIn, outsideTxt], listEl, &dropped)
Check("UiaScopedHits drops the stray", scoped.Length = 1 && dropped = 1
    && UiaSameElement(scoped[1], rowIn), "kept " scoped.Length " dropped " dropped)
rowsIn := UiaFindElements(listEl, UiaIntCondition(UIA_PROP_CONTROLTYPE(), UIA_TYPE_LISTITEM()), 4, 0, &whyW)
Check("40 rows from the list, none dropped", rowsIn.Length = 40 && whyW = "", rowsIn.Length " " whyW)
rowsIn.Push(outsideBtn)
scoped := UiaScopedHits(rowsIn, listEl, &dropped)
Check("a stray at the end of a long list is caught (the ends are always sampled)",
    scoped.Length = 40 && dropped = 1, "kept " scoped.Length " dropped " dropped)

; ---- a rectangle is not a place you can click (2026-10-14) ------------
; From a real build: Chrome reports rectangles for content scrolled out of
; an inner panel or under a pinned header, and UiaClickEl clicked there —
; once on a different monitor. The target's second window (VKUiaVis_ZZ) is
; the Win32 stand-in: a pane with scroll bars (a scroll container) holding
; a button inside it, one two-thirds past its edge, and one wholly past it
; but still inside the window (it keeps a rectangle and IsOffscreen stays
; false — measured); a button an overlay window covers; and VKUiaFar_ZZ,
; shown off every monitor. Every refused click is proved NOT sent: each
; button (and the overlay) counts its clicks, and the mouse doesn't move.
visHwnd := WinExist("VKUiaVis_ZZ ahk_pid " tpid)
farHwnd := WinExist("VKUiaFar_ZZ ahk_pid " tpid)
coverHwnd := WinExist("VKUiaCover_ZZ ahk_pid " tpid)
Check("the visibility fixtures are up", visHwnd && farHwnd && coverHwnd)
; The main target window may have been activated above them: raise the
; fixture window, then the overlay over it (WinMoveTop: no activation).
WinActivate("ahk_id " visHwnd)
WinWaitActive("ahk_id " visHwnd, , 2)
WinMoveTop("ahk_id " coverHwnd)
Sleep(300)
VisClicks(k) => Integer(TargetState(k "clicks"))

Say("about to: get_CurrentIsOffscreen (Element slot 38) / get_CurrentProcessId (slot 20)")
Check("a button is not offscreen", UiaIsOffscreen(el) = false)
farRow := UiaFind(hwnd, "Lv Row 40", 2000)
Check("a list row past the fold reports IsOffscreen (and no rectangle)",
    farRow != "" && UiaIsOffscreen(farRow) = true && UiaRect(farRow) = "")
Check("UiaIsOffscreen of nothing is false", UiaIsOffscreen("") = false)
Check("UiaProcessId names the target's process", UiaProcessId(el) = tpid, UiaProcessId(el) " vs " tpid)
Check("UiaProcessId of nothing is 0", UiaProcessId("") = 0)

Say("about to: GetCurrentPattern(ScrollPattern 10004) — UiaIsScrollContainer")
paneEl := UiaFromWindow(Integer(TargetState("panehwnd")))
Check("the pane with scroll bars is a scroll container", UiaIsScrollContainer(paneEl) = true)
Check("...so is the list", UiaIsScrollContainer(listEl) = true)
Check("...a button is not", UiaIsScrollContainer(el) = false)
Check("...nor a top-level window", UiaIsScrollContainer(root) = false)
Check("UiaIsScrollContainer of nothing is false", UiaIsScrollContainer("") = false)

Say("about to: UiaIntersect / UiaOnMonitors")
ix := UiaIntersect({x: 0, y: 0, w: 10, h: 10}, {x: 5, y: 6, w: 10, h: 10})
Check("UiaIntersect overlaps", IsObject(ix) && ix.x = 5 && ix.y = 6 && ix.w = 5 && ix.h = 4)
Check("...edge-touching rectangles don't overlap", UiaIntersect({x: 0, y: 0, w: 10, h: 10}, {x: 10, y: 0, w: 5, h: 5}) = "")
Check("...nor does a non-rectangle", UiaIntersect("", {x: 0, y: 0, w: 1, h: 1}) = "")
vRight := SysGet(76) + SysGet(78)
Check("a rectangle past the virtual screen is on no monitor",
    UiaOnMonitors({x: vRight + 50, y: SysGet(77) + 10, w: 100, h: 100}) = "")
MonitorGet(MonitorGetPrimary(), &pl, &pt_, &pr, &pb)
straddle := UiaOnMonitors({x: pl - 5000, y: pt_ + 10, w: 5100, h: 50})
Check("a rectangle straddling the primary monitor's edge keeps an on-monitor piece",
    IsObject(straddle) && straddle.x >= pl - 5000 && straddle.w <= 5100 && straddle.w > 0)

Say("about to: UiaVisibleRect")
inBtn := UiaFind(visHwnd, "Inside Btn Zz", 2000)
clipBtn := UiaFind(visHwnd, "Clipped Btn Zz", 2000)
hidBtn := UiaFind(visHwnd, "Hidden Btn Zz", 2000)
covBtn := UiaFind(visHwnd, "Covered Btn Zz", 2000)
Check("the fixtures are findable", inBtn && clipBtn && hidBtn && covBtn)
rIn := UiaRect(inBtn), vIn := UiaVisibleRect(inBtn, &whyV)
Check("a wholly visible button: the visible rect IS its rect",
    IsObject(vIn) && vIn.x = rIn.x && vIn.y = rIn.y && vIn.w = rIn.w && vIn.h = rIn.h && whyV = "", whyV)
rClip := UiaRect(clipBtn), rPane := UiaRect(paneEl)
vClip := UiaVisibleRect(clipBtn, &whyV)
Check("a button two-thirds past its scroll pane's edge: only the part inside the pane",
    IsObject(vClip) && vClip.x = rClip.x && vClip.w < rClip.w && vClip.x + vClip.w <= rPane.x + rPane.w && whyV = "",
    IsObject(vClip) ? vClip.x "," vClip.y " " vClip.w "x" vClip.h " of " rClip.w "x" rClip.h : whyV)
rHid := UiaRect(hidBtn)
Check("the hidden button still reports a rectangle and is NOT IsOffscreen (the Chrome-like case)",
    IsObject(rHid) && UiaIsOffscreen(hidBtn) = false)
Check("...yet it has no visible rect, and why says a scroll container (a Pane) clips it",
    UiaVisibleRect(hidBtn, &whyV, &detV) = "" && InStr(whyV, "scrolling container (a Pane)"), whyV)
Check("...why names no element (it may be recorded); detail does",
    !InStr(whyV, "VKUiaPane_ZZ") && InStr(detV, "VKUiaPane_ZZ"), detV)
; The point at the hidden button's full centre is over its own WINDOW — an
; ancestor. Chrome answers a hit test with the nearest hit-testable
; ancestor, so some ancestors must count — but not the window, the page or
; the scroll container, which a click can hit without touching the element
; (review, 2026-10-14: the first version accepted any ancestor, so a header
; the accessibility tree ignores, pinned over a panel, passed as a hit).
Check("...and a hit test at its full centre says the WINDOW is there, not the button",
    UiaHitTest(hidBtn, rHid.x + rHid.w // 2, rHid.y + rHid.h // 2, &whatH) = 0
    && InStr(whatH, "a Window that holds the element"), whatH)
Check("UiaHitCountsFor: the window and the scroll pane above a button don't count",
    !UiaHitCountsFor(inBtn, UiaFromWindow(visHwnd))
    && !UiaHitCountsFor(inBtn, paneEl) && !UiaHitCountsFor("", paneEl))
Check("a rect-less row has no visible rect (no bounding rectangle)",
    UiaVisibleRect(farRow, &whyV) = "" && InStr(whyV, "no bounding rectangle"), whyV)
Check("UiaVisibleRect of nothing is empty with a reason", UiaVisibleRect("", &whyV) = "" && InStr(whyV, "no element"), whyV)
Check("UiaWaitVisible returns the visible rect at once", IsObject(UiaWaitVisible(inBtn, 300)))

Say("about to: UiaElementAtPoint (IUIAutomation slot 7, with &why) / UiaHitTest")
cIn := UiaJitteredCenter(rIn)
atIn := UiaElementAtPoint(cIn.x, cIn.y, &whyP)
Check("UiaElementAtPoint finds the button under its centre",
    atIn != "" && UiaSameElement(atIn, inBtn) && whyP = "", whyP)
Check("UiaHitTest: a click there reaches the button", UiaHitTest(inBtn, cIn.x, cIn.y) = 1)
rCov := UiaRect(covBtn), cCov := UiaJitteredCenter(rCov)
atCov := UiaElementAtPoint(cCov.x, cCov.y)
Check("over the covered button, the point holds the OVERLAY", UiaName(atCov) = "Cover Zz",
    "got " UiaDescribe(atCov))
Check("UiaHitTest says something else is there: its type, no names",
    UiaHitTest(covBtn, cCov.x, cCov.y, &whatC, &detC) = 0 && whatC = "a Text", whatC)
Check("...detail names it and its window", InStr(detC, 'Text "Cover Zz"') && InStr(detC, "VKUiaCover_ZZ"), detC)
Check("UiaHitTest of nothing can't tell", UiaHitTest("", 1, 1) = -1)
; r.x + r.w / 2 is a Float in v2; the int64 POINT packing threw on one
; (measured) from functions that promise never to throw.
Check("Float coordinates are rounded, not thrown on",
    UiaSameElement(UiaElementAtPoint(cIn.x + 0.4, cIn.y + 0.4, &whyP), inBtn) && UiaHitTest(inBtn, cIn.x + 0.4, cIn.y - 0.4) = 1, whyP)
Check("...and a non-number is a refusal with a reason",
    UiaElementAtPoint("x", 5, &whyP) = "" && InStr(whyP, "not a screen point") && UiaHitTest(inBtn, "x", 5) = -1, whyP)

Say("about to: UiaClickEl on the clipped button (clicks the VISIBLE part)")
cp := UiaClickablePoint(clipBtn, 0, &whyCp)
Check("UiaClickablePoint picks a point inside the visible part",
    IsObject(cp) && cp.x >= vClip.x && cp.x < vClip.x + vClip.w && cp.y >= vClip.y && cp.y < vClip.y + vClip.h && whyCp = "", whyCp)
Check("...which is NOT the full rect's centre (that one is clipped away)",
    IsObject(cp) && cp.x < rClip.x + rClip.w // 2)
before := VisClicks("clip")
Check("UiaClickEl clicks the clipped button", UiaClickEl(clipBtn, 3, "Left", 1, &whyCp) = true, whyCp)
Check("...and the click landed on it", TargetState("clipclicks", before + 1) = before + 1,
    before " -> " TargetState("clipclicks"))

Say("about to: UiaClickEl refusals (nothing may be clicked)")
; The click above activated VKUiaVis_ZZ, which lifts it over the overlay:
; put the overlay back on top before relying on it.
WinMoveTop("ahk_id " coverHwnd)
Sleep(300)
Check("the overlay covers the button again", UiaName(UiaElementAtPoint(cCov.x, cCov.y)) = "Cover Zz")
CoordMode("Mouse", "Screen")
MouseGetPos(&mx0, &my0)
hidBefore := VisClicks("hid"), covBefore := VisClicks("cov"), coverBefore := VisClicks("cover")
whyH := "", whyC := ""
Check("UiaClickEl refuses the hidden button", UiaClickEl(hidBtn, 0, "Left", 1, &whyH) = false)
Check("...why: nowhere visible, outside the scroll container, can't scroll itself",
    InStr(whyH, "nowhere visible") = 1 && InStr(whyH, "scrolling container") && InStr(whyH, "no ScrollItemPattern"), whyH)
Check("UiaClickEl refuses the covered button", UiaClickEl(covBtn, 0, "Left", 1, &whyC) = false)
Check("...why says something is in the way, by type only", InStr(whyC, "something else is in the way") = 1
    && InStr(whyC, "a Text") && !InStr(whyC, "Cover Zz") && !InStr(whyC, "VKUiaCover_ZZ"), whyC)
UiaClickEl(covBtn, 0, "Left", 1, &whyC, &detC)
Check("...detail names it", InStr(detC, 'Text "Cover Zz"') && InStr(detC, "VKUiaCover_ZZ"), detC)
Check("UiaClickCenter inherits the refusal",
    UiaClickCenter(visHwnd, "Covered Btn Zz", 2000, 0, &whyC, &detC) = false && InStr(whyC, "in the way") && InStr(detC, "Cover Zz"), detC)
Sleep(500)
MouseGetPos(&mx1, &my1)
Check("NO click was sent: the hidden button's count is unchanged", VisClicks("hid") = hidBefore)
Check("...nor the covered button's", VisClicks("cov") = covBefore)
Check("...nor the overlay's (a blind click would have hit it)", VisClicks("cover") = coverBefore)
Check("...and the mouse never moved", mx0 = mx1 && my0 = my1, mx0 "," my0 " -> " mx1 "," my1)

Say("about to: a window off every monitor")
WinGetPos(&fx, &fy, &fw, &fh, "ahk_id " farHwnd)
if (fx >= vRight) {
    farBtn := UiaFind(farHwnd, "Far Btn Zz", 2000)
    Check("the off-monitor button is findable and has a rectangle", farBtn != "" && IsObject(UiaRect(farBtn)))
    Check("...but no visible rect: it is on no monitor",
        UiaVisibleRect(farBtn, &whyF) = "" && InStr(whyF, "not on any monitor"), whyF)
    ; UiaClickablePoint first: it is the whole decision UiaClickEl makes, and
    ; it clicks nothing — so a regression fails HERE instead of clicking at
    ; the screen edge the cursor would be clamped to.
    if (UiaClickablePoint(farBtn, 0, &whyF) = "") {
        farBefore := VisClicks("far")
        MouseGetPos(&mx0, &my0)
        Check("UiaClickEl refuses it", UiaClickEl(farBtn, 0, "Left", 1, &whyF) = false
            && InStr(whyF, "not on any monitor"), whyF)
        Sleep(400)
        MouseGetPos(&mx1, &my1)
        Check("...with no click sent and the mouse unmoved",
            VisClicks("far") = farBefore && mx0 = mx1 && my0 = my1)
    } else {
        Check("UiaClickablePoint refuses an off-monitor element (UiaClickEl NOT called)", false)
    }
} else {
    Say("SKIP  the off-monitor window was moved back onto a monitor (x=" fx ") — not provable here")
}

; ---- the hit test's ScrollIntoView retry (review, 2026-10-14) ---------
; VKUiaRescue_ZZ: a ListView showing five and a half rows. VKUiaPin_ZZ sits
; over the first row slot (a header pinned over the content); VKUiaStrip_ZZ
; over the half row at the bottom. Both overlays count their clicks, and so
; does the list (rsn, with the row in rslast).
Say("about to: the hit-test retry - a pinned header (refused) and a covering strip (rescued)")
rsHwnd := WinExist("VKUiaRescue_ZZ ahk_pid " tpid)
stripHwnd := WinExist("VKUiaStrip_ZZ ahk_pid " tpid)
pinHwnd := WinExist("VKUiaPin_ZZ ahk_pid " tpid)
Check("the retry fixtures are up", rsHwnd && stripHwnd && pinHwnd)
WinMoveTop("ahk_id " stripHwnd)
WinMoveTop("ahk_id " pinHwnd)
Sleep(300)
rs1 := UiaFind(rsHwnd, "Rs Row 1", 2000)
rs6 := UiaFind(rsHwnd, "Rs Row 6", 2000)
v1 := UiaVisibleRect(rs1, &w1), v6 := UiaVisibleRect(rs6, &w6)
Check("row 1 is visible, and so is the part of row 6 above the fold",
    IsObject(v1) && IsObject(v6) && v6.h < v1.h, w1 " / " w6)
if (IsObject(v1) && IsObject(v6)) {
    c1 := UiaJitteredCenter(v1), c6 := UiaJitteredCenter(v6)
    Check("...the pin covers row 1", UiaName(UiaElementAtPoint(c1.x, c1.y)) = "VKUiaPin_ZZ",
        UiaDescribe(UiaElementAtPoint(c1.x, c1.y)))
    Check("...the strip covers what shows of row 6", UiaName(UiaElementAtPoint(c6.x, c6.y)) = "VKUiaStrip_ZZ",
        UiaDescribe(UiaElementAtPoint(c6.x, c6.y)))
    Check("before: row 1 is the top row", TargetState("rstop") = "0")

    rsBefore := Integer(TargetState("rsn")), pinBefore := VisClicks("pin"), stripBefore := VisClicks("strip")
    MouseGetPos(&mx0, &my0)
    whyPin := "", detPin := ""
    Check("UiaClickEl refuses the row under the pinned header",
        UiaClickEl(rs1, 0, "Left", 1, &whyPin, &detPin) = false, detPin)
    Check("...after a ScrollIntoView retry that couldn't help: why says 'still'",
        InStr(whyPin, "something else is in the way") = 1 && InStr(whyPin, "still, after ScrollIntoView"), whyPin)
    Check("...why names no window; detail does", !InStr(whyPin, "VKUiaPin_ZZ") && InStr(detPin, "VKUiaPin_ZZ"),
        whyPin " | " detPin)
    Sleep(400)
    MouseGetPos(&mx1, &my1)
    Check("...NO click sent: the list and the pin counted nothing, the mouse didn't move",
        Integer(TargetState("rsn")) = rsBefore && VisClicks("pin") = pinBefore && mx0 = mx1 && my0 = my1)

    WinMoveTop("ahk_id " stripHwnd)
    Sleep(200)
    why6 := "unset", det6 := ""
    Check("UiaClickEl rescues row 6 from under the strip (hit test in the way -> ScrollIntoView -> retry)",
        UiaClickEl(rs6, 0, "Left", 1, &why6, &det6) = true, det6)
    Check("...the list really scrolled", TargetState("rstop", "1") = "1", "top=" TargetState("rstop"))
    Check("...the click landed on row 6", TargetState("rslast", "Rs Row 6") = "Rs Row 6"
        && Integer(TargetState("rsn")) = rsBefore + 1, TargetState("rslast") " n=" TargetState("rsn"))
    Check("...and not on the strip", VisClicks("strip") = stripBefore)
}

; ---- the element's OWN window (code review, 2026-10-14) ----------------
; UiaVisibleRect once took "the ancestor just below the desktop root" as the
; element's window, and a walk that failed partway as complete. An owned
; window (a dialog) may sit under its owner in the tree, and its controls
; were clipped to the owner's box.
Say("about to: get_CurrentNativeWindowHandle (Element slot 36) / UiaIsWindowRoot / UiaClipChain")
visRoot := UiaFromWindow(visHwnd)
Check("UiaNativeHwnd of a window's element is its HWND", UiaNativeHwnd(visRoot) = visHwnd, UiaNativeHwnd(visRoot) " vs " visHwnd)
Check("...of a child pane, the pane's", UiaNativeHwnd(paneEl) = Integer(TargetState("panehwnd")))
Check("...of nothing, 0", UiaNativeHwnd("") = 0)
Check("UiaIsWindowRoot: a top-level window yes; a child pane, a button, nothing and the desktop no",
    UiaIsWindowRoot(visRoot) && !UiaIsWindowRoot(paneEl) && !UiaIsWindowRoot(inBtn)
    && !UiaIsWindowRoot("") && !UiaIsWindowRoot(UiaParent(visRoot)))
chIn := UiaClipChain(inBtn, &whyCh)
Check("UiaClipChain: from a button, up through its pane, ending AT its window (no desktop root)",
    IsObject(chIn) && chIn.Length >= 2 && UiaSameElement(chIn[chIn.Length], visRoot)
    && UiaIsWithin(paneEl, chIn[1]) && whyCh = "", whyCh)
Check("...a window's own chain is empty", IsObject(UiaClipChain(visRoot)) && UiaClipChain(visRoot).Length = 0)
Check("...and nothing has none, with a reason", UiaClipChain("", &whyCh) = "" && whyCh != "")

ownerHwnd := WinExist("VKUiaOwner_ZZ ahk_pid " tpid)
ownedHwnd := WinExist("VKUiaOwned_ZZ ahk_pid " tpid)
Check("the owned-window fixtures are up", ownerHwnd && ownedHwnd)
WinMoveTop("ahk_id " ownedHwnd)
Sleep(200)
ownedRoot := UiaFromWindow(ownedHwnd)
ownedUp := UiaParent(ownedRoot)
Say("INFO  the owned window's UIA parent is " (UiaSameElement(ownedUp, UiaFromWindow(ownerHwnd)) ? "its OWNER" : "not its owner (" UiaDescribe(ownedUp) ")"))
ownedBtn := UiaFind(ownedHwnd, "Owned Btn Zz", 2000)
rOwned := UiaRect(ownedBtn), rOwner := UiaRect(UiaFromWindow(ownerHwnd))
Check("the owned window's button lies wholly outside its owner's box",
    IsObject(rOwned) && IsObject(rOwner) && rOwned.x >= rOwner.x + rOwner.w)
chOwned := UiaClipChain(ownedBtn)
Check("...its chain ends at the OWNED window, not the owner",
    IsObject(chOwned) && UiaSameElement(chOwned[chOwned.Length], ownedRoot))
vOwned := UiaVisibleRect(ownedBtn, &whyO)
Check("...so it is wholly visible", IsObject(vOwned) && vOwned.x = rOwned.x && vOwned.w = rOwned.w && whyO = "", whyO)
ownedBefore := VisClicks("owned")
Check("UiaClickEl clicks it", UiaClickEl(ownedBtn, 0, "Left", 1, &whyO, &detO) = true, detO)
Check("...and the click landed", TargetState("ownedclicks", ownedBefore + 1) = ownedBefore + 1)
seenOwner := UiaDumpTree(ownerHwnd, 8, "Owned Btn", 50, , false, true)
seenOwned := UiaDumpTree(ownedHwnd, 8, "Owned Btn", 50, , false, true)
Check("a visibleOnly dump from the owned window shows the button", InStr(seenOwned, "Owned Btn Zz") > 0, seenOwned)
if UiaSameElement(ownedUp, UiaFromWindow(ownerHwnd))
    Check("...and so does one from the OWNER (the owned window starts its own clip)",
        InStr(seenOwner, "Owned Btn Zz") > 0, seenOwner)

; ---- one coordinate space for the click (2026-10-14) -------------------
; Measured: UIA rectangles, MonitorGet, WindowFromPoint and MouseMove all
; follow the thread's DPI context; UiaClickEl decides and clicks in
; per-monitor-v2 (physical pixels) and must hand the script back its own.
Say("about to: UiaDpiPhysical / UiaDpiRestore / UiaSleep")
DpiAw() => DllCall("GetAwarenessFromDpiAwarenessContext", "ptr", DllCall("GetThreadDpiAwarenessContext", "ptr"))
aw0 := DpiAw()
prevCtx := UiaDpiPhysical()
awIn := DpiAw()
UiaSleep(50)
awAfterSleep := DpiAw()
UiaDpiRestore(prevCtx)
Check("UiaDpiPhysical switches to per-monitor awareness and back", prevCtx && awIn = 2 && DpiAw() = aw0,
    aw0 " -> " awIn " -> " DpiAw())
Check("...and UiaSleep inside it keeps the scope", awAfterSleep = 2)
UiaClickEl(UiaFind(visHwnd, "Inside Btn Zz", 2000), 0)
Check("UiaClickEl leaves the script's own DPI context as it found it", DpiAw() = aw0, DpiAw() " vs " aw0)
UiaClickEl(hidBtn, 0)
Check("...also when it refuses", DpiAw() = aw0)

; ---- walking up, not searching down (2026-10-14) ----------------------
; A window-wide UiaFindById on a big Chrome page ran past 400 ms although the
; id was there; walking up from an element in hand was instant.
Say("about to: UiaFindAncestorById / UiaFindAncestorByName")
listId := UiaAutomationId(listEl)
Check("the list has an AutomationId (Win32: its control id)", listId != "", "id='" listId "'")
anc := UiaFindAncestorById(rowIn, listId, 64, &whyA)
Check("from a row, the ancestor with the list's id IS the list", UiaSameElement(anc, listEl) && whyA = "", whyA)
Check("...an element is not its own ancestor", UiaFindAncestorById(listEl, listId, 64, &whyA) = ""
    && InStr(whyA, "top of the element's window"), whyA)
Check("...a missing id says it walked to the top",
    UiaFindAncestorById(rowIn, "no.such.id.zz", 64, &whyA) = "" && InStr(whyA, "AutomationId 'no.such.id.zz'"), whyA)
Check("...and maxHops bounds the walk",
    UiaFindAncestorById(rowIn, "no.such.id.zz", 1, &whyA) = "" && InStr(whyA, "within 1 levels"), whyA)
Check("...and nothing to start from says so", UiaFindAncestorById("", listId, 64, &whyA) = "" && InStr(whyA, "no start element"), whyA)
Check("UiaFindAncestorByName finds the pane above its button",
    UiaSameElement(UiaFindAncestorByName(inBtn, "VKUiaPane_ZZ"), paneEl))
Check("...the type must match when one is given",
    UiaFindAncestorByName(inBtn, "VKUiaPane_ZZ", UIA_TYPE_BUTTON(), 64, &whyA) = "" && InStr(whyA, "of type Button"), whyA)
Check("...and it never answers with the desktop root",
    UiaFindAncestorByName(inBtn, UiaName(UiaParent(UiaFromWindow(visHwnd))), 0, 64) = "")

; ---- icon-font characters (2026-10-14) ---------------------------------
; A web app's "..." toggle was named by ONE private-use character (U+E611),
; so every "has no name" check said it had one.
Say("about to: UiaStripIcons / UiaShowIcons / UiaName(el, true)")
Check("a name that is only an icon strips to empty", UiaStripIcons(Chr(0xE611)) = "")
Check("...icons and the space around them go, text stays", UiaStripIcons(" " Chr(0xE611) " Menu " Chr(0xF8FF)) = "Menu")
Check("...supplementary-plane icons (planes 15/16) go too",
    UiaStripIcons("a" Chr(0xF0001) "b" Chr(0x10FFFD)) = "ab")
Check("...ordinary text is untouched", UiaStripIcons("Caf" Chr(0xE9) " " Chr(0x2026)) = "Caf" Chr(0xE9) " " Chr(0x2026))
; A LONE surrogate (malformed UTF-16) once swallowed the next real
; character: the regex read "high surrogate + b" as one plane-15/16 icon.
Check("...a lone high surrogate keeps the character after it",
    UiaStripIcons("a" Chr(0xDB80) "b") = "a" Chr(0xDB80) "b" && UiaStripIcons("a" Chr(0xDB80) "b" Chr(0xE611)) = "a" Chr(0xDB80) "b")
Check("...and so does UiaShowIcons", UiaShowIcons(Chr(0xE611) "a" Chr(0xDC00) "b") = "<U+E611>a" Chr(0xDC00) "b")
Check("UiaShowIcons writes each icon out", UiaShowIcons(Chr(0xE611) "x" Chr(0x10FFFD)) = "<U+E611>x<U+10FFFD>",
    UiaShowIcons(Chr(0xE611) "x" Chr(0x10FFFD)))
Check("...and leaves a name without one alone", UiaShowIcons("Plain Zz") = "Plain Zz")
iconBtn := UiaFind(visHwnd, Chr(0xE611), 2000)
Check("the icon-named button is findable by its glyph", iconBtn != "")
Check("UiaName returns the glyph by default (unchanged)", UiaName(iconBtn) = Chr(0xE611))
Check("UiaName(el, true) says it has no name", UiaName(iconBtn, true) = "")
Check("UiaDescribe shows the glyph visibly", InStr(UiaDescribe(iconBtn), 'Button "<U+E611>"') = 1, UiaDescribe(iconBtn))

; ---- the dump: subtrees, positions, visible only (2026-10-14) ----------
Say("about to: UiaDumpTree positions / visibleOnly / icons")
plainVis := UiaDumpTree(visHwnd, 8, "", 300, &stPlain)
posVis := UiaDumpTree(visHwnd, 8, "", 300, &stPos, true)
seenVis := UiaDumpTree(visHwnd, 8, "", 300, &stSeen, false, true)
Check("an icon name shows as <U+E611> in the dump", InStr(plainVis, 'Button "<U+E611>"') > 0)
Check("...and nameFilter finds it by that form", InStr(UiaDumpTree(visHwnd, 8, "<U+E611>", 50), 'Button "<U+E611>"') > 0)
okPos := posVis != ""
for dl in StrSplit(posVis, "`n")
    okPos := okPos && RegExMatch(dl, " @(-?\d+,-?\d+ \d+x\d+|none)$")
Check("positions: every line ends in @x,y wxh (or @none)", okPos, SubStr(posVis, 1, 200))
Check("...with the clipped button's real rectangle",
    InStr(posVis, 'Button "Clipped Btn Zz" <id=') && InStr(posVis, "@" rClip.x "," rClip.y " " rClip.w "x" rClip.h))
Check("positions and visibleOnly don't change the walk: same fingerprint and count",
    stPos.fingerprint = stPlain.fingerprint && stSeen.fingerprint = stPlain.fingerprint
    && stPos.visited = stPlain.visited && stSeen.visited = stPlain.visited,
    stPlain.fingerprint " / " stPos.fingerprint " / " stSeen.fingerprint)
UiaDumpTree(visHwnd, 8, "", 2, &stCap, true, true)
Check("...also with the line cap hit (the per-line reads stop there; the walk doesn't)",
    stCap.linesHit && stCap.fingerprint = stPlain.fingerprint && stCap.visited = stPlain.visited)
Check("visibleOnly keeps the visible buttons", InStr(seenVis, "Inside Btn Zz") && InStr(seenVis, "Clipped Btn Zz"))
Check("...and drops the one clipped away by the scroll pane", !InStr(seenVis, "Hidden Btn Zz"))
Check("...without counting it as a line cap", stSeen.linesHit = false)
seenMain := UiaDumpTree(hwnd, 8, "Lv Row", 300, , false, true)
Check("visibleOnly drops list rows past the fold", InStr(seenMain, "Lv Row") && !InStr(seenMain, '"Lv Row 40"'),
    SubStr(seenMain, 1, 200))
UiaDumpTree(hwnd, 8, "", 300, &stMainPos, true, true)
Check("...and leaves the main window's fingerprint as it was", stMainPos.fingerprint = stFull.fingerprint,
    stMainPos.fingerprint " vs " stFull.fingerprint)

Say("about to: UiaDumpSubtree")
sub := UiaDumpSubtree(paneEl, 8, "", 300, &stSub, true)
subLines := StrSplit(sub, "`n")
Check("a subtree dump starts at its element, at depth 0",
    subLines.Length && InStr(subLines[1], 'Pane "VKUiaPane_ZZ"') = 1, subLines.Length ? subLines[1] : "(empty)")
Check("...its children one level in", RegExMatch(sub, 'm)^  Button "Inside Btn Zz"') > 0)
Check("...and nothing from outside it", !InStr(sub, "Covered Btn Zz") && !InStr(sub, "Visibility fixtures"))
Check("...walking fewer nodes than the window", stSub.visited > 0 && stSub.visited < stPlain.visited,
    stSub.visited " vs " stPlain.visited)
subSeen := UiaDumpSubtree(paneEl, 8, "Btn", 300, , false, true)
Check("a visible-only subtree dump drops the hidden button too",
    InStr(subSeen, "Inside Btn Zz") && !InStr(subSeen, "Hidden Btn Zz"), subSeen)
UiaDumpSubtree(UiaFromWindow(visHwnd), 8, "", 0, &stRootSub)
Check("a subtree dump from the window root = the window dump's fingerprint", stRootSub.fingerprint = stPlain.fingerprint)
; The fingerprint hashes the RAW name: a one-node dump of the icon button
; equals the CRC of its line built with the glyph itself, not <U+E611>.
UiaDumpSubtree(iconBtn, 0, "", 10, &stIcon)
rawCrc := Format("{:08x}", UiaCrc32("0`t" UiaControlType(iconBtn) "`t" Chr(0xE611) "`t" UiaAutomationId(iconBtn) "`n"))
Check("the fingerprint hashes the raw glyph, not its shown form", stIcon.fingerprint = rawCrc,
    stIcon.fingerprint " vs " rawCrc)
Check("UiaDumpSubtree of nothing: empty, and why says so",
    UiaDumpSubtree("", 8, "", 300, &stNoSub) = "" && stNoSub.visited = 0 && InStr(stNoSub.why, "no start element"), stNoSub.why)

; ---- the probe's tree mode (mcp\uia_probe.ahk) --------------------------
; The MCP's dump_uia_tree calls it with the trailing args in this order:
; window, max_depth, max_lines, name_filter, root_id, root_name,
; positions (0|1), visible_only (0|1). Run it as the server does.
ProbeTree(args) {
    out := A_Temp "\vk-uia-selftest-probe.txt"
    try FileDelete(out)
    Run('"' A_AhkPath '" /ErrorStdOut "' A_ScriptDir '\..\mcp\uia_probe.ahk" "' out '" tree ' args, , "Hide", &ppid)
    if ProcessWaitClose(ppid, 30) {
        ProcessClose(ppid)
        return "(probe timed out)"
    }
    txt := ""
    try txt := FileRead(out, "UTF-8")
    try FileDelete(out)
    return txt
}
Say("about to: the probe, rooted by name, with positions and visible_only")
win := '"VKUiaVis_ZZ ahk_pid ' tpid '"'
rep := ProbeTree(win ' 8 300 "" "" "VKUiaPane_ZZ" 1 1')
hdr := StrSplit(rep, "`n`n")[1]
Check("probe: root= names the element the dump starts at", InStr(rep, '`nroot=Pane "VKUiaPane_ZZ"`n'), hdr)
Check("probe: the outline starts there, with positions",
    RegExMatch(rep, '\n\nPane "VKUiaPane_ZZ" @-?\d+,-?\d+ \d+x\d+') > 0, SubStr(rep, 1, 400))
Check("probe: visible_only drops the hidden button", InStr(rep, "Inside Btn Zz") && !InStr(rep, "Hidden Btn Zz"))
inId := UiaAutomationId(inBtn)
rep2 := ProbeTree(win ' 8 300 "" "' inId '" "Inside Btn Zz"')
Check("probe: root_id AND root_name pick the element with both",
    InStr(rep2, '`nroot=Button "Inside Btn Zz" <id=' inId '>`n'), StrSplit(rep2, "`n`n")[1])
rep3 := ProbeTree(win ' 8 300 "" "no.such.id.zz"')
Check("probe: a root that isn't there is an error= answer with the find's reason",
    InStr(rep3, "error=No element with AutomationId 'no.such.id.zz'") = 1 && InStr(rep3, "no match"), rep3)
rep4 := ProbeTree(win ' 8 300')
Check("probe: no root args = today's report (no root= line, the window first)",
    !InStr(rep4, "root=") && InStr(rep4, '`n`nWindow "VKUiaVis_ZZ"') && InStr(rep4, "Hidden Btn Zz") && !InStr(rep4, " @"),
    SubStr(rep4, 1, 300))

; ---- the own-process guards -------------------------------------------
; Deliberately LAST. All three entrances must refuse our own process; if a
; guard ever regresses, its call does not fail, it HANGS — the runner's
; 120 s kill turns that into a reported failure, and every check above has
; already been written to the result file by then.
Say("about to: UiaFromWindow on OUR OWN window (must be refused, not answered)")
selfGui := Gui("+AlwaysOnTop", "VKUiaSelf_ZZ")
selfGui.AddButton("w200", "Self Button Zz")
selfGui.Show("Hide")
Check("our own process is refused", UiaFromWindow(selfGui.Hwnd) = "")
whyW := ""
UiaFromWindow(selfGui.Hwnd, &whyW)
Check("...and why names the own-process rule", InStr(whyW, "own process") > 0, whyW)
UiaFind(selfGui.Hwnd, "Self Button Zz", 300, 1, &whyW)
Check("...and so does a find on it (refused before any UIA call)", InStr(whyW, "own process") > 0, whyW)
Check("UiaOtherProcess says no to our own window", UiaOtherProcess(selfGui.Hwnd) = false)
Check("UiaOtherProcess says yes to the target", UiaOtherProcess(hwnd) = true)

; Second entrance: a point over our own window. Shown NoActivate but
; AlwaysOnTop, so it really is the window under that point.
Say("about to: UiaFromPoint over OUR OWN window (must be refused)")
selfGui.Show("x120 y180 w240 h90 NoActivate")
Sleep(200)
WinGetPos(&sx, &sy, &sw, &sh, "ahk_id " selfGui.Hwnd)
Check("a point over our own window is refused",
    UiaFromPoint(sx + sw // 2, sy + sh // 2) = "")
Check("...while a point over the target still answers",
    UiaFromPoint(r.x + r.w // 2, r.y + r.h // 2) != "")
UiaElementAtPoint(sx + sw // 2, sy + sh // 2, &whyP)
Check("UiaElementAtPoint's why names the own-process rule", InStr(whyP, "own process") > 0, whyP)

; The click check meets the same rule: OUR window over the target's button
; is something in the way — reported from WindowFromPoint alone, never by
; asking UIA about our own window — and nothing is clicked.
Say("about to: a click on a button OUR OWN window covers (must refuse, no UIA on us)")
cIn := UiaJitteredCenter(rIn)
; Raise it until it really IS the window at that point (z-order changes from
; another process can land late; measured once: a single WinMoveTop + 200 ms
; was not enough). Only then is the click attempt safe to make.
covered := false
Loop 20 {
    WinMove(rIn.x - 5, rIn.y - 5, rIn.w + 10, rIn.h + 10, "ahk_id " selfGui.Hwnd)
    WinMoveTop("ahk_id " selfGui.Hwnd)
    Sleep(100)
    atHwnd := DllCall("WindowFromPoint", "int64", (cIn.y << 32) | (cIn.x & 0xFFFFFFFF), "ptr")
    if (covered := DllCall("GetAncestor", "ptr", atHwnd, "uint", 2, "ptr") = selfGui.Hwnd)
        break
}
if covered {
    inBefore := VisClicks("in")
    Check("UiaHitTest: our own window is in the way", UiaHitTest(inBtn, cIn.x, cIn.y, &whatS) = 0
        && InStr(whatS, "this script's own process"), whatS)
    Check("UiaClickEl refuses, naming it", UiaClickEl(inBtn, 0, "Left", 1, &whyS) = false
        && InStr(whyS, "in the way") && InStr(whyS, "own process"), whyS)
    Sleep(400)
    Check("...and the covered button got no click", VisClicks("in") = inBefore)
} else {
    Say("SKIP  couldn't put our own window over the target's button — own-window cover not provable here")
}

; Third entrance: focus. With our own window foreground, GetFocusedElement
; would call back into this thread — the guard answers "" instead.
Say("about to: UiaFocused while OUR OWN window is foreground (must be refused)")
WinActivate("ahk_id " selfGui.Hwnd)
if WinWaitActive("ahk_id " selfGui.Hwnd, , 3)
    Check("focus in our own process is refused", UiaFocused() = "")
else
    Say("SKIP  couldn't bring our own window foreground — focus guard not provable here")
selfGui.Destroy()

TargetStop()
TestEnd()
