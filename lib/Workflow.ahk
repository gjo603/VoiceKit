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
;
;  The `ask` step (ask|<label>|<suggested answer>|) collects a
;  text input from the user: every ask in the workflow is asked
;  UP FRONT (one dialog per unique label, before step 1 runs),
;  and the answer is typed at the step's position like a `text`
;  step. Cancelling any dialog cancels the whole run quietly.
;
;  The `collect` step (collect|<label>|<element name>|) is the
;  mirror image: it GRABS a value at its position and saves it
;  under the label — with no element name it copies the current
;  selection (clipboard preserved), with one it reads that named
;  box's accessible value in the active window. Collected values
;  land in the workflow's sheet (<Base>.inputs.csv): a single run
;  appends a row (inputs used + values collected); a loop fed by
;  the sheet fills the collect columns of the row that ran.
; ============================================================
#Include "%A_LineFile%\..\Acc.ahk"

; Optional abort hook: a host (the loop runner's Stop button) sets this to
; a callable returning true when the run should stop. The engine polls it
; between steps and inside its long waits (Wait steps, window waits, the
; settle pauses), so a stop cuts in mid-run instead of after the pass.
; An aborted run returns false QUIETLY — no failure popup, like cancel.
global wfRunAbortCheck := ""

; True when the host asked the current run to stop.
WfAborted() {
    global wfRunAbortCheck
    return IsObject(wfRunAbortCheck) && wfRunAbortCheck.Call()
}

; Sleep in slices so the abort hook can cut it short. False if aborted.
WfSleep(ms) {
    left := ms
    while (left > 0) {
        if WfAborted()
            return false
        chunk := Min(100, left)
        Sleep(chunk)
        left -= chunk
    }
    return !WfAborted()
}

; WinWait, sliced the same way. Returns the HWND, or 0 on timeout/abort.
WfWinWait(crit, timeoutSec) {
    deadline := A_TickCount + Round(timeoutSec * 1000)
    loop {
        if (hwnd := WinExist(crit))
            return hwnd
        if (WfAborted() || A_TickCount >= deadline)
            return 0
        Sleep(100)
    }
}

; Run a saved workflow file. Returns true if every step ran.
RunWorkflow(stepsFile) {
    if !FileExist(stepsFile) {
        MsgBox("Workflow file not found:`n" stepsFile, "VoiceKit workflow", "Iconx 262144")   ; 262144 = always-on-top
        return false
    }
    steps := WorkflowLoad(stepsFile)
    ; Gather inputs HERE rather than inside RunWorkflowSteps, so a run that
    ; also collects values can save the inputs it used beside the results.
    askVals := ""
    askLabels := WfAskLabels(steps)
    if askLabels.Length {
        askVals := WfGatherInputs(steps)
        if !IsObject(askVals)
            return false                ; cancelled — quiet, no error popup
    }
    collected := Map()
    collected.CaseSense := false
    ok := RunWorkflowSteps(steps, askVals, collected)
    ; A finished run that collected values appends one row (inputs used +
    ; values collected) to the workflow's sheet — the same file loop batches
    ; read from and fill in.
    if (ok && collected.Count) {
        r := WfSheetApplyResults(WfSheetPath(stepsFile), askLabels, WfCollectLabels(steps),
            [{src: 0, ins: IsObject(askVals) ? askVals : Map(), out: collected}])
        TrayTip(r.err = ""
            ? "Saved " collected.Count " collected value" (collected.Count = 1 ? "" : "s") " to " r.name
            : r.err, "VoiceKit", "Iconi")
    }
    return ok
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
RunWorkflowSteps(steps, askVals := "", collected := "") {
    ; Collect every `ask` input before anything runs, so the user answers
    ; up front and the rest of the run is hands-free. A caller (the loop
    ; runner feeding CSV rows) may pass a ready Map(label -> answer)
    ; instead, which skips the dialogs entirely. `collected` is the mirror:
    ; pass a Map and every `collect` step deposits its value there under
    ; its label — callers decide what to do with them (sheet, display).
    if !IsObject(askVals) {
        askVals := WfGatherInputs(steps)
        if !IsObject(askVals)
            return false                ; cancelling is deliberate — no error popup
    }
    i := 1, n := steps.Length
    while (i <= n) {
        if WfAborted()                  ; host asked the run to stop — quiet, like cancel
            return false
        s := steps[i], t := s[1]
        if (t = "ask") {                ; type the answer collected up front
            SendText(askVals.Get(WfAskLabel(s), ""))
            Sleep(150)
            i += 1
            continue
        }
        if (t = "collect") {            ; grab a value here and remember it by label
            cerr := ""
            val := ""
            if (Trim(s[3]) != "") {     ; read the named box's content (in the active window)
                hwndA := WinExist("A")
                r := hwndA ? AccValueByName(hwndA, s[3]) : {found: false, value: ""}
                if !r.found
                    cerr := "Couldn't find a box named `"" s[3] "`" in the active window."
                else
                    val := r.value
            } else {
                val := WfCopySelection(&cerr)
            }
            if (cerr != "") {
                if WfAborted()
                    return false
                MsgBox("Workflow stopped at step " i " of " n ".`n`n"
                    . WfDesc(s) "`n`n" cerr, "VoiceKit workflow", "Icon! 262144")
                return false
            }
            if IsObject(collected)
                collected[WfCollectLabel(s)] := val
            Sleep(150)
            i += 1
            continue
        }
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
            if WfAborted()              ; the Stop cut this step's wait short — not a real failure
                return false
            MsgBox("Workflow stopped at step " i " of " n ".`n`n"
                . WfDesc(s) "`n`n" err, "VoiceKit workflow", "Icon! 262144")   ; 262144 = always-on-top
            return false
        }
        i += 1
    }
    return !WfAborted()     ; a stop during the LAST step must still report "didn't finish"
}

; The label an `ask` step is keyed by ("Input" if somehow blank — the
; Studio and the MCP writer both require one at authoring time).
WfAskLabel(s) {
    label := Trim(s[2])
    return label != "" ? label : "Input"
}

; Unique `ask` labels in step order. The loop runner uses this to batch
; inputs (typed-in rows or a CSV whose columns are these labels).
WfAskLabels(steps) {
    seen := Map()
    seen.CaseSense := false
    labels := []
    for s in steps {
        if (s[1] != "ask")
            continue
        l := WfAskLabel(s)
        if !seen.Has(l) {
            seen[l] := true
            labels.Push(l)
        }
    }
    return labels
}

; The label a `collect` step saves its value under ("Collected" if somehow
; blank — every authoring surface requires one).
WfCollectLabel(s) {
    label := Trim(s[2])
    return label != "" ? label : "Collected"
}

; Unique `collect` labels in step order — the sheet's output columns.
WfCollectLabels(steps) {
    seen := Map()
    seen.CaseSense := false
    labels := []
    for s in steps {
        if (s[1] != "collect")
            continue
        l := WfCollectLabel(s)
        if !seen.Has(l) {
            seen[l] := true
            labels.Push(l)
        }
    }
    return labels
}

; Copy whatever is selected right now, preserving the user's clipboard.
; err is set when nothing landed on the clipboard (nothing selected, or
; the app puts nothing textual there).
WfCopySelection(&err) {
    err := ""
    saved := ClipboardAll()
    A_Clipboard := ""
    Send("^c")
    ok := ClipWait(1)
    text := ok ? A_Clipboard : ""
    A_Clipboard := saved
    if !ok
        err := "Nothing was copied — the steps before this one should leave the text selected."
    return text
}

; Ask the user for every `ask` step's answer, in step order, one dialog per
; unique label (case-insensitive — the same label twice is asked once and
; typed at both spots). Returns Map(label -> answer), or "" if the user
; cancelled any dialog. Asks even for `ask` steps inside an if-branch that
; may later be skipped — branch outcomes aren't knowable before the run.
WfGatherInputs(steps) {
    vals := Map()
    vals.CaseSense := false
    for s in steps {
        if (s[1] != "ask")
            continue
        label := WfAskLabel(s)
        if vals.Has(label)
            continue
        ans := WfAskInputDialog(label, s[3])
        if !IsObject(ans)
            return ""
        vals[label] := ans.text
    }
    return vals
}

; One input dialog: label as the prompt, optional prefilled suggestion.
; Returns {text: answer} or "" on cancel. Deliberately a plain Gui — the
; engine has no Theme dependency — with native controls so Voice Access
; can click OK/Cancel by name; always-on-top because a run's dialogs
; appear over arbitrary apps.
WfAskInputDialog(label, suggestion := "") {
    result := ""
    d := Gui("+AlwaysOnTop", "VoiceKit — " label)
    d.SetFont("s10", "Segoe UI")
    d.AddText("xm w380", label ":")
    ed := d.AddEdit("xm y+8 w380", suggestion)
    btnOK := d.AddButton("xm y+14 w120 Default", "OK")
    btnCancel := d.AddButton("x+8 w120", "Cancel")
    btnOK.OnEvent("Click", (*) => (result := {text: ed.Value}, d.Destroy()))
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ; Capture the HWNDs BEFORE Show: the dialog can be answered/destroyed
    ; the instant it appears (voice click, fast Enter), and a property read
    ; on a destroyed Gui throws "Gui has no window" — which would pop an
    ; error dialog and hang the run. Raw hwnds stay safe to pass around:
    ; WinWaitClose on an already-gone window just returns.
    hwnd := d.Hwnd, edHwnd := ed.Hwnd
    d.Show()
    try {
        WinActivate("ahk_id " hwnd)
        ControlFocus(edHwnd, "ahk_id " hwnd)
    }
    ; Wait for the dialog, but let the abort hook close it: in the loop's
    ; "ask me before each run" mode, clicking Stop Looping while a question
    ; is up should end things right there — a quiet cancel.
    while WinExist("ahk_id " hwnd) {
        if WfAborted() {
            try d.Destroy()
            break
        }
        Sleep(100)
    }
    return result
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
                WfSleep(300)        ; let the app take focus before keys arrive
                return ""
            }
            if (b = "") {
                ; Recorded timing is coarse (and older recordings captured
                ; none at all), so a window that appears a beat later (a
                ; dialog, a loading app) is normal — wait for it like
                ; waitwin does instead of failing instantly.
                if !WfWinWait(a, 10)
                    return "Window not found (and no launch command is set): " a
                WinActivate(a)
                WfSleep(300)
                return ""
            }
            try Run(b)
            catch
                return "Couldn't launch: " b
            if !WfWinWait(a, 10)
                return "Launched, but the window never appeared: " a
            WinActivate(a)
            WfSleep(300)
        case "waitwin":
            timeout := 10
            if (b != "")
                try timeout := Number(b)
            if !WfWinWait(a, timeout)
                return "Window didn't appear within " timeout "s: " a
            WinActivate(a)
            WfSleep(300)
        case "wait":
            ms := 0
            try ms := Integer(a)
            catch
                return "Not a number of milliseconds: " a
            WfSleep(ms)             ; sliced, so a loop Stop cuts it short
        case "text":
            SendText(a)
            Sleep(150)          ; same beat the ask/click steps give the app
        case "keys":
            try Send(a)
            catch
                return "Bad key syntax (see AHK v2 Send docs): " a
            ; Recorded keystroke steps replay machine-fast: without a beat
            ; between them, {Down} after typed text races the app's own UI
            ; (an autocomplete list that hasn't populated yet). Bigger gaps
            ; the user actually took are recorded as Wait steps.
            Sleep(150)
        case "click", "dblclick", "rclick":
            ; a = window, b = element name (may be ""), c = "x,y" window-relative fallback
            if (!WinExist(a) && !WfWinWait(a, 10))   ; same grace as focus/waitwin
                return "Window not found: " a
            WinActivate(a)
            if (b = "")
                WfPosOnlySettle(a)    ; blind click — wait for the app to be ready
            else
                WfSleep(400)
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
        case "hover":
            ; a = window, b = element name (may be ""), c = "x,y" window-relative
            ; fallback. Move the pointer there and dwell so hover-triggered UI
            ; (submenus, tooltips) has time to appear; the next step acts on it.
            if (!WinExist(a) && !WfWinWait(a, 10))   ; same grace as click/focus
                return "Window not found: " a
            WinActivate(a)
            if (b = "")
                WfPosOnlySettle(a)    ; blind hover — same readiness wait as clicks
            else
                WfSleep(400)
            CoordMode("Mouse", "Screen")
            if (b != "") {
                loc := AccFindByName(WinExist(a), b)
                if IsObject(loc) {
                    MouseMove(loc.x + loc.w // 2, loc.y + loc.h // 2, 0)
                    WfSleep(700)                     ; dwell so the hover registers
                    return ""
                }
                if (c = "")
                    return "Couldn't find anything named `"" b "`" to hover over in that window."
            }
            if (c = "")
                return "Nothing to hover over — no element name and no recorded position."
            xy := StrSplit(c, ",")
            if (xy.Length != 2 || !IsInteger(Trim(xy[1])) || !IsInteger(Trim(xy[2])))
                return "Bad hover position: " c
            WinGetPos(&wx, &wy, , , a)
            MouseMove(wx + Trim(xy[1]), wy + Trim(xy[2]), 0)
            WfSleep(700)
        case "drag":
            ; a = window, c = "x1,y1,x2,y2" window-relative press/release points
            ; (paramB is reserved — a drag has no element name; it's inherently
            ; positional, like a position-only click, and gets the same care).
            if (!WinExist(a) && !WfWinWait(a, 10))   ; same grace as click/focus
                return "Window not found: " a
            WinActivate(a)
            WfPosOnlySettle(a)      ; drags always fire blind at recorded coords
            p := StrSplit(c, ",")
            if (p.Length != 4 || !IsInteger(Trim(p[1])) || !IsInteger(Trim(p[2]))
                || !IsInteger(Trim(p[3])) || !IsInteger(Trim(p[4])))
                return "Bad drag path (need x1,y1,x2,y2): " c
            WinGetPos(&wx, &wy, , , a)
            x1 := wx + Trim(p[1]), y1 := wy + Trim(p[2])
            x2 := wx + Trim(p[3]), y2 := wy + Trim(p[4])
            CoordMode("Mouse", "Screen")
            ; Press, travel in small increments, release. Apps only treat a
            ; gesture as a drag when they see intermediate move events past
            ; the system drag threshold — a single teleporting MouseMove
            ; (SendMode Input) would select nothing in many of them.
            MouseMove(x1, y1, 0)
            Sleep(100)              ; let the app see the hover before the press
            Click("Down")
            Sleep(100)              ; and register the press before movement
            segs := 16
            Loop segs {
                MouseMove(x1 + (x2 - x1) * A_Index // segs,
                          y1 + (y2 - y1) * A_Index // segs, 0)
                Sleep(10)
            }
            Sleep(100)              ; settle on the end point before releasing
            Click("Up")
            Sleep(150)              ; same beat the click steps give the app
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

; A position-only click/hover fires blind at recorded coordinates, so unlike
; a named step it can't retry while content renders (AccFindByName's 3 s
; budget does that for named clicks — position-only steps got only a 400 ms
; pause, which clicked into half-loaded windows). Wait for real readiness
; instead: the window must be active, its process must reach input-idle
; (a just-launched app whose window exists while it's still building its
; UI), and late-drawing content gets a longer settle pause. All waits are
; deterministic with fixed caps; content that loads later still needs an
; explicit Wait step before the click.
WfPosOnlySettle(win) {
    deadline := A_TickCount + 3000                   ; WinWaitActive, sliced for the abort hook
    while (!WinActive(win) && A_TickCount < deadline && !WfAborted())
        Sleep(100)
    try {
        pid := WinGetPID(win)
        ; SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION — enough for
        ; WaitForInputIdle on Vista+, and openable on more processes than
        ; full query rights. A failed open just skips straight to the pause.
        hProc := DllCall("OpenProcess", "uint", 0x101000, "int", 0, "uint", pid, "ptr")
        if hProc {
            deadline := A_TickCount + 5000           ; sliced too (258 = WAIT_TIMEOUT)
            loop {
                if (DllCall("user32\WaitForInputIdle", "ptr", hProc, "uint", 250) != 258)
                    break
                if (WfAborted() || A_TickCount >= deadline)
                    break
            }
            DllCall("CloseHandle", "ptr", hProc)
        }
    }
    WfSleep(1200)
}

; One-line description of a step (Studio list + error messages).
WfDesc(s) {
    t := s[1], a := s[2], b := s[3]
    c := (s.Length >= 4) ? s[4] : ""
    switch t {
        case "run":      return "Open  " a
        case "focus":    return "Focus  " a (b != "" ? "    (launches: " b ")" : "")
        case "waitwin":  return "Wait for window  " a "    (up to " (b != "" ? b : "10") "s)"
        case "wait":     return "Wait  " WfDurDesc(a)
        case "text":     return "Type  `"" a "`""
        case "ask":      return "Ask me for  `"" a "`""
            . (b != "" ? "    (suggested: " b ")" : "") "    — the answer is typed here"
        case "collect":  return "Collect  `"" a "`""
            . (b != "" ? "    (what's in the box named `"" b "`")" : "    (copies the selected text)")
        case "keys":     return "Press keys  " a
        case "click":    return "Click  " (b != "" ? "`"" b "`"" : "at (" c ")") "    in  " a
        case "dblclick": return "Double-click  " (b != "" ? "`"" b "`"" : "at (" c ")") "    in  " a
        case "rclick":   return "Right-click  " (b != "" ? "`"" b "`"" : "at (" c ")") "    in  " a
        case "hover":    return "Hover over  " (b != "" ? "`"" b "`"" : "at (" c ")") "    in  " a
        case "drag":     return "Drag  " WfDragDesc(c) "    in  " a
        case "move":     return "Position  " a "  ->  " b
        case "close":    return "Close  " a
        case "if":       return "If  " WfCondDesc(c, a, b)     ; a=window, b=element, c=condType
        case "else":     return "Otherwise:"
        case "endif":    return "End if"
    }
    return t "  " a "  " b
}

; Friendly form of a drag step's "x1,y1,x2,y2" path. Junk is shown raw —
; like WfDurDesc, this renders the error popup and must never throw.
WfDragDesc(c) {
    p := StrSplit(c, ",")
    if (p.Length != 4)
        return "(" c ")"
    return "from (" Trim(p[1]) "," Trim(p[2]) ") to (" Trim(p[3]) "," Trim(p[4]) ")"
}

; Friendly duration for a wait step's milliseconds: "2.6 s", "2 s", "800 ms".
; Integer math only (no float formatting surprises), and junk is shown raw —
; WfDesc must never throw, it renders the error popup for a failing step.
WfDurDesc(ms) {
    if (!IsInteger(ms) || ms < 1000)
        return ms " ms"
    whole := ms // 1000, tenth := Mod(ms // 100, 10)
    return whole (tenth ? "." tenth : "") " s"
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

; ============================================================
;  CSV + the workflow's sheet (<Base>.inputs.csv)
;  The sheet is the workflow's data file: ask labels are its
;  input columns, collect labels its output columns. The loop
;  reads batches from it; collect steps write results back.
; ============================================================

; Minimal RFC-4180 CSV parser: quoted fields may hold commas, doubled
; quotes and even newlines. Returns an array of records (arrays of strings).
WfCsvParse(text) {
    text := StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n")
    recs := []
    rec := []
    field := ""
    inQ := false
    len := StrLen(text)
    i := 1
    while (i <= len) {
        ch := SubStr(text, i, 1)
        if inQ {
            if (ch = '"') {
                if (SubStr(text, i + 1, 1) = '"') {   ; doubled quote -> literal quote
                    field .= '"'
                    i += 2
                    continue
                }
                inQ := false
                i += 1
                continue
            }
            field .= ch
            i += 1
            continue
        }
        switch ch {
            case '"':
                if (field = "")
                    inQ := true
                else
                    field .= ch                       ; stray quote mid-field: keep it
            case ",":
                rec.Push(field)
                field := ""
            case "`n":
                rec.Push(field)
                field := ""
                recs.Push(rec)
                rec := []
            default:
                field .= ch
        }
        i += 1
    }
    if (field != "" || rec.Length) {                  ; file didn't end with a newline
        rec.Push(field)
        recs.Push(rec)
    }
    return recs
}

; Quote a CSV field when it holds a comma, quote or newline (RFC-4180).
WfCsvField(s) {
    if !RegExMatch(s, '[,"`n`r]')
        return s
    return '"' StrReplace(s, '"', '""') '"'
}

; The workflow's sheet path, derived from its steps file.
WfSheetPath(stepsFile) {
    return RegExReplace(stepsFile, "i)\.steps\.txt$") ".inputs.csv"
}

; Ensure the sheet's header row (recs[1]) names every label; returns
; Map(label -> column index). Matching is case-insensitive on trimmed
; header cells, exactly like the loop's CSV reader; missing labels are
; appended as new columns (existing columns are never moved or renamed).
WfSheetEnsureCols(recs, labels) {
    hdr := recs[1]
    cols := Map()
    cols.CaseSense := false
    for j, h in hdr
        if (Trim(h) != "" && !cols.Has(Trim(h)))
            cols[Trim(h)] := j
    out := Map()
    out.CaseSense := false
    for l in labels {
        if !cols.Has(l) {
            hdr.Push(l)
            cols[l] := hdr.Length
        }
        out[l] := cols[l]
    }
    return out
}

; Set one cell, padding the record out to the column if it's short.
WfSheetSetCell(rec, idx, val) {
    while (rec.Length < idx)
        rec.Push("")
    rec[idx] := val
}

; Serialize records back to a CSV file — UTF-8 BOM + CRLF so Excel is happy.
WfSheetWrite(path, recs) {
    out := ""
    for rec in recs {
        line := ""
        for j, v in rec
            line .= (j > 1 ? "," : "") WfCsvField(v)
        out .= line "`r`n"
    }
    f := FileOpen(path, "w", "UTF-8")
    f.Write(out)
    f.Close()
}

; Write collected results into the workflow's sheet. Each result is
; {src, ins, out}: src > 1 fills the collect columns of that record index
; (a loop pass fed by the sheet's own row — 1 is the header), src = 0
; appends a new row holding the inputs used plus the values collected.
; Creates the sheet if needed; input columns come before collect columns;
; extra columns and existing cells are preserved. Returns {name, err} —
; name is the file the results actually landed in: if the sheet can't be
; read or written (open in Excel, which locks CSVs), the results are
; appended to <Base>.results.csv beside it so nothing is lost. Never
; overwrites a file it couldn't read.
WfSheetApplyResults(sheetPath, askLabels, colLabels, results) {
    readOk := true
    recs := []
    if FileExist(sheetPath) {
        try recs := WfCsvParse(FileRead(sheetPath, "UTF-8"))
        catch
            readOk := false
    }
    if readOk {
        if !recs.Length
            recs.Push([])                              ; header row, filled in below
        inCols := WfSheetEnsureCols(recs, askLabels)
        outCols := WfSheetEnsureCols(recs, colLabels)
        for r in results {
            if (r.src > 1 && r.src <= recs.Length) {
                for l, ci in outCols
                    WfSheetSetCell(recs[r.src], ci, r.out.Get(l, ""))
            } else {
                rec := []
                for l, ci in inCols
                    WfSheetSetCell(rec, ci, r.ins.Get(l, ""))
                for l, ci in outCols
                    WfSheetSetCell(rec, ci, r.out.Get(l, ""))
                recs.Push(rec)
            }
        }
        try {
            WfSheetWrite(sheetPath, recs)
            SplitPath(sheetPath, &name)
            return {name: name, err: "", path: sheetPath}
        }
    }
    ; Sheet unreadable or unwritable — append the results to a side file.
    alt := RegExReplace(sheetPath, "i)\.inputs\.csv$") ".results.csv"
    try {
        altRecs := FileExist(alt) ? WfCsvParse(FileRead(alt, "UTF-8")) : []
        if !altRecs.Length {
            hdr := []
            for l in askLabels
                hdr.Push(l)
            for l in colLabels
                hdr.Push(l)
            altRecs.Push(hdr)
        }
        inCols := WfSheetEnsureCols(altRecs, askLabels)
        outCols := WfSheetEnsureCols(altRecs, colLabels)
        for r in results {
            rec := []
            for l, ci in inCols
                WfSheetSetCell(rec, ci, r.ins.Get(l, ""))
            for l, ci in outCols
                WfSheetSetCell(rec, ci, r.out.Get(l, ""))
            altRecs.Push(rec)
        }
        WfSheetWrite(alt, altRecs)
        SplitPath(alt, &name)
        return {name: name, err: "", path: alt}
    } catch {
        return {name: "", err: "Couldn't save the collected values — the sheet and its results file "
            . "are both locked (close them in Excel and run again).", path: ""}
    }
}
