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

; Run steps in order; stop and explain if one fails.
RunWorkflowSteps(steps) {
    for i, s in steps {
        err := WfRunStep(s)
        if (err != "") {
            MsgBox("Workflow stopped at step " i " of " steps.Length ".`n`n"
                . WfDesc(s) "`n`n" err, "VoiceKit workflow", "Icon! 262144")   ; 262144 = always-on-top
            return false
        }
    }
    return true
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
            if (b = "")
                return "Window not found (and no launch command is set): " a
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
            if !WinExist(a)
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
    }
    return t "  " a "  " b
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
