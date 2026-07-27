#Requires AutoHotkey v2.0
; ============================================================
;  Minimal MSAA (Microsoft Active Accessibility) helpers used
;  for element clicks in workflows. No dependencies.
;
;  Elements are identified by their accessible NAME — the text
;  a screen reader would announce: button captions, menu items,
;  links, file names in Explorer. Recording stores that name;
;  playback finds it again and clicks its center. Names beat
;  raw coordinates: they survive window moves and resizes.
; ============================================================

; oleacc.dll must STAY loaded: the COM objects it hands out point
; back into the DLL's image, and AHK frees on-demand DLLs right
; after each DllCall — which would leave those objects pointing
; at unmapped memory (hard crash on first use).
AccPin() {
    static hOleacc := DllCall("kernel32\LoadLibraryW", "wstr", "oleacc.dll", "ptr")
}

; UI element under a screen point -> {acc, child} or "".
AccFromPoint(x, y) {
    AccPin()
    pt := (y << 32) | (x & 0xFFFFFFFF)
    varChild := Buffer(8 + 2 * A_PtrSize, 0)
    if DllCall("oleacc\AccessibleObjectFromPoint", "int64", pt, "ptr*", &pAcc := 0, "ptr", varChild) != 0 || !pAcc
        return ""
    return {acc: ComObjFromPtr(pAcc), child: NumGet(varChild, 8, "int")}
}

; Accessible name of an element ("" if it has none).
AccName(acc, child := 0) {
    try return Trim(acc.accName[child])
    catch
        return ""
}

; Accessible VALUE of an element ("" if it has none) — the CONTENT of an
; edit / combo / URL bar (accName is its label, accValue what's inside).
; Plain IDispatch, like accName — no vtable tricks needed.
AccValue(acc, child := 0) {
    try return acc.accValue[child]
    catch
        return ""
}

; Screen rectangle of an element -> {x,y,w,h}, or "" if hidden.
; Uses the raw vtable (slot 22 = accLocation): IDispatch doesn't
; marshal its four long* out-params reliably. 64-bit ABI: the
; VARIANT arg is passed by reference.
AccLocation(acc, child := 0) {
    varChild := Buffer(24, 0)
    NumPut("ushort", 3, varChild, 0)        ; VT_I4
    NumPut("int", child, varChild, 8)
    x := 0, y := 0, w := 0, h := 0
    try ComCall(22, ComObjValue(acc), "int*", &x, "int*", &y, "int*", &w, "int*", &h, "ptr", varChild)
    catch
        return ""
    return (w > 0 && h > 0) ? {x: x, y: y, w: w, h: h} : ""
}

; All children of an accessible object.
AccChildren(acc) {
    AccPin()
    kids := []
    cnt := 0
    try cnt := acc.accChildCount
    if (cnt < 1)
        return kids
    stride := 8 + 2 * A_PtrSize             ; sizeof(VARIANT)
    buf := Buffer(stride * cnt, 0)
    if DllCall("oleacc\AccessibleChildren", "ptr", ComObjValue(acc), "int", 0, "int", cnt, "ptr", buf, "int*", &got := 0) != 0
        return kids
    Loop got {
        off := stride * (A_Index - 1)
        vt := NumGet(buf, off, "ushort")
        if (vt = 9) {                       ; VT_DISPATCH: an object child
            if (p := NumGet(buf, off + 8, "ptr"))
                kids.Push({acc: ComObjFromPtr(p), child: 0})
        } else if (vt = 3) {                ; VT_I4: simple element of same parent
            kids.Push({acc: acc, child: NumGet(buf, off + 8, "int")})
        }
    }
    return kids
}

; Find a visible element by exact name (case-insensitive) inside
; a window, retrying until ~budgetMs so late-rendering UIs get a
; chance. Returns its screen rect {x,y,w,h}, or "".
AccFindByName(hwnd, name, budgetMs := 3000) {
    deadline := A_TickCount + budgetMs
    loop {
        loc := AccFindOnce(hwnd, name, deadline)
        if (IsObject(loc) || A_TickCount > deadline)
            return loc
        Sleep(250)
    }
}

AccFindOnce(hwnd, name, deadline) {
    dummy := false
    node := AccNodeOnce(hwnd, name, deadline, false, &dummy)
    return IsObject(node) ? node.loc : ""
}

; Same visible-element-by-name search, but returns the accessible NODE
; ({acc, child, loc}) so callers can also read its value, not just click it.
; requireValue skips matches whose accValue is empty — a label and the box
; beside it often SHARE a name (oleacc derives the box's name from the
; label), and a value reader wants the box, not the label. When only
; empty-valued matches exist, foundEmpty is set so the caller can tell
; "empty box" from "no such element".
AccNodeOnce(hwnd, name, deadline, requireValue, &foundEmpty) {
    AccPin()
    if DllCall("oleacc\AccessibleObjectFromWindow", "ptr", hwnd, "uint", 0xFFFFFFFC   ; OBJID_CLIENT
        , "ptr", AccIID(), "ptr*", &p := 0) != 0 || !p
        return ""
    name := Trim(name)
    stack := [{acc: ComObjFromPtr(p), child: 0, depth: 0}]
    visited := 0
    while stack.Length {
        if (A_TickCount > deadline || ++visited > 6000)   ; huge trees (browsers): give up, caller may retry
            return ""
        node := stack.Pop()
        if (AccName(node.acc, node.child) = name) {
            loc := AccLocation(node.acc, node.child)
            if IsObject(loc) {
                if (!requireValue || AccValue(node.acc, node.child) != "")
                    return {acc: node.acc, child: node.child, loc: loc}
                foundEmpty := true
            }
        }
        if (node.child = 0 && node.depth < 14) {
            for kid in AccChildren(node.acc)
                stack.Push({acc: kid.acc, child: kid.child, depth: node.depth + 1})
        }
    }
    return ""
}

; Find a visible element by name (retrying like AccFindByName) and read its
; accessible VALUE. Prefers a match that HAS a value (see AccNodeOnce);
; if only empty-valued matches exist by the deadline, that's a legitimate
; empty box — found=true, value="". found=false means nothing of that name
; appeared at all within the budget.
AccValueByName(hwnd, name, budgetMs := 3000) {
    deadline := A_TickCount + budgetMs
    foundEmpty := false
    loop {
        node := AccNodeOnce(hwnd, name, deadline, true, &foundEmpty)
        if IsObject(node)
            return {found: true, value: AccValue(node.acc, node.child)}
        if (A_TickCount > deadline)
            return {found: foundEmpty, value: ""}
        Sleep(250)
    }
}

AccIID() {
    static iid := 0
    if !iid {
        iid := Buffer(16)
        DllCall("ole32\IIDFromString", "wstr", "{618736E0-3C3D-11CF-810C-00AA00389B71}", "ptr", iid)   ; IID_IAccessible
    }
    return iid
}
