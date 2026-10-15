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
;  But an empty answer must not be a MYSTERY (2026-10-12 feedback:
;  "no match", "couldn't get the window root" and "the lookup threw
;  and was swallowed" all looked identical, and a page change was
;  blamed on a flaky browser). Every find — UiaFromWindow,
;  UiaFindFirst / UiaFindElements, UiaFindCond / UiaFindAllCond and
;  their wrappers — takes a trailing optional &why: "" on success,
;  otherwise the reason, with elapsed ms and attempts for the
;  retrying ones. Pass it whenever an empty result would surprise you.
;
;  !! A SEARCH FROM A SUB-ELEMENT CAN COME BACK FROM OUTSIDE IT !!
;  Measured in Chrome (2026-10-12, a tax-software page): FindFirst
;  for an Edit, started from three DIFFERENT label groups, returned
;  the SAME box all three times — an element outside every one of
;  them. Nothing errors and the answer looks plausible, which is the
;  worst way to fail. So UiaFindFirst, when started below a window,
;  checks the hit really is inside its start element (UiaIsWithin)
;  and, when it is not, searches the start element's own subtree by
;  walking it (UiaFindFirstWalk — what found the right box by hand)
;  and says so in &why; UiaFindElements drops out-of-scope hits the
;  same way. A search from a WINDOW root (UiaFind*, UiaFindCond)
;  skips the check: everything in the window is in scope. Rule:
;  search from the window root, or through these helpers — never a
;  raw ComCall(5/6) from a sub-element.
;
;  !! A RECTANGLE IS NOT A PLACE YOU CAN CLICK !! (2026-10-14)
;  Chrome reports a rectangle for an element scrolled outside an inner
;  scroll panel, or sitting under a header pinned over the panel, and a
;  click at that rectangle lands on whatever is really there — on a
;  three-monitor desk, once, a different monitor. So UiaClickEl (and
;  everything built on it) clicks only inside UiaVisibleRect — the part
;  of the element its scrolling containers, its window and a real
;  monitor all let through — then hit-tests that point
;  (UiaElementAtPoint) and refuses, with &why saying what kind of
;  thing is in the way (&detail names it), when the point belongs to
;  something else. Never click a raw UiaRect from a module; go through
;  UiaClickEl / UiaClickablePoint.
;
;  Coordinates follow the CALLING THREAD's DPI context (measured
;  2026-10-14: UIA rectangles, MonitorGet, WindowFromPoint and
;  MouseMove all do), so the numbers these functions take and give
;  agree with each other and with MouseClick/MouseGetPos in the same
;  script. AutoHotkey runs system-DPI-aware, where Windows virtualizes
;  coordinates on a monitor whose scale differs from the main one, so
;  UiaClickEl decides and clicks inside UiaDpiPhysical() /
;  UiaDpiRestore() (physical pixels, nothing virtualized).
;
;  The click path's &why never contains an element name, a window
;  title or a program name — the workflow engine records it, and those
;  can name a client. &detail (UiaClickEl, UiaClickablePoint,
;  UiaVisibleRect, UiaHitTest ...) is the same text WITH them, for a
;  local log or Out().
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
UIA_PAT_SCROLL()     => 10004   ; a scroll CONTAINER (what clips its content)
UIA_PAT_SCROLLITEM() => 10017

; How far UiaVisibleRect climbs looking for the top-level window. A real
; tree is far shallower (a deep Chrome page is under 100 levels); hitting
; this means the walk is broken, and the visible area is then unknown.
UIA_VIS_MAX_HOPS() => 256

; How much of a subtree a text walk will look at before giving up. Same
; shape as Acc.ahk's AccNodeOnce limits and for the same reason: a browser's
; tree is enormous, and an unbounded walk turns a 200 ms check into a stall.
UIA_NODE_BUDGET() => 6000

; The longest a UiaDumpTree walk may run. The node budget bounds the COUNT,
; but on a slow provider 6000 nodes can still take longer than the MCP probe
; lives (25 s); stopping here leaves time to report what was walked, with
; timeHit set, instead of being killed with nothing to show.
UIA_DUMP_TIME_MS() => 15000

; The longest UiaFindFirstWalk may run — the fallback UiaFindFirst takes
; when a provider answers from outside the start element. Shorter than the
; dump's cap: it runs inside bodies, where a find that misses must give up
; and say so rather than stall the run.
UIA_WALK_TIME_MS() => 5000

; ---- the automation object -------------------------------------------
; Created once and cached. Unlike oleacc there is no DLL to pin: this is a
; real COM server, so the object keeps itself alive.
; Returns the IUIAutomation object, or 0 when UIA is unavailable.
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
; Returns true when UIA can be used, false when it is unavailable.
UiaAvailable() {
    return UiaAuto() != 0
}

; ---- small COM plumbing ----------------------------------------------
; A VARIANT holding a BSTR. Returned as {buf, bstr}; free with UiaFreeVar.
; On x64 a VARIANT argument is passed BY REFERENCE, which is why callers
; hand ComCall the buffer as "ptr" (same trap as Acc.ahk's accLocation).
; Returns an object {buf, bstr}: buf the 24-byte VARIANT Buffer, bstr the
; string pointer UiaFreeVar frees.
UiaVarBSTR(text) {
    buf := Buffer(24, 0)
    bstr := DllCall("oleaut32\SysAllocString", "wstr", text, "ptr")
    NumPut("ushort", 8, buf, 0)             ; VT_BSTR
    NumPut("ptr", bstr, buf, 8)
    return {buf: buf, bstr: bstr}
}

; Free a UiaVarBSTR's string (a no-op on a UiaVarI4).
; Returns nothing.
UiaFreeVar(v) {
    if (v.bstr)
        DllCall("oleaut32\SysFreeString", "ptr", v.bstr)
}

; A VARIANT holding a 32-bit int (VT_I4). Nothing to free, so it is returned
; in the same {buf, bstr} shape with a null bstr and UiaFreeVar is a no-op on
; it — callers then treat both kinds of condition value identically.
; Returns an object {buf, bstr: 0} (nothing to free).
UiaVarI4(n) {
    buf := Buffer(24, 0)
    NumPut("ushort", 3, buf, 0)             ; VT_I4
    NumPut("int", n, buf, 8)
    return {buf: buf, bstr: 0}
}

; The process a window belongs to. GetWindowThreadProcessId rather than
; WinGetPID: this is called with control HWNDs too, and it has no
; window-detection semantics to get in the way.
; Returns the process id, or 0 when the window doesn't exist or the call
; failed.
UiaWindowPid(hwnd) {
    pid := 0
    try DllCall("GetWindowThreadProcessId", "ptr", hwnd, "uint*", &pid)
    return pid
}

; False for a window owned by the calling script — see the header. This is
; the guard that turns "wedge the process forever" into "find nothing".
; Returns true for a window of another process; false for one of this script's
; own process, or when its process can't be read (no such window).
UiaOtherProcess(hwnd) {
    pid := UiaWindowPid(hwnd)
    return pid != 0 && pid != DllCall("GetCurrentProcessId", "uint")
}

; Read and free a BSTR out-param.
; Returns the string (the BSTR is freed), or "" for a null BSTR.
UiaBStrOut(bstr) {
    if !bstr
        return ""
    s := StrGet(bstr, "UTF-16")
    DllCall("oleaut32\SysFreeString", "ptr", bstr)
    return s
}

; Wrap a raw interface pointer so AHK releases it for us. 13 = VT_UNKNOWN.
; Returns a ComValue wrapper (VT_UNKNOWN, released automatically), or "" for a
; null pointer.
UiaWrap(p) {
    return p ? ComValue(13, p) : ""
}

; A caught error as one line for a &why: its message, plus the HRESULT when
; the message doesn't already carry it, plus what the common one means.
; Returns one line of text, never "" (the error's type name when it has no
; message).
UiaErrText(e) {
    msg := Trim(StrReplace(StrReplace(e.Message, "`r", " "), "`n", " "))
    code := (e is OSError && e.Number) ? e.Number & 0xFFFFFFFF : 0
    if (code && !InStr(msg, Format("{:08X}", code)))
        msg .= " (0x" Format("{:08X}", code) ")"
    if (code = 0x80040201)                  ; UIA_E_ELEMENTNOTAVAILABLE
        msg .= " — the element is gone (the page changed or the window closed)"
    return msg != "" ? msg : Type(e)
}

; " after N ms (K attempts)" — how a retrying find's &why says how long it
; tried, so a 5 s miss and a 0 ms miss can't read alike.
; Returns the text " after N ms (K attempts)", leading space included.
UiaTookText(t0, attempts) {
    return " after " (A_TickCount - t0) " ms (" attempts " attempt" (attempts = 1 ? "" : "s") ")"
}

; CRC-32 of a string's UTF-16 bytes, chained from `crc` — ntdll's own
; RtlComputeCrc32, so a fingerprint over thousands of nodes costs no AHK
; loop. Standard CRC-32 (tests\uia-selftest.ahk pins "123456789").
; Returns the CRC-32 as an unsigned integer (pass it back as crc to chain).
UiaCrc32(s, crc := 0) {
    return DllCall("ntdll\RtlComputeCrc32", "uint", crc, "str", s, "int", StrLen(s) * 2, "uint")
}

; ---- IUIAutomation (vtable slots after IUnknown's 0,1,2) -------------
;   3 CompareElements      4 CompareRuntimeIds    5 GetRootElement
;   6 ElementFromHandle    7 ElementFromPoint     8 GetFocusedElement
;  21 CreateTrueCondition 23 CreatePropertyCondition
;  25 CreateAndCondition

; The element for a whole window — and the one place the own-process rule is
; enforced, because every window-scoped query in this file starts here.
; A window of our own process gives "" rather than a permanent hang.
; Returns the window's root element, or ""; `why` is "" on success, else
; which of the five ways it failed.
UiaFromWindow(hwnd, &why?) {
    why := ""
    if !UiaAvailable() {
        why := "UI Automation is unavailable on this system"
        return ""
    }
    if !hwnd {
        why := "no window (hwnd 0) — the window lookup matched nothing"
        return ""
    }
    isWin := 0
    try isWin := DllCall("IsWindow", "ptr", hwnd)
    if !isWin {
        why := "no such window (hwnd " hwnd ") — it has closed"
        return ""
    }
    if !UiaOtherProcess(hwnd) {
        why := "the window belongs to this script's own process — refused, because UIA against its own process deadlocks (automate other processes only)"
        return ""
    }
    try {
        ComCall(6, UiaAuto(), "ptr", hwnd, "ptr*", &el := 0)     ; ElementFromHandle
        if el
            return UiaWrap(el)
        why := "couldn't get the window's UIA root element (ElementFromHandle returned nothing)"
    } catch as e {
        why := "couldn't get the window's UIA root element (ElementFromHandle failed: " UiaErrText(e) ")"
    }
    return ""
}

; The element under a screen point (IUIAutomation::ElementFromPoint — the
; POINT goes by value as one int64, y in the high half). Guarded like
; UiaFromWindow: if the window under the point is ours, ElementFromPoint
; would query our own provider on this blocked thread — the same deadlock
; through a different entrance. So the window is resolved first
; (WindowFromPoint + its process) and our own is refused. This is the hit
; test UiaClickEl runs before every click (see UiaHitTest). A provider may
; answer with the nearest hit-testable ANCESTOR rather than the leaf under
; the point (Chrome does), and a point over no window answers the desktop.
; Returns the element, or ""; `why` is "" on success, else why there is
; none (UIA unavailable, not a point, our own window there, or the call
; failed). x and y may be Floats (r.x + r.w / 2): they are rounded.
UiaElementAtPoint(x, y, &why?) {
    why := ""
    if !UiaAvailable() {
        why := "UI Automation is unavailable on this system"
        return ""
    }
    if !UiaPointArg(&x, &y) {
        why := "not a screen point (x and y must be numbers)"
        return ""
    }
    pt := (y << 32) | (x & 0xFFFFFFFF)
    hwnd := DllCall("WindowFromPoint", "int64", pt, "ptr")
    if (hwnd && !UiaOtherProcess(hwnd)) {
        why := "the window at " x "," y " belongs to this script's own process — refused, because UIA against its own process deadlocks"
        return ""
    }
    try {
        ComCall(7, UiaAuto(), "int64", pt, "ptr*", &el := 0)     ; ElementFromPoint
        if el
            return UiaWrap(el)
        why := "ElementFromPoint returned nothing at " x "," y
    } catch as e {
        why := "ElementFromPoint failed at " x "," y ": " UiaErrText(e)
    }
    return ""
}

; Rounds x and y to whole pixels in place — the int64 POINT packing below
; throws on a Float (measured 2026-10-14: `r.x + r.w / 2` is a Float in v2,
; and "Expected an Integer but got a Float" escaped a function that
; promises never to throw).
; Returns true when both are numbers (now Integers), false otherwise.
UiaPointArg(&x, &y) {
    try {
        x := Integer(Round(x)), y := Integer(Round(y))
        return true
    }
    return false
}

; The element under a screen point — UiaElementAtPoint without the &why
; (kept for existing callers).
; Returns the element, or "" (nothing there, our own window, no UIA).
UiaFromPoint(x, y) {
    return UiaElementAtPoint(x, y)
}

; The element with keyboard focus. Same guard, third entrance: the focused
; element lives in the foreground window, and if that window is ours,
; GetFocusedElement calls back into this thread and never returns.
; Returns the element, or "" (our own window in front, no UIA).
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
; Returns the condition object, or "" when UIA refuses it or is unavailable.
UiaPropCondition(propId, text) {
    return UiaCondFromVar(propId, UiaVarBSTR(text))
}

; A "this property equals this number" condition — ControlType and the other
; int-valued properties, which a BSTR condition simply cannot express.
; Returns the condition object, or "" when UIA refuses it or is unavailable.
UiaIntCondition(propId, n) {
    return UiaCondFromVar(propId, UiaVarI4(n))
}

; Shared CreatePropertyCondition: the VARIANT is passed BY REFERENCE on x64
; (hence "ptr", v.buf) and freed either way.
; Returns the condition object, or "" when UIA refuses it or is unavailable; v
; is freed either way.
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
; Returns the condition object, or "" when UIA refuses it or is unavailable.
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
; Returns the combined condition, or "" when either input is empty or UIA
; refuses it or is unavailable.
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
; Returns true for the same element; false for different ones, an empty
; argument, or any failure.
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
;  16 GetCurrentPattern   20 get_CurrentProcessId
;  21 get_CurrentControlType  23 get_CurrentName
;  28 get_CurrentIsEnabled    29 get_CurrentAutomationId
;  35 get_CurrentIsPassword   38 get_CurrentIsOffscreen
;  43 get_CurrentBoundingRectangle
;  (20 and 38 added 2026-10-14, counted off IUIAutomationElementVtbl in
;  UIAutomationClient.h, SDK 10.0.26100.0, and exercised by the selftest.)
;
; ---- IUIAutomationElementArray (what FindAll hands back) --------------
;   3 get_Length           4 GetElement

; The element's UIA Name, or "" (no element, or the read failed).
;
; stripIcons := true drops icon-font characters first (UiaStripIcons):
; 2026-10-14, a web app's "..." toggle had an accessible name that was ONE
; private-use character (U+E611, an icon-font glyph), so every "has no
; name" check said it had one. Default false: the name exactly as exposed.
; Returns the Name string, or "" (no element, no name, nothing but icon
; characters with stripIcons, or the read failed).
UiaName(el, stripIcons := false) {
    if !el
        return ""
    try {
        ComCall(23, el, "ptr*", &b := 0)                         ; get_CurrentName
        s := UiaBStrOut(b)
        return stripIcons ? UiaStripIcons(s) : s
    }
    return ""
}

; Private Use Area characters as one regex class: the BMP block
; U+E000-U+F8FF and supplementary planes 15/16 (U+F0000-U+FFFFD,
; U+100000-U+10FFFD). Icon fonts (Font Awesome, Material, a web app's own
; glyph font) map their pictures there, and the accessibility tree hands
; the glyph out as the element's text. Measured 2026-10-14: AutoHotkey's
; PCRE runs in UTF mode, so the plane-15/16 ranges match a whole surrogate
; pair (a range written as raw surrogates is a compile error there).
; Returns the regex character class as a string.
UiaIconCharClass() {
    return "[\x{E000}-\x{F8FF}\x{F0000}-\x{FFFFD}\x{100000}-\x{10FFFD}]"
}

; `text` without icon-font (Private Use Area) characters, then trimmed —
; so a name that is only an icon reads as "". What UiaName(el, true) does.
; Returns the cleaned text, "" when nothing else was there.
UiaStripIcons(text) {
    return Trim(UiaIconMap(text, false))
}

; `text` with each icon-font character written out as <U+E611> — how the
; tree dump shows them, so an icon-only name is visible and greppable
; instead of an invisible box (the fingerprint still hashes the raw name).
; Returns the text with every Private Use Area character replaced by its
; <U+XXXX> form (unchanged when it has none).
UiaShowIcons(text) {
    return UiaIconMap(text, true)
}

; The one scan behind UiaStripIcons / UiaShowIcons: each Private Use Area
; character dropped (show false) or written as <U+XXXX> (show true).
; Walked code unit by code unit rather than by regex: measured 2026-10-14,
; a LONE high surrogate (malformed UTF-16, which a provider can hand out)
; made the regex take it AND the next real character as one plane-15/16
; character — UiaStripIcons("a" Chr(0xDB80) "b") returned "a". Here a
; surrogate counts as half of a pair only when the other half is really
; there; a stray one is left as it is. The regex is the fast path: no
; match means nothing to change.
; Returns the mapped text (the same string when it holds no PUA character).
UiaIconMap(text, show) {
    try {
        if !RegExMatch(text, UiaIconCharClass())
            return text
    }
    out := "", p := StrPtr(text), n := StrLen(text), i := 0
    while (i < n) {
        u := NumGet(p, i * 2, "ushort"), len := 1, cp := u
        if (u >= 0xD800 && u <= 0xDBFF && i + 1 < n) {
            lo := NumGet(p, (i + 1) * 2, "ushort")
            if (lo >= 0xDC00 && lo <= 0xDFFF)
                cp := 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00), len := 2
        }
        if ((cp >= 0xE000 && cp <= 0xF8FF) || (cp >= 0xF0000 && cp <= 0xFFFFD)
            || (cp >= 0x100000 && cp <= 0x10FFFD))
            out .= show ? Format("<U+{:04X}>", cp) : ""
        else
            out .= SubStr(text, i + 1, len)
        i += len
    }
    return out
}

; The element's AutomationId (the app developer's id for it), or "".
; Returns the AutomationId string, or "" (no element, none set, or the read
; failed).
UiaAutomationId(el) {
    if !el
        return ""
    try {
        ComCall(29, el, "ptr*", &b := 0)                         ; get_CurrentAutomationId
        return UiaBStrOut(b)
    }
    return ""
}

; True when the element is enabled; false when disabled, or on any failure.
; Returns true when enabled; false when disabled, for no element, or on any
; failure.
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
; Returns true for a password box; false for any other element, for no
; element, or when the read failed.
UiaIsPassword(el) {
    if !el
        return false
    try {
        ComCall(35, el, "int*", &v := 0)                         ; get_CurrentIsPassword
        return v != 0
    }
    return false
}

; True when the provider says the element is not on screen
; (UIA_IsOffscreenPropertyId 30022). Chrome sets it for content clipped by
; a scroll container; a Win32 list sets it for rows past the fold. It is
; NOT a complete answer — measured 2026-10-14: a Win32 child control
; clipped entirely out of its scrolling parent pane reports false (and a
; rectangle) — which is why UiaVisibleRect also intersects the containers.
; Returns true when the element reports itself offscreen; false when it
; doesn't, for no element, or when the read failed.
UiaIsOffscreen(el) {
    if !el
        return false
    try {
        ComCall(38, el, "int*", &v := 0)                         ; get_CurrentIsOffscreen
        return v != 0
    }
    return false
}

; The id of the process the element belongs to — how a hit test says the
; thing in the way is ANOTHER program's window.
; Returns the process id, or 0 for no element or a failed read.
UiaProcessId(el) {
    if !el
        return 0
    try {
        ComCall(20, el, "int*", &v := 0)                         ; get_CurrentProcessId
        return v
    }
    return 0
}

; The element's own window handle (UIA_NativeWindowHandlePropertyId 30020)
; — set for an element that IS a window (a top-level window, a Win32 child
; control, Chrome's render widget), 0 for content inside one.
; Returns the HWND, or 0 for no element, no window of its own, or a failed
; read.
UiaNativeHwnd(el) {
    if !el
        return 0
    try {
        ComCall(36, el, "ptr*", &h := 0)                         ; get_CurrentNativeWindowHandle
        return h
    }
    return 0
}

; True when the element is a top-level window by Win32's rules: its own HWND
; is its root (GetAncestor GA_ROOT). Unlike UiaIsTopLevel this is true for an
; OWNED window too — a dialog, a dropdown, an autocomplete popup — which UIA
; lists as a CHILD of its owner window, not of the desktop (review,
; 2026-10-14: clipping by "the ancestor below the desktop root" clipped a
; dialog's controls to its owner's box). One property read, no tree walk.
; Returns true for a top-level window's element; false otherwise, for no
; element, the desktop root, or on any failure.
UiaIsWindowRoot(el) {
    h := UiaNativeHwnd(el)
    return h != 0 && DllCall("GetAncestor", "ptr", h, "uint", 2, "ptr") = h   ; GA_ROOT
}

; The ancestors that decide what of el can be seen, nearest-first, ending
; with its top-level window — the nearest ancestor that UiaIsWindowRoot
; (so an owned dialog's controls end at the dialog, not its owner). The
; desktop root is never in it: its box is the PRIMARY monitor. A walk that
; stops before reaching a window is a FAILURE, never taken as complete —
; UiaParent's "" means both "the top" and "the read failed", and a broken
; walk once read as "the last wrapper reached is the window" (review,
; 2026-10-14). Shared by UiaVisibleRect, UiaClipAbove and UiaHitCountsFor,
; so a click and a visibleOnly dump agree on what clips. Bounded by
; UIA_VIS_MAX_HOPS() parent steps.
; Returns an array of elements (empty when el is itself a window root), or
; "" when its window can't be reached; `why` is "" or says so (no names).
UiaClipChain(el, &why?) {
    why := ""
    if !el {
        why := "no element"
        return ""
    }
    chain := []
    if UiaIsWindowRoot(el)
        return chain
    node := el
    Loop UIA_VIS_MAX_HOPS() {
        node := UiaParent(node)
        if (node = "") {
            why := "couldn't reach the element's window (the walk up the tree stopped short) — its visible area is unknown"
            return ""
        }
        chain.Push(node)
        if UiaIsWindowRoot(node)
            return chain
    }
    why := "couldn't reach the element's window within " UIA_VIS_MAX_HOPS() " parent steps — its visible area is unknown"
    return ""
}

; True for a scrolling container — an element with ScrollPattern (the same
; thing as UIA_IsScrollPatternAvailablePropertyId 30034), i.e. one that
; clips what it holds to its own box. Measured 2026-10-14: a Win32 list and
; a child window with scroll bars both say true, a top-level window and a
; button say false.
; Returns true when the element has ScrollPattern; false otherwise, for no
; element, or on any failure.
UiaIsScrollContainer(el) {
    if !el
        return false
    try {
        ComCall(16, el, "int", UIA_PAT_SCROLL(), "ptr*", &pat := 0)   ; GetCurrentPattern
        if pat {
            UiaWrap(pat)                     ; released when the wrapper goes
            return true
        }
    }
    return false
}

; One line naming an element the way the tree dump does —
;     Button "Save" <id=SaveBtn>
; with newlines folded and icon-font characters shown as <U+E611>.
; Returns the one-line description (Type "name", plus <id=...> when it has
; an AutomationId), or "" for no element.
UiaDescribe(el) {
    if !el
        return ""
    name := UiaShowIcons(StrReplace(StrReplace(UiaName(el), "`r", " "), "`n", " "))
    aid := UiaAutomationId(el)
    return UiaControlTypeName(UiaControlType(el)) ' "' name '"' (aid != "" ? " <id=" aid ">" : "")
}

; The element's UIA_*ControlTypeId (50004 = Edit, ...), or 0. Worth reading
; when you have an element and want to know whether you got the label or the
; box beside it.
; Returns the control type id (an integer such as 50004), or 0 for no element
; or a failed read.
UiaControlType(el) {
    if !el
        return 0
    try {
        ComCall(21, el, "int*", &v := 0)                         ; get_CurrentControlType
        return v
    }
    return 0
}

; The element's screen rectangle. Offscreen / collapsed elements report a
; zero rect, which counts as none.
; Returns an object {x, y, w, h} in screen pixels, or "" when the element
; has no rectangle (or there is no element).
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

; ---- dry run (2026-10-12) ----------------------------------------------
;  run_automation(dry_run=True) loads lib\DryRunShim.ahk ahead of the
;  script, which replaces Send / Click / Control* -- but the three actions
;  below act through COM, not a built-in, so each asks here first. True =
;  a dry run: the action was LOGGED and must not happen (the caller returns
;  success, so the script's flow continues as on a real run). The shim
;  defines _VkDryRunNote; without it -- every normal run -- the dynamic
;  lookup throws "Variable not found", caught here, and the action goes
;  ahead exactly as before (measured: no #Warn VarUnset warning for it).
; Returns true during a dry run (the action was logged; skip it and report
; success), false on every normal run.
UiaDryRun(fn, el, text?) {
    try note := %"_VkDryRunNote"%
    catch
        return false
    detail := Map()
    try detail["element"] := UiaName(el)
    try detail["type"] := UiaControlTypeName(UiaControlType(el))
    if IsSet(text)
        detail["text"] := text
    try note(fn, detail)
    return true
}

; Give the element keyboard focus (SetFocus). True when UIA accepted it,
; false on any failure. A dry run (UiaDryRun) logs it and returns true.
; Returns true when UIA accepted the focus (or a dry run logged it), false for
; no element or on any failure.
UiaFocus(el) {
    if !el
        return false
    if UiaDryRun("UiaFocus", el)
        return true
    try {
        ; No trailing type: the default return handling checks the HRESULT, so
        ; a failure lands in this try instead of being silently swallowed.
        ComCall(3, el)                                           ; SetFocus
        return true
    }
    return false
}

; First element matching `cond` within `scope` of `el`, or "".
;
; `why` (optional): "" on a plain hit; otherwise why there is no element —
; no start element, no condition, the FindFirst call itself failed (its
; error, never swallowed), or "no match". A NON-empty why WITH an element is
; a note: the provider answered with an element outside `el` and the walk
; found this one instead (see the header: a measured Chrome behaviour).
;
; The containment check costs two parent hops to see whether `el` is a
; window root (then nothing can be out of scope and it is skipped), plus one
; hop per level between the hit and `el`. The retrying window-level finds
; below call UiaFindFirstRaw and pay none of it.
; Returns the element, or ""; `why` is "" on a plain hit, else why there is
; none (or, beside an element, a note that the walk found it instead).
UiaFindFirst(el, cond, scope := 4, &why?) {
    why := ""
    if !el {
        why := "no start element (the find that should have produced it returned nothing)"
        return ""
    }
    if !cond {
        why := "no search condition (building it failed)"
        return ""
    }
    hit := UiaFindFirstRaw(el, cond, scope, &err)
    if (err != "") {
        why := "FindFirst failed: " err
        return ""
    }
    if !hit {
        why := "no match"
        return ""
    }
    return UiaKeepInScope(hit, el, cond, scope, &why)
}

; The bare FindFirst (Element slot 5): no scope check, and a failure is
; reported in `err` instead of being swallowed. For callers that start at a
; window root — everything in the window is in scope there.
; Returns the element, or "" (no match, an empty argument, or the call
; failed); `err` is "" or the failure's text.
UiaFindFirstRaw(el, cond, scope, &err?) {
    err := ""
    if (!el || !cond)
        return ""
    try {
        ComCall(5, el, "int", scope, "ptr", cond, "ptr*", &found := 0)
        return UiaWrap(found)
    } catch as e {
        err := UiaErrText(e)
    }
    return ""
}

; The scope decision UiaFindFirst makes about a provider's answer, on its
; own so a test can hand it an out-of-scope hit (the Win32 provider never
; produces one): `hit` when it lies inside `start` (or `start` is a window
; root), else the first real match from walking `start`'s own subtree, with
; `why` saying the provider's answer was thrown away.
; Returns `hit` when it is in scope, else the walk's element or ""; `why` is
; "" when `hit` was kept, else says it was replaced (and why the walk found
; nothing).
UiaKeepInScope(hit, start, cond, scope, &why?) {
    why := ""
    if (!hit || UiaIsTopLevel(start) || UiaIsWithin(hit, start))
        return hit
    walked := UiaFindFirstWalk(start, cond, scope, &wwhy)
    why := "the provider's FindFirst returned an element OUTSIDE the start element "
         . "(a known Chrome behaviour) — searched the start element's own subtree by walking instead"
         . (walked ? "" : "; " wwhy)
    return walked
}

; True when `el` is `ancestor` or lies inside it, walking `el`'s raw-view
; parents (bounded by maxHops). False on any failure.
; Returns true when `el` is `ancestor` or inside it; false otherwise, past
; maxHops, or on any failure.
UiaIsWithin(el, ancestor, maxHops := 256) {
    if (!el || !ancestor)
        return false
    node := el
    Loop maxHops + 1 {
        if UiaSameElement(node, ancestor)
            return true
        node := UiaParent(node)
        if (node = "")
            return false
    }
    return false
}

; True for a top-level window's element (what UiaFromWindow returns for a
; real window): its parent is the desktop, which has no parent. Two hops.
; Returns true for a top-level window's element, false otherwise (including no
; element).
UiaIsTopLevel(el) {
    p := UiaParent(el)
    return p != "" && UiaParent(p) = ""
}

; True when `node` itself matches `cond`: FindFirst with TreeScope_Element,
; and the answer must BE the node — so this can't be fooled the way a
; subtree search was.
; Returns true when `node` matches `cond`, false otherwise or on any failure.
UiaMatchesSelf(node, cond) {
    hit := UiaFindFirstRaw(node, cond, 1)
    return hit != "" && UiaSameElement(hit, node)
}

; First match by WALKING `el`'s subtree in tree order (raw view, pre-order,
; at most UIA_NODE_BUDGET() nodes), testing each node with UiaMatchesSelf —
; so any condition works and nothing outside `el` can be returned. Slower
; than FindFirst (three cross-process calls a node); the reliable fallback
; when a provider's FindFirst can't be trusted. scope as FindFirst: 1 the
; element, 2 its children, 4 descendants (7 = all of them).
; Bounded by time as well as count (timeMs, default UIA_WALK_TIME_MS()): a
; miss in a big subtree is otherwise thousands of nodes at four calls each,
; and a body must not stall on a diagnostic fallback. A cut walk says so in
; why ("stopped after N nodes / T ms").
; Returns the first matching element, or ""; `why` is "" on a hit, else why
; not (no match, an empty argument, or the node budget or time limit cut the
; walk).
UiaFindFirstWalk(el, cond, scope := 4, &why?, timeMs := 0) {
    why := ""
    if (!el || !cond) {
        why := !el ? "no start element" : "no search condition (building it failed)"
        return ""
    }
    if ((scope & 1) && UiaMatchesSelf(el, cond))
        return el
    if !(scope & 6) {
        why := "no match"
        return ""
    }
    deep := (scope & 4) != 0
    budget := UIA_NODE_BUDGET()
    if (timeMs <= 0)
        timeMs := UIA_WALK_TIME_MS()
    t0 := A_TickCount
    walked := 0
    ; Each stack entry is the next node to visit at some level; a node's
    ; next sibling goes under its first child, so the order is pre-order.
    stack := [UiaFirstChild(el)]
    while stack.Length {
        node := stack.Pop()
        if (node = "")
            continue
        if (--budget < 0) {
            why := "no match in the first " UIA_NODE_BUDGET() " nodes walked (node budget spent)"
            return ""
        }
        if (A_TickCount - t0 > timeMs) {
            why := "no match — the walk stopped after " walked " nodes / "
                 . (A_TickCount - t0) " ms (time limit " timeMs " ms); the rest of the subtree was not searched"
            return ""
        }
        walked += 1
        if UiaMatchesSelf(node, cond)
            return node
        stack.Push(UiaNextSibling(node))
        if deep
            stack.Push(UiaFirstChild(node))
    }
    why := "no match"
    return ""
}

; EVERY element matching `cond` within `scope` of `el`, in tree order, as a
; plain AHK array. Bounded by maxItems — a true-condition walk of a browser
; tab can otherwise hand back tens of thousands of elements, and reading
; each one is a cross-process call. (The FindAll itself is ONE call that UIA
; completes before anything here can count: maxItems caps what is read
; afterwards, not how long the provider takes to build the array.)
;
; Started below a window root, the hits are checked against `el` the way
; UiaFindFirst checks its one (see the header): up to 32 evenly spaced hits
; — the ends included — and only if one of those is out of scope is every
; hit checked and the strays dropped (why then says how many). Sampling
; keeps a big, correct answer from costing a parent walk per element.
; `why`: "" on success; else the reason for an empty array (as UiaFindFirst).
; Returns an array of elements in tree order (at most maxItems; 0 = the node
; budget), empty on a miss; `why` is "" on success, else why it is empty or
; how many out-of-scope hits were dropped.
UiaFindElements(el, cond, scope := 4, maxItems := 0, &why?) {
    why := ""
    if (!el || !cond) {
        why := !el ? "no start element (the find that should have produced it returned nothing)"
                   : "no search condition (building it failed)"
        return []
    }
    out := UiaFindAllRaw(el, cond, scope, maxItems, &err)
    if (err != "") {
        why := "FindAll failed: " err
        return out
    }
    if !out.Length {
        why := "no match"
        return out
    }
    if UiaIsTopLevel(el)
        return out
    kept := UiaScopedHits(out, el, &dropped)
    if dropped
        why := "the provider's FindAll returned " dropped " element" (dropped = 1 ? "" : "s")
             . " OUTSIDE the start element (a known Chrome behaviour) — dropped"
             . (kept.Length ? "" : "; nothing inside it matched")
    return kept
}

; The bare FindAll (Element slot 6) + reading the array (ElementArray slots
; 3 get_Length, 4 GetElement). No scope check; a failure goes to `err`.
; Returns an array of elements (at most maxItems; 0 = the node budget), empty
; on no match, an empty argument or a failure; `err` is "" or the failure's
; text.
UiaFindAllRaw(el, cond, scope, maxItems := 0, &err?) {
    err := ""
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
    } catch as e {
        err := UiaErrText(e)
    }
    return out
}

; `hits` without the ones outside `start` (see UiaFindElements for the
; sampling); `dropped` = how many went.
; Returns an array of the hits inside `start` (`hits` itself when every
; sampled hit is in scope); `dropped` is how many were removed (0 when none).
UiaScopedHits(hits, start, &dropped?) {
    dropped := 0
    n := hits.Length
    samples := Min(n, 32)
    allIn := true
    Loop samples {
        i := samples = 1 ? 1 : 1 + Round((A_Index - 1) * (n - 1) / (samples - 1))
        if !UiaIsWithin(hits[i], start) {
            allIn := false
            break
        }
    }
    if allIn
        return hits
    kept := []
    for h in hits
        if UiaIsWithin(h, start)
            kept.Push(h)
    dropped := n - kept.Length
    return kept
}

; ---- what a module actually calls -------------------------------------
;  Every one of these takes a trailing optional &why — "" on success, else
;  the reason for the empty answer with how long it tried, e.g.
;      no match after 3012 ms (19 attempts)
;      the search failed: (0x80040201) ... — the element is gone (...) after 0 ms (1 attempt)
;      no such window (hwnd 4523) — it has closed

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
; Returns the element, or "" when nothing matched in time (`why` says why).
UiaFind(hwnd, name, timeoutMs := 3000, occurrence := 1, &why?) {
    return UiaFindBy(hwnd, UIA_PROP_NAME(), name, timeoutMs, occurrence, &why)
}

; Find by AutomationId. PREFER THIS where an app provides one: unlike a
; visible Name it is set by the developer, so it survives relabelling and
; translation.
; Returns the element, or "" when nothing matched in time (`why` says why).
UiaFindById(hwnd, automationId, timeoutMs := 3000, occurrence := 1, &why?) {
    return UiaFindBy(hwnd, UIA_PROP_AUTOMATIONID(), automationId, timeoutMs, occurrence, &why)
}

; Shared find-by-string-property with a retry budget.
; Returns the element, or "" when nothing matched in time or the condition
; couldn't be built (`why` says why).
UiaFindBy(hwnd, propId, text, timeoutMs := 3000, occurrence := 1, &why?) {
    return UiaFindCond(hwnd, UiaPropCondition(propId, text), timeoutMs, occurrence, &why)
}

; Every element of this Name in the window, in tree order. The answer to
; "which one of these is the box and which is the label?" — read UiaRect or
; UiaControlType on each and pick.
; Returns an array of elements — empty when nothing matched or the window
; couldn't be searched (`why` tells which).
UiaFindAll(hwnd, name, timeoutMs := 3000, maxItems := 0, &why?) {
    return UiaFindAllCond(hwnd, UiaPropCondition(UIA_PROP_NAME(), name), timeoutMs, maxItems, &why)
}

; The Edit named `name` — not the label that shares its name. This is the
; one that unblocks form filling; UiaFind alone returns whichever comes
; first in tree order, which on a label-then-input layout is the label.
; Returns the Edit element, or "" when nothing matched in time (`why` says
; why).
UiaFindEdit(hwnd, name, timeoutMs := 3000, occurrence := 1, &why?) {
    return UiaFindOfType(hwnd, name, UIA_TYPE_EDIT(), timeoutMs, occurrence, &why)
}

; The same idea for any control type: Name AND ControlType, ANDed together.
; controlType is a UIA_*ControlTypeId (UIA_TYPE_EDIT(), UIA_TYPE_BUTTON(), ...).
; Returns the element, or "" when nothing matched in time or the condition
; couldn't be built (`why` says why).
UiaFindOfType(hwnd, name, controlType, timeoutMs := 3000, occurrence := 1, &why?) {
    cond := UiaAndCondition(UiaPropCondition(UIA_PROP_NAME(), name),
                            UiaIntCondition(UIA_PROP_CONTROLTYPE(), controlType))
    return UiaFindCond(hwnd, cond, timeoutMs, occurrence, &why)
}

; Shared retry loop for any condition. occurrence 1 uses FindFirst (one
; cross-process call); anything higher needs the whole match list. Searches
; from the window root, so no scope check is needed (see the header).
;
; A failing call is not "no match": its error goes into `why`, and the root
; is fetched afresh before the next attempt — an error usually means the
; element went stale (the page navigated), and a re-fetch that fails says
; the window itself is gone.
; Returns the element (the occurrence-th match), or "" when there was none in
; time; `why` is "" on success, else the reason with how long it tried.
UiaFindCond(hwnd, cond, timeoutMs := 3000, occurrence := 1, &why?) {
    why := ""
    t0 := A_TickCount
    root := UiaFromWindow(hwnd, &why)
    if !root
        return ""
    if !cond {
        why := "couldn't build the search condition (UIA refused it)"
        return ""
    }
    deadline := t0 + timeoutMs
    attempts := 0, failed := 0, firstErr := "", got := 0
    loop {
        attempts += 1
        if (occurrence <= 1) {
            if (el := UiaFindFirstRaw(root, cond, UIA_SCOPE_SUBTREE(), &err))
                return el
        } else {
            all := UiaFindAllRaw(root, cond, UIA_SCOPE_SUBTREE(), occurrence, &err)
            if (all.Length >= occurrence)
                return all[occurrence]
            got := all.Length
        }
        if (err != "") {
            failed += 1
            if (firstErr = "")
                firstErr := err
            if !(fresh := UiaFromWindow(hwnd, &rwhy)) {
                why := rwhy UiaTookText(t0, attempts)
                return ""
            }
            root := fresh
        }
        if (A_TickCount >= deadline) {
            why := UiaMissText(err, failed, firstErr, occurrence, got) UiaTookText(t0, attempts)
            return ""
        }
        Sleep(150)
    }
}

; Shared retry loop returning ALL matches. Retries only while there are none
; — once something matches, that is the answer for this moment.
; Returns an array of elements (at most maxItems; 0 = the node budget),
; empty on a miss; `why` as UiaFindCond.
UiaFindAllCond(hwnd, cond, timeoutMs := 3000, maxItems := 0, &why?) {
    why := ""
    t0 := A_TickCount
    root := UiaFromWindow(hwnd, &why)
    if !root
        return []
    if !cond {
        why := "couldn't build the search condition (UIA refused it)"
        return []
    }
    deadline := t0 + timeoutMs
    attempts := 0, failed := 0, firstErr := ""
    loop {
        attempts += 1
        all := UiaFindAllRaw(root, cond, UIA_SCOPE_SUBTREE(), maxItems, &err)
        if all.Length
            return all
        if (err != "") {
            failed += 1
            if (firstErr = "")
                firstErr := err
            if !(fresh := UiaFromWindow(hwnd, &rwhy)) {
                why := rwhy UiaTookText(t0, attempts)
                return all
            }
            root := fresh
        }
        if (A_TickCount >= deadline) {
            why := UiaMissText(err, failed, firstErr, 1, 0) UiaTookText(t0, attempts)
            return all
        }
        Sleep(150)
    }
}

; The reason a retry loop ran out: the LAST attempt's error if it had one,
; else "no match" (or too few for the occurrence asked for), plus a word
; about earlier attempts that threw.
; Returns the reason text, never "".
UiaMissText(lastErr, failed, firstErr, occurrence, got) {
    if (lastErr != "")
        return "the search failed: " lastErr
    s := (occurrence > 1 && got > 0)
        ? "only " got " match" (got = 1 ? "" : "es") ", wanted occurrence " occurrence
        : "no match"
    if failed
        s .= " (" failed " earlier attempt" (failed = 1 ? "" : "s") " failed: " firstErr ")"
    return s
}

; Wait for an element (by Name) to appear.
; Returns the element, or "" if it never does within timeoutMs (`why` says
; why).
UiaWaitFor(hwnd, name, timeoutMs := 10000, &why?) {
    return UiaFind(hwnd, name, timeoutMs, 1, &why)
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
; Returns the ValuePattern text, or "" (no element, no ValuePattern, an empty
; value, or a failed read); `has` is true when the element has a ValuePattern,
; else false.
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
; Returns the ValuePattern text when it is not empty, else the Name, else ""
; (no element, or neither has text).
UiaValue(el) {
    if !el
        return ""
    v := UiaValueOnly(el)
    return v != "" ? v : UiaName(el)
}

; Set an edit box's contents outright — no keystrokes, so nothing races the
; app's own handlers. True once set; false when the element has no
; ValuePattern or the set failed. A dry run (UiaDryRun) logs it and returns
; true -- but only for an element that HAS a ValuePattern, as a real run would.
; Returns true once set (or logged by a dry run); false for no element, no
; ValuePattern, or a failed set.
UiaSetValue(el, text) {
    if !el
        return false
    try {
        ComCall(16, el, "int", UIA_PAT_VALUE(), "ptr*", &pat := 0)
        if !pat
            return false
        p := UiaWrap(pat)
        if UiaDryRun("UiaSetValue", el, text)
            return true
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
; real Win32 list: rect none -> ScrollIntoView -> real rect. True when the
; request was made; false when the element offers no such pattern (nothing
; moves then).
; Returns true when the request was made; false for no element, no
; ScrollItemPattern, or a failed call.
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
; view rescue and the no-rectangle refusal). True when pressed; on false,
; `why` says which precondition failed. A dry run logs the Invoke (UiaDryRun)
; and returns true; the click fallback is logged by the shim's MouseClick.
; Returns true when pressed (or a dry run logged it), false otherwise; `why`
; is "" on success, else what failed (no names or titles); `detail` is the
; same with them (UiaClickEl's).
UiaInvoke(el, &why?, &detail?) {
    why := "", detail := ""
    if !el {
        why := detail := "no element — the find returned nothing"
        return false
    }
    try {
        ComCall(16, el, "int", UIA_PAT_INVOKE(), "ptr*", &pat := 0)
        if pat {
            p := UiaWrap(pat)
            if UiaDryRun("UiaInvoke", el)
                return true
            ComCall(3, p)                                         ; Invoke
            return true
        }
    }
    return UiaClickEl(el, 0, "Left", 1, &why, &detail)
}

; Convenience: find by name in a window and press it. The one-liner most
; modules want — but see UiaClickCenter when the target is a form field.
; True when pressed; on false, `why` names what went wrong (nothing found /
; nowhere to click).
; Returns true when pressed, false otherwise; `why` is "" on success, else
; what went wrong (nothing found / nowhere to click); `detail` adds the names
; a click refusal leaves out of `why` (UiaClickEl's).
UiaClickName(hwnd, name, timeoutMs := 3000, &why?, &detail?) {
    why := "", detail := ""
    el := UiaFind(hwnd, name, timeoutMs, 1, &fwhy)
    if !el {
        why := detail := UiaNotFoundText(name, fwhy)
        return false
    }
    return UiaInvoke(el, &why, &detail)
}

; The click helpers' &why for a find that came back empty: a plain miss
; gets the virtualization advice; anything else (window gone, own process,
; the search threw) says so instead of pretending the name was absent.
; Returns the reason text, never "".
UiaNotFoundText(name, findWhy) {
    if (findWhy = "" || InStr(findWhy, "no match") = 1)
        return "no element named '" name "' in the window" (findWhy != "" ? " (" findWhy ")" : "")
             . " — web pages VIRTUALIZE (only content near the viewport is in the tree), so scroll it into view first or navigate directly"
    return "couldn't search the window for '" name "': " findWhy
}

; ---- what is actually visible (2026-10-14) ---------------------------
;  A rectangle says where an element IS, not whether you can see it. From a
;  real build (a browser module driving a triage view in Chrome): Chrome
;  reports rectangles for elements scrolled outside an inner scroll panel
;  and for elements under a header pinned over the panel, so a click at the
;  rectangle landed on whatever was really there — once on a different
;  monitor, sending a download click somewhere else entirely. The
;  reporter's two failed fixes are the spec for what NOT to do:
;    - intersecting EVERY ancestor's box wipes the area out, because web
;      wrappers are often smaller than the content they hold;
;    - climbing to the desktop root and intersecting with it wipes out
;      anything on a secondary monitor — the root's box is the PRIMARY
;      monitor (measured here too: the root reports 0,0 at the primary
;      monitor's size).
;  UiaVisibleRect intersects only what really clips: ancestors that are
;  scroll containers, the top-level window (and stops THERE), and a real
;  monitor — and honours IsOffscreen. What it cannot see is something drawn
;  ON TOP (a pinned header, an overlay, another app); that is the hit
;  test's job (UiaHitTest), and UiaClickEl runs both before every click.

; The overlap of two {x, y, w, h} rectangles.
; Returns the overlap as {x, y, w, h}, or "" when they don't overlap (or
; either is not a rectangle).
UiaIntersect(a, b) {
    if (!IsObject(a) || !IsObject(b))
        return ""
    l := Max(a.x, b.x), t := Max(a.y, b.y)
    r := Min(a.x + a.w, b.x + b.w), btm := Min(a.y + a.h, b.y + b.h)
    return (r > l && btm > t) ? {x: l, y: t, w: r - l, h: btm - t} : ""
}

; The part of rectangle r that is on a real monitor — the largest piece
; when it spans two. The virtual screen alone won't do: with monitors of
; different sizes it is not a rectangle, and a point inside its bounds can
; still be on no monitor at all.
; Returns the largest on-monitor piece as {x, y, w, h}, or "" when no part
; of r is on any monitor.
UiaOnMonitors(r) {
    best := "", bestArea := 0
    if !IsObject(r)
        return ""
    Loop MonitorGetCount() {
        try MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        catch
            continue
        piece := UiaIntersect(r, {x: ml, y: mt, w: mr - ml, h: mb - mt})
        if (IsObject(piece) && piece.w * piece.h > bestArea)
            best := piece, bestArea := piece.w * piece.h
    }
    return best
}

; The part of the element actually visible on screen: its rectangle,
; clipped by every ancestor that is a scroll container (UiaIsScrollContainer
; — never plain wrappers), by its own top-level window (UiaClipChain's last
; element — an owned dialog's, not its owner's; the desktop root is never
; used), and by the monitors (UiaOnMonitors). An element that reports
; IsOffscreen is not visible whatever its rectangle says. Read-only;
; bounded by UIA_VIS_MAX_HOPS() parent steps; never throws. Something drawn
; OVER the element is not seen here — see UiaHitTest. In the calling
; thread's DPI context, like UiaRect (see the file header). `chain` is
; UiaClipChain(el) when the caller already has it (one walk per click).
; Returns {x, y, w, h} in screen pixels, or ""; `why` is "" when visible,
; else why not (no rectangle, offscreen, outside a scroll container or its
; window, its window unreachable, on no monitor) with no names or titles;
; `detail` is the same naming the container or window.
UiaVisibleRect(el, &why?, &detail?, chain := "") {
    why := "", detail := ""
    if !el {
        why := detail := "no element — the find returned nothing"
        return ""
    }
    r := UiaRect(el)
    if !IsObject(r) {
        why := detail := "the element has no bounding rectangle (offscreen, collapsed or virtualized)"
        return ""
    }
    if UiaIsOffscreen(el) {
        why := detail := "the element reports itself offscreen (IsOffscreen) — scrolled out of view or hidden"
        return ""
    }
    if !IsObject(chain)
        chain := UiaClipChain(el, &cwhy)
    if !IsObject(chain) {
        why := detail := cwhy
        return ""
    }
    n := chain.Length
    for i, a in chain {
        isTop := (i = n)            ; el's own top-level window
        if (!isTop && !UiaIsScrollContainer(a))
            continue
        ar := UiaRect(a)
        clipped := UiaIntersect(r, ar)
        if !IsObject(clipped) {
            if isTop {
                tail := IsObject(ar) ? "" : " (the window has no rectangle — minimized or hidden?)"
                why := "it lies outside its window" tail
                detail := "it lies outside its window " UiaDescribe(a) tail
            } else {
                why := "it lies outside the visible area of the scrolling container (" UiaKind(a)
                     . ") that holds it — scrolled out of view"
                detail := "it lies outside the visible area of the scrolling container " UiaDescribe(a)
                        . " — scrolled out of view"
            }
            return ""
        }
        r := clipped
    }
    vis := UiaOnMonitors(r)
    if !IsObject(vis) {
        why := detail := "it is not on any monitor (at " r.x "," r.y " " r.w "x" r.h ") — its window is off-screen"
        return ""
    }
    return vis
}

; "a Pane", "an Edit" — an element's control type with its article, which
; is all the click path's &why says about the things it names (no names or
; titles: see the file header).
; Returns the phrase, or "nothing" for no element.
UiaKind(el) {
    if !el
        return "nothing"
    t := UiaControlTypeName(UiaControlType(el))
    return (InStr("AEIOU", SubStr(t, 1, 1)) ? "an " : "a ") t
}

; UiaVisibleRect, polled every 100 ms for up to timeoutMs — what a click
; waits for after asking an element to scroll itself into view.
; Returns the visible rectangle, or "" when there still is none at the
; deadline; `why` / `detail` are UiaVisibleRect's from the last look.
UiaWaitVisible(el, timeoutMs := 1200, &why?, &detail?, chain := "") {
    deadline := A_TickCount + timeoutMs
    loop {
        v := UiaVisibleRect(el, &why, &detail, chain)
        if (IsObject(v) || A_TickCount >= deadline)
            return v
        UiaSleep(100)
    }
}

; Does a click at screen point x,y reach `el`? Asks what is AT the point
; (UiaElementAtPoint) and accepts el itself, anything inside el, or an
; ancestor UiaHitCountsFor accepts — one BELOW el's nearest scroll
; container / Document / window (Chrome answers with the nearest
; hit-testable ancestor; a hit on the container itself proves nothing).
; Anything else is in the way — a header pinned over a scroll panel, an
; overlay, another program's window. A window of THIS script at the point
; is reported as in the way without asking UIA about it (the own-process
; rule). Read-only. x and y may be Floats (rounded). `chain` is
; UiaClipChain(el) when the caller already has it; otherwise it is walked
; only when the hit is not el or inside it.
; Returns 1 when the click would reach el, 0 when something else is there,
; -1 when the hit test itself is unavailable; `what` says what is there (its
; control type, and "in another program" — no names or titles) or why
; there is no answer; `detail` names it, its window title and its program.
UiaHitTest(el, x, y, &what?, &detail?, chain := "") {
    what := "", detail := ""
    if !el {
        what := detail := "no element"
        return -1
    }
    if !UiaPointArg(&x, &y) {
        what := detail := "not a screen point (x and y must be numbers)"
        return -1
    }
    pt := (y << 32) | (x & 0xFFFFFFFF)
    hwnd := DllCall("WindowFromPoint", "int64", pt, "ptr")
    top := hwnd ? DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr") : 0     ; GA_ROOT
    title := ""
    if top
        try title := WinGetTitle("ahk_id " top)
    if (hwnd && !UiaOtherProcess(hwnd)) {
        what := "a window of this script's own process"
        detail := what (title != "" ? ' ("' title '")' : "")
        return 0
    }
    hit := UiaElementAtPoint(x, y, &hwhy)
    if !hit {
        what := detail := hwhy
        return -1
    }
    if (UiaSameElement(hit, el) || UiaIsWithin(hit, el))
        return 1
    if !IsObject(chain)
        chain := UiaClipChain(el)
    if UiaHitCountsFor(el, hit, chain)
        return 1
    what := UiaKind(hit)
    detail := UiaDescribe(hit) (title != "" ? ' in window "' title '"' : "")
    holder := false
    if IsObject(chain) {
        for a in chain
            if UiaSameElement(a, hit) {
                holder := true
                break
            }
    } else
        holder := UiaIsWithin(el, hit)
    if holder {
        holds := " that holds the element (its scrolling container, page or window — the point is not on the element itself)"
        what .= holds, detail .= holds
    }
    hp := UiaProcessId(hit), ep := UiaProcessId(el)
    if (hp && ep && hp != ep) {
        exe := ""
        try exe := ProcessGetName(hp)
        what .= " in another program"
        detail .= " — another program" (exe != "" ? " (" exe ")" : "")
    }
    return 0
}

; Does a hit test that answered `anc` (an ancestor of el) count as a hit
; on el? Chrome answers with the nearest hit-testable ANCESTOR of what is
; under the point (a link's wrapper for its text), so some must — but not
; one a click can land on WITHOUT touching el: el's nearest scroll
; container, a Document, the top-level window, or anything above them.
; (Review, 2026-10-14: the first version accepted any ancestor but the
; desktop root. A header pinned over a scroll panel is often a plain
; styled box the accessibility tree ignores, so a hit test there answers
; with the panel or the page — an ancestor — and the click went into the
; header. Measured on Win32: a hit over a button, an edit, a static or a
; list-box row is the element itself; over a ListView row it is the row's
; own Text child — both inside el, so this rule costs them nothing.)
; The window is el's OWN top-level window (UiaClipChain's last element), so
; an owned dialog is its own boundary. `chain` is UiaClipChain(el) when the
; caller already has it.
; Returns true when anc is an ancestor of el strictly below that boundary;
; false otherwise, including for no element or an unreachable window.
UiaHitCountsFor(el, anc, chain := "") {
    if (!el || !anc)
        return false
    if !IsObject(chain)
        chain := UiaClipChain(el)
    if !IsObject(chain)
        return false
    n := chain.Length
    for i, a in chain {
        if (i = n)                              ; the top-level window
            return false
        if (UiaIsScrollContainer(a) || UiaControlType(a) = UIA_TYPE_DOCUMENT())
            return false
        if UiaSameElement(a, anc)
            return true
    }
    return false
}

; ---- DPI: one coordinate space for the whole click (2026-10-14) ---------
;  Measured here (one 2560x1600 monitor at 150%): a UIA rectangle,
;  MonitorGet, WinGetPos, WindowFromPoint and MouseMove ALL follow the
;  calling thread's DPI awareness — a DPI-unaware thread got 247,270
;  200x60 for a button that a per-monitor-aware one saw at 371,405
;  300x90. AutoHotkey runs system-aware, where every one of them is
;  virtualized on a monitor whose scale differs from the main one —
;  the reporter's three-monitor desk. Per-monitor-v2 awareness means
;  physical pixels and no virtualization anywhere, so UiaClickEl
;  decides and clicks inside it. Not measured: a real mixed-scale desk
;  (none here); on a single-scale desk the numbers are identical.

; Puts this thread in per-monitor-v2 DPI awareness (physical pixels, no
; virtualization) until UiaDpiRestore(prev). Wrap a decision AND the click
; that uses it, never one without the other:
;     prev := UiaDpiPhysical()
;     try p := UiaClickablePoint(el, 0, &why), (p && MouseClick(, p.x, p.y))
;     finally UiaDpiRestore(prev)
; Inside it, wait with UiaSleep, not Sleep (a timer that runs during a
; Sleep would inherit the context).
; Returns the previous context to hand to UiaDpiRestore, or 0 when Windows
; can't switch (before Windows 10 1703 — nothing changed then).
UiaDpiPhysical() {
    prev := 0
    try prev := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")   ; PER_MONITOR_AWARE_V2
    return prev
}

; Ends a UiaDpiPhysical scope: puts back the context it returned (0 does
; nothing).
; Returns nothing.
UiaDpiRestore(prev) {
    if prev
        try DllCall("SetThreadDpiAwarenessContext", "ptr", prev, "ptr")
}

; Sleep(ms) — in the script's OWN DPI context for its duration. Sleep lets
; this thread's timers and hotkeys run, and inside a UiaDpiPhysical scope
; they would otherwise inherit per-monitor awareness (their own WinMove or
; MouseGetPos numbers would change on a mixed-scale desk). Outside a scope
; it is a plain Sleep.
; Returns nothing.
UiaSleep(ms) {
    cur := 0, own := 0
    try {
        cur := DllCall("GetThreadDpiAwarenessContext", "ptr")
        own := DllCall("GetDpiAwarenessContextForProcess", "ptr", DllCall("GetCurrentProcess", "ptr"), "ptr")
        if (cur && own && DllCall("AreDpiAwarenessContextsEqual", "ptr", cur, "ptr", own))
            cur := 0
    }
    if !(cur && own) {
        Sleep(ms)
        return
    }
    DllCall("SetThreadDpiAwarenessContext", "ptr", own, "ptr")
    try Sleep(ms)
    finally DllCall("SetThreadDpiAwarenessContext", "ptr", cur, "ptr")
}

; ---- clicking for real ------------------------------------------------
;  UiaInvoke fires InvokePattern where there is one, which is right for
;  buttons and links: it works even when the control is scrolled away. It is
;  the WRONG tool for a text field. Invoke moves no mouse and gives nothing
;  keyboard focus, and plenty of controls (an <input> among them) expose no
;  InvokePattern at all, so the call quietly does nothing and the keystrokes
;  that follow land wherever focus happened to be.
;
;  These put the pointer on the element and click it, which is what a
;  person does and what every control responds to — but only where the
;  element can actually be seen and nothing else is in the way.

; Where a click on el should land, decided WITHOUT clicking — the whole of
; UiaClickEl's safety check, on its own so a module (or a test) can ask
; first. In order:
;   1. the visible part (UiaVisibleRect). None — no rectangle, IsOffscreen,
;      outside a scroll container or the window, on no monitor — asks the
;      element to UiaScrollIntoView, waits up to 1.2 s and looks again;
;   2. the centre of that VISIBLE part, jittered by up to jitterPx and
;      clamped to a third of it (UiaJitteredCenter), so it cannot leave it;
;   3. a hit test there (UiaHitTest). Something else in the way gets ONE
;      ScrollIntoView retry (if the element hasn't been scrolled yet), then
;      a refusal. A hit test that is unavailable does not block.
; Not purely a read: the ScrollIntoView rescue really scrolls the target
; app (deliberately, also under a dry run — see UiaDryRun). The point is in
; the calling thread's DPI context; UiaClickEl asks inside UiaDpiPhysical.
; A refusal's `why` starts with one of three fixed phrases a caller may
; test: "no element", "nowhere visible to click" (hidden, scrolled away,
; off-screen) or "something else is in the way" (covered).
; Returns {x, y} (screen pixels), or "" when there is nowhere safe to
; click; `why` is "" on success, else the reason (no names or titles);
; `detail` is the reason naming what is in the way.
UiaClickablePoint(el, jitterPx := 0, &why?, &detail?) {
    why := "", detail := ""
    if !el {
        why := detail := "no element — the find returned nothing"
        return ""
    }
    scrolled := false
    ; One walk up the tree for the whole decision (scrolling doesn't change
    ; what holds the element). "" when it failed: each step then walks again
    ; and reports why.
    chain := UiaClipChain(el)
    v := UiaVisibleRect(el, &vwhy, &vdet, chain)
    if !IsObject(v) {
        scrolled := UiaScrollIntoView(el)
        if scrolled
            v := UiaWaitVisible(el, 1200, &vwhy, &vdet, chain)
        if !IsObject(v) {
            tail := (scrolled ? " — even after ScrollIntoView" : " — and it cannot scroll itself into view (no ScrollItemPattern)")
                  . " — a mouse click has nowhere to land"
            why := "nowhere visible to click: " vwhy tail
            detail := "nowhere visible to click: " vdet tail
            return ""
        }
    }
    p := UiaJitteredCenter(v, jitterPx)
    hit := UiaHitTest(el, p.x, p.y, &what, &wdet, chain)
    if (hit = 0 && !scrolled && UiaScrollIntoView(el)) {
        scrolled := true
        UiaSleep(300)                       ; let a scroll animation settle
        v := UiaWaitVisible(el, 1200, &vwhy, &vdet, chain)
        if !IsObject(v) {
            at := "something else is in the way at " p.x "," p.y
            tail := " — not clicking"
            why := at " (" what "), and after ScrollIntoView it is not visible at all: " vwhy tail
            detail := at " (" wdet "), and after ScrollIntoView it is not visible at all: " vdet tail
            return ""
        }
        p := UiaJitteredCenter(v, jitterPx)
        hit := UiaHitTest(el, p.x, p.y, &what, &wdet, chain)
    }
    if (hit = 0) {
        at := "something else is in the way at " p.x "," p.y ": "
        tail := (scrolled ? " (still, after ScrollIntoView)" : "")
              . " — not clicking (a header pinned over the content, an overlay, a dialog or another window covers the element)"
        why := at what tail
        detail := at wdet tail
        return ""
    }
    return p
}

; Click an element at the centre of its VISIBLE part, optionally jittered
; by up to jitterPx pixels (clamped inside that part, so a jittered click
; can never leave it). Restores the caller's CoordMode and DPI context.
;
; FAILS LOUDLY rather than clicking blind. 2026-08-03: a click on a
; rect-less element "worked" — no error — and went nowhere, which cost a
; real session most of an hour. 2026-10-14: a click on an element Chrome
; still gave a rectangle for, but which was scrolled out of its panel,
; landed on another monitor. So nothing is clicked until UiaClickablePoint
; has found a visible point that a hit test says reaches the element (with
; a ScrollIntoView rescue for the scrolled-away case); on false, `why`
; says why — fit for a run record (no names or titles; it starts with one
; of UiaClickablePoint's fixed phrases) — and `detail` names what is in
; the way, so a module can Out()/log it instead of shrugging. The decision
; and the click run inside UiaDpiPhysical, so both use physical pixels on
; any desk. Under a dry run the click itself is DryRunShim's MouseClick
; (logged, not sent); the checks before it read the target and may scroll
; it (ScrollIntoView stays live), and a hidden or covered target is
; refused exactly as on a real run.
; Returns true once the click is sent; false when nothing was clicked (no
; element, nothing visible, or something else in the way); `why` is "" on
; success, else the reason; `detail` is the reason with names.
UiaClickEl(el, jitterPx := 0, button := "Left", count := 1, &why?, &detail?) {
    prev := UiaDpiPhysical()
    try {
        p := UiaClickablePoint(el, jitterPx, &why, &detail)
        if !IsObject(p)
            return false
        cm := A_CoordModeMouse
        CoordMode("Mouse", "Screen")
        try MouseClick(button, p.x, p.y, count)
        finally CoordMode("Mouse", cm)
        return true
    } finally UiaDpiRestore(prev)
}

; Where a click on rect r ({x, y, w, h} — UiaRect's shape, and Acc.ahk's)
; lands: its centre, offset by up to jitterPx in each direction but clamped
; to a third of the extent (UiaJitter), so it can never leave the element.
; The one copy of this maths: lib\Workflow.ahk's WfClickPoint uses it too.
; Returns an object {x, y}: the screen point to click.
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
; matters when a workflow hits the same site in a loop. True once clicked;
; on false, `why` names what went wrong (nothing found / nowhere to click).
; Returns true once clicked, false otherwise; `why` is "" on success, else
; what went wrong (nothing found / nowhere to click); `detail` adds the
; names a click refusal leaves out of `why` (UiaClickEl's).
UiaClickCenter(hwnd, name, timeoutMs := 3000, jitterPx := 0, &why?, &detail?) {
    why := "", detail := ""
    el := UiaFind(hwnd, name, timeoutMs, 1, &fwhy)
    if !el {
        why := detail := UiaNotFoundText(name, fwhy)
        return false
    }
    return UiaClickEl(el, jitterPx, "Left", 1, &why, &detail)
}

; A random offset in [-maxPx, +maxPx], never more than a third of the extent
; it is applied to — on a 12 px control a 4 px jitter would sit on the edge.
;
; The parameter is maxPx, not max: functions and variables share one
; case-insensitive namespace, so a parameter called `max` shadows the Max()
; built-in and the call below fails at RUNTIME with "Integer has no method
; named Call" — it load-checks clean, which is how it got this far once.
; Returns an integer offset in [-maxPx, +maxPx], capped at a third of extent;
; 0 when maxPx <= 0 or extent is under 3 px.
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
; Returns true when found before timeoutMs; false otherwise, and for an empty
; needle or a window UIA can't read.
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
        for el in UiaFindAllRaw(root, cond, UIA_SCOPE_SUBTREE(), UIA_NODE_BUDGET()) {
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
; Returns the newline-joined text (at most maxChars), or "" when UIA can't see
; the window or nothing in it has text.
UiaDumpText(hwnd, maxChars := 100000) {
    root := UiaFromWindow(hwnd)
    cond := UiaTrueCondition()
    if (!root || !cond)
        return ""
    out := "", last := ""
    for el in UiaFindAllRaw(root, cond, UIA_SCOPE_SUBTREE(), UIA_NODE_BUDGET()) {
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
; Returns the TreeWalker object, or "" when UIA is unavailable or the walker
; can't be created.
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
; Returns the parent element, or "" at the top of the tree or on any failure.
UiaParent(el) {
    return UiaWalkerStep(3, el)
}

; The element's first child in the raw tree, or "" when it has none.
; Returns the first child element, or "" when it has none or on any failure.
UiaFirstChild(el) {
    return UiaWalkerStep(4, el)
}

; The element's next sibling in the raw tree, or "" after the last one.
; Returns the next sibling element, or "" after the last one or on any
; failure.
UiaNextSibling(el) {
    return UiaWalkerStep(6, el)
}

; Shared TreeWalker navigation: slot 3 parent / 4 first child / 6 next
; sibling. All three take (element in, element out) and NULL out means
; "there isn't one", which wraps to "".
; Returns the element reached, or "" when there isn't one or on any failure.
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

; The nearest ANCESTOR of el (el itself excluded) with this AutomationId,
; found by walking UP — one parent step and one property read a level. The
; fast way to the container of an element you already hold (2026-10-14: a
; window-wide UiaFindById on a big Chrome page regularly ran past a 400 ms
; timeout although the id was there; walking up from a known element was
; instant). Stops below the desktop root and after maxHops levels.
; Returns the ancestor, or ""; `why` is "" on a hit, else why not (no
; element, reached the top of its window, or maxHops spent).
UiaFindAncestorById(el, automationId, maxHops := 64, &why?) {
    return UiaFindAncestorWhere(el, (a) => UiaAutomationId(a) == automationId,
        "with AutomationId '" automationId "'", maxHops, &why)
}

; The nearest ANCESTOR of el (el itself excluded) with this exact Name and,
; when controlType is not 0, this UIA_*ControlTypeId — UiaFindAncestorById
; for the many web elements that have no id. Same walk, same bounds.
; Returns the ancestor, or ""; `why` is "" on a hit, else why not (no
; element, reached the top of its window, or maxHops spent).
UiaFindAncestorByName(el, name, controlType := 0, maxHops := 64, &why?) {
    test(a) {
        if (UiaName(a) !== name)
            return false
        return controlType = 0 || UiaControlType(a) = controlType
    }
    return UiaFindAncestorWhere(el, test,
        "named '" name "'" (controlType ? " of type " UiaControlTypeName(controlType) : ""), maxHops, &why)
}

; Shared upward walk: the first ancestor for which pred(ancestor) is true,
; never the desktop root (an element with no parent) and never el itself.
; what describes the target for the &why ("with AutomationId 'x'").
; Returns the ancestor, or ""; `why` is "" on a hit, else why not.
UiaFindAncestorWhere(el, pred, what, maxHops := 64, &why?) {
    why := ""
    if !el {
        why := "no start element (the find that should have produced it returned nothing)"
        return ""
    }
    node := UiaParent(el), hops := 0
    while (node != "") {
        up := UiaParent(node)
        if (up = "")                        ; node is the desktop root
            break
        if (hops >= maxHops) {
            why := "no ancestor " what " within " maxHops " levels (stopped there — raise maxHops)"
            return ""
        }
        hops += 1
        if pred(node)
            return node
        node := up
    }
    why := "no ancestor " what " — walked up to the top of the element's window"
    return ""
}

; Readable name for a UIA_*ControlTypeId — "Button", "Edit", ... An unknown
; id comes back as its bare number, still greppable. Ids verified against
; UIAutomationClient.h (Windows SDK 10.0.26100.0).
; Returns the type's name ("Button", "Edit" and so on), or the id as a string
; for an unknown id.
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
; depth stays visible in the indent. Bounded four ways — maxDepth, maxLines
; of output, UIA_NODE_BUDGET() visited nodes and UIA_DUMP_TIME_MS() —
; because a diagnostic must never become the stall it is diagnosing. ""
; when UIA can't see the window (stats.why says why). An icon-font
; character in a name shows as <U+E611> (UiaShowIcons); nameFilter matches
; the raw name or that shown form. To dump ONE part of the window, start
; from an element instead: UiaDumpSubtree, which this delegates to.
;
; Two more LINE filters/decorations (2026-10-14, from a real build that
; kept hand-rolling subtree walks to see positions):
;   positions    true appends " @x,y wxh" (screen pixels) to every line, or
;                " @none" when the element has no rectangle
;   visibleOnly  true keeps only elements that can be seen: a rectangle,
;                not IsOffscreen, and some of it inside every scroll
;                container above it, its window and a monitor — the rule
;                UiaVisibleRect applies, carried down the walk instead of
;                re-climbing for every node. Something drawn OVER an element
;                does not hide it here (only a hit test can tell).
; Like nameFilter, neither changes WHICH nodes are walked: the counts and
; the fingerprint below are the same with them on or off. They do add
; reads, so they can change how FAR a time-capped walk gets: positions
; reads one rectangle per printed line; visibleOnly reads a rectangle,
; IsOffscreen and the monitors per matching line and, while lines can
; still be printed, a ScrollPattern check per node that has children.
; Both stop once maxLines is reached. On a big browser page that can be
; enough to hit UIA_DUMP_TIME_MS() where a plain dump finished (timeHit,
; and then no fingerprint) — compare fingerprints between plain dumps.
;
; An outline that is cut short must SAY so (2026-10-12 feedback: a dump
; capped at depth 25 showed a form's fields as empty groups, a filter for a
; field's label returned nothing, and "nothing there" was nearly concluded).
; `stats` (optional) describes the walk:
;   visited      nodes walked
;   cutAtDepth   nodes at maxDepth that HAVE children — subtrees not shown;
;                > 0 means a match may be deeper than the dump went
;   budgetHit    the node budget ran out with nodes left to visit
;   timeHit      UIA_DUMP_TIME_MS() ran out first
;   linesHit     a matching line was dropped at maxLines (never set when
;                maxLines <= 0, which means "no outline, just the stats")
;   fingerprint  8 hex digits over every visited node's depth, control type,
;                name and automation id. Compare across calls: a different
;                value means the content changed even when the window title
;                did not. The same for a filtered and an unfiltered dump of
;                one unchanged page at one maxDepth — the walk never depends
;                on nameFilter, maxLines, positions or visibleOnly (it keeps
;                going past maxLines, so the counts above are true for the
;                whole walk). It hashes the RAW name (icon characters as
;                themselves, not their <U+...> form).
;                Only comparable for a walk that ENDED ON ITS OWN: "" when
;                timeHit (where a slow provider stops the walk varies from
;                call to call, so two dumps of one unchanged page would
;                differ), and with budgetHit it covers only the first
;                UIA_NODE_BUDGET() nodes — a change past them doesn't show.
;   why          "" or why the window couldn't be read
;
; Cost: because the walk doesn't stop at maxLines, an unfiltered dump of a
; big tree walks until the node budget or the time cap (about five
; cross-process calls a node — up to UIA_DUMP_TIME_MS() on a browser page),
; not just the first maxLines nodes. Lower maxDepth for a quick look.
; Returns the outline text, or "" when UIA can't read the window (stats.why
; says why), nothing matched the filters, or maxLines <= 0; `stats` is always
; filled in (fields above).
UiaDumpTree(hwnd, maxDepth := 8, nameFilter := "", maxLines := 300, &stats?, positions := false, visibleOnly := false) {
    root := UiaFromWindow(hwnd, &w)
    if !root {
        UiaDumpSubtree("", maxDepth, nameFilter, maxLines, &stats)
        stats.why := w
        return ""
    }
    return UiaDumpSubtree(root, maxDepth, nameFilter, maxLines, &stats, positions, visibleOnly)
}

; UiaDumpTree from any element: el is depth 0 and only its subtree is
; walked — one panel of a big page instead of the whole window, with the
; same filters, bounds and stats (fingerprint included: a subtree dump
; started at a window's root element gives the window dump's fingerprint).
; Get el from a find (UiaFindById, UiaFind, UiaFindAncestorById ...).
; Returns the outline text, or "" when there is no start element
; (stats.why says so), nothing matched the filters, or maxLines <= 0;
; `stats` is always filled in (UiaDumpTree's fields).
UiaDumpSubtree(el, maxDepth := 8, nameFilter := "", maxLines := 300, &stats?, positions := false, visibleOnly := false) {
    stats := {visited: 0, cutAtDepth: 0, budgetHit: false, timeHit: false,
              linesHit: false, fingerprint: "", why: ""}
    if !el {
        stats.why := "no start element (the find that should have produced it returned nothing)"
        return ""
    }
    st := {budget: UIA_NODE_BUDGET(), deadline: A_TickCount + UIA_DUMP_TIME_MS(),
           crc: 0, lines: [], maxDepth: maxDepth, nameFilter: nameFilter,
           maxLines: maxLines, stats: stats, positions: positions, visibleOnly: visibleOnly}
    ; What the start element's own ancestors let through — only needed when
    ; visibility decides lines. A top-level start (a window root) is its
    ; own window: its box clips its children (UiaDumpChildClip).
    clip := visibleOnly ? UiaClipAbove(el) : ""
    UiaDumpTreeWalk(el, 0, st, clip, visibleOnly && UiaIsWindowRoot(el))
    ; A time-cut walk stops wherever the provider's speed left it — not
    ; reproducible, so no fingerprint rather than a misleading one.
    stats.fingerprint := stats.timeHit ? "" : Format("{:08x}", st.crc)
    out := ""
    for line in st.lines
        out .= (out = "" ? "" : "`n") line
    return out
}

; Just the fingerprint of a window's tree to maxDepth (UiaDumpTree's, so the
; two agree) — "" when the window can't be read (stats.why) or the walk ran
; out of time (stats.timeHit). Take one before acting and one after to tell
; "the page changed" from "my find is wrong"; with stats.budgetHit it covers
; only the first UIA_NODE_BUDGET() nodes.
; Returns 8 hex digits, or "" when the window can't be read (stats.why) or the
; walk ran out of time (stats.timeHit); `stats` as UiaDumpTree's.
UiaTreeFingerprint(hwnd, maxDepth := 8, &stats?) {
    UiaDumpTree(hwnd, maxDepth, "", 0, &stats)
    return stats.fingerprint
}

; The area el's ancestors let through — the intersection of every scroll
; container above it and its own top-level window (UiaClipChain, the same
; walk UiaVisibleRect clips by), i.e. UiaVisibleRect's clipping without
; el's own box. For the tree dump's visibleOnly, which then narrows it on
; the way down instead of climbing again for every node.
; Returns {x, y, w, h}; "" when nothing above el clips it (el is a window
; root) or its window can't be reached (nothing is hidden on a guess);
; "none" when the ancestors let nothing through.
UiaClipAbove(el) {
    chain := UiaClipChain(el)
    if !IsObject(chain)
        return ""
    clip := ""
    n := chain.Length
    for i, a in chain {
        if (i != n && !UiaIsScrollContainer(a))
            continue
        ar := UiaRect(a)
        if !IsObject(ar)
            return "none"
        clip := (clip = "") ? ar : UiaIntersect(clip, ar)
        if !IsObject(clip)
            return "none"
    }
    return clip
}

; The clip a node hands its children in a visibleOnly dump: its own clip,
; narrowed by its box when it is a scroll container (or the window root
; the dump started at). clip is a rect, "" (unclipped) or "none".
; Returns the children's clip: a rect, "" or "none".
UiaDumpChildClip(node, clip, isTop) {
    if (clip = "none" || !(isTop || UiaIsScrollContainer(node)))
        return clip
    r := UiaRect(node)
    if !IsObject(r)
        return "none"
    c := (clip = "") ? r : UiaIntersect(clip, r)
    return IsObject(c) ? c : "none"
}

; Recursive worker. `st` carries the walk's shared state: the node budget,
; the deadline, the running CRC, the output lines, the options and the
; caller's stats; clip / isTop are what visibleOnly needs (UiaDumpChildClip).
; Returns nothing: it adds to st's lines, CRC and stats.
UiaDumpTreeWalk(el, depth, st, clip := "", isTop := false) {
    s := st.stats
    if (A_TickCount > st.deadline) {
        s.timeHit := true
        return
    }
    if (st.budget <= 0) {
        s.budgetHit := true
        return
    }
    st.budget -= 1
    s.visited += 1
    ; Fold a multi-line name onto one line — one element, one line, always.
    name := StrReplace(StrReplace(UiaName(el), "`r", " "), "`n", " ")
    tid := UiaControlType(el)
    aid := UiaAutomationId(el)
    st.crc := UiaCrc32(depth "`t" tid "`t" name "`t" aid "`n", st.crc)   ; the RAW name
    shown := UiaShowIcons(name)
    ; Once a line has been dropped at maxLines (linesHit) nothing more can be
    ; printed, so the per-line reads below stop too (review, 2026-10-14: they
    ; ran for every node of the walk, which on a big page roughly doubled
    ; its cost and could push it into the time cap).
    if (st.maxLines > 0 && !s.linesHit
        && (st.nameFilter = "" || InStr(name, st.nameFilter) || InStr(shown, st.nameFilter))) {
        r := (st.positions || st.visibleOnly) ? UiaRect(el) : ""
        keep := true
        if st.visibleOnly
            keep := IsObject(r) && clip != "none" && !UiaIsOffscreen(el)
                 && IsObject(UiaOnMonitors(clip = "" ? r : UiaIntersect(r, clip)))
        if (keep && st.lines.Length < st.maxLines) {
            line := ""
            Loop depth
                line .= "  "
            line .= UiaControlTypeName(tid) ' "' shown '"'
            if (aid != "")
                line .= " <id=" aid ">"
            if st.positions
                line .= IsObject(r) ? " @" r.x "," r.y " " r.w "x" r.h : " @none"
            st.lines.Push(line)
        } else if keep {                    ; an invisible element is no dropped line
            s.linesHit := true
        }
    }
    child := UiaFirstChild(el)
    if (depth >= st.maxDepth) {
        if (child != "")
            s.cutAtDepth += 1
        return
    }
    if (child != "" && st.visibleOnly && !s.linesHit)
        clip := UiaDumpChildClip(el, clip, isTop)
    while (child != "") {
        ; An owned window (a dialog, a dropdown) is listed under its owner
        ; but is not clipped by it: it starts its own clip.
        if (st.visibleOnly && UiaIsWindowRoot(child))
            UiaDumpTreeWalk(child, depth + 1, st, "", true)
        else
            UiaDumpTreeWalk(child, depth + 1, st, clip)
        if (s.budgetHit || s.timeHit)
            return
        child := UiaNextSibling(child)
    }
}
