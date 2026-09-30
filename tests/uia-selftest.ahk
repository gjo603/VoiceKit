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
if !(hwnd := TargetLaunch("uia-selftest-target.ahk", "VKUiaTarget_ZZ"))
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
