#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Self-test for the `module` step (lib\Workflow.ahk WfModuleRun):
;  module|<module phrase>|<seconds>| -- run an isolated hotkey
;  module's body and wait for it to finish.
;
;  Everything runs against a SANDBOX VoiceKit tree in %TEMP%
;  (wfModuleRoot): its own bridge-map.txt, hotkeys\bodies\ and a
;  copy of lib\_Common.ahk for the bodies' #Include -- never the
;  user's bridge map, modules or logs. The bodies are throwaway
;  scripts written here. Runs are quiet (no failure MsgBox can
;  wedge the suite), run logs go to %TEMP%. ASCII only.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"
#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("engine-module-selftest")
wfLogFolder := A_Temp "\vk-selftest-logs"   ; keep test runs out of the user's real run history
wfTrayOff := true
wfRunQuiet := true
wfRunName := "VKModuleTest"

sbox := A_Temp "\vk-module-selftest"
try DirDelete(sbox, true)
DirCreate(sbox "\hotkeys\bodies")
DirCreate(sbox "\lib")
DirCreate(sbox "\logs")
FileCopy(A_ScriptDir "\..\lib\_Common.ahk", sbox "\lib\_Common.ahk")
wfModuleRoot := sbox

; ---------- the sandbox: bridge map + bodies ------------------------------
FileAppend("; sandbox bridge map`n"
    . "Ctrl+Alt+Shift+A|open mod ok|hotkeys\ModOk.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+B|mod fail|hotkeys\ModFail.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+D|mod crash|hotkeys\ModCrash.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+F|mod slow|hotkeys\ModSlow.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+G|mod inproc|hotkeys\ModInproc.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+J|open mod companion|hotkeys\ModCompanion.hotkey.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+K|mod handled|hotkeys\ModHandled.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+L|mod badload|hotkeys\ModBadLoad.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+M|mod typer|hotkeys\ModTyper.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+P|mod handled box|hotkeys\ModHandledBox.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+Q|mod stopped|hotkeys\ModStopped.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+S|mod testmode|hotkeys\ModTestMode.ahk|2026-10-12`n"
    . "Ctrl+Alt+Shift+T|mod testcrash|hotkeys\ModTestCrash.ahk|2026-10-12`n"
    . "; Ctrl+Alt+Shift+O|mod parked|hotkeys\ModParked.ahk|2026-10-12`n",
    sbox "\bridge-map.txt", "UTF-8")
head := "#Requires AutoHotkey v2.0`n#SingleInstance Ignore`n"
    . '#Include "%A_ScriptDir%\..\..\lib\_Common.ahk"' "`n"
MakeBody(base, code) {
    global sbox, head
    FileAppend(head 'BodySingleInstance("' base '")' "`n" code "`n", sbox "\hotkeys\bodies\" base ".body.ahk", "UTF-8")
}
MakeBody("ModOk", 'FileAppend("scoped=" VkModuleScoped() " env=[" EnvGet("VOICEKIT_MODULE_SCRIPT") "]``n", A_ScriptDir "\..\..\ok.marker", "UTF-8")`nExitApp(0)')
MakeBody("ModFail", 'BodyStatus("ModFail", "failing on Client X")`nExitApp(1)')
MakeBody("ModCrash", 'x := 1`nx.NoSuchMethod()`nFileAppend("continued", A_ScriptDir "\..\..\crash.marker")`nExitApp(0)')
MakeBody("ModHandled", 'OnError((e, m) => 1)`nx := 1`nx.NoSuchMethod()`nExitApp(0)')
MakeBody("ModSlow", 'Run(Chr(34) A_AhkPath Chr(34) " " Chr(34) A_ScriptDir "\..\..\sleeper.ahk" Chr(34), , , &cpid)`n'
    . 'FileAppend(cpid, A_ScriptDir "\..\..\slow.child", "UTF-8")`nSleep(60000)`nExitApp(0)')
; Fails CLOSED: run without the dry-run shim (a regression in WfModuleRun's
; shim propagation), it would type into whatever window is active -- so it
; refuses, leaving typer.live, unless every Send it makes is the shim's.
MakeBody("ModTyper", 'if !VkDryRun() || Send.IsBuiltIn {`n'
    . '    FileAppend("LIVE", A_ScriptDir "\..\..\typer.live", "UTF-8")`n    ExitApp(1)`n}`n'
    . 'FileAppend("reached", A_ScriptDir "\..\..\typer.reached", "UTF-8")`n'
    . 'Send("hello{Enter}")`nFileAppend("ran", A_ScriptDir "\..\..\typer.marker", "UTF-8")`nExitApp(0)')
; Its own OnError handler shows a MsgBox and returns 1 (handled). The
; handler's MsgBox must NOT be taken for AutoHotkey's error dialog. Nothing
; reaches the screen: the body's own CBT hook (installed after, so called
; first) passes the creation down the chain to VkModuleCbt -- which would
; end the process right there if it mistook the MsgBox -- and then vetoes it.
MakeBody("ModHandledBox", 'OnError(Handler)`n'
    . 'Handler(e, m) {`n'
    . '    hk := DllCall("SetWindowsHookExW", "Int", 5, "Ptr", CallbackCreate(Veto, "F", 3), "Ptr", 0, "UInt", DllCall("GetCurrentThreadId", "UInt"), "Ptr")`n'
    . '    try MsgBox("Could not finish: " e.Message)`n'
    . '    DllCall("UnhookWindowsHookEx", "Ptr", hk)`n'
    . '    FileAppend("survived", A_ScriptDir "\..\..\box.marker", "UTF-8")`n'
    . '    return 1`n}`n'
    . 'Veto(n, w, l) {`n'
    . '    r := DllCall("CallNextHookEx", "Ptr", 0, "Int", n, "Ptr", w, "Ptr", l, "Ptr")`n'
    . '    if (n = 3) {`n'
    . '        cls := Buffer(64, 0)`n'
    . '        DllCall("GetClassNameW", "Ptr", w, "Ptr", cls, "Int", 32)`n'
    . '        if (StrGet(cls) = "#32770") {`n'
    . '            FileAppend("vetoed ", A_ScriptDir "\..\..\box.marker", "UTF-8")`n'
    . '            return 1`n'
    . '        }`n'
    . '    }`n'
    . '    return r`n}`n'
    . 'x := 1`nx.NoSuchMethod()`nExitApp(0)')
; Stops cooperatively the way the template does (a stop request -> ExitApp()).
MakeBody("ModStopped", 'FileAppend("", BodyStopFile("ModStopped"))`n'
    . 'if BodyStopRequested("ModStopped")`n    ExitApp()`nExitApp(0)')
; What a body sees when a TEST run of a workflow runs it.
MakeBody("ModTestMode", 'FileAppend("test=" VkTestMode() " scoped=" VkRunScoped() " result=[" EnvGet("VOICEKIT_RESULT_FILE") "]", A_ScriptDir "\..\..\testmode.marker", "UTF-8")`nExitApp(0)')
MakeBody("ModTestCrash", 'x := 1`nx.NoSuchMethodZz()`nExitApp(0)')
FileAppend("#Requires AutoHotkey v2.0`nx := (`n", sbox "\hotkeys\bodies\ModBadLoad.body.ahk", "UTF-8")
FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`nSleep(60000)`nExitApp(0)`n", sbox "\sleeper.ahk", "UTF-8")
; ModInproc has no body (it would run inside VoiceKit.ahk); ModParked is
; commented out; ModCompanion is a keyboard shortcut for something else.

; ---------- 1. resolving the module ---------------------------------------
ResolveMod(name) => WfModuleResolve(name)
m := ResolveMod("open mod ok")
Check("exact phrase resolves to the body", m.kind = "ok" && m.module = "ModOk"
    && m.body = sbox "\hotkeys\bodies\ModOk.body.ahk", m.kind " " m.module " " m.body)
Check("caseless + trimmed", ResolveMod("  OPEN MOD OK ").module = "ModOk")
Check("without the leading 'open '", ResolveMod("mod ok").module = "ModOk" && ResolveMod("Mod OK").phrase = "open mod ok")
Check("with an 'open ' the map lacks", ResolveMod("open mod fail").module = "ModFail")
Check("by the module's file base", ResolveMod("ModOk").module = "ModOk" && ResolveMod("Mod Crash").module = "ModCrash")
Check("unknown -> unknown", ResolveMod("nothing like it").kind = "unknown" && ResolveMod("").kind = "unknown")
Check("a commented-out (parked) entry isn't a module", ResolveMod("mod parked").kind = "unknown")
Check("a companion shortcut is refused as such", ResolveMod("open mod companion").kind = "companion")
Check("no body -> runs inside VoiceKit", ResolveMod("mod inproc").kind = "inprocess")
ch := WfModuleChoices()
lst := ""
for c in ch
    lst .= c.module " "
Check("the Studio's choices are the isolated modules, in map order",
    Trim(lst) = "ModOk ModFail ModCrash ModSlow ModHandled ModBadLoad ModTyper ModHandledBox "
    . "ModStopped ModTestMode ModTestCrash", lst)

; ---------- 2. seconds + description --------------------------------------
Check("seconds: blank -> 60", WfModuleSecs("") = 60)
Check("seconds: a number is kept", WfModuleSecs(" 5 ") = 5 && WfModuleSecs("1.5") = 1.5)
Check("seconds: junk / zero / negative -> 60",
    WfModuleSecs("abc") = 60 && WfModuleSecs("0") = 60 && WfModuleSecs("-3") = 60)
Check("seconds: capped at an hour", WfModuleSecs("99999") = 3600)
d := WfDesc(["module", "open mod ok", "", ""])
Check("description names the module and the default wait", InStr(d, "open mod ok") && InStr(d, "60s"), d)
Check("the module name is never substituted",
    WfSubstStep(["module", "{{M}}", "{{S}}", ""], Map("M", "mod fail", "S", "1"))[2] = "{{M}}")

; ---------- 3. success -----------------------------------------------------
t0 := A_TickCount
r := WfModuleRun("open mod ok", 30)
Check("exit 0 = ok", r.ok && r.code = 0, r.reason)
mk := ""
try mk := Trim(FileRead(sbox "\ok.marker", "UTF-8"), "`r`n ")
Check("the body knew it was run by a module step (scoped)", InStr(mk, "scoped=1 ") = 1, mk)
Check("...and dropped the variables from its own environment at load (its children never inherit them)",
    InStr(mk, "env=[]"), mk)
Check("the engine's environment is restored afterwards",
    EnvGet("VOICEKIT_MODULE_SCRIPT") = "" && EnvGet("VOICEKIT_MODULE_ERROR") = "")
; a voice/hotkey press of the same body sets nothing: run it the launcher's way
try FileDelete(sbox "\ok.marker")
RunWait('"' A_AhkPath '" "' sbox '\hotkeys\bodies\ModOk.body.ahk"')
mk := ""
try mk := Trim(FileRead(sbox "\ok.marker", "UTF-8"), "`r`n ")
Check("a plain launch of the body is NOT scoped", InStr(mk, "scoped=0 ") = 1, mk)

ok := RunWorkflowSteps([["module", "mod ok", "", ""], ["set", "after", "yes", ""]], Map())
Check("a workflow with a module step finishes ok", ok && wfRun["outcome"] = "ok", wfRun.Get("reason", ""))

; ---------- 4. a body that says it failed (ExitApp(1)) --------------------
r := WfModuleRun("mod fail", 30)
Check("ExitApp(1) fails the step", !r.ok && r.code = 1, r.reason)
Check("...reason names the module and the code only",
    r.reason = "Module 'mod fail' failed (exit code 1).", r.reason)
Check("...its last status line goes to the local popup detail", InStr(r.detail, "failing on Client X"), r.detail)
ok := RunWorkflowSteps([["module", "mod fail", "", ""], ["set", "after", "yes", ""]], Map())
Check("the workflow stops at the module step", !ok && wfRun["outcome"] = "failed"
    && wfRun["failed_step"] = 1, wfRun.Get("outcome", ""))
Check("...the run record carries no body text", wfRun["reason"] = "Module 'mod fail' failed (exit code 1)."
    && !InStr(wfRun["reason"], "Client"), wfRun["reason"])

; ---------- 5. uncaught error -> exit 3, no dialog ------------------------
t0 := A_TickCount
r := WfModuleRun("mod crash", 20)
el := A_TickCount - t0
Check("an uncaught error ends the body with exit 3", !r.ok && r.code = 3, r.reason " code=" r.code)
Check("...at once (no error dialog holding it open)", el < 10000, el " ms")
Check("...and nothing after the error ran", !FileExist(sbox "\crash.marker"))
Check("...the error text reaches the local detail only", InStr(r.detail, "NoSuchMethod")
    && !InStr(r.reason, "NoSuchMethod"), r.detail)
elog := ""
try elog := FileRead(sbox "\logs\errors.log", "UTF-8")
Check("...and errors.log got its usual line", InStr(elog, "ModCrash.body.ahk") && InStr(elog, "NoSuchMethod"), elog)
r := WfModuleRun("mod handled", 20)
Check("an error the body's own OnError handles is not a failure", r.ok, r.reason " code=" r.code)
try FileDelete(sbox "\box.marker")
r := WfModuleRun("mod handled box", 20)
bm := ""
try bm := FileRead(sbox "\box.marker", "UTF-8")
Check("a handler that shows its OWN MsgBox isn't killed as if it were the error dialog",
    r.ok && r.code = 0, r.reason " code=" r.code " marker=" bm)
Check("...its MsgBox was created (then vetoed by the body itself) and the handler finished",
    bm = "vetoed survived", bm)

; ---------- 5b. a cooperative stop is not success --------------------------
r := WfModuleRun("mod stopped", 20)
Check("a body that stopped on a stop request (ExitApp() = exit 0) fails the step",
    !r.ok && r.code = 0 && r.reason = "Module 'mod stopped' was stopped before it finished.", r.reason)
stale := ""
Loop Files A_Temp "\vk-module-" DllCall("GetCurrentProcessId", "uint") "-*.stopped"
    stale .= A_LoopFileName " "
Check("...and its stop marker is cleaned up", stale = "", stale)

; ---------- 6. a body that doesn't load -> exit 2, no dialog --------------
t0 := A_TickCount
r := WfModuleRun("mod badload", 20)
Check("a body with a load error exits 2 at once", !r.ok && r.code = 2 && A_TickCount - t0 < 10000,
    r.reason " " (A_TickCount - t0) " ms")
Check("...and the popup says why", InStr(r.detail, "doesn't load"), r.detail)

; ---------- 7. timeout kills the whole tree --------------------------------
try FileDelete(sbox "\slow.child")
t0 := A_TickCount
r := WfModuleRun("mod slow", 2)
el := A_TickCount - t0
Check("a timeout fails the step", !r.ok && !r.aborted
    && r.reason = "Module 'mod slow' didn't finish within 2 s and was stopped.", r.reason)
Check("...promptly", el < 8000, el " ms")
cpid := 0
try cpid := Integer(Trim(FileRead(sbox "\slow.child", "UTF-8")))
Sleep(300)
Check("...and the body's own child process is gone too", cpid && !ProcessExist(cpid), "child pid " cpid)
Check("...and the body itself", !WfCommonFn("BodyMutexHeld")("ModSlow"))

; ---------- 8. Stop --------------------------------------------------------
SlowChild() {
    global sbox
    cpid := 0
    try cpid := Integer(Trim(FileRead(sbox "\slow.child", "UTF-8")))
    try FileDelete(sbox "\slow.child")
    Sleep(300)
    return cpid
}
try FileDelete(sbox "\slow.child")
stopAt := A_TickCount + 1000
wfRunAbortCheck := () => A_TickCount >= stopAt
t0 := A_TickCount
r := WfModuleRun("mod slow", 30)
Check("Stop ends a running module (aborted, quiet)", !r.ok && r.aborted && A_TickCount - t0 < 8000,
    r.reason " " (A_TickCount - t0) " ms")
cpid := SlowChild()
Check("...and its tree is gone", cpid && !ProcessExist(cpid), "child pid " cpid)
stopAt := A_TickCount + 1000
ok := RunWorkflowSteps([["module", "mod slow", "30", ""]], Map())
Check("...a stopped workflow records 'stopped'", !ok && wfRun["outcome"] = "stopped", wfRun["outcome"])
wfRunAbortCheck := ""
cpid := SlowChild()
Check("...and that tree is gone too", cpid && !ProcessExist(cpid), "child pid " cpid)

; ---------- 9. refusals -----------------------------------------------------
h := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "WStr", BodyMutexName("ModOk"), "Ptr")
r := WfModuleRun("open mod ok", 10)
DllCall("CloseHandle", "Ptr", h)
Check("an already-running body is refused (it would exit 0 at once)",
    !r.ok && InStr(r.reason, "already running") && r.code = "", r.reason)
r := WfModuleRun("mod inproc", 10)
Check("a module inside VoiceKit is refused, saying so", !r.ok && InStr(r.reason, "isn't isolated"), r.reason)
r := WfModuleRun("no such module", 10)
Check("an unknown module is refused", !r.ok && InStr(r.reason, "No hotkey module answers"), r.reason)
r := WfModuleRun("open mod companion", 10)
Check("a companion shortcut is refused", !r.ok && InStr(r.reason, "not a hotkey module"), r.reason)
; A mutex we may not open (an elevated body's, in real life) is still held:
; an empty DACL denies SYNCHRONIZE to everyone, so OpenMutexW gets error 5.
sd := Buffer(64, 0), acl := Buffer(8, 0), sa := Buffer(A_PtrSize * 3, 0)
DllCall("advapi32\InitializeSecurityDescriptor", "Ptr", sd, "UInt", 1)
DllCall("advapi32\InitializeAcl", "Ptr", acl, "UInt", 8, "UInt", 2)
DllCall("advapi32\SetSecurityDescriptorDacl", "Ptr", sd, "Int", 1, "Ptr", acl, "Int", 0)
NumPut("UInt", sa.Size, sa, 0), NumPut("Ptr", sd.Ptr, sa, A_PtrSize)
h := DllCall("CreateMutexW", "Ptr", sa, "Int", 0, "WStr", BodyMutexName("ModTestMode"), "Ptr")
held := BodyMutexHeld("ModTestMode")
r := WfModuleRun("mod testmode", 10)
DllCall("CloseHandle", "Ptr", h)
Check("an access-denied mutex counts as held (as voicekit_writer _body_mutex_held)", h && held, "h=" h)
Check("...so the step refuses it", !r.ok && InStr(r.reason, "already running"), r.reason)
Check("...and a mutex nobody holds is not", !BodyMutexHeld("ModTestMode"))

; ---------- 10. a dry run of the workflow dry-runs the body ----------------
; A host under lib\DryRunShim.ahk (as run_automation(dry_run=True) loads a
; stub) runs the module step: the body must run under the same shim, so its
; Send is LOGGED, not typed.
host := sbox "\host.ahk"
FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n"
    . '#Include "' A_ScriptDir '\..\lib\_Common.ahk"' "`n"
    . '#Include "' A_ScriptDir '\..\lib\Workflow.ahk"' "`n"
    . 'wfModuleRoot := "' sbox '"' "`n"
    . 'r := WfModuleRun("mod typer", 20)' "`n"
    . 'FileAppend(r.ok "|" r.reason, "' sbox '\host.out", "UTF-8")' "`n"
    . "ExitApp(0)`n", host, "UTF-8")
tlog := sbox "\test-log.txt"
EnvSet("VOICEKIT_TEST_LOG", tlog)
hpid := 0
SetTimer(KillHost, -30000)
KillHost() {
    global hpid
    if hpid
        WfKillTree(hpid)
}
RunWait('"' A_AhkPath '" /ErrorStdOut /include "' A_ScriptDir '\..\lib\DryRunShim.ahk" "' host '"', sbox, "Hide", &hpid)
SetTimer(KillHost, 0)
EnvSet("VOICEKIT_TEST_LOG")
hout := "", tl := ""
try hout := FileRead(sbox "\host.out", "UTF-8")
try tl := FileRead(tlog, "UTF-8")
Check("a dry-run host's module step finishes", SubStr(hout, 1, 2) = "1|", hout)
Check("...the body ran under the dry-run shim (it never took the live path)",
    !FileExist(sbox "\typer.live") && FileExist(sbox "\typer.reached") != "")
Check("...the body ran (its own file write is real)", FileExist(sbox "\typer.marker") != "")
Check("...but its Send was logged, not sent", InStr(tl, '"kind":"input"') && InStr(tl, '"fn":"Send"')
    && InStr(tl, "hello{Enter}"), tl)

; ---------- 11. a TEST run of the workflow makes the body a test run -------
; A host under lib\TestShim.ahk with the run variables run_automation(test=True)
; sets for a stub. The body must see VkTestMode() (so it can skip a real side
; effect), keep its uncaught error out of the user's errors.log, and log it
; to the shared test log tagged with ITS script; the host's variables come back.
host2 := sbox "\host2.ahk"
FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n"
    . '#Include "' A_ScriptDir '\..\lib\_Common.ahk"' "`n"
    . '#Include "' A_ScriptDir '\..\lib\Workflow.ahk"' "`n"
    . 'wfModuleRoot := "' sbox '"' "`n"
    . 'r1 := WfModuleRun("mod testmode", 20)' "`n"
    . 'r2 := WfModuleRun("mod testcrash", 20)' "`n"
    . 'FileAppend(r1.ok "|" r2.code "|" (EnvGet("VOICEKIT_RUN_SCRIPT") = A_ScriptFullPath) "|" EnvGet("VOICEKIT_RESULT_FILE"), "' sbox '\host2.out", "UTF-8")' "`n"
    . "ExitApp(0)`n", host2, "UTF-8")
tlog2 := sbox "\test-log2.txt"
EnvSet("VOICEKIT_TEST_LOG", tlog2)
EnvSet("VOICEKIT_TEST", "1")
EnvSet("VOICEKIT_RUN_SCRIPT", host2)
EnvSet("VOICEKIT_RESULT_FILE", sbox "\result2.txt")
hpid := 0
SetTimer(KillHost, -30000)
RunWait('"' A_AhkPath '" /ErrorStdOut /include "' A_ScriptDir '\..\lib\TestShim.ahk" "' host2 '"', sbox, "Hide", &hpid)
SetTimer(KillHost, 0)
for k in ["VOICEKIT_TEST_LOG", "VOICEKIT_TEST", "VOICEKIT_RUN_SCRIPT", "VOICEKIT_RESULT_FILE"]
    EnvSet(k)
hout := "", tl := "", tm := "", elog := ""
try hout := FileRead(sbox "\host2.out", "UTF-8")
try tl := FileRead(tlog2, "UTF-8")
try tm := FileRead(sbox "\testmode.marker", "UTF-8")
try elog := FileRead(sbox "\logs\errors.log", "UTF-8")
hp := StrSplit(hout, "|")
Check("under a test-run host, the body is in test mode (VkTestMode, scoped to it, no result file)",
    tm = "test=1 scoped=1 result=[]", tm)
Check("...the module step still succeeds", hp.Length >= 1 && hp[1] = "1", hout)
Check("...a crashing body ends with exit 3", hp.Length >= 2 && hp[2] = "3", hout)
Check("...and stays out of the user's errors.log", !InStr(elog, "NoSuchMethodZz"), elog)
Check("...its error lands in the shared test log, tagged with the BODY's script",
    InStr(tl, '"kind":"error"') && InStr(tl, "NoSuchMethodZz") && InStr(tl, "ModTestCrash.body.ahk"), tl)
Check("...and the host's own run variables are restored",
    hp.Length >= 4 && hp[3] = "1" && hp[4] = sbox "\result2.txt", hout)

try DirDelete(sbox, true)
TestEnd()
