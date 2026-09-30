#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Self-test for the `capture` step (lib\Workflow.ahk WfCapture):
;  capture|<name>|<command line>|<seconds>.
;
;  The commands it runs are engine-capture-selftest-target.ahk (a
;  command-line child in its own process) plus cmd's own echo and,
;  when one is installed, python -- never anything of the user's.
;  The one window it types into is a throwaway GUI with a unique
;  title. Runs are quiet (no failure MsgBox can wedge the suite),
;  logs go to %TEMP%, fixtures live in %TEMP%. ASCII only:
;  non-ASCII test text is built with Chr().
; ============================================================
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"
#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("engine-capture-selftest")
wfLogFolder := A_Temp "\vk-selftest-logs"   ; keep test runs out of the user's real run history
wfTrayOff := true
wfRunQuiet := true
wfRunName := "VKCaptureTest"

target := A_ScriptDir "\engine-capture-selftest-target.ahk"
T := '"' A_AhkPath '" "' target '" '           ; command prefix: run the target
fx := A_Temp "\vk-capture-selftest"
try DirDelete(fx, true)
DirCreate(fx)
none := Map()
none.CaseSense := false
myPid := DllCall("GetCurrentProcessId", "uint")

; The working directory must be forced, not inherited: run from %TEMP%.
SetWorkingDir(A_Temp)

; ---------- 1. plain output, trimming, empty, separation -----------------
r := WfCapture(T "echo hello")
Check("plain output becomes the value", r.ok && r.value = "hello", r.reason " / " r.value)
r := WfCapture(T "trail")
Check("trailing blank lines/spaces trimmed, leading spaces kept", r.ok && r.value = "  lead",
    "[" r.value "]")
r := WfCapture(T "empty")
Check("no output + exit 0 is fine (an empty value)", r.ok && r.value = "", r.reason)
r := WfCapture(T "mixed")
Check("stderr is kept OUT of the value", r.ok && r.value = "VALUE", "[" r.value "]")
r := WfCapture(T "cwd")
Check("working directory = the VoiceKit root, not the caller's", r.ok && r.value = WfRootDir(),
    r.value " vs " WfRootDir())
Check("...which is the folder holding lib\", FileExist(WfRootDir() "\lib\Workflow.ahk") != "")
r := WfCapture("cd")
Check("...for cmd's own commands too", r.ok && r.value = WfRootDir(), r.value)

; ---------- 2. UTF-8 ------------------------------------------------------
want := "caf" Chr(0xE9) " " Chr(0x2014) " na" Chr(0xEF) "ve"
r := WfCapture(T "unicode")
Check("UTF-8 output from a program decodes", r.ok && r.value = want, r.value)
; cmd's own echo: the nested cmd starts after chcp 65001, so it writes UTF-8
; too (a chcp in the SAME cmd leaves its echo in the OEM code page).
r := WfCapture("echo caf" Chr(0xE9) " " Chr(0x2014) " ok")
Check("cmd's echo of non-ASCII decodes", r.ok && r.value = "caf" Chr(0xE9) " " Chr(0x2014) " ok",
    r.value)
py := WfCapture('python -c "print(1)"', 20)
if (py.ok && py.value = "1") {
    r := WfCapture('python -c "print(\"caf\u00e9 \u2014 ok\")"', 20)
    Check("python's non-ASCII output decodes (PYTHONIOENCODING)",
        r.ok && r.value = "caf" Chr(0xE9) " " Chr(0x2014) " ok", r.value)
} else
    Say("SKIP  python output check (no python on PATH)")
Check("bytes that aren't UTF-8 fall back to the ANSI code page",
    WfDecodeTest() = "caf" Chr(0xE9))
WfDecodeTest() {
    b := Buffer(4)
    NumPut("UChar", 0x63, "UChar", 0x61, "UChar", 0x66, "UChar", 0xE9, b)   ; "caf" + CP1252 e-acute
    return WfDecodeBytes(b.Ptr, 4)
}

; A real cmd line: &, quotes and ! mean what they mean in cmd.
r := WfCapture('echo one& echo "two & three"! & echo four')
Check("a full cmd line (&, quotes, !) runs as written",
    r.ok && r.value = "one`n`"two & three`"! `nfour", "[" r.value "]")

; ---------- 3. failures: exit code, reason hygiene, the stderr tail -------
r := WfCapture(T "fail 3")
Check("nonzero exit fails", !r.ok && r.code = 3, r.code)
Check("...reason is only 'Command exited with code 3.'", r.reason = "Command exited with code 3.",
    r.reason)
Check("...stderr tail = the LAST 10 lines", InStr(r.errTail, "err line 15")
    && InStr(r.errTail, "err line 6") && !InStr(r.errTail, "err line 5`n")
    && StrSplit(r.errTail, "`n").Length = 10, StrReplace(r.errTail, "`n", " / "))
r := WfCapture(T "big")
Check("more than 1 MB of output fails, not truncates", !r.ok && InStr(r.reason, "1 MB"), r.reason)
r := WfCapture("   ")
Check("an empty command fails", !r.ok && r.reason != "")
long := ""
loop 8100
    long .= "x"
r := WfCapture("echo " long)
Check("a command past cmd's length limit fails before running", !r.ok && InStr(r.reason, "too long"),
    r.reason)
Check("timeout: junk/blank/zero -> 30", WfCaptureSecs("") = 30 && WfCaptureSecs("abc") = 30
    && WfCaptureSecs("0") = 30 && WfCaptureSecs("-5") = 30)
Check("timeout: a positive number is kept", WfCaptureSecs(" 2 ") = 2 && WfCaptureSecs("1.5") = 1.5)

; Through the engine: the RECORD and LOG carry no stderr and no resolved
; command -- a traceback, or a filled-in {{selected_file}}, names a client.
secret := fx "\Secret Client Invoice.pdf"
FileAppend("x", secret)
wfSelection := [secret]
try FileDelete(WfLogFile())
ok := RunWorkflowSteps([["capture", "Data", T "fail 3 {{selected_file}}", ""]], none)
rec := wfRun
Check("engine: a failing capture stops the run", ok = false && WfRunOutcome() = "failed"
    && rec["failed_step"] = 1, WfRunOutcome())
Check("engine: record reason = 'Command exited with code 3.'",
    rec["reason"] = "Command exited with code 3.", rec["reason"])
Check("engine: record never carries the resolved path or stderr",
    !InStr(rec["reason"] rec["step"], "Secret") && !InStr(rec["reason"] rec["step"], "err line"),
    rec["step"])
Check("engine: the step is recorded AS WRITTEN (placeholder, not value)",
    InStr(rec["step"], "{{selected_file}}"), rec["step"])
logTxt := ""
try logTxt := FileRead(WfLogFile(), "UTF-8")
Check("engine: the run log has neither the path nor stderr",
    logTxt != "" && !InStr(logTxt, "Secret") && !InStr(logTxt, "err line"))
Check("engine: quiet mode's tray note carries no stderr", !InStr(wfTrayLast, "err line"), wfTrayLast)

; ---------- 4. timeout kills the WHOLE tree; abort -> stopped -------------
pidFile := fx "\sleeper.pid"
try FileDelete(pidFile)
t0 := A_TickCount
r := WfCapture(T 'sleep "' pidFile '"', 2)
el := A_TickCount - t0
Check("timeout fails, naming the limit", !r.ok && InStr(r.reason, "after 2s"), r.reason)
Check("...and returns promptly", el < 6000, el " ms")
cpid := 0
try cpid := Integer(Trim(FileRead(pidFile)))
Sleep(300)
Check("...and the child under cmd is GONE (tree kill)", cpid && !ProcessExist(cpid), "pid " cpid)

try FileDelete(pidFile)
abortAt := A_TickCount + 1500
wfRunAbortCheck := () => A_TickCount >= abortAt
t0 := A_TickCount
ok := RunWorkflowSteps([["capture", "Never", T 'sleep "' pidFile '"', "60"]], none)
el := A_TickCount - t0
wfRunAbortCheck := ""
Check("abort mid-command: the run ends quietly as 'stopped'", ok = false
    && WfRunOutcome() = "stopped", WfRunOutcome())
Check("...promptly, not at the 60 s timeout", el < 8000, el " ms")
cpid := 0
try cpid := Integer(Trim(FileRead(pidFile)))
Sleep(300)
Check("...and the child is gone", cpid && !ProcessExist(cpid), "pid " cpid)

; ---------- 5. housekeeping ------------------------------------------------
left := 0
loop files A_Temp "\vk-capture-" myPid "-*"
    left += 1
Check("temp output files are deleted", left = 0, left " left")
Check("the env vars used to hand over the command are cleared",
    EnvGet("VK_CAPTURE_CMD") = "" && EnvGet("VK_CAPTURE_OUT") = "")

; ---------- 6. {{selected_file}} / {{selected_files}} in a command --------
p1 := fx "\Invoice & Co 2025.pdf", p2 := fx "\b.pdf"
FileAppend("x", p1)
FileAppend("y", p2)
wfSelection := [p1]
Check("command form: a bare {{selected_file}} arrives quoted",
    WfSubst("x {{selected_file}} y", none, true) = 'x "' p1 '" y')
Check("command form: quotes written around it are absorbed, not doubled",
    WfSubst('x "{{selected_file}}" y', none, true) = 'x "' p1 '" y')
Check("text form: {{selected_file}} stays the bare path", WfSubst("{{selected_file}}", none) = p1)
wfSelection := [p1, p2]
Check("command form: {{selected_files}} quoted either way",
    WfSubst("{{selected_files}}", none, true) = '"' p1 '" "' p2 '"'
    && WfSubst('"{{selected_files}}"', none, true) = '"' p1 '" "' p2 '"')
mine := Map()
mine.CaseSense := false
mine["selected_file"] := "C:\mine.txt"
Check("a user value named selected_file is never quoted for you",
    WfSubst("x {{selected_file}}", mine, true) = "x C:\mine.txt")
wfSelection := [p1]
sr := WfSubstStep(["run", "notepad {{selected_file}}", "", ""], none)
Check("run targets get the command form too", sr[2] = 'notepad "' p1 '"', sr[2])
sr := WfSubstStep(["capture", "{{selected_file}}", "echo {{selected_file}}", "{{selected_file}}"], none)
Check("capture: name and timeout never substituted, command is",
    sr[2] = "{{selected_file}}" && sr[4] = "{{selected_file}}" && sr[3] = 'echo "' p1 '"')
; cmd's quote parity decides: after a quoted script path it is OUTSIDE quotes
; (gets its own); inside a quoted argument the author opened it goes in bare.
Check("command form: after a quoted script path, still quoted",
    WfSubst('python "C:\t\invoice.py" {{selected_file}}', none, true) = 'python "C:\t\invoice.py" "' p1 '"')
Check("command form: inside the author's own quoted argument, bare",
    WfSubst('x "--in={{selected_file}}" y', none, true) = 'x "--in=' p1 '" y',
    WfSubst('x "--in={{selected_file}}" y', none, true))

; A failing run step whose target came from the selection: the record names
; the target AS WRITTEN, never the client's path.
wfSelection := [fx "\no such dir\Secret Client Invoice.pdf"]
ok := RunWorkflowSteps([["run", "{{selected_file}}", "", ""]], none)
Check("a failed run of {{selected_file}} records the placeholder, not the path",
    ok = false && wfRun["reason"] = "Couldn't open: {{selected_file}}", wfRun["reason"])
wfSelection := [p1]

; stdin is NUL: a prompt reads end-of-input instead of hanging to the timeout.
t0 := A_TickCount
r := WfCapture("set /p Q=prompt: & echo after", 20)
Check("a command that asks for input doesn't hang (stdin is NUL)",
    r.ok && InStr(r.value, "after") && A_TickCount - t0 < 8000, r.reason " / " r.value)

v := Map()
ok := RunWorkflowSteps([["capture", "Got", T "args {{selected_file}}", ""],
    ["capture", "Got2", T 'args "{{selected_file}}"', ""]], none, , v)
Check("{{selected_file}} flows into a command as ONE argument (spaces, &)",
    ok && v.Get("Got", "") = "1|" p1, v.Get("Got", "?"))
Check("...written with or without quotes", v.Get("Got2", "") = "1|" p1, v.Get("Got2", "?"))
wfSelection := [p1, p2]
v := Map()
ok := RunWorkflowSteps([["capture", "All", T "args {{selected_files}}", ""]], none, , v)
Check("{{selected_files}} arrives as one argument per file", ok
    && v.Get("All", "") = "2|" p1 "|" p2, v.Get("All", "?"))

; Two selected + the singular: refused BEFORE step 1 -- the command never runs.
mark := fx "\ran.txt"
try FileDelete(mark)
ok := RunWorkflowSteps([["capture", "X", T 'mark "' mark '" {{selected_file}}', ""]], none)
Sleep(200)
Check("two selected + {{selected_file}}: refused before step 1", ok = false
    && WfRunOutcome() = "error" && wfRun["failed_step"] = 0, WfRunOutcome())
Check("...and the command never ran", !FileExist(mark))

; ---------- 7. authoring helpers --------------------------------------------
st := [["capture", "Invoice Data", "python invoice.py {{selected_file}}", "90"],
       ["text", "{{Invoice Data}} {{Nope}}", "", ""]]
names := WfVarNames(st)
Check("a capture name is a defined value", names.Length = 1 && names[1] = "Invoice Data")
undef := WfUndefinedVars(st)
Check("...so {{Invoice Data}} isn't flagged (only {{Nope}} is)", undef.Length = 1 && undef[1] = "Nope")
Check("capture's command counts toward the selection check", WfSelectionNeeds(st) = 2)
Check("WfDesc shows the command, the name and the timeout",
    WfDesc(st[1]) = "Run  python invoice.py {{selected_file}}  and save its output as  {{Invoice Data}}    (up to 90s)",
    WfDesc(st[1]))

; ---------- 8. end to end: the value lands in a later step -----------------
title := "VKCaptureTest_ZZ"
tg := Gui("+AlwaysOnTop", title)
ed := tg.AddEdit("w420 r3")
tg.Show()
WinActivate("ahk_id " tg.Hwnd)
ControlFocus(ed.Hwnd, "ahk_id " tg.Hwnd)
Sleep(400)
wfSelection := [p1]
v := Map()
ok := RunWorkflowSteps([
    ["capture", "Data", T "echo INV-total=1,234", ""],
    ["set", "Line", "[{{Data}}]", ""],
    ["focus", title, "", ""],
    ["text", "{{Line}}", "", ""]], none, , v)
Sleep(200)
got := ed.Value
tg.Destroy()
Check("a captured value is typed by a later step", ok && got = "[INV-total=1,234]", "got: " got)
Check("...and is run-local (a named value, never collected)", v.Get("Data", "") = "INV-total=1,234")

; ---------- 9. Draft With AI refuses capture, keeps other paramC -----------
; NewAutomation.ahk is a GUI macro (it can't be #Included), so its REAL
; parser functions are lifted out of the source into a throwaway script in
; %TEMP% and run there. A copy written here would prove nothing.
src := FileRead(A_ScriptDir "\..\macros\NewAutomation.ahk", "UTF-8")
funcs := ""
for fn in ["ParseDraft", "ParseDraftInner", "DraftField", "DraftBalanceError"] {
    if RegExMatch(src, "ms)^" fn "\(.*?^\}", &m)
        funcs .= m[0] "`n`n"
    else
        Check("draft parser: found " fn " in NewAutomation.ahk", false)
}
root := WfRootDir()
dOut := fx "\draft.out"
dScript := fx "\draft-probe.ahk"
FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n"
    . '#Include "' root '\lib\Json.ahk"' "`n"
    . '#Include "' root '\lib\Workflow.ahk"' "`n"
    . funcs
    . "o := ''`n"
    . "s := ParseDraft('[{`"type`":`"text`",`"a`":`"x`"},{`"type`":`"capture`",`"a`":`"X`",`"b`":`"python x.py`",`"c`":`"30`"}]', &e)`n"
    . "o .= (IsObject(s) ? 'ACCEPTED' : 'REFUSED|' e) '``n'`n"
    . "s := ParseDraft('[{`"type`":`"waitfor`",`"a`":`"w`",`"b`":`"x`",`"c`":`"textvisible,30`"},{`"type`":`"text`",`"a`":`"hi`",`"c`":`"junk`"},{`"type`":`"drag`",`"a`":`"w`",`"c`":`"1,2,3,4`"}]', &e)`n"
    . "o .= IsObject(s) ? s[1][4] '|' s[2][4] '|' s[3][4] : 'ERR|' e`n"
    ; fill: paramC is the VALUE and must survive exactly; no label = refused
    . "s := ParseDraft('[{`"type`":`"fill`",`"a`":`"w`",`"b`":`"Amount#2`",`"c`":`" {{Inv}} 1,234.50`"}]', &e)`n"
    . "o .= '``n' (IsObject(s) ? 'FILL|' s[1][3] '|' s[1][4] : 'ERR|' e)`n"
    . "s := ParseDraft('[{`"type`":`"fill`",`"a`":`"w`",`"c`":`"x`"}]', &e)`n"
    . "o .= '``n' (IsObject(s) ? 'ACCEPTED' : 'REFUSED|' e)`n"
    . 'FileAppend(o, "' dOut '", "UTF-8")' "`nExitApp`n", dScript, "UTF-8")
Run('"' A_AhkPath '" /ErrorStdOut "' dScript '"', , "Hide", &dpid)
if ProcessWaitClose(dpid, 20)           ; bounded: a runtime error dialog must not wedge the suite
    ProcessClose(dpid)
dres := ""
try dres := FileRead(dOut, "UTF-8")
dl := StrSplit(dres, "`n")
Check("Draft With AI: a capture step is refused, by name",
    dl.Length >= 1 && InStr(dl[1], "REFUSED|") = 1 && InStr(dl[1], "capture")
    && InStr(dl[1], "Workflow Studio"), dres)
Check("...while waitfor/drag keep paramC and junk paramC is dropped",
    dl.Length >= 2 && dl[2] = "textvisible,30||1,2,3,4", dres)
Check("...a fill keeps its label and its VALUE (paramC) exactly",
    dl.Length >= 3 && dl[3] == "FILL|Amount#2| {{Inv}} 1,234.50", dres)
Check("...and a fill with no box label is refused", dl.Length >= 4 && InStr(dl[4], "REFUSED|") = 1
    && InStr(dl[4], "fill"), dres)

wfRunQuiet := false
SetWorkingDir(A_ScriptDir)
try DirDelete(fx, true)
TestEnd()
