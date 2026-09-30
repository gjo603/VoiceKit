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
    ; Only a NEGATIVE HRESULT is a failure. S_FALSE (1) means "fewer children
    ; than you asked for" — routine when a container's accChildCount is stale
    ; or overstated (dynamic lists, lazily built trees) — and the `got` it did
    ; return are real. Treating S_FALSE as failure dropped the whole subtree
    ; ("Couldn't find anything named ...") and leaked every child it handed us.
    hr := DllCall("oleacc\AccessibleChildren", "ptr", ComObjValue(acc), "int", 0, "int", cnt, "ptr", buf, "int*", &got := 0, "int")
    if (hr < 0)
        return kids
    Loop Min(got, cnt) {
        off := stride * (A_Index - 1)
        vt := NumGet(buf, off, "ushort")
        if (vt = 9) {                       ; VT_DISPATCH: an object child
            ; ComObjFromPtr takes over the reference AccessibleChildren gave us
            ; (no AddRef), so the wrapper's release is the one release it needs.
            if (p := NumGet(buf, off + 8, "ptr"))
                kids.Push({acc: ComObjFromPtr(p), child: 0})
        } else if (vt = 3) {                ; VT_I4: simple element of same parent
            kids.Push({acc: acc, child: NumGet(buf, off + 8, "int")})
        } else if (vt != 0) {
            ; Anything else holds nothing we wrap, but may still own a resource
            ; (a BSTR, an unexpected interface) — clear it rather than leak it.
            ; oleaut32 is a system DLL AutoHotkey itself keeps loaded.
            DllCall("oleaut32\VariantClear", "ptr", buf.Ptr + off)
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

; True if `needle` appears anywhere in the window's accessible tree — a
; case-insensitive SUBSTRING of any element's name or value.
;
; This is the "did the search actually return anything?" test. AccFindByName
; needs the EXACT accessible name, which for a result row or a status message
; is usually unknowable; the words on screen are not. Same walk limits as
; AccNodeOnce (depth 14, 6000 nodes, honours the deadline) so a browser's
; huge tree can't stall a run.
AccTextOnce(hwnd, needle, deadline) {
    AccPin()
    if DllCall("oleacc\AccessibleObjectFromWindow", "ptr", hwnd, "uint", 0xFFFFFFFC   ; OBJID_CLIENT
        , "ptr", AccIID(), "ptr*", &p := 0) != 0 || !p
        return false
    stack := [{acc: ComObjFromPtr(p), child: 0, depth: 0}]
    visited := 0
    while stack.Length {
        if (A_TickCount > deadline || ++visited > 6000)
            return false
        node := stack.Pop()
        ; InStr is case-insensitive by default in v2 — deliberate here: the
        ; author types what they saw, not what the app capitalised.
        if InStr(AccName(node.acc, node.child), needle)
            return true
        if InStr(AccValue(node.acc, node.child), needle)
            return true
        if (node.child = 0 && node.depth < 14) {
            for kid in AccChildren(node.acc)
                stack.Push({acc: kid.acc, child: kid.child, depth: node.depth + 1})
        }
    }
    return false
}

; AccTextOnce, retried until ~budgetMs so late-rendering content counts.
AccTextPresent(hwnd, text, budgetMs := 700) {
    text := Trim(text)
    if (text = "")
        return false
    deadline := A_TickCount + budgetMs
    loop {
        if AccTextOnce(hwnd, text, deadline)
            return true
        if (A_TickCount > deadline)
            return false
        Sleep(150)
    }
}

; ---- input boxes (the `fill` step's MSAA fallback) -----------------------
; MSAA roles/states used below (oleacc.h).
ACC_ROLE_TEXT()        => 42      ; ROLE_SYSTEM_TEXT — an editable text box
ACC_ROLE_COMBOBOX()    => 46
ACC_ROLE_SPINBUTTON()  => 52
ACC_STATE_UNAVAILABLE()=> 0x1     ; disabled
ACC_STATE_FOCUSED()    => 0x4
ACC_STATE_PROTECTED()  => 0x20000000   ; a password box

AccRole(acc, child := 0) {
    try return Integer(acc.accRole[child])
    catch
        return 0
}

AccState(acc, child := 0) {
    try return Integer(acc.accState[child])
    catch
        return 0
}

; The window an accessible object belongs to (0 if oleacc can't say).
AccWindowOf(acc) {
    AccPin()
    try {
        if DllCall("oleacc\WindowFromAccessibleObject", "ptr", ComObjValue(acc), "ptr*", &h := 0) = 0
            return h
    }
    return 0
}

; Every visible INPUT named `name` in the window, in TREE ORDER (so "the 2nd
; box labelled Amount" means the same thing it does on screen): editable text
; (ROLE_SYSTEM_TEXT), combo boxes and spin buttons — never the label that
; shares the name (oleacc names a Win32 edit after the static before it, so
; the role is the only thing that tells them apart). Same walk limits as
; AccNodeOnce (depth 14, 6000 nodes, the deadline). Returns [{acc, child, loc}].
AccInputNodes(hwnd, name, deadline, maxItems := 30) {
    AccPin()
    out := []
    if DllCall("oleacc\AccessibleObjectFromWindow", "ptr", hwnd, "uint", 0xFFFFFFFC   ; OBJID_CLIENT
        , "ptr", AccIID(), "ptr*", &p := 0) != 0 || !p
        return out
    name := Trim(name)
    ; inBox: inside an input already counted — a Win32 combo box's own edit
    ; carries the combo's name too, and one box must count once.
    stack := [{acc: ComObjFromPtr(p), child: 0, depth: 0, inBox: false}]
    visited := 0
    while stack.Length {
        if (A_TickCount > deadline || ++visited > 6000)
            return out
        node := stack.Pop()
        isBox := false
        if (!node.inBox && AccName(node.acc, node.child) = name) {
            role := AccRole(node.acc, node.child)
            if (role = ACC_ROLE_TEXT() || role = ACC_ROLE_COMBOBOX() || role = ACC_ROLE_SPINBUTTON()) {
                loc := AccLocation(node.acc, node.child)
                if IsObject(loc) {
                    isBox := true
                    out.Push({acc: node.acc, child: node.child, loc: loc})
                    if (out.Length >= maxItems)
                        return out
                }
            }
        }
        if (node.child = 0 && node.depth < 14) {
            kids := AccChildren(node.acc)
            i := kids.Length                 ; pushed in reverse, so they POP in tree order
            while (i >= 1) {
                stack.Push({acc: kids[i].acc, child: kids[i].child, depth: node.depth + 1
                    , inBox: node.inBox || isBox})
                i -= 1
            }
        }
    }
    return out
}

AccIID() {
    static iid := 0
    if !iid {
        iid := Buffer(16)
        DllCall("ole32\IIDFromString", "wstr", "{618736E0-3C3D-11CF-810C-00AA00389B71}", "ptr", iid)   ; IID_IAccessible
    }
    return iid
}
