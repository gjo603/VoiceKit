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
;
;  Named values: every `ask` label, `collect` label and `set`
;  name can be reused anywhere later in the run by writing
;  {{Name}} — in typed text, key sequences, window criteria and
;  element names. `set|<name>|<value>|` names one outright and
;  may itself contain {{Name}} (so values compose, and
;  {{clipboard}} / {{date}} / {{time}} / {{datetime}} are there
;  as fallbacks). An unknown name is left literal, so workflows
;  written before any of this behave exactly as they always did.
;
;  {{selected_file}} / {{selected_files}} are the file(s) selected
;  in File Explorer when the run STARTED (one snapshot, taken
;  before any dialog or step can move focus — see wfSelection).
;  The singular is one path and the run refuses to start unless
;  exactly one item is selected; the plural is every path in double
;  quotes, space-joined. In a COMMAND LINE (a capture step's command,
;  a run step's target) both always arrive correctly quoted, with or
;  without quotes written around them — see WfSubst. A workflow
;  launched with arguments (run_automation(args=...), a file dropped
;  on its shortcut) uses those instead of Explorer.
;
;  The `capture` step runs a command hidden and keeps what it
;  printed as a named value:
;      capture|<name>|<command line>|<timeout seconds, blank = 30>
;  stdout becomes {{name}}; stderr is kept apart (a warning can't
;  pollute the value) and a nonzero exit code stops the run. It is
;  the first step that EXECUTES something, so a shared workflow
;  deserves the trust you'd give a script — see WfCapture.
;
;  The `fill` step puts a value into an input box found by its
;  label, then reads it back:
;      fill|<window>|<label>[#N]|<value>
;  It clicks the box for real, refuses to type unless the keyboard
;  focus actually landed there, and fails if the box doesn't hold
;  the value afterwards — a failure reason never contains the value
;  (it may be client data). "Amount#2" is the 2nd input labelled
;  Amount; "##" is a literal "#". See WfFill.
;
;  The `waitfor` step waits for something to HAPPEN rather than
;  for a guessed number of milliseconds:
;      waitfor|<window>|<element or text>|<condType>[,<seconds>]
;  It shares its condition vocabulary with `if` (WfEvalCond), so
;  anything testable is waitable, and it fails with a message
;  naming what never happened instead of pressing on regardless.
;
;  Finding things on screen: Acc (MSAA) FIRST, then UIA. Current
;  Chrome publishes no web page content over MSAA at all — only
;  its own toolbars and tabs — so anything that clicked or read
;  inside a page found nothing, saved workflows included. Both
;  trees are now searched, interleaved (see WfFindElement), which
;  leaves desktop apps behaving exactly as they did and stops
;  browsers being invisible. No steps file changes.
;
;  A `wait` step may be a RANGE — wait|600-1400 pauses a random
;  600-1400 ms — and element clicks land a few pixels off centre.
;  Both exist because a workflow looping against a website with
;  metronome timing and pixel-identical clicks is the easiest
;  pattern in the world to flag as a robot. Jitter is clamped
;  inside the element, so it can never miss; recorded coordinate
;  clicks stay exact (see WfClickJitter).
; ============================================================
#Include "%A_LineFile%\..\Acc.ahk"
#Include "%A_LineFile%\..\UIA.ahk"
#Include "%A_LineFile%\..\Clip.ahk"
#Include "%A_LineFile%\..\ExplorerSel.ahk"

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

; ============================================================
;  Run log and run record — evidence that a run happened.
;
;  A run used to leave nothing behind but a modal popup: a batch
;  that died at step 7 looked exactly like one that worked, and
;  the reason string built for the popup was thrown away. Two
;  artifacts now, both under logs\ (user data, gitignored):
;
;    workflow-runs.log   one line per step, rolling, human-read
;    workflow-runs.ini   the LAST run of each workflow, machine-
;                        readable — the MCP add-on reports from it
;
;  Both are best-effort and fully wrapped: a logging failure must
;  never be the thing that stops an automation. The record is
;  written BEFORE the failure popup, so a caller that gave up
;  waiting can still find out what happened while the dialog is
;  still sitting there.
;
;  Steps are logged AS WRITTEN, not with {{Name}} values filled
;  in — the placeholder is the diagnostic part, and an ask answer
;  (which may be a password) has no business on disk.
; ============================================================
global wfRunName := ""          ; what to call the current run — the workflow's file base
global wfRunQuiet := false      ; headless caller: record failures, don't pop a modal
global wfRun := Map()           ; the current run's record (written to the ini)
global wfTrayOff := false       ; self-tests: swallow tray notifications (see WfTray)
global wfTrayLast := ""         ; the last notification's text, shown or not

; Every engine/loop tray notification goes through here. Self-tests set
; wfTrayOff: Windows keeps a toast on screen for as long as the user is idle
; and hands it the FOREGROUND when a window closes, after which no background
; process can activate anything — one test's toast failed the next suite's
; every activation (measured on an unattended run). Hiding the tray icon does
; NOT pull a toast on Windows 11 (measured too), so the only fix is not to
; raise one. wfTrayLast keeps the text either way, so a test can still check
; what would have been said.
WfTray(text, title, icon := "") {
    global wfTrayOff, wfTrayLast
    wfTrayLast := text
    if !wfTrayOff
        TrayTip(text, title, icon)
}

; Where the two artifacts live. Self-tests point wfLogFolder at a temp folder
; so running the suite never writes into the user's real run history. (Named
; wfLogFolder, not wfLogDir: functions and variables share one case-insensitive
; namespace, so a `wfLogDir` variable would collide with `WfLogDir()`.)
global wfLogFolder := ""

WfLogDir() {
    global wfLogFolder
    return wfLogFolder != "" ? wfLogFolder : A_LineFile "\..\..\logs"
}
WfLogFile()    => WfLogDir() "\workflow-runs.log"
WfRecordFile() => WfLogDir() "\workflow-runs.ini"
WfLogCap()     => 1048576       ; 1 MB, then the oldest half goes

; Collapse anything to one line — a log line and an ini value are both
; single-line formats, and a step description or error may not be.
WfOneLine(s, maxLen := 300) {
    s := Trim(RegExReplace(s, "\s+", " "))
    return StrLen(s) > maxLen ? SubStr(s, 1, maxLen) "..." : s
}

; Append one timestamped line to the rolling log. Never throws.
WfLog(text) {
    global wfRunName
    try {
        path := WfLogFile()
        SplitPath(path, , &dir)
        if !DirExist(dir)
            DirCreate(dir)
        if (FileExist(path) && FileGetSize(path) > WfLogCap())
            WfLogTrim(path)
        FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  "
            . (wfRunName != "" ? wfRunName : "(unnamed)") "  " text "`n", path, "UTF-8")
    }
}

; Drop the oldest half when the log passes its cap, cutting at a line
; boundary so the file never starts mid-sentence. Written to a temp file
; and moved over the log (like _Common.ahk FileReplaceText — the engine keeps
; its own copy, it includes no _Common), so a kill mid-trim can't empty it;
; a refused move leaves the log as it was.
WfLogTrim(path) {
    tmp := path ".tmp-" DllCall("GetCurrentProcessId", "uint")
    try {
        txt := FileRead(path, "UTF-8")
        cut := InStr(txt, "`n", , StrLen(txt) // 2)
        try FileDelete(tmp)
        FileAppend(cut ? SubStr(txt, cut + 1) : "", tmp, "UTF-8")
        FileMove(tmp, path, 1)
        return
    }
    try FileDelete(tmp)
}

; The workflow's file base ("MorningTabs"), which names it in both artifacts.
WfRunNameFromFile(stepsFile) {
    SplitPath(stepsFile, &fname)
    return RegExReplace(fname, "i)\.steps\.txt$")
}

; Start a fresh record. Called at the top of every run (so every pass of a
; loop gets its own — the loop adds the pass counts at the end).
WfRunBegin(n) {
    global wfRun
    wfRun := Map("started", A_Now, "started_text", FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
        , "steps_total", n, "outcome", "running", "failed_step", 0, "step", "", "reason", "")
    WfLog("---- run started: " n " step" (n = 1 ? "" : "s"))
}

; Stamp, log and persist the finished run. Returns true only for "ok", so
; callers can `return WfRunFinish(...)`.
WfRunFinish(outcome) {
    global wfRun
    if !wfRun.Count
        WfRunBegin(0)
    wfRun["outcome"] := outcome
    wfRun["ended"] := A_Now
    WfLog("---- run " outcome (wfRun["reason"] != "" ? ": " wfRun["reason"] : ""))
    WfRunRecordWrite()
    return outcome = "ok"
}

; The outcome of the current/last run ("" when nothing has run yet).
WfRunOutcome() {
    global wfRun
    return (wfRun.Count && wfRun.Has("outcome")) ? wfRun["outcome"] : ""
}

; Add fields to the record after the fact — the loop's pass counts, which
; only it knows. Re-persists, so the file always holds the whole story.
WfRunRecordUpdate(fields) {
    global wfRun
    if !wfRun.Count
        WfRunBegin(0)
    for k, v in fields
        wfRun[k] := v
    WfRunRecordWrite()
}

; Persist the record under a section named for the workflow. NOTE IniWrite
; creates the file as UTF-16LE with a BOM — anything reading it outside AHK
; must sniff that (the Python side already does, for master-status.ini).
;
; The WHOLE section is written in one call (IniWrite's section form replaces
; it wholesale). It used to be one IniWrite per key, which never removed
; anything: a loop's passes_done / loop_started outlived it, and a later
; plain run of the same workflow was reported with the old loop's start time
; and pass counts. wfRun always holds the complete record (WfRunBegin
; replaces it, WfRunRecordUpdate merges into it), so replacing is safe — and
; a reader now sees one consistent snapshot instead of a half-written mix.
WfRunRecordWrite() {
    global wfRun, wfRunName
    try {
        path := WfRecordFile()
        SplitPath(path, , &dir)
        if !DirExist(dir)
            DirCreate(dir)
        sect := wfRunName != "" ? wfRunName : "Unnamed"
        pairs := ""
        for k, v in wfRun
            pairs .= (pairs = "" ? "" : "`n") k "=" WfOneLine(v)
        IniWrite(pairs, path, sect)
    }
}

; One place a step failure is recorded, logged and reported — every failing
; step in the engine funnels through here. Returns false, so a caller can
; `return WfRunFail(...)`.
;
; In quiet mode (a headless batch) the modal popup becomes a TrayTip: nobody
; may be at the machine, and a modal dialog holds the process open, which is
; exactly why every batch used to exit 0 and report "finished cleanly".
;
; detail: extra text for the LOCAL popup only (a capture step's stderr tail) —
; never recorded, logged or shown in the quiet-mode tray note, because the
; record travels (MCP responses) and detail may carry client data.
;
; The RECORD and the LOG get the reason with every filled-in value put back
; as written (WfUnsubst): "Window not found: {{Client}} - Excel", never the
; client's name — the record travels (run_automation / read_log -> MCP -> a
; cloud model). The local popup and tray note still show what was tried.
WfRunFail(i, n, s, sr, reason, detail := "") {
    global wfRun, wfRunQuiet
    recReason := WfUnsubst(reason, s, sr)
    wfRun["failed_step"] := i
    wfRun["steps_total"] := n
    wfRun["step"] := WfOneLine(WfDesc(s))
    wfRun["reason"] := WfOneLine(recReason)
    WfLog("FAILED at step " i "/" n ": " WfOneLine(recReason))
    WfRunFinish("failed")            ; record first — the popup below blocks
    if wfRunQuiet
        WfTray("Stopped at step " i " of " n ".`n" WfOneLine(reason, 120), "VoiceKit workflow", "Icon!")
    else
        MsgBox("Workflow stopped at step " i " of " n ".`n`n"
            . WfStepDesc(s, sr) "`n`n" reason (detail != "" ? "`n`n" detail : ""),
            "VoiceKit workflow", "Icon! 262144")   ; 262144 = always-on-top
    return false
}

; Record a run that never got as far as its steps (missing file, no steps,
; a cancelled chooser) — "it never ran" and "it ran and failed" must not
; look the same to whoever reads the record later.
WfRunRecordSimple(name, outcome, reason := "") {
    global wfRunName
    wfRunName := name
    WfRunBegin(0)
    WfRunRecordUpdate(Map("reason", WfOneLine(reason)))
    return WfRunFinish(outcome)
}

; The generated macros\<Base>.ahk stub Workflow Studio writes on save: a
; header carrying the "Generated by Workflow Studio" marker (the overwrite
; and delete guards look for it — see IsWorkflowStub) and one RunWorkflow
; call. date ("yyyy-MM-dd", default today) is pinned only by the generator
; parity check. mcp\voicekit_writer.workflow_stub mirrors this byte for
; byte (test_generators_match_ahk runs both).
WfStubContent(phrase, base, date := "") {
    if (date = "")
        date := FormatTime(A_Now, "yyyy-MM-dd")
    return "#Requires AutoHotkey v2.0`n"
        . "#SingleInstance Force`n"
        . "; ============================================================`n"
        . ";  " phrase "   (workflow, saved " date ")`n"
        . ';  Trigger by voice:  "open ' phrase '"`n'
        . ";`n"
        . ";  Generated by Workflow Studio — don't edit steps here.`n"
        . ';  Edit by voice:  "open workflow studio"  ->  pick "' phrase '"`n'
        . ";  Steps live in:  workflows\" base ".steps.txt`n"
        . "; ============================================================`n"
        . '#Include "%A_ScriptDir%\..\lib\_Common.ahk"`n'
        . '#Include "%A_ScriptDir%\..\lib\Workflow.ahk"`n'
        . 'RunWorkflow(A_ScriptDir "\..\workflows\' base '.steps.txt")`n'
}

; Run a saved workflow file. Returns true if every step ran.
;
; Arguments on the command line (the stub's A_Args — run_automation(args=...)
; or files dropped on the workflow's shortcut) ARE the selection: they stand
; in for File Explorer, so a selected-file workflow can be tried on a fixture
; file without touching anyone's Explorer windows. Only this entry point
; reads them — LoopRunner's arguments mean something else. The generated stub
; text is unchanged (A_Args is a built-in, readable from in here).
RunWorkflow(stepsFile) {
    global wfRunName, wfSelection
    wfRunName := WfRunNameFromFile(stepsFile)
    if !FileExist(stepsFile) {
        WfRunRecordSimple(wfRunName, "error", "Workflow file not found: " stepsFile)
        MsgBox("Workflow file not found:`n" stepsFile, "VoiceKit workflow", "Iconx 262144")   ; 262144 = always-on-top
        return false
    }
    steps := WorkflowLoad(stepsFile)
    if A_Args.Length {
        wfSelection := []
        for a in A_Args
            wfSelection.Push(WfFullPath(a))
    }
    ; The selection is read BEFORE the ask dialogs below: a dialog (or the
    ; user alt-tabbing to answer it) must not change which file is acted on,
    ; and a run that can't have its file should say so before asking anything.
    if (serr := WfSelectionPrecheck(steps)) {
        WfRunRecordSimple(wfRunName, "error", serr)
        WfSelectionReport(serr)
        return false
    }
    ; Gather inputs HERE rather than inside RunWorkflowSteps, so a run that
    ; also collects values can save the inputs it used beside the results.
    askVals := ""
    askLabels := WfAskLabels(steps)
    if askLabels.Length {
        askVals := WfGatherInputs(steps)
        if !IsObject(askVals) {
            ; Quiet (no popup), but never unrecorded: a caller waiting on the
            ; run record would otherwise be told "nothing recorded yet" forever.
            WfRunRecordSimple(wfRunName, "cancelled", "Cancelled at an ask-for-input dialog.")
            return false
        }
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
        WfTray(r.err = ""
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
; varsOut: pass a Map to watch the run's named values fill in. It IS the
; working namespace, so it stays populated even when a step fails — which is
; exactly when you want to see what {{Name}} actually resolved to.
RunWorkflowSteps(steps, askVals := "", collected := "", varsOut := "") {
    ; Collect every `ask` input before anything runs, so the user answers
    ; up front and the rest of the run is hands-free. A caller (the loop
    ; runner feeding CSV rows) may pass a ready Map(label -> answer)
    ; instead, which skips the dialogs entirely. `collected` is the mirror:
    ; pass a Map and every `collect` step deposits its value there under
    ; its label — callers decide what to do with them (sheet, display).
    WfRunBegin(steps.Length)
    ; {{selected_file(s)}}: snapshot the Explorer selection (unless the host
    ; already did — RunWorkflow, a loop) BEFORE any dialog, and refuse to
    ; start when the singular form has 0 or several files to choose from.
    if (serr := WfSelectionPrecheck(steps)) {
        WfRunRecordUpdate(Map("reason", WfOneLine(serr)))
        WfRunFinish("error")            ; no step ran — "it never got as far as running"
        WfSelectionReport(serr)
        return false
    }
    if !IsObject(askVals) {
        askVals := WfGatherInputs(steps)
        if !IsObject(askVals) {
            WfRunFinish("cancelled")
            return false                ; cancelling is deliberate — no error popup
        }
    }
    ; One namespace of named values for the run, seeded with every ask answer
    ; so {{Label}} works from step 1 — including batches, whose rows arrive as
    ; this same Map. `collect` and `set` add to it as the run goes.
    vars := IsObject(varsOut) ? varsOut : Map()
    if !vars.Count                      ; CaseSense can only be set on an EMPTY Map —
        vars.CaseSense := false         ; a caller's pre-seeded one keeps its own setting
    for k, v in askVals
        vars[k] := v

    i := 1, n := steps.Length
    while (i <= n) {
        if WfAborted() {                ; host asked the run to stop — quiet, like cancel
            WfRunFinish("stopped")
            return false
        }
        s := steps[i]
        sr := WfSubstStep(s, vars)      ; {{Name}} resolved for this step only
        t := sr[1]
        WfLog("step " i "/" n "  " WfOneLine(WfDesc(s)))
        if (t = "ask") {                ; type the answer collected up front
            SendText(askVals.Get(WfAskLabel(sr), ""))
            Sleep(150)
            i += 1
            continue
        }
        if (t = "set") {                ; name a value for later steps to reuse
            nm := Trim(sr[2])
            if (nm != "")
                vars[nm] := sr[3]
            i += 1
            continue
        }
        if (t = "collect") {            ; grab a value here and remember it by label
            cerr := ""
            val := ""
            if (Trim(sr[3]) != "") {    ; read the named box's content (in the active window)
                hwndA := WinExist("A")
                r := hwndA ? WfFieldValue(hwndA, sr[3]) : {found: false, value: ""}   ; MSAA first, then UIA
                if !r.found
                    cerr := "Couldn't find a box named `"" Trim(sr[3]) "`" in the active window."
                else
                    val := r.value
            } else {
                val := WfCopySelection(&cerr)
            }
            if (cerr != "") {
                if WfAborted() {
                    WfRunFinish("stopped")
                    return false
                }
                return WfRunFail(i, n, s, sr, cerr)
            }
            if IsObject(collected)
                collected[WfCollectLabel(sr)] := val
            vars[WfCollectLabel(sr)] := val     ; usable as {{Label}} from here on
            Sleep(150)
            i += 1
            continue
        }
        if (t = "capture") {            ; run a command; what it printed becomes {{Name}}
            r := WfCapture(sr[3], WfCaptureSecs(sr[4]))
            if !r.ok {
                if (r.aborted || WfAborted()) {     ; Stop killed it — quiet, like any stop
                    WfRunFinish("stopped")
                    return false
                }
                ; The record/log/MCP get only r.reason ("exited with code N"):
                ; a traceback routinely names the client file it choked on.
                ; The stderr tail is for the person at THIS machine — the popup.
                return WfRunFail(i, n, s, sr, r.reason, r.errTail != ""
                    ? "What it printed as errors (last lines):`n" r.errTail : "")
            }
            nm := Trim(sr[2])
            if (nm != "")
                vars[nm] := r.value     ; run-local like set — never a sheet column
            i += 1
            continue
        }
        if (t = "fill") {               ; put a value in a box by its label, read it back
            ; The as-written window and label name the box in the reason (like
            ; `run` below): the reason travels (record -> MCP), and a filled-in
            ; field may carry client data. The VALUE is never in it at all.
            r := WfFill(sr[2], sr[3], sr[4], s[2], s[3])
            for note in r.notes
                WfLog("       note: " WfOneLine(note))
            if (r.err != "") {
                if WfAborted() {
                    WfRunFinish("stopped")
                    return false
                }
                return WfRunFail(i, n, s, sr, r.err, r.detail)
            }
            i += 1
            continue
        }
        if (t = "if") {
            res := WfEvalCond(sr)
            if (res.err != "")
                return WfRunFail(i, n, s, sr, res.err)
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
            err := WfRunStep(sr)
        catch as e
            err := "Unexpected error: " e.Message
        if (err != "") {
            if WfAborted() {            ; the Stop cut this step's wait short — not a real failure
                WfRunFinish("stopped")
                return false
            }
            ; A run target filled in from {{selected_file}} (or any value) names
            ; a client's file, and the reason travels (record -> MCP). Record
            ; the target AS WRITTEN; the popup's step line still shows what
            ; was actually tried.
            if (t = "run" && s[2] != sr[2])
                err := "Couldn't open: " s[2]
            return WfRunFail(i, n, s, sr, err)
        }
        i += 1
    }
    ; A stop during the LAST step must still report "didn't finish".
    return WfRunFinish(WfAborted() ? "stopped" : "ok")
}

; ============================================================
;  Named values — {{Name}}
;
;  Every `ask` label, `collect` label and `set` name is a value
;  the rest of the run can reuse by writing {{Name}} in a step.
;  Before this, an ask answer was typed at exactly one position
;  and the clipboard was the only way to carry it anywhere else.
;
;  Resolution happens per step, just before it runs (see
;  WfSubstStep), so a {{Name}} filled in by a `collect` earlier
;  in the run is available to every step after it.
; ============================================================

; The names resolved when nothing user-defined claims them. Deliberately a
; FALLBACK, not reserved: an ask labelled "Date" still wins, so no label is
; off-limits.
;
; selected_file / selected_files only READ the run's snapshot (wfSelection)
; — never Explorer itself — so the authoring-time check (WfUndefinedVars)
; stays free of COM, and every step of a run sees the same files.
WfBuiltinVar(name, &found) {
    global wfSelection
    found := true
    switch StrLower(name) {
        case "clipboard": return A_Clipboard
        case "date":      return FormatTime(A_Now, "yyyy-MM-dd")
        case "time":      return FormatTime(A_Now, "HH:mm")
        case "datetime":  return FormatTime(A_Now, "yyyy-MM-dd HH:mm")
        case "selected_file":
            return (IsObject(wfSelection) && wfSelection.Length = 1) ? wfSelection[1] : ""
        case "selected_files":
            out := ""
            if IsObject(wfSelection)
                for p in wfSelection                ; a Windows path can't contain `"`,
                    out .= (out = "" ? "" : " ") '"' p '"'   ; so the quoting is exact
            return out
    }
    found := false
    return ""
}

; ============================================================
;  The Explorer selection — {{selected_file}} / {{selected_files}}
;
;  wfSelection is "" until a run takes its snapshot, then an
;  Array of full paths. It is taken ONCE per run, at the start,
;  before the ask dialogs and before any step can raise another
;  Explorer window (a `run|C:\folder` step would change which
;  window is topmost). Hosts own its lifetime: a workflow stub is
;  one short process; a loop takes it once for all its passes;
;  Studio Test clears it before each test. Nothing touches
;  Explorer unless a step actually uses one of the two names.
; ============================================================
global wfSelection := ""

; Which of the two names the workflow uses, not counting a user value of the
; same name (which wins, like every built-in): 0 neither, 1 only the plural,
; 2 the singular (with or without the plural).
WfSelectionNeeds(steps) {
    defined := Map()
    defined.CaseSense := false
    for nm in WfVarNames(steps)
        defined[nm] := true
    need := 0
    for s in steps {
        txt := WfStepSubstText(s), pos := 1
        while (at := RegExMatch(txt, "\{\{\s*([^{}]+?)\s*\}\}", &m, pos)) {
            nm := StrLower(m[1])
            if !defined.Has(nm) {
                if (nm = "selected_file")
                    need := 2
                else if (nm = "selected_files" && need < 1)
                    need := 1
            }
            pos := at + StrLen(m[0])
        }
    }
    return need
}

; "" when the run may start; otherwise the reason it can't. Takes the
; snapshot if the host hasn't. Never guesses: the singular with 0 or several
; files selected is an error, not "the first one".
WfSelectionPrecheck(steps) {
    global wfSelection
    need := WfSelectionNeeds(steps)
    if !need
        return ""
    if !IsObject(wfSelection)
        wfSelection := ExplorerSelectedFiles()
    n := wfSelection.Length
    if (need = 2 && n != 1)
        return "Select exactly one file in File Explorer first — found " n ". "
            . "This workflow uses {{selected_file}}: the one file selected in the "
            . "front-most File Explorer window when it starts."
    if (n = 0)
        return "Select the files in File Explorer first — found 0. "
            . "This workflow uses {{selected_files}}: the files selected in the "
            . "front-most File Explorer window when it starts."
    return ""
}

; Tell the user a run couldn't start for want of a selection: a popup, or a
; tray note in quiet mode (a headless caller reads the run record instead).
WfSelectionReport(reason) {
    global wfRunQuiet
    if wfRunQuiet
        WfTray(WfOneLine(reason, 200), "VoiceKit workflow", "Icon!")
    else
        MsgBox(reason, "VoiceKit workflow", "Icon! 262144")   ; 262144 = always-on-top
}

; An argument as a full path (a relative one is taken against the working
; directory, as the launching shell meant it). Never throws.
WfFullPath(p) {
    try {
        n := DllCall("GetFullPathNameW", "str", p, "uint", 0, "ptr", 0, "ptr", 0, "uint")
        if n {
            buf := Buffer(n * 2)
            if DllCall("GetFullPathNameW", "str", p, "uint", n, "ptr", buf, "ptr", 0, "uint")
                return StrGet(buf)
        }
    }
    return p
}

; ============================================================
;  The capture step — capture|<name>|<command line>|<seconds>
;
;  Runs a command hidden and keeps what it printed (stdout) as a
;  run-local value, like `set`. What it takes to make that honest:
;
;  - It is a real cmd.exe command line (quotes, &, |, %VAR% all
;    mean what they mean in cmd). The command reaches a NESTED
;    cmd through an environment variable (!VK_CAPTURE_CMD!,
;    delayed expansion), so the outer cmd that owns the redirects
;    never parses it: nothing in the command can escape the
;    redirects, and the nested cmd starts AFTER `chcp 65001` —
;    a cmd reads its code page once at startup, so a chcp in the
;    same instance leaves its own echo output in the OEM code page
;    (measured: "café" came back as caf\x82). PYTHONIOENCODING
;    covers Python, which ignores the console code page when
;    redirected. Output is decoded as UTF-8, falling back to the
;    ANSI code page (CP0) when it isn't valid UTF-8.
;  - stdin is NUL: the console is hidden, so nobody could answer a
;    prompt (`set /p`, Python's input(), `pause`) — without this a
;    command that asks for input sat there until its timeout
;    (measured); with it the prompt reads end-of-input at once.
;  - stdout and stderr go to SEPARATE temp files (a warning on
;    stderr can't end up inside the value — the Split Pages bug),
;    unique per process/tick/call, deleted in `finally` because
;    they may hold client data.
;  - Working directory = the VoiceKit root, whatever launched the
;    run (a stub runs in macros\, a loop in the root), so a
;    relative path means one thing everywhere.
;  - A timer watches the clock and the abort hook; either one
;    kills the WHOLE process tree (taskkill /T /F — killing cmd
;    alone would orphan the python under it).
;  - The reason a failure records is only "exited with code N" /
;    "still running after Ns": no stderr, no resolved command.
;    The record travels (workflow-runs.ini -> the MCP), and a
;    traceback or a filled-in command names the client's file.
;    The stderr tail comes back separately for the local popup.
; ============================================================

; A capture step's timeout: a positive number of seconds, else 30.
WfCaptureSecs(c) {
    c := Trim(c)
    return (c != "" && IsNumber(c) && Number(c) > 0) ? Number(c) : 30
}

WfCaptureCap() => 1048576       ; 1 MB of output is the most a value may hold

; The VoiceKit root (the folder holding lib\), as a full path.
WfRootDir() => WfFullPath(A_LineFile "\..\..")

; Run `command` and return {ok, value, reason, errTail, aborted, code}.
; ok = exit code 0 (an empty value is legitimate). Never throws.
WfCapture(command, secs := 30) {
    static seq := 0
    r := {ok: false, value: "", reason: "", errTail: "", aborted: false, code: ""}
    if (Trim(command) = "") {
        r.reason := "There is no command to run."
        return r
    }
    ; cmd.exe's command-line limit is 8191; the nested cmd adds a few.
    if (StrLen(command) > 8000) {
        r.reason := "The command is too long for Windows (" StrLen(command) " characters; "
            . "about 8,000 is the limit). With {{selected_files}}, select fewer files."
        return r
    }
    seq += 1
    base := A_Temp "\vk-capture-" DllCall("GetCurrentProcessId", "uint") "-" A_TickCount "-" seq
    outF := base ".out", errF := base ".err"
    env := ["VK_CAPTURE_CMD", "VK_CAPTURE_OUT", "VK_CAPTURE_ERR", "PYTHONIOENCODING"]
    saved := Map()
    for k in env
        saved[k] := EnvGet(k)
    pid := 0, why := "", deadline := A_TickCount + Round(secs * 1000)

    ; Runs on a timer WHILE RunWait waits (RunWait's pid is filled in as the
    ; process starts, so a timer can see it — measured).
    Watch() {
        if (why != "" || !pid)
            return
        if WfAborted()
            why := "abort"
        else if (A_TickCount >= deadline)
            why := "timeout"
        else
            return
        WfKillTree(pid)
    }

    try {
        EnvSet("VK_CAPTURE_CMD", command)
        EnvSet("VK_CAPTURE_OUT", outF)
        EnvSet("VK_CAPTURE_ERR", errF)
        EnvSet("PYTHONIOENCODING", "utf-8")
        cs := '"' A_ComSpec '"'
        line := cs ' /d /v:on /s /c "chcp 65001 >nul & ' cs ' /d /s /c "!VK_CAPTURE_CMD!"'
            . ' 0<nul 1>"!VK_CAPTURE_OUT!" 2>"!VK_CAPTURE_ERR!""'
        SetTimer(Watch, 100)
        try
            code := RunWait(line, WfRootDir(), "Hide", &pid)
        catch {
            r.reason := "Couldn't start the command."      ; no detail: it would name the command
            return r
        }
        SetTimer(Watch, 0)
        if (why = "abort") {
            r.aborted := true
            r.reason := "Stopped while the command was running."
            return r
        }
        if (why = "timeout") {
            r.reason := "The command was still running after " secs "s and was stopped."
            r.errTail := WfCaptureTail(errF)
            return r
        }
        r.code := code
        if (code != 0) {
            r.reason := "Command exited with code " code "."
            r.errTail := WfCaptureTail(errF)
            return r
        }
        size := FileExist(outF) ? FileGetSize(outF) : 0
        if (size > WfCaptureCap()) {
            r.reason := "The command printed more than 1 MB — too much to keep as a value."
            return r
        }
        txt := ""
        if (size > 0) {
            buf := FileRead(outF, "RAW")
            txt := WfDecodeBytes(buf.Ptr, buf.Size)
        }
        r.value := RTrim(StrReplace(txt, "`r`n", "`n"), " `t`r`n")
        r.ok := true
        return r
    } catch as e {
        r.reason := "The command's output couldn't be read."
        return r
    } finally {
        SetTimer(Watch, 0)
        for k, v in saved
            (v = "") ? EnvSet(k) : EnvSet(k, v)       ; EnvSet(k) alone removes it
        WfDeleteSoon(outF)
        WfDeleteSoon(errF)
    }
}

; Delete a file, retrying briefly: a process taskkill just ended can hold its
; redirect handles for a moment after it is reported gone (measured: the
; abort path left both temp files behind on a plain FileDelete).
WfDeleteSoon(path) {
    loop 20 {
        try FileDelete(path)
        if !FileExist(path)
            return
        Sleep(50)
    }
}

; Kill a process and everything it started. Waits, so the tree is gone when
; this returns.
WfKillTree(pid) {
    try RunWait('"' A_WinDir '\System32\taskkill.exe" /T /F /PID ' pid, , "Hide")
}

; Bytes -> text: UTF-8 (BOM skipped) when the bytes are valid UTF-8, else the
; ANSI code page — a console program that ignores chcp still reads sensibly.
WfDecodeBytes(ptr, n) {
    if (n >= 3 && NumGet(ptr, 0, "UChar") = 0xEF && NumGet(ptr, 1, "UChar") = 0xBB
        && NumGet(ptr, 2, "UChar") = 0xBF)
        ptr += 3, n -= 3
    if (n <= 0)
        return ""
    ; MB_ERR_INVALID_CHARS (8): 0 = not valid UTF-8
    if DllCall("MultiByteToWideChar", "uint", 65001, "uint", 8, "ptr", ptr, "int", n, "ptr", 0, "int", 0)
        return StrGet(ptr, n, "UTF-8")
    return StrGet(ptr, n, "CP0")
}

; The last few lines a command wrote to stderr (read from the file's end, so a
; chatty command can't make this slow). "" when there were none.
WfCaptureTail(path, maxLines := 10) {
    try {
        f := FileOpen(path, "r")
        size := f.Length
        if !size {
            f.Close()
            return ""
        }
        take := Min(size, 65536)
        buf := Buffer(take)
        f.Pos := size - take
        f.RawRead(buf, take)
        f.Close()
        off := 0                    ; a mid-file cut may land inside a UTF-8 sequence
        if (take < size)
            while (off < take && (NumGet(buf, off, "UChar") & 0xC0) = 0x80)
                off += 1
        lines := StrSplit(RTrim(StrReplace(WfDecodeBytes(buf.Ptr + off, take - off), "`r`n", "`n"), " `t`r`n"), "`n")
        out := ""
        loop Min(maxLines, lines.Length) {
            ln := lines[lines.Length - Min(maxLines, lines.Length) + A_Index]
            out .= (out = "" ? "" : "`n") (StrLen(ln) > 300 ? SubStr(ln, 1, 300) "..." : ln)
        }
        return out
    }
    return ""
}

; Replace every {{Name}} in `text` with its value. An UNKNOWN name is left
; exactly as written, on purpose: no workflow saved before this existed can
; change behaviour, and a mistyped name shows up on screen instead of
; silently typing nothing. Never throws — it runs on every step of every run.
;
; cmdLine: the text is a COMMAND LINE (a capture step's command, a run step's
; target). There, {{selected_file}} / {{selected_files}} always come out
; correctly quoted — "C:\Invoice 2025\Smith.pdf" — whether or not the author put
; quotes around them. The rule is cmd's own quote parity: OUTSIDE a quoted
; argument (an even number of " so far) the path arrives wrapped in quotes;
; INSIDE one the author opened ("{{selected_file}}", "--in={{selected_file}}")
; it arrives bare, because the author's quotes already cover it. The plural
; hugged by the author's own quotes ("{{selected_files}}") absorbs them, since
; several paths can't share one pair. Client file names are full of spaces,
; and "remember to quote it" is exactly the rule that fails silently on the
; first file with one. Only the two selection names are treated this way; any
; other value lands as-is, so quote it yourself ("{{Customer}}"). A user value
; that shadows the name is never touched.
WfSubst(text, vars, cmdLine := false) {
    if (text = "" || !InStr(text, "{{"))
        return text
    out := "", pos := 1
    while (at := RegExMatch(text, "\{\{\s*([^{}]+?)\s*\}\}", &m, pos)) {
        lit := SubStr(text, pos, at - pos)
        after := at + StrLen(m[0])
        name := m[1]
        if (IsObject(vars) && vars.Has(name))
            val := vars[name]
        else {
            val := WfBuiltinVar(name, &found)
            if !found
                val := m[0]                  ; unknown -> leave it literal
            else if (cmdLine && WfIsSelectionName(name)) {
                StrReplace(out lit, '"', '"', , &nq)      ; quotes cmd has seen so far
                hugged := SubStr(lit, -1) = '"' && SubStr(text, after, 1) = '"'
                if (StrLower(name) = "selected_files") {
                    val := WfSelectionQuoted(name)
                    if (hugged && Mod(nq, 2))            ; "{{selected_files}}": absorb the pair
                        lit := SubStr(lit, 1, -1), after += 1
                } else if Mod(nq, 2)                     ; inside the author's quotes: bare
                    val := WfBuiltinVar(name, &found)
                else
                    val := WfSelectionQuoted(name)
            }
        }
        out .= lit val
        pos := after
    }
    return out SubStr(text, pos)
}

; The two File Explorer selection built-ins.
WfIsSelectionName(name) {
    n := StrLower(name)
    return n = "selected_file" || n = "selected_files"
}

; A selection name in its command-line form: every path wrapped in double
; quotes (a Windows path can't contain one, so the quoting is exact). The
; singular is "" unless exactly one file is selected — the run's precheck
; refuses to start before that could ever reach a command.
WfSelectionQuoted(name) {
    global wfSelection
    if (StrLower(name) = "selected_files")
        return WfBuiltinVar(name, &found)          ; already quoted
    return (IsObject(wfSelection) && wfSelection.Length = 1) ? '"' wfSelection[1] '"' : ""
}

; A copy of the step with {{Name}} resolved in the fields where a value makes
; sense. Done out here so WfRunStep needs no knowledge of values at all.
;
; Deliberately NOT substituted: `wait` milliseconds, recorded coordinates and
; condition types (paramC — with ONE exception, below), `move` positions, and
; an `ask` step's label or suggestion — asks are gathered before step 1, so
; nothing would be resolvable there anyway.
;
; The exception: a `fill` step's paramC is the VALUE to put in the box, and a
; value is exactly what {{Name}} is for (a batch row's column, an ask answer).
; It is the first — and so far only — paramC that is substituted.
WfSubstStep(s, vars) {
    t := s[1], a := s[2], b := s[3]
    c := (s.Length >= 4) ? s[4] : ""
    switch t {
        case "run":                          ; a command line: selections arrive quoted
            a := WfSubst(a, vars, true)
        case "text", "keys", "waitwin", "move", "close", "drag":
            a := WfSubst(a, vars)
        case "focus", "click", "dblclick", "rclick", "hover", "if", "waitfor":
            a := WfSubst(a, vars), b := WfSubst(b, vars)
        case "collect", "set":               ; a is the NAME — never substituted
            b := WfSubst(b, vars)
        case "capture":                      ; a is the name; b the command line
            b := WfSubst(b, vars, true)      ; (c, the timeout, is never substituted)
        case "fill":                         ; window, label AND the value (paramC)
            a := WfSubst(a, vars), b := WfSubst(b, vars), c := WfSubst(c, vars)
    }
    return [t, a, b, c]
}

; The step text {{Name}} is resolved in — the same fields WfSubstStep touches.
; Used by the authoring-time check below, so the two can't drift.
WfStepSubstText(s) {
    switch s[1] {
        case "text", "keys", "run", "waitwin", "move", "close", "drag":
            return s[2]
        case "focus", "click", "dblclick", "rclick", "hover", "if", "waitfor":
            return s[2] "`n" s[3]
        case "collect", "set", "capture":
            return s[3]
        case "fill":
            return s[2] "`n" s[3] "`n" ((s.Length >= 4) ? s[4] : "")
    }
    return ""
}

; Every name this workflow defines, in step order — what the Studio offers
; as "values you can use here".
WfVarNames(steps) {
    seen := Map()
    seen.CaseSense := false
    out := []
    for s in steps {
        nm := ""
        switch s[1] {
            case "ask":     nm := WfAskLabel(s)
            case "collect": nm := WfCollectLabel(s)
            case "set", "capture": nm := Trim(s[2])
        }
        if (nm != "" && !seen.Has(nm)) {
            seen[nm] := true
            out.Push(nm)
        }
    }
    return out
}

; {{Name}} references that nothing defines and no built-in covers. An
; authoring-time WARNING only — never a block: the reference still runs
; (it types itself literally), and a `set` inside an if-branch is legitimate.
WfUndefinedVars(steps) {
    defined := Map()
    defined.CaseSense := false
    for nm in WfVarNames(steps)
        defined[nm] := true
    for nm in WfFillInputNames(steps)   ; a fill value's own inputs — asked, not undefined
        defined[nm] := true
    seen := Map()
    seen.CaseSense := false
    out := []
    for s in steps {
        txt := WfStepSubstText(s), pos := 1
        while (at := RegExMatch(txt, "\{\{\s*([^{}]+?)\s*\}\}", &m, pos)) {
            nm := m[1]
            WfBuiltinVar(nm, &isBuiltin)
            if (!defined.Has(nm) && !isBuiltin && !seen.Has(nm)) {
                seen[nm] := true
                out.Push(nm)
            }
            pos := at + StrLen(m[0])
        }
    }
    return out
}

; The label an `ask` step is keyed by ("Input" if somehow blank — the
; Studio and the MCP writer both require one at authoring time).
WfAskLabel(s) {
    label := Trim(s[2])
    return label != "" ? label : "Input"
}

; The workflow's INPUTS, in step order: every unique `ask` label, then every
; fill-value input (WfFillInputNames). The loop runner uses this to batch
; inputs (typed-in rows or a CSV whose columns are these labels), a single
; run asks for each up front, and the sheet's input columns are these.
; Mirrored by mcp\voicekit_writer._input_labels (batch validation).
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
    for l in WfFillInputNames(steps)
        if !seen.Has(l) {
            seen[l] := true
            labels.Push(l)
        }
    return labels
}

; {{Name}}s a `fill` VALUE uses that no step defines (not an ask, collect,
; set or capture name) and no built-in covers. They are INPUTS of the
; workflow, exactly like an ask label — asked up front on a single run, a
; column of the inputs sheet, a column of a batch — only nothing is typed
; where they are declared, because a fill step types them itself, into the
; right box. Without this, feeding a batch row into fill steps needed an
; `ask` step per value, and an ask TYPES its answer at its own position.
; So `fill|Billing Portal|Invoice total|{{Box 1}}` makes "Box 1" an input.
WfFillInputNames(steps) {
    defined := Map()
    defined.CaseSense := false
    for nm in WfVarNames(steps)
        defined[nm] := true
    seen := Map()
    seen.CaseSense := false
    out := []
    for s in steps {
        if (s[1] != "fill")
            continue
        txt := (s.Length >= 4) ? s[4] : "", pos := 1
        while (at := RegExMatch(txt, "\{\{\s*([^{}]+?)\s*\}\}", &m, pos)) {
            nm := m[1]
            if !(defined.Has(nm) || seen.Has(nm) || WfIsBuiltinName(nm)) {
                seen[nm] := true
                out.Push(nm)
            }
            pos := at + StrLen(m[0])
        }
    }
    return out
}

; True for a built-in value name (clipboard, date, ... — WfBuiltinVar's list),
; without reading any of them.
WfIsBuiltinName(nm) {
    n := StrLower(nm)
    return n = "clipboard" || n = "date" || n = "time" || n = "datetime"
        || n = "selected_file" || n = "selected_files"
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
    text := ClipCapture(() => Send("^c"), 1, &ok)      ; lib\Clip.ahk: restores in a finally
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
    for label in WfFillInputNames(steps) {      ; a fill value's inputs (no suggestion)
        if vals.Has(label)
            continue
        ans := WfAskInputDialog(label, "")
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
        return {err: "This step has no window to check.", val: false}
    switch cond {
        case "winexists":        return {err: "", val: (WinExist(win) != 0)}
        case "winnotexists":     return {err: "", val: (WinExist(win) = 0)}
        case "elementexists":    return {err: "", val: WfElementPresent(win, name)}
        case "elementnotexists": return {err: "", val: !WfElementPresent(win, name)}
        case "textvisible":      return {err: "", val: WfTextVisible(win, name)}
        case "textnotvisible":   return {err: "", val: !WfTextVisible(win, name)}
        case "clipboardchanged":
            ; Needs a "before" to compare against, which only a wait has —
            ; an `if` has no baseline, so this is a waitfor-only condition.
            return {err: "'clipboard changed' only works on a Wait-until step, not an If.", val: false}
    }
    return {err: "Unknown condition: " cond, val: false}
}

; True if `text` appears anywhere in the window — the loose test that answers
; "did the search return anything?", where an exact element NAME can't.
WfTextVisible(win, text) {
    hwnd := WinExist(win)
    if (!hwnd || Trim(text) = "")
        return false
    ; Cheap first: classic Win32 controls hand over their captions in one
    ; call, no accessibility tree walk needed. VISIBLE controls only: v2's
    ; DetectHiddenText defaults to On, and Win32 apps often pre-create a
    ; hidden "No results found" static — which made `if textvisible` true
    ; and `waitfor textnotvisible` time out while nothing was showing. The
    ; setting is thread-local; the caller's is put back either way.
    prevHidden := A_DetectHiddenText
    DetectHiddenText(false)
    try {
        if InStr(WinGetText("ahk_id " hwnd), Trim(text))
            return true
    } catch {
        ; window gone mid-check — fall through to the tree walks
    } finally {
        DetectHiddenText(prevHidden)
    }
    ; Then both accessibility trees, splitting one budget between them — a
    ; browser answers only over UIA, a desktop app usually only over MSAA.
    if AccTextPresent(hwnd, text, 350)
        return true
    return UiaAvailable() ? UiaTextPresent(hwnd, text, 350) : false
}

; ============================================================
;  Waiting for something to HAPPEN, instead of guessing at ms.
;
;  A `wait` step is a bet that the app will be ready in N
;  milliseconds — hand-tuned, and wrong on a slower morning. A
;  `waitfor` step blocks until the thing it names is actually
;  true, then continues immediately, and FAILS with a message
;  naming what never happened instead of typing into the void.
;
;  On disk: waitfor|<window>|<element or text>|<condType>[,<seconds>]
;  The condition vocabulary is shared with `if` (WfEvalCond), so
;  anything testable is also waitable. Seconds default to 10, and
;  live in paramC beside the condType — paramC is already the
;  comma-delimited "typed extra" slot (click coords, drag paths).
; ============================================================

; Block until the condition holds. Returns "" once it does, or the reason it
; never did. Aborts (Stop Looping) come back as an error the caller suppresses,
; exactly like a WfWinWait timeout does.
WfWaitFor(win, name, cond, timeoutSec) {
    deadline := A_TickCount + Round(timeoutSec * 1000)
    ; The clipboard test is the one condition with memory: "changed" is
    ; relative to whatever was on it when this step began.
    before := (cond = "clipboardchanged") ? A_Clipboard : ""
    loop {
        if (cond = "clipboardchanged") {
            if (A_Clipboard !== before)
                return ""
        } else {
            r := WfEvalCond(["waitfor", win, name, cond])
            if (r.err != "")
                return r.err                ; authoring error, not a timeout
            if r.val
                return ""
        }
        if (A_TickCount >= deadline)
            return WfWaitForTimeoutMsg(cond, win, name, timeoutSec)
        if !WfSleep(150)                    ; abort-aware: false = run stopped
            return "Stopped."
    }
}

; Say what never happened. This message IS the feature — the old failure mode
; was typing into a window that never became ready and never saying why.
WfWaitForTimeoutMsg(cond, win, name, secs) {
    switch cond {
        case "elementexists":
            return "Waited " secs "s but `"" name "`" never appeared in  " win
        case "elementnotexists":
            return "Waited " secs "s but `"" name "`" never went away in  " win
        case "winexists":     return "Waited " secs "s but this window never opened:  " win
        case "winnotexists":  return "Waited " secs "s but this window never closed:  " win
        case "textvisible":
            return "Waited " secs "s but the text `"" name "`" never appeared in  " win
        case "textnotvisible":
            return "Waited " secs "s but the text `"" name "`" never went away in  " win
        case "clipboardchanged":
            return "Waited " secs "s but nothing new was copied to the clipboard."
    }
    return "Waited " secs "s but the condition never came true."
}

; Split a waitfor step's paramC ("<condType>[,<seconds>]") into both parts.
; Junk seconds fall back to the 10 s default rather than failing the step.
WfWaitParts(c) {
    parts := StrSplit(c, ",")
    cond := parts.Length ? Trim(parts[1]) : ""
    secs := 10
    if (parts.Length >= 2 && IsNumber(Trim(parts[2])) && Number(Trim(parts[2])) > 0)
        secs := Number(Trim(parts[2]))
    return {cond: cond, secs: secs}
}

; True if an accessible element named `name` is present in window `win`.
; A condition is a point-in-time snapshot, so use a short budget — not the
; click path's 3 s wait-for-late-render budget, which would stall every
; absent-element check (painful inside a loop) for ~3 s per pass. The budget
; is SPLIT between the two trees rather than doubled, so adding the UIA half
; costs nothing in wall-clock.
;
; Each round is ONE look in each tree, then a short pause — not a 350 ms
; retry loop in MSAA before UIA is even asked. The answer here is only
; "present or not", so the order can't change WHICH element matches; the
; old shape just made a browser (which answers only over UIA) pay ~0.5 s of
; futile MSAA sleeps per check, and a `waitfor elementexists` re-test only
; every ~0.85 s instead of every poll. (WfFindElement below keeps its
; 400 ms MSAA head start on purpose: there the winner IS the element that
; gets clicked, and recorded desktop workflows must keep matching MSAA's.)
WfElementPresent(win, name, budgetMs := 700) {
    hwnd := WinExist(win)
    if !hwnd
        return false
    name := Trim(name)          ; see WfFindElement
    deadline := A_TickCount + budgetMs
    loop {
        ; A huge MSAA tree must not eat the whole budget before UIA looks.
        if IsObject(AccFindOnce(hwnd, name, Min(deadline, A_TickCount + budgetMs // 2)))
            return true
        if IsObject(WfUiaRect(hwnd, name, 0))            ; 0 = a single attempt
            return true
        if (A_TickCount >= deadline || WfAborted())
            return false
        Sleep(150)
    }
}

; ============================================================
;  Finding an element: MSAA first, UIA second.
;
;  Acc.ahk was the engine's only pair of eyes, which was fine
;  until it wasn't: current Chrome exposes no page content over
;  MSAA, so every named click inside a web page failed with
;  "Couldn't find anything named ..." — including workflows that
;  used to work. UIA sees those pages in full.
;
;  Acc still goes first, because recorded desktop workflows were
;  built against the names IT reports and must keep matching them.
;  But the two are INTERLEAVED in short passes rather than run
;  back to back: a straight "3 s of Acc, then 3 s of UIA" would
;  make every browser click pay three seconds of futile MSAA
;  walking before it could succeed, and would double the wait
;  before a genuinely missing element is reported. Alternating
;  keeps the total budget at the 3 s it always was.
;
;  BROWSERS get a shorter MSAA turn (2026-09-30). A desktop window keeps
;  the 400 ms head start, whose retry sleeps are what let a late-rendering
;  desktop control be matched by MSAA before UIA answers. Chromium's MSAA
;  tree holds only its own chrome (tabs, toolbar, caption buttons), which
;  is drawn before the page — so ONE walk per round answers everything
;  MSAA will ever answer there, and the retries were pure delay: measured
;  against the pretend browser in tests\engine-hybrid-selftest-target.ahk,
;  a UIA-only button took ~580 ms to find, nearly all of it futile MSAA
;  sleeping (~45 ms after). MSAA still goes first every round, so anything
;  already on screen that it can see (a recorded "Reload" or tab name —
;  or, in Firefox, which does publish page content over MSAA, the page)
;  matches exactly as before. What changes is only an element that
;  renders during what used to be MSAA's retry sleep: UIA may now answer
;  for it first. That is the tradeoff desktop windows keep refusing.
; ============================================================

; True for a top-level window whose page content MSAA can't be relied on
; to show: Chromium (Chrome, Edge — and Electron apps, which share the
; class) and Firefox. Only used to PACE the lookup, never to skip a tree.
WfIsBrowserWindow(hwnd) {
    try {
        root := DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr") || hwnd   ; GA_ROOT
        cls := WinGetClass("ahk_id " root)
        return (cls = "Chrome_WidgetWin_1" || cls = "MozillaWindowClass")
    }
    return false
}

; The screen rect of the element named `name` in window `win`, or "".
; The needle is trimmed: a stray space typed around a name can't match any
; element in either tree (MSAA's walk already trimmed; UIA's exact-match
; condition did not).
WfFindElement(win, name, budgetMs := 3000) {
    hwnd := WinExist(win)
    name := Trim(name)
    if (!hwnd || name = "")
        return ""
    deadline := A_TickCount + budgetMs
    web := WfIsBrowserWindow(hwnd)
    loop {
        if web {        ; one MSAA walk (browser chrome is already drawn)
            if IsObject(loc := AccFindOnce(hwnd, name, Min(deadline, A_TickCount + 400)))
                return loc
        } else if IsObject(loc := AccFindByName(hwnd, name, 400))
            return loc
        if IsObject(loc := WfUiaRect(hwnd, name, 400))
            return loc
        if (A_TickCount >= deadline || WfAborted())
            return ""
    }
}

; The UIA half: the rect of the first element of that Name that HAS one.
; A zero rect means collapsed/offscreen, which is unclickable — and it is
; also how the label-vs-input trap shows up, so when the first match has no
; rect the other matches get a look before giving up.
WfUiaRect(hwnd, name, budgetMs := 400) {
    name := Trim(name)
    if !UiaAvailable()
        return ""
    el := UiaFind(hwnd, name, budgetMs)
    if (el && IsObject(r := UiaRect(el)))
        return r
    if !el
        return ""
    for e in UiaFindAll(hwnd, name, 0, 8)
        if IsObject(r := UiaRect(e))
            return r
    return ""
}

; ============================================================
;  Reading a named box: `collect|<label>|<element name>|`.
;
;  The same two trees, the same order, the same 3 s budget as a
;  click. It used to be MSAA only (AccValueByName), so a collect
;  inside a web page — the read half of any fill-and-verify or
;  extraction workflow — always failed with "Couldn't find a box".
;
;  Semantics kept from the MSAA-only version, deliberately:
;  - A value found by MSAA wins. MSAA goes first every round, so a
;    recorded desktop workflow reads exactly the box it always did.
;  - Found-but-EMPTY is a legitimate empty box, not a failure — but
;    only at the deadline: until then the lookup keeps trying, in
;    case the box fills in late (the 3 s it always waited).
;  - Not found at all is a step failure.
;
;  The UIA half asks for the EDIT of that name (UiaFindEdit), never
;  the first element of that name: on real web forms the label and
;  the input share their accessible name and the label comes first,
;  so a plain find reads the label. It reads with UiaValueOnly — no
;  Name fallback, which would hand back the needle itself. When no
;  Edit carries the name, any same-named element WITH a ValuePattern
;  counts (a combo box, a spinner); one without a ValuePattern (a
;  label, a button) does not — there is no box there to read.
; ============================================================

; {found, value} for the box named `name` in window hwnd.
WfFieldValue(hwnd, name, budgetMs := 3000) {
    name := Trim(name)
    if (!hwnd || name = "")
        return {found: false, value: ""}
    deadline := A_TickCount + budgetMs
    web := WfIsBrowserWindow(hwnd)
    foundEmpty := false
    loop {
        ; MSAA: a same-named element WITH a value wins at once; one with
        ; only an empty value (or a label sharing the name) is remembered.
        if web {        ; one walk per round, as in WfFindElement
            node := AccNodeOnce(hwnd, name, Min(deadline, A_TickCount + 400), true, &foundEmpty)
            if IsObject(node)
                return {found: true, value: AccValue(node.acc, node.child)}
        } else {
            r := AccValueByName(hwnd, name, 400)
            if (r.found && r.value != "")
                return r
            if r.found
                foundEmpty := true
        }
        r := WfUiaFieldValue(hwnd, name)
        if (r.found && r.value != "")
            return r
        if r.found
            foundEmpty := true
        if (A_TickCount >= deadline || WfAborted())
            return {found: foundEmpty, value: ""}
        if web
            Sleep(150)
    }
}

; The UIA half of WfFieldValue: one look, no retries (the caller paces).
WfUiaFieldValue(hwnd, name) {
    if !UiaAvailable()
        return {found: false, value: ""}
    if (el := UiaFindEdit(hwnd, name, 0)) {
        v := UiaValueOnly(el, &has)
        if has
            return {found: true, value: v}
    }
    for el in UiaFindAll(hwnd, name, 0, 8) {
        v := UiaValueOnly(el, &has)
        if has
            return {found: true, value: v}
    }
    return {found: false, value: ""}
}

; ============================================================
;  Filling a box by its label: `fill|<window>|<label>[#N]|<value>`.
;
;  The write half of fill-and-verify (an office typing invoice
;  figures into a web app's input screens, one batch row per
;  client). Clicking a box and typing into it was always possible;
;  what was not was KNOWING it worked — a click that missed, a
;  pop-up that stole the focus, a box that rejected or trimmed the
;  value all looked exactly like success. So a fill:
;
;  1. FINDS the input by its accessible name (what a screen reader
;     announces — for a web form, its <label>). UIA first, and only
;     the INPUT kinds: Edit, ComboBox (an editable one — its inner
;     Edit is the same box and is not counted twice), Spinner (a
;     number box). Never the Text label that shares the name (the
;     label-vs-input trap). Not Document either: a browser page's
;     root IS a Document, named after the page, so a label that
;     happened to match the page title would select-all the whole
;     page. MSAA is the fallback, for desktop inputs only it can see
;     (role editable text / combo / spin button — the same filter).
;     "Amount#2" = the 2nd input labelled Amount in tree order;
;     "##" writes a literal "#". Several matches and no #N: the FIRST
;     is filled and the run log says so. 3 s budget, abort-aware.
;  2. Refuses a DISABLED box, before anything is typed.
;  3. CLICKS it for real (UiaClickEl: scroll-into-view rescue, fail
;     loudly with no rectangle). Only when there is nowhere to click
;     does it set the value through UIA's ValuePattern instead — a
;     rescue, not the default: a set skips the app's own keyboard and
;     validation handlers, which matters in form software.
;  4. FOCUS GATE, before any keystroke: the keyboard focus must be ON
;     that box (or a child of it — a combo's inner edit). Otherwise
;     nothing is typed and the step fails: a readback alone can pass
;     while the text went into a different box (measured once, see
;     lib\Browser.ahk BrowserTypeVerified).
;  5. ^a, then SendText. No {Esc}: it reverts a cell being edited in
;     some apps and closes dialogs in others. A browser's autofill
;     drop-down does not take the keyboard focus, so it can't eat
;     the typing; if one ever does, the focus gate refuses (nothing
;     typed) and a `keys|{Esc}` step before the fill is the fix.
;  6. READS IT BACK (ValuePattern; select-all + copy, clipboard kept,
;     for a box without one) and compares with WfFillMatches, retried
;     for a second so a box that reformats as you type can settle.
;     A password box is filled but never read back — noted in the log.
;
;  PRIVACY: values may be client data (an SSN, an amount). No
;  failure reason and no log note ever contains the value; the local
;  popup (WfRunFail's detail) may show typed vs held, because the
;  person at THIS machine is the one who can fix it. Steps are still
;  logged as written, so a batch's {{SSN}} stays a placeholder — a
;  value written literally into a step is part of the workflow, like
;  a Type text step's.
; ============================================================

; Self-tests only: true skips the UIA half so the MSAA fallback can be proved
; against a real classic edit (Win32 controls show up in BOTH trees, so no
; ordinary control is MSAA-only). Never set in production.
global wfFillUiaOff := false

; A fill label -> {name, occ, explicit, err}. "Amount#2" -> Amount, 2nd
; input. "##" is a literal "#" ("Line ##4" is the label "Line #4"), and a
; single "#" not followed by digits at the end is literal too ("Box #A").
; Spaces before the "#N" are dropped with the rest of the trim.
; Mirrored by mcp\voicekit_writer.fill_label (same table in both tests).
WfFillLabel(raw) {
    s := Trim(raw)
    occ := 1, explicit := false
    ; An ODD run of # before the trailing digits: the last one is the
    ; separator, the rest are ## pairs. An even run is all pairs — literal.
    if (RegExMatch(s, "^(.*?)(#+)(\d+)$", &m) && Mod(StrLen(m[2]), 2) = 1) {
        occ := StrLen(m[3]) > 6 ? 999999 : Integer(m[3])
        explicit := true
        s := m[1] SubStr(m[2], 2)
    }
    name := Trim(StrReplace(s, "##", "#"))
    err := ""
    if (name = "")
        err := "This fill step has no label — give the input's label as it appears on screen."
    else if (explicit && occ < 1)
        err := "`"#0`" isn't an input number — count from #1 (the first input with that label)."
    return {name: name, occ: occ, explicit: explicit, err: err}
}

; Put `value` into the input labelled `label` in window `win` and check it
; took. Returns {err, detail, notes}: err "" on success; detail is for the
; LOCAL popup only (may show values); notes go to the run log (never values).
; shownWin / shownLabel: the step AS WRITTEN, used to name the box in any
; message (a {{Name}} filled in could carry client data).
WfFill(win, label, value, shownWin := "", shownLabel := "") {
    r := {err: "", detail: "", notes: []}
    lab := WfFillLabel(label)
    shown := WfFillLabel(shownLabel != "" ? shownLabel : label)
    q := "`"" shown.name "`"" (shown.explicit ? " #" shown.occ : "")
    shownWin := (shownWin != "") ? shownWin : win
    if (lab.err != "") {
        r.err := lab.err
        return r
    }
    ; SendText turns a line break into Enter — which submits a web form.
    if RegExMatch(value, "[\r\n]") {
        r.err := "The value for the input labelled " q " has a line break in it. A fill types "
            . "one line (a line break would press Enter, which can submit the form) — use a "
            . "Type text step for multi-line text."
        return r
    }
    if (Trim(win) = "") {
        r.err := "This fill step has no window."
        return r
    }
    if (!WinExist(win) && !WfWinWait(win, 10))        ; same grace as click
        return (r.err := "Window not found: " shownWin, r)
    try WinActivate(win)
    if !WfSleep(400)
        return (r.err := "Stopped.", r)
    if !(hwnd := WinExist(win))
        return (r.err := "Window not found: " shownWin, r)

    f := WfFillFind(hwnd, lab.name, lab.occ)
    if !f.found {
        if WfAborted()
            r.err := "Stopped."
        else if (f.count > 0)
            r.err := "Only " f.count " input" (f.count = 1 ? " is" : "s are") " labelled `"" shown.name
                . "`" in that window — #" lab.occ " asks for input number " lab.occ "."
        else if f.sawName
            r.err := "No input labelled " q " in  " shownWin "  — something there IS named that, but "
                . "it isn't a box you can type into (a label or a button). Point Pick element at the "
                . "box itself to get its own name."
        else
            r.err := "No input labelled " q " in  " shownWin "  — the label must match the box's "
                . "accessible name exactly (Pick element on the box shows it). Web pages only build "
                . "what's near the screen: scroll to it, or add a Wait-until step first."
        return r
    }
    if (f.count > 1 && !lab.explicit)
        r.notes.Push(f.count " inputs are labelled `"" shown.name "`" — filled the FIRST. Write `""
            . shown.name "#2`" (and so on) in the label to pick another.")
    return (f.kind = "uia") ? WfFillUia(f.el, value, q, r) : WfFillAcc(f.node, value, q, r)
}

; The UIA half of WfFill, from "found it" on.
WfFillUia(el, value, q, r) {
    if !UiaEnabled(el)
        return (r.err := "The input labelled " q " is disabled — nothing was typed.", r)
    pw := UiaIsPassword(el)
    if UiaClickEl(el, WfClickJitter(), "Left", 1, &why) {
        gate := WfFillFocusGate(el)
        if !gate.ok
            return WfFillGateFail(q, gate.desc, r)
        WfFillType(value)
    } else if UiaSetValue(el, value) {
        ; Nowhere to click (virtualized / collapsed) but the box takes a value
        ; directly: set it, and let the readback decide whether that counted.
        r.notes.Push("the input labelled " q " had nowhere to click, so its value was set "
            . "directly through UI Automation — no keystrokes reached the app")
        Sleep(200)
    } else
        return (r.err := "Couldn't click the input labelled " q ": " why, r)
    if pw {
        r.notes.Push("the input labelled " q " is a password box — filled, not verified (a password box can't be read back)")
        Sleep(150)
        return r
    }
    ReadUia(&readable) {
        v := UiaValueOnly(el, &has)
        if has {
            readable := true
            return v
        }
        ; No ValuePattern: select-all + copy, the user's clipboard put back.
        ; Only after the gate proved the focus is on this box — so the copy
        ; reads THIS box, not whichever control has focus.
        ; Nothing copied means "couldn't read it" — unless the box was being
        ; CLEARED, where an empty box copies nothing too.
        text := ClipCapture(() => (Send("^a"), Sleep(50), Send("^c")), 1, &copied)
        readable := copied || value = ""
        return text
    }
    return WfFillVerify(ReadUia, value, q, r)
}

; The MSAA half of WfFill: a desktop input only MSAA exposes. Same rules —
; enabled, a real click, the focus gate, the readback.
WfFillAcc(node, value, q, r) {
    st := AccState(node.acc, node.child)
    if (st & ACC_STATE_UNAVAILABLE())
        return (r.err := "The input labelled " q " is disabled — nothing was typed.", r)
    p := WfClickPoint(node.loc)
    prev := A_CoordModeMouse
    CoordMode("Mouse", "Screen")
    try MouseClick("Left", p.x, p.y)
    finally CoordMode("Mouse", prev)
    deadline := A_TickCount + 1000
    while !WfFillAccFocused(node) {
        if (A_TickCount >= deadline || WfAborted())
            return WfFillGateFail(q, "(another control — MSAA doesn't name it)", r)
        Sleep(100)
    }
    WfFillType(value)
    if (st & ACC_STATE_PROTECTED()) {
        r.notes.Push("the input labelled " q " is a password box — filled, not verified (a password box can't be read back)")
        Sleep(150)
        return r
    }
    ReadAcc(&readable) {
        readable := true
        return AccValue(node.acc, node.child)
    }
    return WfFillVerify(ReadAcc, value, q, r)
}

WfFillGateFail(q, focusDesc, r) {
    r.err := WfAborted() ? "Stopped."
        : "Clicked the input labelled " q ", but the keyboard focus went somewhere else — "
        . "nothing was typed, so nothing landed in the wrong box. (A pop-up or the page itself "
        . "moved the focus; a Press keys {Esc} step before this one clears a pop-up.)"
    r.detail := "The keyboard focus was on:  " focusDesc
    return r
}

; ^a then the value — or Delete, to clear. Default SendLevel, like `text`.
WfFillType(value) {
    Send("^a")
    Sleep(80)
    if (value = "")
        Send("{Delete}")
    else
        SendText(value)
    Sleep(200)
}

; Read the box back (readFn(&readable) -> text) and compare. Retried for up
; to a second: a box that reformats as you type settles a moment later.
WfFillVerify(readFn, value, q, r) {
    deadline := A_TickCount + 1000
    loop {
        got := readFn.Call(&readable)
        if (readable && WfFillMatches(value, got)) {
            Sleep(150)                  ; the same beat the text/click steps give the app
            return r
        }
        if (A_TickCount >= deadline || WfAborted())
            break
        Sleep(150)
    }
    if WfAborted()
        return (r.err := "Stopped.", r)
    if !readable
        return (r.err := "Typed into the input labelled " q " but couldn't read it back to "
            . "check it — use a Type text step if this box can't be verified.", r)
    r.err := "Value in the input labelled " q " did not match after typing — the app rejected, "
        . "cut short or changed it. (The values are left out of this message on purpose.)"
    r.detail := "Typed:  " value "`nThe box holds:  " got
    return r
}

; Is the keyboard focus on `el` — the element itself, or something inside it
; (an editable combo's own edit)? Polled briefly: a browser moves focus a
; beat after the click. {ok, desc}: desc names where it WAS, for the popup.
WfFillFocusGate(el, budgetMs := 1000) {
    deadline := A_TickCount + budgetMs
    loop {
        f := UiaFocused()
        g := f
        loop 4 {                        ; the focused element, then up to 3 ancestors
            if !g
                break
            if UiaSameElement(g, el)
                return {ok: true, desc: ""}
            g := UiaParent(g)
        }
        if (A_TickCount >= deadline || WfAborted())
            return {ok: false, desc: f ? UiaControlTypeName(UiaControlType(f)) " `"" UiaName(f) "`""
                : "(nothing UI Automation can see)"}
        Sleep(100)
    }
}

; The MSAA focus test: the node says it is focused, or the Win32 control it
; belongs to (or a child of it) holds the thread's keyboard focus.
;
; The window test speaks only for a node that IS a window of its own (a Win32
; edit or combo, whose window rect matches the node's rect). A simple element
; (a child id) or a windowless box shares its HOST's window with every other
; box in it, and "the focus is somewhere in that window" says nothing about
; WHICH box has it — accepting that would let the gate pass while the typing
; went into a sibling box.
WfFillAccFocused(node) {
    if (AccState(node.acc, node.child) & ACC_STATE_FOCUSED())
        return true
    if (node.child != 0)
        return false
    h := AccWindowOf(node.acc)
    if (!h || !WfWinRectNear(h, node.loc))
        return false
    fh := WfFocusedHwnd(h)
    return fh != 0 && (fh = h || DllCall("IsChild", "ptr", h, "ptr", fh, "int"))
}

; True when window h's screen rect is within tolPx of rect loc ({x,y,w,h})
; on every edge — a Win32 edit's client rect (what MSAA reports) sits a
; 2 px client edge inside its window rect.
WfWinRectNear(h, loc, tolPx := 8) {
    rc := Buffer(16, 0)
    if (!IsObject(loc) || !DllCall("GetWindowRect", "ptr", h, "ptr", rc))
        return false
    return Abs(NumGet(rc, 0, "int") - loc.x) <= tolPx
        && Abs(NumGet(rc, 4, "int") - loc.y) <= tolPx
        && Abs(NumGet(rc, 8, "int") - (loc.x + loc.w)) <= tolPx
        && Abs(NumGet(rc, 12, "int") - (loc.y + loc.h)) <= tolPx
}

; The control holding the keyboard focus in the thread that owns hwnd.
WfFocusedHwnd(hwnd) {
    tid := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr", 0, "uint")
    gti := Buffer(A_PtrSize = 8 ? 72 : 48, 0)          ; GUITHREADINFO
    NumPut("uint", gti.Size, gti, 0)
    if !DllCall("GetGUIThreadInfo", "uint", tid, "ptr", gti, "int")
        return 0
    return NumGet(gti, 8 + A_PtrSize, "ptr")           ; hwndFocus (after cbSize, flags, hwndActive)
}

; Find input number `occ` labelled `name`. {found, kind, el|node, count,
; sawName}: count = inputs of that label seen; sawName = SOMETHING (a label,
; a button) carries the name, which makes "not found" say more.
WfFillFind(hwnd, name, occ, budgetMs := 3000) {
    global wfFillUiaOff
    deadline := A_TickCount + budgetMs
    web := WfIsBrowserWindow(hwnd)
    saw := false
    loop {
        count := 0                      ; this round's answer, not a stale one
        if (!wfFillUiaOff && UiaAvailable()) {
            res := WfFillUiaInputs(hwnd, name)
            saw := saw || res.sawName
            count := res.inputs.Length
            if (count >= occ)
                return {found: true, kind: "uia", el: res.inputs[occ], count: count, sawName: true}
        }
        if (count = 0) {                ; UIA sees no input of that name: MSAA's turn
            nodes := AccInputNodes(hwnd, name, Min(deadline, A_TickCount + (web ? 300 : 400)))
            count := nodes.Length
            if (count >= occ)
                return {found: true, kind: "acc", node: nodes[occ], count: count, sawName: true}
        }
        if (A_TickCount >= deadline || WfAborted())
            return {found: false, count: count, sawName: saw}
        if !WfSleep(150)
            return {found: false, count: count, sawName: saw}
    }
}

; Every UIA INPUT named `name`, tree order: Edit, ComboBox, Spinner — see the
; section header for why not Text or Document. An Edit inside a same-named
; ComboBox is that combo's own box and is not counted twice.
WfFillUiaInputs(hwnd, name) {
    out := [], saw := false
    for e in UiaFindAll(hwnd, name, 0, 30) {
        saw := true
        ct := UiaControlType(e)
        if (ct = UIA_TYPE_EDIT()) {
            p := UiaParent(e)
            if (p && UiaControlType(p) = UIA_TYPE_COMBOBOX() && Trim(UiaName(p)) = name)
                continue
            out.Push(e)
        } else if (ct = UIA_TYPE_COMBOBOX() || ct = UIA_TYPE_SPINNER())
            out.Push(e)
    }
    return {inputs: out, sawName: saw}
}

; Does the box hold what was typed? Deterministic, and never accepts a
; different digit sequence:
;   - identical, or equal after trimming, case-insensitively ("acme" = "ACME")
;   - both NUMBERS once currency symbols, thousands separators and spaces are
;     dropped, equal after dropping TRAILING decimal zeros:
;     1234.5 = 1,234.50 = $1,234.50; (12) and 12- are -12. Two numbers that
;     differ are a mismatch, full stop (1.5 is never 15, 01234 is not 1234).
;   - a MASK that only added or dropped separators (- space ( ) / _), with
;     no . or , on either side: 123456789 = 123-45-6789 (an SSN box),
;     01152025 = 01/15/2025. The same characters in the same order — which
;     is the whole rule.
WfFillMatches(want, got) {
    if (want == got)
        return true
    w := Trim(want), g := Trim(got)
    if (w = g)                                  ; = is case-insensitive in v2
        return true
    nw := WfFillNum(w), ng := WfFillNum(g)
    if (nw != "" && ng != "")
        return nw == ng
    mask := "^[\w\-\s()/]*$"
    if (RegExMatch(w, mask) && RegExMatch(g, mask)
        && StrLower(RegExReplace(w, "[\-\s()/_]")) == StrLower(RegExReplace(g, "[\-\s()/_]"))
        && RegExReplace(w, "[\-\s()/_]") != "")
        return true
    return false
}

; A number's canonical text ("-1234.5"), or "" if s isn't one. Currency
; symbols, spaces (incl. no-break) and a trailing % are dropped; (n) or a
; trailing minus means negative. A comma counts only as a THOUSANDS separator
; in its proper place (1,234,567.5): "1,5" or "12,34" is not a number here, so
; typing "1,5" (a decimal comma — 1.5) into a box that kept "15" can never
; pass as the same digits.
WfFillNum(s) {
    s := RegExReplace(s, "[\s\x{00A0}\x{202F}$€£¥]")
    s := RegExReplace(s, "%$")
    neg := false
    if RegExMatch(s, "^\((.*)\)$", &m)
        s := m[1], neg := true
    if (SubStr(s, 1, 1) = "-")
        s := SubStr(s, 2), neg := !neg
    else if (SubStr(s, -1) = "-")
        s := SubStr(s, 1, -1), neg := !neg
    else if (SubStr(s, 1, 1) = "+")
        s := SubStr(s, 2)
    if InStr(s, ",") {
        if !RegExMatch(s, "^\d{1,3}(?:,\d{3})+(?:\.\d*)?$")
            return ""
        s := StrReplace(s, ",")
    }
    if !RegExMatch(s, "^(\d*)(?:\.(\d*))?$", &m) || (m[1] = "" && m[2] = "")
        return ""
    ; Trailing decimal zeros go (1234.50 = 1234.5); LEADING zeros stay: a box
    ; that turned ZIP 01234 into 1234 changed the value, whatever a
    ; calculator says. Only a bare ".5" gains its "0".
    whole := (m[1] = "") ? "0" : m[1], frac := RTrim(m[2], "0")
    out := whole (frac != "" ? "." frac : "")
    return (neg && out != "0") ? "-" out : out
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
            w := WfWaitMs(a)
            if (w.err != "")
                return w.err
            WfSleep(w.ms)           ; sliced, so a loop Stop cuts it short
        case "waitfor":
            ; a = window, b = element / text, c = "<condType>[,<seconds>]".
            ; Deliberately does NOT activate anything — it only observes.
            w := WfWaitParts(c)
            return WfWaitFor(a, b, w.cond, w.secs)
        case "text":
            SendText(a)
            Sleep(150)          ; same beat the ask/click steps give the app
        case "fill":
            ; a = window, b = label (optionally "#N"), c = value. RunWorkflowSteps
            ; handles fill itself (for the local-only popup detail and the log
            ; notes); this branch serves direct callers.
            return WfFill(a, b, c).err
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
                loc := WfFindElement(a, b)      ; MSAA first, then UIA
                if IsObject(loc) {
                    p := WfClickPoint(loc)
                    MouseClick(btn, p.x, p.y, n)
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
                loc := WfFindElement(a, b)           ; MSAA first, then UIA
                if IsObject(loc) {
                    ; No jitter here on purpose: a hover is aimed at a menu
                    ; strip or a tooltip target, and the centre is the point
                    ; least likely to slip onto a neighbouring item.
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

; ============================================================
;  Pacing and aim — the two things that make a run look automated
;
;  A `wait` step is a fixed number of milliseconds and an element
;  click has always landed on the exact centre of its rect. Loop
;  that against a website and you get metronome timing and
;  pixel-identical clicks, which is the cheapest bot signal there
;  is. Neither of these makes a run non-deterministic in any way
;  that matters: the SAME steps run in the SAME order, they just
;  don't run like a machine gun.
; ============================================================

; A wait step's paramA -> {ms, err}. Accepts a plain number of milliseconds
; ("1500") or a RANGE ("600-1400"), which pauses for a random duration in
; that span. A reversed range is read the way it was obviously meant.
WfWaitMs(a) {
    a := Trim(a)
    if RegExMatch(a, "^(\d+)\s*-\s*(\d+)$", &m) {
        lo := Integer(m[1]), hi := Integer(m[2])
        if (lo > hi) {
            t := lo, lo := hi, hi := t
        }
        return {ms: Random(lo, hi), err: ""}
    }
    if IsInteger(a)
        return {ms: Integer(a), err: ""}
    return {ms: 0, err: "Not a number of milliseconds (or a range like 600-1400): " a}
}

; How far an element click may stray from dead centre, in pixels. 0 disables
; it. Set the global to override for one process (the self-tests do, so their
; assertions can be exact); otherwise it comes from logs\settings.ini
; [Workflow] ClickJitter, read once.
;
; Named wfClickJitterPx rather than wfClickJitter: functions and variables
; share one case-insensitive namespace, so a variable spelled like the
; WfClickJitter() below is a load error, not a shadowing subtlety.
global wfClickJitterPx := ""

WfClickJitter() {
    global wfClickJitterPx
    static cached := -1
    if (wfClickJitterPx != "")
        return Max(0, Integer(wfClickJitterPx))
    if (cached < 0) {
        cached := 3
        try cached := Max(0, Integer(IniRead(WfLogDir() "\settings.ini", "Workflow", "ClickJitter", "3")))
    }
    return cached
}

; Where a click on this element rect actually lands. The offset is clamped
; to a third of the rect in each direction, so however large the jitter
; setting is, the click cannot leave the element it was aimed at.
; Acc and UIA rects share the {x, y, w, h} shape, so the maths is UIA.ahk's
; one copy (UiaJitteredCenter) — UiaClickEl lands its clicks the same way.
WfClickPoint(loc) {
    return UiaJitteredCenter(loc, WfClickJitter())
}

; Kept as an alias of UiaJitter (the self-tests and older notes name it):
; a random offset in [-maxPx, +maxPx], never more than a third of the extent.
WfJitter(maxPx, extent) => UiaJitter(maxPx, extent)

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

; A failure reason with the step's filled-in fields put back AS WRITTEN: each
; field {{Name}} changed (sr vs s) is replaced in the text by its original —
; longest first, and its trimmed form too, since several messages quote a
; Trim()med name. What a {{Name}} resolved to can be client data, and the
; run record / log travel (MCP -> a cloud model); the local popup keeps the
; resolved form. Never throws.
WfUnsubst(reason, s, sr) {
    try {
        pairs := []
        k := 2
        while (k <= s.Length && k <= sr.Length) {
            if (sr[k] != "" && sr[k] != s[k]) {
                pairs.Push([sr[k], s[k]])
                if (Trim(sr[k]) != sr[k] && Trim(sr[k]) != "")
                    pairs.Push([Trim(sr[k]), Trim(s[k])])
            }
            k += 1
        }
        ; longest resolved text first, so a field that contains another's
        ; value is put back whole
        loop pairs.Length {
            best := A_Index
            j := A_Index + 1
            while (j <= pairs.Length) {
                if (StrLen(pairs[j][1]) > StrLen(pairs[best][1]))
                    best := j
                j += 1
            }
            if (best != A_Index) {
                tmp := pairs[A_Index], pairs[A_Index] := pairs[best], pairs[best] := tmp
            }
        }
        for p in pairs
            reason := StrReplace(reason, p[1], p[2], true)
    }
    return reason
}

; A failing step, described as WRITTEN and — when they differ — as actually
; resolved. A popup that only says {{Customer}} hides what was really tried.
WfStepDesc(s, sr) {
    d := WfDesc(s), r := WfDesc(sr)
    return (d = r) ? d : d "`n(with values filled in:  " r ")"
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
        case "waitfor":  return "Wait until  " WfWaitDesc(c, a, b)
        case "text":     return "Type  `"" a "`""
        case "ask":      return "Ask me for  `"" a "`""
            . (b != "" ? "    (suggested: " b ")" : "") "    — the answer is typed here"
        case "collect":  return "Collect  `"" a "`""
            . (b != "" ? "    (what's in the box named `"" b "`")" : "    (copies the selected text)")
        case "set":      return "Set  {{" a "}}  to  `"" b "`""
        case "capture":  return "Run  " b "  and save its output as  {{" a "}}"
            . (Trim(c) != "" ? "    (up to " Trim(c) "s)" : "")
        case "keys":     return "Press keys  " a
        case "fill":     return "Fill  `"" b "`"  with  `"" c "`"    in  " a
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
; A range reads as "0.6 s to 1.4 s (random)". Integer math only (no float
; formatting surprises), and junk is shown raw — WfDesc must never throw, it
; renders the error popup for a failing step.
WfDurDesc(ms) {
    if RegExMatch(Trim(ms), "^(\d+)\s*-\s*(\d+)$", &m)
        return WfDurDesc(Integer(m[1])) " to " WfDurDesc(Integer(m[2])) " (random)"
    if (!IsInteger(ms) || ms < 1000)
        return ms " ms"
    whole := ms // 1000, tenth := Mod(ms // 100, 10)
    return whole (tenth ? "." tenth : "") " s"
}

; Human-readable form of an `if` condition. cond = condType, win = window,
; name = element name (used only by the element / text conditions).
WfCondDesc(cond, win, name) {
    switch cond {
        case "winexists":        return "window  " win "  is open"
        case "winnotexists":     return "window  " win "  is NOT open"
        case "elementexists":    return "`"" name "`"  is on screen in  " win
        case "elementnotexists": return "`"" name "`"  is NOT on screen in  " win
        case "textvisible":      return "the text `"" name "`"  is showing in  " win
        case "textnotvisible":   return "the text `"" name "`"  is NOT showing in  " win
    }
    return cond "  " win "  " name
}

; Friendly form of a waitfor step. c is "<condType>[,<seconds>]" and, like
; WfDurDesc, this renders the error popup — it must never throw.
WfWaitDesc(c, win, name) {
    w := WfWaitParts(c)
    body := (w.cond = "clipboardchanged")
        ? "something new is copied to the clipboard"
        : WfCondDesc(w.cond, win, name)
    return body "    (up to " w.secs "s)"
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
    if (SubStr(text, 1, 1) = Chr(0xFEFF))             ; a BOM that survived the read
        text := SubStr(text, 2)                       ; would glue itself to header 1
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

; A COLLECTED value made safe for a sheet Excel will open. Collect scrapes
; third-party pages, and a value starting with = + - or @ (=HYPERLINK(...),
; say) would become a live formula. Such values get a leading apostrophe —
; Excel's own "this is text" mark. Numbers are left alone, so a negative
; amount like -12.50 (or -$1,234.56) survives as a number. Only collected
; cells go through this: the user's own inputs and headers round-trip as-is.
WfSheetSafeCell(v) {
    if (v = "" || !InStr("=+-@", SubStr(v, 1, 1)))
        return v
    if IsNumber(StrReplace(StrReplace(StrReplace(v, ",", ""), "$", ""), "%", ""))
        return v
    return "'" v
}

; Does record `rec` still hold the inputs a result was produced from? Used
; before writing a result back into the row it came from: the sheet may
; have been edited (rows inserted, deleted, sorted) while a long batch ran,
; and a row number captured at the start would then point at somebody
; else's row.
WfSheetRowMatches(rec, inCols, ins) {
    for l, ci in inCols {
        cell := (ci <= rec.Length) ? rec[ci] : ""
        if !(cell == ins.Get(l, ""))
            return false
    }
    return true
}

; Serialize records back to a CSV file — UTF-8 BOM + CRLF so Excel is happy.
; Written to a temp file beside it and then moved over it, so a process
; killed mid-write (the loop's OnExit save runs while a #SingleInstance Force
; replacement is waiting to terminate it) leaves the old sheet whole, never a
; truncated one. Throws on failure like the plain write did (a locked sheet),
; after cleaning up the temp file.
WfSheetWrite(path, recs) {
    out := ""
    for rec in recs {
        line := ""
        for j, v in rec
            line .= (j > 1 ? "," : "") WfCsvField(v)
        out .= line "`r`n"
    }
    tmp := path ".tmp-" DllCall("GetCurrentProcessId", "uint")
    try {
        f := FileOpen(tmp, "w", "UTF-8")
        f.Write(out)
        f.Close()
        FileMove(tmp, path, 1)
    } catch as e {
        try f.Close()
        try FileDelete(tmp)
        throw e
    }
}

; Write collected results into the workflow's sheet. Each result is
; {src, ins, out}: src > 1 fills the collect columns of that record index
; (a loop pass fed by the sheet's own row — 1 is the header) as long as that
; row still holds `ins` (else the matching row, else a new row — see
; WfSheetRowMatches), src = 0 appends a new row holding the inputs used plus
; the values collected. Collected cells go through WfSheetSafeCell. A result
; flagged `old` (a leftover journal row — see WfLoopSaveResults, which passes
; newer results first) is dropped instead of appended when its row is already
; filled; `skipped` in the return value counts those.
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
        claimed := Map()                               ; record index -> already filled by this save
        skipped := 0
        for r in results {
            ; A result goes back into the row it came from ONLY if that row
            ; still holds the inputs that produced it. Otherwise (the sheet
            ; was edited mid-run) find the unclaimed row that does, and failing
            ; that append it as a new row — never into someone else's row.
            dest := 0
            if (r.src > 1 && r.src <= recs.Length && !claimed.Has(r.src)
                && WfSheetRowMatches(recs[r.src], inCols, r.ins))
                dest := r.src
            else if (r.src > 1) {
                loop recs.Length - 1 {
                    k := A_Index + 1
                    if (!claimed.Has(k) && WfSheetRowMatches(recs[k], inCols, r.ins)) {
                        dest := k
                        break
                    }
                }
            }
            if (!dest && r.src > 1 && r.HasProp("old") && r.old) {
                ; A leftover from an interrupted earlier loop whose row a
                ; NEWER result already filled (the caller passes newer ones
                ; first): drop it. Appending would duplicate the row's inputs.
                superseded := false
                loop recs.Length - 1
                    if WfSheetRowMatches(recs[A_Index + 1], inCols, r.ins) {
                        superseded := true
                        break
                    }
                if superseded {
                    skipped += 1
                    continue
                }
            }
            if dest {
                claimed[dest] := true
                for l, ci in outCols
                    WfSheetSetCell(recs[dest], ci, WfSheetSafeCell(r.out.Get(l, "")))
            } else {
                rec := []
                for l, ci in inCols
                    WfSheetSetCell(rec, ci, r.ins.Get(l, ""))
                for l, ci in outCols
                    WfSheetSetCell(rec, ci, WfSheetSafeCell(r.out.Get(l, "")))
                recs.Push(rec)
            }
        }
        try {
            WfSheetWrite(sheetPath, recs)
            SplitPath(sheetPath, &name)
            return {name: name, err: "", path: sheetPath, skipped: skipped}
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
                WfSheetSetCell(rec, ci, WfSheetSafeCell(r.out.Get(l, "")))
            altRecs.Push(rec)
        }
        WfSheetWrite(alt, altRecs)
        SplitPath(alt, &name)
        return {name: name, err: "", path: alt, skipped: 0}
    } catch {
        return {name: "", err: "Couldn't save the collected values — the sheet and its results file "
            . "are both locked (close them in Excel and run again).", path: "", skipped: 0}
    }
}
