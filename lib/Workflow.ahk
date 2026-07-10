#Requires AutoHotkey v2.0
; ============================================================
;  Workflow engine — loads and runs the .steps.txt files that
;  Workflow Studio creates (say "open workflow studio").
;
;  Steps file format: one step per line,
;      type|paramA|paramB|paramC
;  Params are percent-encoded (%, |, newlines) so any text
;  survives the pipe-delimited format. paramC is used by click
;  steps as a recorded window-relative position fallback.
; ============================================================
#Include "%A_LineFile%\..\Acc.ahk"

; Run a saved workflow file. Returns true if every step ran.
RunWorkflow(stepsFile) {
    if !FileExist(stepsFile) {
        MsgBox("Workflow file not found:`n" stepsFile, "VoiceKit workflow", "Iconx 262144")   ; 262144 = always-on-top
        return false
    }
    return RunWorkflowSteps(WorkflowLoad(stepsFile))
}

; Parse a steps file into an array of [type, paramA, paramB, paramC].
WorkflowLoad(stepsFile) {
    steps := []
    Loop Parse FileRead(stepsFile, "UTF-8"), "`n", "`r" {
        line := Trim(A_LoopField)
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        parts := StrSplit(line, "|")
        while (parts.Length < 4)
            parts.Push("")
        steps.Push([parts[1], WfDecode(parts[2]), WfDecode(parts[3]), WfDecode(parts[4])])
    }
    return steps
}

; Run steps in order; stop and explain if one fails. The `if`/`else`/`endif`
; steps add optional branching: an `if` whose condition is false skips its
; block (to the matching `else`, or past `endif`); everything else runs
; straight through, so ordinary (recorded) workflows behave exactly as before.
RunWorkflowSteps(steps) {
    i := 1, n := steps.Length
    while (i <= n) {
        s := steps[i], t := s[1]
        if (t = "if") {
            res := WfEvalCond(s)
            if (res.err != "") {
                MsgBox("Workflow stopped at step " i " of " n ".`n`n"
                    . WfDesc(s) "`n`n" res.err, "VoiceKit workflow", "Icon! 262144")
                return false
            }
            i := res.val ? i + 1 : WfSkipToElseOrEndif(steps, i) + 1
            continue
        }
        if (t = "else") {                       ; reached while running the true branch — skip to endif
            i := WfSkipToEndif(steps, i) + 1
            continue
        }
        if (t = "endif") {
            i += 1
            continue
        }
        ; WfRunStep converts expected failures into a returned message,
        ; but a few ops (e.g. WinGetPos on a window that closed mid-step)
        ; can THROW. Catch those so the run stops with the same friendly
        ; popup instead of a raw unhandled-exception dialog.
        try
            err := WfRunStep(s)
        catch as e
            err := "Unexpected error: " e.Message
        if (err != "") {
            MsgBox("Workflow stopped at step " i " of " n ".`n`n"
                . WfDesc(s) "`n`n" err, "VoiceKit workflow", "Icon! 262144")   ; 262144 = always-on-top
            return false
        }
        i += 1
    }
    return true
}

; Evaluate an `if` step. Format: if|<window>|<element>|<condType>.
; Returns {err, val}: a non-empty err (unknown condition) stops the run;
; otherwise val is the boolean result. Conditions are deterministic state
; tests only (window present / accessible element present), no guessing.
WfEvalCond(s) {
    win := s[2], name := s[3], cond := (s.Length >= 4) ? s[4] : ""
    ; An empty window would make WinExist("") match the LAST-FOUND window
    ; (whatever the previous step touched) and silently take the wrong branch.
    if (Trim(win) = "")
        return {err: "This 'if' step has no window to check.", val: false}
    switch cond {
        case "winexists":        return {err: "", val: (WinExist(win) != 0)}
        case "winnotexists":     return {err: "", val: (WinExist(win) = 0)}
        case "elementexists":    return {err: "", val: WfElementPresent(win, name)}
        case "elementnotexists": return {err: "", val: !WfElementPresent(win, name)}
    }
    return {err: "Unknown 'if' condition: " cond, val: false}
}

; True if an accessible element named `name` is present in window `win`.
; A condition is a point-in-time snapshot, so use a short Acc budget — not
; the click path's 3 s wait-for-late-render budget, which would stall every
; absent-element check (painful inside a loop) for ~3 s per pass.
WfElementPresent(win, name) {
    hwnd := WinExist(win)
    if !hwnd
        return false
    return IsObject(AccFindByName(hwnd, name, 700))
}

; From an `if` at fromIdx, index of its matching `else` (if one precedes the
; matching `endif`) or that `endif`, honoring nesting. Unterminated -> past end.
WfSkipToElseOrEndif(steps, fromIdx) {
    depth := 0, i := fromIdx + 1
    while (i <= steps.Length) {
        t := steps[i][1]
        if (t = "if")
            depth += 1
        else if (t = "endif") {
            if (depth = 0)
                return i
            depth -= 1
        } else if (t = "else" && depth = 0)
            return i
        i += 1
    }
    return i                                     ; steps.Length + 1: fall off the end
}

; From an `if`/`else` at fromIdx, index of the matching `endif` (honoring
; nesting), or past the end if the block is never closed.
WfSkipToEndif(steps, fromIdx) {
    depth := 0, i := fromIdx + 1
    while (i <= steps.Length) {
        t := steps[i][1]
        if (t = "if")
            depth += 1
        else if (t = "endif") {
            if (depth = 0)
                return i
            depth -= 1
        }
        i += 1
    }
    return i
}

; Execute one step. Returns "" on success, or the reason it failed.
WfRunStep(s) {
    t := s[1], a := s[2], b := s[3]
    c := (s.Length >= 4) ? s[4] : ""
    switch t {
        case "run":
            target := (InStr(a, " ") && FileExist(a)) ? '"' a '"' : a
            try Run(target)
            catch
                return "Couldn't open: " a
        case "focus":
            if WinExist(a) {
                WinActivate(a)
                Sleep(300)          ; let the app take focus before keys arrive
                return ""
            }
            if (b = "") {
                ; Recordings capture no timing, so a window that appears a
                ; beat later (a dialog, a loading app) is normal — wait for
                ; it like waitwin does instead of failing instantly.
                if !WinWait(a, , 10)
                    return "Window not found (and no launch command is set): " a
                WinActivate(a)
                Sleep(300)
                return ""
            }
            try Run(b)
            catch
                return "Couldn't launch: " b
            if !WinWait(a, , 10)
                return "Launched, but the window never appeared: " a
            WinActivate(a)
            Sleep(300)
        case "waitwin":
            timeout := 10
            if (b != "")
                try timeout := Number(b)
            if !WinWait(a, , timeout)
                return "Window didn't appear within " timeout "s: " a
            WinActivate(a)
            Sleep(300)
        case "wait":
            try Sleep(Integer(a))
            catch
                return "Not a number of milliseconds: " a
        case "text":
            SendText(a)
        case "keys":
            try Send(a)
            catch
                return "Bad key syntax (see AHK v2 Send docs): " a
        case "click", "dblclick", "rclick":
            ; a = window, b = element name (may be ""), c = "x,y" window-relative fallback
            if (!WinExist(a) && !WinWait(a, , 10))   ; same grace as focus/waitwin
                return "Window not found: " a
            WinActivate(a)
            Sleep(400)
            CoordMode("Mouse", "Screen")
            btn := (t = "rclick") ? "Right" : "Left"
            n := (t = "dblclick") ? 2 : 1
            if (b != "") {
                loc := AccFindByName(WinExist(a), b)
                if IsObject(loc) {
                    MouseClick(btn, loc.x + loc.w // 2, loc.y + loc.h // 2, n)
                    Sleep(150)
                    return ""
                }
                if (c = "")
                    return "Couldn't find anything named `"" b "`" in that window."
            }
            if (c = "")
                return "Nothing to click — no element name and no recorded position."
            xy := StrSplit(c, ",")
            if (xy.Length != 2 || !IsInteger(Trim(xy[1])) || !IsInteger(Trim(xy[2])))
                return "Bad click position: " c
            WinGetPos(&wx, &wy, , , a)
            MouseClick(btn, wx + Trim(xy[1]), wy + Trim(xy[2]), n)
            Sleep(150)
        case "move":
            if !WinExist(a)
                return "Window not found: " a
            halfW := A_ScreenWidth // 2, halfH := A_ScreenHeight // 2
            switch b {
                case "max":
                    WinMaximize(a)
                case "left":
                    WinRestore(a)
                    WinMove(0, 0, halfW, A_ScreenHeight, a)
                case "right":
                    WinRestore(a)
                    WinMove(halfW, 0, halfW, A_ScreenHeight, a)
                case "top":
                    WinRestore(a)
                    WinMove(0, 0, A_ScreenWidth, halfH, a)
                case "bottom":
                    WinRestore(a)
                    WinMove(0, halfH, A_ScreenWidth, halfH, a)
                default:
                    return "Unknown position (use left / right / top / bottom / max): " b
            }
        case "close":
            if WinExist(a)
                WinClose(a)
        default:
            return "Unknown step type: " t
    }
    return ""
}

; One-line description of a step (Studio list + error messages).
WfDesc(s) {
    t := s[1], a := s[2], b := s[3]
    c := (s.Length >= 4) ? s[4] : ""
    switch t {
        case "run":      return "Open  " a
        case "focus":    return "Focus  " a (b != "" ? "    (launches: " b ")" : "")
        case "waitwin":  return "Wait for window  " a "    (up to " (b != "" ? b : "10") "s)"
        case "wait":     return "Wait  " a " ms"
        case "text":     return "Type  `"" a "`""
        case "keys":     return "Press keys  " a
        case "click":    return "Click  " (b != "" ? "`"" b "`"" : "at (" c ")") "    in  " a
        case "dblclick": return "Double-click  " (b != "" ? "`"" b "`"" : "at (" c ")") "    in  " a
        case "rclick":   return "Right-click  " (b != "" ? "`"" b "`"" : "at (" c ")") "    in  " a
        case "move":     return "Position  " a "  ->  " b
        case "close":    return "Close  " a
        case "if":       return "If  " WfCondDesc(c, a, b)     ; a=window, b=element, c=condType
        case "else":     return "Otherwise:"
        case "endif":    return "End if"
    }
    return t "  " a "  " b
}

; Human-readable form of an `if` condition. cond = condType, win = window,
; name = element name (used only by the element conditions).
WfCondDesc(cond, win, name) {
    switch cond {
        case "winexists":        return "window  " win "  is open"
        case "winnotexists":     return "window  " win "  is NOT open"
        case "elementexists":    return "`"" name "`"  is on screen in  " win
        case "elementnotexists": return "`"" name "`"  is NOT on screen in  " win
    }
    return cond "  " win "  " name
}

; Percent-encode / decode params so they survive the pipe format.
WfEncode(s) {
    s := StrReplace(s, "%", "%25")
    s := StrReplace(s, "|", "%7C")
    s := StrReplace(s, "`r", "%0D")
    return StrReplace(s, "`n", "%0A")
}
WfDecode(s) {
    s := StrReplace(s, "%0A", "`n")
    s := StrReplace(s, "%0D", "`r")
    s := StrReplace(s, "%7C", "|")
    return StrReplace(s, "%25", "%")
}
