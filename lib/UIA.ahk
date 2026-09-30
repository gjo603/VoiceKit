#Requires AutoHotkey v2.0
; ============================================================
;  Minimal UI Automation (UIA) helpers.
;
;  WHY THIS EXISTS
;  lib\Acc.ahk speaks MSAA, which is old and increasingly thin:
;  modern apps (WinUI/XAML, WPF, Electron, browsers) often expose
;  a poor MSAA tree while their UIA tree is complete. The way to
;  reach UIA from AutoHotkey is raw vtable calls, and getting one
;  offset wrong is not an error you can catch — it is an access
;  violation that ends the process. Somebody worked that out the
;  hard way and took VoiceKit down with them. Nobody should pay
;  that twice: the offsets below are written down, commented with
;  the interface they belong to, and covered by a test that calls
;  every one of them.
;
;  WHERE TO USE IT
;  In a hotkey module's BODY (hotkeys\bodies\<Base>.body.ahk),
;  which runs in its own process — so even a fault in here costs
;  one short-lived process, not every hotkey and snippet:
;      #Include "%A_ScriptDir%\..\..\lib\UIA.ahk"
;  Do NOT include it into VoiceKit.ahk itself.
;
;  NEVER POINT IT AT YOUR OWN PROCESS
;  Automate OTHER apps with this. Querying a window belonging to
;  the same script HANGS: UIA calls back into the provider on the
;  thread that is already blocked inside the UIA call, and the two
;  wait on each other forever. It is timing-dependent, so it will
;  seem to work in a small test and then wedge for good in a real
;  one — measured exactly that way while this file was written.
;  There is no timeout and nothing to catch; the process just
;  stops. (tests\uia-selftest.ahk drives a SEPARATE target script
;  for this reason.)
;  The rule is now ENFORCED at all three entrances: UiaFromWindow
;  refuses a window of the calling process, UiaFromPoint refuses a
;  point over one, and UiaFocused refuses while one is foreground —
;  each returns "" instead of wedging the process. Every other
;  window-scoped call funnels through UiaFromWindow.
;
;  THE WORKFLOW ENGINE USES THIS AS A FALLBACK (2026-08-01)
;  It used to say the engine stayed on Acc.ahk, one accessibility
;  path for recording and playback. That stopped being tenable:
;  current Chrome exposes NO web page content over MSAA — only its
;  own toolbars and tabs — so every workflow that clicked or read
;  inside a page was blind, including saved ones that used to
;  work. (Measured: an MSAA dump of a data-rich Chrome window gave
;  ~109 descendants, all browser chrome; the same window over UIA
;  gave the whole page.) lib\Workflow.ahk now tries Acc FIRST and
;  falls back to UIA — desktop apps behave exactly as before, and
;  browsers stop being invisible. This is still the escape hatch
;  for hand-written modules; it is now also the engine's second
;  pair of eyes.
;
;  EVERYTHING RETURNS EMPTY RATHER THAN THROWING
;  A missing element gives "" / 0 / false. A module built on this
;  can be wrong without being fatal — which is the entire point.
;
;  Elements are ComValue(13) wrappers (VT_UNKNOWN), so AHK
;  releases them for you when they go out of scope.
; ============================================================

; ---- identifiers ------------------------------------------------------
; Functions, not bare "NAME => value" constants: the fat-arrow property form
; is only legal inside a class, and a plain global would need the assignment
; to run before whatever includes this file uses it.
;
; CLSID_CUIAutomation / IID_IUIAutomation. IUIAutomation is a pure vtable
; interface (no IDispatch), which is why every call below is a ComCall.
UIA_CLSID() => "{FF48DBA4-60EF-4201-AA87-54103EEF594E}"
UIA_IID()   => "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}"

; Property ids (UIA_*PropertyId). ControlType is an INT property, which is
; why UiaIntCondition exists: a BSTR condition can never filter on it, and
; without that filter you cannot tell a form's label from its input (they
; share one accessible Name — see UiaFindEdit).
UIA_PROP_NAME()         => 30005
UIA_PROP_AUTOMATIONID() => 30011
UIA_PROP_CONTROLTYPE()  => 30003

; ControlType ids (UIA_*ControlTypeId) — the few worth naming. Any other id
; can be passed to UiaFindOfType directly.
UIA_TYPE_BUTTON()   => 50000
UIA_TYPE_CHECKBOX() => 50002
UIA_TYPE_COMBOBOX() => 50003
UIA_TYPE_EDIT()     => 50004
UIA_TYPE_LINK()     => 50005
UIA_TYPE_LISTITEM() => 50007
UIA_TYPE_MENUITEM() => 50011
UIA_TYPE_RADIO()    => 50013
UIA_TYPE_SPINNER()  => 50016
UIA_TYPE_TEXT()     => 50020
UIA_TYPE_DOCUMENT() => 50030

; TreeScope: 4 = descendants, 7 = the element and its whole subtree.
UIA_SCOPE_DESCENDANTS() => 4
UIA_SCOPE_SUBTREE()     => 7

; Pattern ids (UIA_*PatternId).
UIA_PAT_INVOKE()     => 10000
UIA_PAT_VALUE()      => 10002
UIA_PAT_SCROLLITEM() => 10017

; How much of a subtree a text walk will look at before giving up. Same
; shape as Acc.ahk's AccNodeOnce limits and for the same reason: a browser's
; tree is enormous, and an unbounded walk turns a 200 ms check into a stall.
UIA_NODE_BUDGET() => 6000

; ---- the automation object -------------------------------------------
; Created once and cached. Unlike oleacc there is no DLL to pin: this is a
; real COM server, so the object keeps itself alive.
UiaAuto() {
    static auto := ""
    if (auto = "") {
        try auto := ComObject(UIA_CLSID(), UIA_IID())
        catch
            auto := 0                       ; UIA unavailable — stay usable
    }
    return auto
}

; True when UIA can be used at all. Check once at the top of a module.
UiaAvailable() {
    return UiaAuto() != 0
}

; ---- small COM plumbing ----------------------------------------------
; A VARIANT holding a BSTR. Returned as {buf, bstr}; free with UiaFreeVar.
; On x64 a VARIANT argument is passed BY REFERENCE, which is why callers
; hand ComCall the buffer as "ptr" (same trap as Acc.ahk's accLocation).
UiaVarBSTR(text) {
    buf := Buffer(24, 0)
    bstr := DllCall("oleaut32\SysAllocString", "wstr", text, "ptr")
    NumPut("ushort", 8, buf, 0)             ; VT_BSTR
    NumPut("ptr", bstr, buf, 8)
    return {buf: buf, bstr: bstr}
}

UiaFreeVar(v) {
    if (v.bstr)
        DllCall("oleaut32\SysFreeString", "ptr", v.bstr)
}

; A VARIANT holding a 32-bit int (VT_I4). Nothing to free, so it is returned
; in the same {buf, bstr} shape with a null bstr and UiaFreeVar is a no-op on
; it — callers then treat both kinds of condition value identically.
UiaVarI4(n) {
    buf := Buffer(24, 0)
    NumPut("ushort", 3, buf, 0)             ; VT_I4
    NumPut("int", n, buf, 8)
    return {buf: buf, bstr: 0}
}

; The process a window belongs to. GetWindowThreadProcessId rather than
; WinGetPID: this is called with control HWNDs too, and it has no
; window-detection semantics to get in the way.
UiaWindowPid(hwnd) {
    pid := 0
    try DllCall("GetWindowThreadProcessId", "ptr", hwnd, "uint*", &pid)
    return pid
}

; False for a window owned by the calling script — see the header. This is
; the guard that turns "wedge the process forever" into "find nothing".
UiaOtherProcess(hwnd) {
    pid := UiaWindowPid(hwnd)
    return pid != 0 && pid != DllCall("GetCurrentProcessId", "uint")
}

; Read and free a BSTR out-param.
UiaBStrOut(bstr) {
    if !bstr
        return ""
    s := StrGet(bstr, "UTF-16")
    DllCall("oleaut32\SysFreeString", "ptr", bstr)
    return s
}

; Wrap a raw interface pointer so AHK releases it for us. 13 = VT_UNKNOWN.
UiaWrap(p) {
    return p ? ComValue(13, p) : ""
}

; ---- IUIAutomation (vtable slots after IUnknown's 0,1,2) -------------
;   3 CompareElements      4 CompareRuntimeIds    5 GetRootElement
;   6 ElementFromHandle    7 ElementFromPoint     8 GetFocusedElement
;  21 CreateTrueCondition 23 CreatePropertyCondition
;  25 CreateAndCondition

; The element for a whole window — and the one place the own-process rule is
; enforced, because every window-scoped query in this file starts here.
; A window of our own process gives "" rather than a permanent hang.
UiaFromWindow(hwnd) {
    if (!UiaAvailable() || !hwnd || !UiaOtherProcess(hwnd))
        return ""
    try {
        ComCall(6, UiaAuto(), "ptr", hwnd, "ptr*", &el := 0)     ; ElementFromHandle
        return UiaWrap(el)
    }
    return ""
}

; The element under a screen point. Guarded like UiaFromWindow: if the
; window under the point is ours, ElementFromPoint would query our own
; provider on this blocked thread — the same deadlock through a different
; entrance. Resolve the window first and refuse our own.
UiaFromPoint(x, y) {
    if !UiaAvailable()
        return ""
    pt := (y << 32) | (x & 0xFFFFFFFF)
    hwnd := DllCall("WindowFromPoint", "int64", pt, "ptr")
    if (hwnd && !UiaOtherProcess(hwnd))
        return ""
    try {
        ComCall(7, UiaAuto(), "int64", pt, "ptr*", &el := 0)     ; ElementFromPoint
        return UiaWrap(el)
    }
    return ""
}

; The element with keyboard focus. Same guard, third entrance: the focused
; element lives in the foreground window, and if that window is ours,
; GetFocusedElement calls back into this thread and never returns.
UiaFocused() {
    if !UiaAvailable()
        return ""
    fg := DllCall("GetForegroundWindow", "ptr")
    if (fg && !UiaOtherProcess(fg))
        return ""
    try {
        ComCall(8, UiaAuto(), "ptr*", &el := 0)                  ; GetFocusedElement
        return UiaWrap(el)
    }
    return ""
}

; A "this property equals this string" condition.
UiaPropCondition(propId, text) {
    return UiaCondFromVar(propId, UiaVarBSTR(text))
}

; A "this property equals this number" condition — ControlType and the other
; int-valued properties, which a BSTR condition simply cannot express.
UiaIntCondition(propId, n) {
    return UiaCondFromVar(propId, UiaVarI4(n))
}

; Shared CreatePropertyCondition: the VARIANT is passed BY REFERENCE on x64
; (hence "ptr", v.buf) and freed either way.
UiaCondFromVar(propId, v) {
    if !UiaAvailable()
        return ""
    try {
        ComCall(23, UiaAuto(), "int", propId, "ptr", v.buf, "ptr*", &cond := 0)
        return UiaWrap(cond)
    } finally {
        UiaFreeVar(v)
    }
    return ""
}

; Matches everything — the condition a whole-subtree walk needs.
UiaTrueCondition() {
    if !UiaAvailable()
        return ""
    try {
        ComCall(21, UiaAuto(), "ptr*", &cond := 0)               ; CreateTrueCondition
        return UiaWrap(cond)
    }
    return ""
}

; Both conditions at once — e.g. Name = "Name:" AND ControlType = Edit.
UiaAndCondition(c1, c2) {
    if (!UiaAvailable() || !c1 || !c2)
        return ""
    try {
        ComCall(25, UiaAuto(), "ptr", c1, "ptr", c2, "ptr*", &cond := 0)   ; CreateAndCondition
        return UiaWrap(cond)
    }
    return ""
}

; True when two element objects stand for the SAME element on screen
; (CompareElements compares runtime ids). Two finds of one control hand back
; two different wrapper objects, so `=` on the wrappers means nothing — this
; is how "does the keyboard focus sit on the box I clicked?" gets answered
; (lib\Workflow.ahk WfFill's focus gate). False on any failure.
UiaSameElement(el1, el2) {
    if (!UiaAvailable() || !el1 || !el2)
        return false
    try {
        ComCall(3, UiaAuto(), "ptr", el1, "ptr", el2, "int*", &same := 0)   ; CompareElements
        return same != 0
    }
    return false
}

; ---- IUIAutomationElement (vtable slots) ------------------------------
;   3 SetFocus             5 FindFirst            6 FindAll
;  16 GetCurrentPattern   21 get_CurrentControlType
;  23 get_CurrentName     28 get_CurrentIsEnabled
;  29 get_CurrentAutomationId  35 get_CurrentIsPassword
;  43 get_CurrentBoundingRectangle
;
; ---- IUIAutomationElementArray (what FindAll hands back) --------------
;   3 get_Length           4 GetElement

UiaName(el) {
    if !el
        return ""
    try {
        ComCall(23, el, "ptr*", &b := 0)                         ; get_CurrentName
        return UiaBStrOut(b)
    }
    return ""
}

UiaAutomationId(el) {
    if !el
        return ""
    try {
        ComCall(29, el, "ptr*", &b := 0)                         ; get_CurrentAutomationId
        return UiaBStrOut(b)
    }
    return ""
}

UiaEnabled(el) {
    if !el
        return false
    try {
        ComCall(28, el, "int*", &v := 0)                         ; get_CurrentIsEnabled
        return v != 0
    }
    return false
}

; True for a password box (a Win32 ES_PASSWORD edit, an <input type=password>).
; What a verifier needs to know BEFORE reading a box back: a password box
; hands out nothing (or a mask), so reading it proves nothing — lib\Workflow.ahk
; WfFill fills one but skips the readback and says so. Slot 35 sits between
; the verified 29 AutomationId and 43 BoundingRectangle and is exercised by
; tests\uia-selftest.ahk against a real password edit and a plain one.
UiaIsPassword(el) {
    if !el
        return false
    try {
        ComCall(35, el, "int*", &v := 0)                         ; get_CurrentIsPassword
        return v != 0
    }
    return false
}

; The element's UIA_*ControlTypeId (50004 = Edit, ...), or 0. Worth reading
; when you have an element and want to know whether you got the label or the
; box beside it.
UiaControlType(el) {
    if !el
        return 0
    try {
        ComCall(21, el, "int*", &v := 0)                         ; get_CurrentControlType
        return v
    }
    return 0
}

; Screen rectangle -> {x, y, w, h}, or "" when the element has none
; (offscreen / collapsed elements report a zero rect).
UiaRect(el) {
    if !el
        return ""
    try {
        r := Buffer(16, 0)
        ComCall(43, el, "ptr", r)                                ; RECT: l, t, r, b
        l := NumGet(r, 0, "int"), t := NumGet(r, 4, "int")
        rr := NumGet(r, 8, "int"), bb := NumGet(r, 12, "int")
        if (rr > l && bb > t)
            return {x: l, y: t, w: rr - l, h: bb - t}
    }
    return ""
}

UiaFocus(el) {
    if !el
        return false
    try {
        ; No trailing type: the default return handling checks the HRESULT, so
        ; a failure lands in this try instead of being silently swallowed.
        ComCall(3, el)                                           ; SetFocus
        return true
    }
    return false
}

; First descendant matching `cond`, or "".
UiaFindFirst(el, cond, scope := 4) {
    if (!el || !cond)
        return ""
    try {
        ComCall(5, el, "int", scope, "ptr", cond, "ptr*", &found := 0)
        return UiaWrap(found)
    }
    return ""
}

; EVERY descendant matching `cond`, in tree order, as a plain AHK array.
; Bounded by maxItems — a true-condition walk of a browser tab can otherwise
; hand back tens of thousands of elements, and reading each one is a
; cross-process call. (The FindAll itself is ONE call that UIA completes
; before anything here can count: maxItems caps what is read afterwards,
; not how long the provider takes to build the array.)
UiaFindElements(el, cond, scope := 4, maxItems := 0) {
    out := []
    if (!el || !cond)
        return out
    if (maxItems <= 0)
        maxItems := UIA_NODE_BUDGET()
    try {
        ComCall(6, el, "int", scope, "ptr", cond, "ptr*", &arr := 0)     ; FindAll
        if !arr
            return out
        a := UiaWrap(arr)
        ComCall(3, a, "int*", &len := 0)                                 ; get_Length
        Loop Min(len, maxItems) {
            ComCall(4, a, "int", A_Index - 1, "ptr*", &item := 0)        ; GetElement
            if item
                out.Push(UiaWrap(item))
        }
    }
    return out
}

; ---- what a module actually calls -------------------------------------

; Find an element by its UIA Name inside a window, retrying until ~timeoutMs
; so late-rendering UIs get a chance (same shape as Acc.ahk AccFindByName).
;
; occurrence picks the Nth match in tree order. It defaults to 1, so every
; existing caller is unaffected — but ONE NAME OFTEN MATCHES MORE THAN ONE
; ELEMENT. Real web forms give the label and the input the same accessible
; name (measured on a live registration form: Text "Name:" at 61 px wide,
; immediately followed by Edit "Name:"), and because UiaValue falls back to
; the Name you cannot even tell from the value that you grabbed the label.
; When you want the input, prefer UiaFindEdit; occurrence is the escape
; hatch for everything else.
UiaFind(hwnd, name, timeoutMs := 3000, occurrence := 1) {
    return UiaFindBy(hwnd, UIA_PROP_NAME(), name, timeoutMs, occurrence)
}

; Find by AutomationId. PREFER THIS where an app provides one: unlike a
; visible Name it is set by the developer, so it survives relabelling and
; translation.
UiaFindById(hwnd, automationId, timeoutMs := 3000, occurrence := 1) {
    return UiaFindBy(hwnd, UIA_PROP_AUTOMATIONID(), automationId, timeoutMs, occurrence)
}

; Shared find-by-string-property with a retry budget.
UiaFindBy(hwnd, propId, text, timeoutMs := 3000, occurrence := 1) {
    return UiaFindCond(hwnd, UiaPropCondition(propId, text), timeoutMs, occurrence)
}

; Every element of this Name in the window, in tree order. The answer to
; "which one of these is the box and which is the label?" — read UiaRect or
; UiaControlType on each and pick.
UiaFindAll(hwnd, name, timeoutMs := 3000, maxItems := 0) {
    return UiaFindAllCond(hwnd, UiaPropCondition(UIA_PROP_NAME(), name), timeoutMs, maxItems)
}

; The Edit named `name` — not the label that shares its name. This is the
; one that unblocks form filling; UiaFind alone returns whichever comes
; first in tree order, which on a label-then-input layout is the label.
UiaFindEdit(hwnd, name, timeoutMs := 3000, occurrence := 1) {
    return UiaFindOfType(hwnd, name, UIA_TYPE_EDIT(), timeoutMs, occurrence)
}

; The same idea for any control type: Name AND ControlType, ANDed together.
; controlType is a UIA_*ControlTypeId (UIA_TYPE_EDIT(), UIA_TYPE_BUTTON(), ...).
UiaFindOfType(hwnd, name, controlType, timeoutMs := 3000, occurrence := 1) {
    cond := UiaAndCondition(UiaPropCondition(UIA_PROP_NAME(), name),
                            UiaIntCondition(UIA_PROP_CONTROLTYPE(), controlType))
    return UiaFindCond(hwnd, cond, timeoutMs, occurrence)
}

; Shared retry loop for any condition. occurrence 1 uses FindFirst (one
; cross-process call); anything higher needs the whole match list.
UiaFindCond(hwnd, cond, timeoutMs := 3000, occurrence := 1) {
    root := UiaFromWindow(hwnd)
    if (!root || !cond)
        return ""
    deadline := A_TickCount + timeoutMs
    loop {
        if (occurrence <= 1) {
            if (el := UiaFindFirst(root, cond, UIA_SCOPE_SUBTREE()))
                return el
        } else {
            all := UiaFindElements(root, cond, UIA_SCOPE_SUBTREE(), occurrence)
            if (all.Length >= occurrence)
                return all[occurrence]
        }
        if (A_TickCount >= deadline)
            return ""
        Sleep(150)
    }
}

; Shared retry loop returning ALL matches. Retries only while there are none
; — once something matches, that is the answer for this moment.
UiaFindAllCond(hwnd, cond, timeoutMs := 3000, maxItems := 0) {
    root := UiaFromWindow(hwnd)
    if (!root || !cond)
        return []
    deadline := A_TickCount + timeoutMs
    loop {
        all := UiaFindElements(root, cond, UIA_SCOPE_SUBTREE(), maxItems)
        if (all.Length || A_TickCount >= deadline)
            return all
        Sleep(150)
    }
}

; Wait for an element to appear; "" if it never does.
UiaWaitFor(hwnd, name, timeoutMs := 10000) {
    return UiaFind(hwnd, name, timeoutMs)
}

; The element's ValuePattern text ONLY — "" when it has no ValuePattern or
; the value is empty, never the Name. Use this to VERIFY what a control
; holds (lib\Browser.ahk's type-and-read-back): a check that can be
; satisfied by an element's label is not a check. UiaValue is the reading
; counterpart, where falling back to the Name is the helpful answer.
;
; `has` (optional) says WHICH kind of "" you got: true when the element HAS
; a ValuePattern (so "" means the box is genuinely empty), false when it has
; none. A verifier must tell those apart — an empty target box is exactly
; what a missed click leaves behind, and treating it as "can't tell" sent
; BrowserTypeVerified off to check whatever control had focus instead.
UiaValueOnly(el, &has?) {
    has := false
    if !el
        return ""
    try {
        ComCall(16, el, "int", UIA_PAT_VALUE(), "ptr*", &pat := 0)  ; GetCurrentPattern
        if pat {
            has := true
            p := UiaWrap(pat)
            ComCall(4, p, "ptr*", &b := 0)                        ; get_CurrentValue
            return UiaBStrOut(b)
        }
    }
    return ""
}

; The element's text content, via ValuePattern (an edit box's contents, a
; combo's selection). Falls back to the Name for things with no value.
UiaValue(el) {
    if !el
        return ""
    v := UiaValueOnly(el)
    return v != "" ? v : UiaName(el)
}

; Set an edit box's contents outright — no keystrokes, so nothing races the
; app's own handlers. False when the element has no ValuePattern.
UiaSetValue(el, text) {
    if !el
        return false
    try {
        ComCall(16, el, "int", UIA_PAT_VALUE(), "ptr*", &pat := 0)
        if !pat
            return false
        p := UiaWrap(pat)
        v := UiaVarBSTR(text)
        try {
            ComCall(3, p, "ptr", v.bstr)                          ; SetValue(BSTR)
        } finally {
            UiaFreeVar(v)
        }
        return true
    }
    return false
}

; ---- IUIAutomationScrollItemPattern (vtable slot after IUnknown) ------
;   3 ScrollIntoView

; Ask the element to bring itself into view. This is the answer to
; VIRTUALIZED content — web pages realize only elements near the viewport,
; so anything scrolled away reports no rectangle (and may not be in the
; tree at all) — and to plain scrolled-out list rows. Measured against a
; real Win32 list: rect none -> ScrollIntoView -> real rect. False when the
; element offers no such pattern; nothing moves then.
UiaScrollIntoView(el) {
    if !el
        return false
    try {
        ComCall(16, el, "int", UIA_PAT_SCROLLITEM(), "ptr*", &pat := 0)  ; GetCurrentPattern
        if !pat
            return false
        ComCall(3, UiaWrap(pat))                                         ; ScrollIntoView
        return true
    }
    return false
}

; Press it. Uses InvokePattern where the control offers one (which works even
; when the control is scrolled out of the way or the pointer is elsewhere);
; otherwise clicks its centre via UiaClickEl (which inherits the scroll-into-
; view rescue and the no-rectangle refusal). On false, `why` says which
; precondition failed.
UiaInvoke(el, &why?) {
    why := ""
    if !el {
        why := "no element — the find returned nothing"
        return false
    }
    try {
        ComCall(16, el, "int", UIA_PAT_INVOKE(), "ptr*", &pat := 0)
        if pat {
            ComCall(3, UiaWrap(pat))                              ; Invoke
            return true
        }
    }
    return UiaClickEl(el, 0, "Left", 1, &why)
}

; Convenience: find by name in a window and press it. The one-liner most
; modules want — but see UiaClickCenter when the target is a form field.
; On false, `why` names what went wrong (nothing found / nowhere to click).
UiaClickName(hwnd, name, timeoutMs := 3000, &why?) {
    why := ""
    el := UiaFind(hwnd, name, timeoutMs)
    if !el {
        why := "no element named '" name "' in the window — web pages VIRTUALIZE (only content near the viewport is in the tree), so scroll it into view first or navigate directly"
        return false
    }
    return UiaInvoke(el, &why)
}

; ---- clicking for real ------------------------------------------------
;  UiaInvoke fires InvokePattern where there is one, which is right for
;  buttons and links: it works even when the control is scrolled away. It is
;  the WRONG tool for a text field. Invoke moves no mouse and gives nothing
;  keyboard focus, and plenty of controls (an <input> among them) expose no
;  InvokePattern at all, so the call quietly does nothing and the keystrokes
;  that follow land wherever focus happened to be.
;
;  These two put the pointer on the element and click it, which is what a
;  person does and what every control responds to.

; Click an element at its centre, optionally jittered by up to jitterPx
; pixels (clamped inside the rect, so a jittered click can never miss).
; Restores the caller's CoordMode.
;
; FAILS LOUDLY when there is nowhere to click (2026-08-03 feedback: a click
; on a rect-less element "worked" — no error — and went nowhere, which cost
; a real session most of an hour). No rectangle is how offscreen and
; VIRTUALIZED elements present, so before refusing this asks the element to
; scroll itself into view (ScrollItemPattern) and re-reads the rectangle —
; that rescues the plain scrolled-away case. On false, `why` names the
; reason, so a module can Out()/log it instead of shrugging.
UiaClickEl(el, jitterPx := 0, button := "Left", count := 1, &why?) {
    why := ""
    if !el {
        why := "no element — the find returned nothing"
        return false
    }
    r := UiaRect(el)
    if !IsObject(r) {
        scrolled := UiaScrollIntoView(el)
        if scrolled {
            deadline := A_TickCount + 1200
            while (!IsObject(r) && A_TickCount < deadline) {
                Sleep(100)
                r := UiaRect(el)
            }
        }
        if !IsObject(r) {
            why := "element has no bounding rectangle (offscreen or virtualized"
            why .= scrolled ? " even after ScrollIntoView)" : "; it cannot scroll itself into view)"
            why .= " — a mouse click has nowhere to land"
            return false
        }
    }
    p := UiaJitteredCenter(r, jitterPx)
    prev := A_CoordModeMouse
    CoordMode("Mouse", "Screen")
    try MouseClick(button, p.x, p.y, count)
    finally CoordMode("Mouse", prev)
    return true
}

; Where a click on rect r ({x, y, w, h} — UiaRect's shape, and Acc.ahk's)
; lands: its centre, offset by up to jitterPx in each direction but clamped
; to a third of the extent (UiaJitter), so it can never leave the element.
; The one copy of this maths: lib\Workflow.ahk's WfClickPoint uses it too.
UiaJitteredCenter(r, jitterPx := 0) {
    cx := r.x + r.w // 2, cy := r.y + r.h // 2
    if (jitterPx > 0) {
        cx += UiaJitter(jitterPx, r.w)
        cy += UiaJitter(jitterPx, r.h)
    }
    return {x: cx, y: cy}
}

; Find by name, then click it for real. jitterPx > 0 spreads the landing
; point a little — see WfClickJitter in lib\Workflow.ahk for why that
; matters when a workflow hits the same site in a loop. On false, `why`
; names what went wrong (nothing found / nowhere to click).
UiaClickCenter(hwnd, name, timeoutMs := 3000, jitterPx := 0, &why?) {
    why := ""
    el := UiaFind(hwnd, name, timeoutMs)
    if !el {
        why := "no element named '" name "' in the window — web pages VIRTUALIZE (only content near the viewport is in the tree), so scroll it into view first or navigate directly"
        return false
    }
    return UiaClickEl(el, jitterPx, "Left", 1, &why)
}

; A random offset in [-maxPx, +maxPx], never more than a third of the extent
; it is applied to — on a 12 px control a 4 px jitter would sit on the edge.
;
; The parameter is maxPx, not max: functions and variables share one
; case-insensitive namespace, so a parameter called `max` shadows the Max()
; built-in and the call below fails at RUNTIME with "Integer has no method
; named Call" — it load-checks clean, which is how it got this far once.
UiaJitter(maxPx, extent) {
    lim := Min(maxPx, Max(0, extent // 3))
    return lim > 0 ? Random(-lim, lim) : 0
}

; ---- reading what is on screen ----------------------------------------
;  Acc.ahk has AccTextPresent; without an equivalent here the only way to
;  read a modern page was ^a/^c, which depends on focus and stamps on the
;  user's clipboard. Both of these walk the UIA subtree instead.

; True if `needle` appears (case-insensitively, as a substring) in any
; element's Name or Value. Retries until ~timeoutMs, so it doubles as
; "wait for the results to render".
;
; The deadline governs the RETRIES, not the scan: each attempt reads the
; whole array FindAll returned (capped by UIA_NODE_BUDGET, 6000 elements).
; It used to break out of the scan at the deadline, but the deadline was set
; BEFORE the FindAll — which on a big page can take the whole budget by
; itself — so the scan often looked at one element and said "not there".
; On a large page an attempt can therefore run past timeoutMs; a slower
; right answer beats a fast wrong one (textvisible read a present result as
; absent, and textnotvisible passed at once).
UiaTextPresent(hwnd, needle, timeoutMs := 700) {
    needle := Trim(needle)
    if (needle = "")
        return false
    root := UiaFromWindow(hwnd)
    cond := UiaTrueCondition()
    if (!root || !cond)
        return false
    deadline := A_TickCount + timeoutMs
    loop {
        for el in UiaFindElements(root, cond, UIA_SCOPE_SUBTREE(), UIA_NODE_BUDGET()) {
            ; InStr is case-insensitive by default in v2 — deliberate, like
            ; AccTextOnce: the author types what they saw on screen, not what
            ; the app capitalised. UiaValueOnly, not UiaValue: the Name was
            ; just checked, and UiaValue's Name fallback would read it twice.
            if InStr(UiaName(el), needle)
                return true
            if InStr(UiaValueOnly(el), needle)
                return true
        }
        if (A_TickCount >= deadline)
            return false
        Sleep(150)
    }
}

; Everything the window says, in tree order, newline-joined — the readable
; dump that replaces select-all-and-copy. Consecutive duplicates are dropped
; (a container and its only child usually report the same string), and the
; result is capped at maxChars so a big page can't blow up a log or a
; message box. Empty string when UIA can't see the window.
UiaDumpText(hwnd, maxChars := 100000) {
    root := UiaFromWindow(hwnd)
    cond := UiaTrueCondition()
    if (!root || !cond)
        return ""
    out := "", last := ""
    for el in UiaFindElements(root, cond, UIA_SCOPE_SUBTREE(), UIA_NODE_BUDGET()) {
        for s in [UiaName(el), UiaValueOnly(el)] {     ; (UiaValue would re-read the Name — deduped anyway)
            s := Trim(s)
            if (s = "" || s = last)
                continue
            last := s
            out .= (out = "" ? "" : "`n") s
            if (StrLen(out) >= maxChars)
                return SubStr(out, 1, maxChars)
        }
    }
    return out
}

; ---- walking the structure --------------------------------------------
;  UiaFind answers "is X here?"; these answer "what IS here?". They exist
;  for the diagnosis case that used to need a throwaway hotkey module: a
;  find that matches nothing, and no way to see the names the window
;  actually exposes. The walker is the RAW view on purpose — FindFirst /
;  FindAll match against the full tree, so a dump filtered to the control
;  view could hide the very element a find would have returned.

; The cached IUIAutomationTreeWalker for the raw view. "" when UIA is
; unavailable or the walker can't be created (then every navigation below
; quietly returns "", like everything else here).
UiaRawWalker() {
    static walker := ""
    if (walker = "" && UiaAvailable()) {
        try {
            ComCall(16, UiaAuto(), "ptr*", &w := 0)      ; get_RawViewWalker
            walker := UiaWrap(w)
        }
    }
    return walker
}

; ---- IUIAutomationTreeWalker (vtable slots after IUnknown's 0,1,2) ----
;   3 GetParentElement     4 GetFirstChildElement
;   6 GetNextSiblingElement

; The element's parent in the raw tree — "" at the top, and on any failure.
UiaParent(el) {
    return UiaWalkerStep(3, el)
}

UiaFirstChild(el) {
    return UiaWalkerStep(4, el)
}

UiaNextSibling(el) {
    return UiaWalkerStep(6, el)
}

; Shared TreeWalker navigation: slot 3 parent / 4 first child / 6 next
; sibling. All three take (element in, element out) and NULL out means
; "there isn't one", which wraps to "".
UiaWalkerStep(slot, el) {
    w := UiaRawWalker()
    if (!w || !el)
        return ""
    try {
        ComCall(slot, w, "ptr", el, "ptr*", &out := 0)
        return UiaWrap(out)
    }
    return ""
}

; Readable name for a UIA_*ControlTypeId — "Button", "Edit", ... An unknown
; id comes back as its bare number, still greppable. Ids verified against
; UIAutomationClient.h (Windows SDK 10.0.26100.0).
UiaControlTypeName(typeId) {
    static names := Map(
        50000, "Button", 50001, "Calendar", 50002, "CheckBox", 50003, "ComboBox",
        50004, "Edit", 50005, "Hyperlink", 50006, "Image", 50007, "ListItem",
        50008, "List", 50009, "Menu", 50010, "MenuBar", 50011, "MenuItem",
        50012, "ProgressBar", 50013, "RadioButton", 50014, "ScrollBar",
        50015, "Slider", 50016, "Spinner", 50017, "StatusBar", 50018, "Tab",
        50019, "TabItem", 50020, "Text", 50021, "ToolBar", 50022, "ToolTip",
        50023, "Tree", 50024, "TreeItem", 50025, "Custom", 50026, "Group",
        50027, "Thumb", 50028, "DataGrid", 50029, "DataItem", 50030, "Document",
        50031, "SplitButton", 50032, "Window", 50033, "Pane", 50034, "Header",
        50035, "HeaderItem", 50036, "Table", 50037, "TitleBar", 50038, "Separator",
        50039, "SemanticZoom", 50040, "AppBar")
    return names.Has(typeId) ? names[typeId] : String(typeId)
}

; The window's tree as an indented text outline, one element per line:
;     Window "VKUiaTarget_ZZ"
;       Button "Press Me Zz" <id=SaveBtn>
; nameFilter (case-insensitive substring) keeps only matching LINES while
; still walking everything, so a match deep in a page stays findable and its
; depth stays visible in the indent. Bounded three ways — maxDepth, maxLines
; of output, and UIA_NODE_BUDGET() visited nodes — because a diagnostic must
; never become the stall it is diagnosing. "" when UIA can't see the window.
UiaDumpTree(hwnd, maxDepth := 8, nameFilter := "", maxLines := 300) {
    root := UiaFromWindow(hwnd)
    if !root
        return ""
    lines := []
    budget := UIA_NODE_BUDGET()
    UiaDumpTreeWalk(root, 0, maxDepth, nameFilter, maxLines, lines, &budget)
    out := ""
    for line in lines
        out .= (out = "" ? "" : "`n") line
    return out
}

; Recursive worker. `budget` counts visited nodes across the whole walk;
; `lines` collects output (its Length enforces maxLines).
UiaDumpTreeWalk(el, depth, maxDepth, nameFilter, maxLines, lines, &budget) {
    if (!el || budget <= 0 || lines.Length >= maxLines)
        return
    budget -= 1
    ; Fold a multi-line name onto one line — one element, one line, always.
    name := StrReplace(StrReplace(UiaName(el), "`r", " "), "`n", " ")
    if (nameFilter = "" || InStr(name, nameFilter)) {
        line := ""
        Loop depth
            line .= "  "
        line .= UiaControlTypeName(UiaControlType(el)) ' "' name '"'
        aid := UiaAutomationId(el)
        if (aid != "")
            line .= " <id=" aid ">"
        lines.Push(line)
    }
    if (depth >= maxDepth)
        return
    child := UiaFirstChild(el)
    while (child != "" && budget > 0 && lines.Length < maxLines) {
        UiaDumpTreeWalk(child, depth + 1, maxDepth, nameFilter, maxLines, lines, &budget)
        child := UiaNextSibling(child)
    }
}
