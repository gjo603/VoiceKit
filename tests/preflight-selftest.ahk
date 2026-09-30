#Requires AutoHotkey v2.0
; Self-test for lib\_Common.ahk: the reload-preflight helpers (the machinery
; that keeps one bad module from taking the whole master down) and the body
; status channel the home window reads.
; Fixtures are written under %TEMP% — nothing lands in the repo.
; Writes PASS/FAIL to preflight-selftest.result — never pops a dialog.
#Include "%A_ScriptDir%\..\lib\_Common.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("preflight-selftest")

; ---- fixtures (in %TEMP%, cleaned at the end) -----------------------
dir := A_Temp "\vk-preflight-selftest"
DirCreate(dir)
good := dir "\fx_good.ahk"
bad  := dir "\fx_bad.ahk"
try FileDelete(good)
try FileDelete(bad)
FileAppend("#Requires AutoHotkey v2.0`nx := 1`n", good, "UTF-8")
FileAppend("#Requires AutoHotkey v2.0`nMsgBox(`"unterminated`n", bad, "UTF-8")

; ---- 1. AhkValidate on a good file ----------------------------------
v := AhkValidate(good)
Check("AhkValidate(good).ok", v.ok = true)

; ---- 2. AhkValidate on a broken file: must capture the ERROR TEXT ----
v := AhkValidate(bad)
Check("AhkValidate(bad).ok is false", v.ok = false)
Check("AhkValidate(bad) captured stdout", v.text != "", "text=" SubStr(StrReplace(v.text, "`n", " | "), 1, 90))
Check("error text names the file", InStr(v.text, "fx_bad.ahk") > 0)

; ---- 3. MasterErrorModule picks a hotkeys\ module -------------------
e1 := 'C:\Automations\VoiceKit\hotkeys\Foo.ahk (12) : ==> Missing "}"' "`n     Specifically: blah"
Check("MasterErrorModule finds module", MasterErrorModule(e1) = "hotkeys\Foo.ahk",
    "got=" MasterErrorModule(e1))

; a path with spaces still parses
e2 := 'C:\My Voice Kit\hotkeys\Bar Baz.ahk (3) : ==> Missing ")"'
Check("MasterErrorModule handles spaces", MasterErrorModule(e2) = "hotkeys\Bar Baz.ahk",
    "got=" MasterErrorModule(e2))

; ---- 4. a broken CORE file is NOT parkable --------------------------
e3 := "C:\Automations\VoiceKit\lib\Acc.ahk (40) : ==> Missing `"}`""
Check("MasterErrorModule refuses lib\", MasterErrorModule(e3) = "", "got=" MasterErrorModule(e3))
Check("MasterErrorModule refuses empty", MasterErrorModule("") = "")

; ---- 5. CommentOutLinesContaining ----------------------------------
idx := dir "\fx_index.ahk"
try FileDelete(idx)
FileAppend('#Include "%A_ScriptDir%\hotkeys\Keep.ahk"' "`n"
    . '#Include "%A_ScriptDir%\hotkeys\Foo.ahk"' "`n"
    . '; #Include "%A_ScriptDir%\hotkeys\Already.ahk"' "`n", idx, "UTF-8")

hit := CommentOutLinesContaining(idx, "\hotkeys\Foo.ahk", "quarantined selftest")
txt := FileRead(idx, "UTF-8")
Check("CommentOut reports a hit", hit = true)
Check("target line commented", InStr(txt, '; #Include "%A_ScriptDir%\hotkeys\Foo.ahk"    quarantined') > 0)
Check("untouched line intact", InStr(txt, "`n#Include `"%A_ScriptDir%\hotkeys\Keep.ahk`"") > 0
    || InStr(txt, '#Include "%A_ScriptDir%\hotkeys\Keep.ahk"') = 1)
; Build the needles from Chr(59): a space-preceded ";" inside a string
; literal starts a comment in AHK v2 (the trap this whole file exercises).
semi := Chr(59)
Check("already-commented not doubled",
    !InStr(txt, semi semi " #Include") && !InStr(txt, semi " " semi " #Include"))
Check("no-match returns false", CommentOutLinesContaining(idx, "\hotkeys\Nope.ahk") = false)

; ---- 6. the parked file really is out of the build ------------------
; A file that #Includes the fixture index must now LOAD, because the
; broken module's line is commented out.
host := dir "\fx_host.ahk"
brokenMod := dir "\hotkeys_broken.ahk"
try FileDelete(host)
try FileDelete(brokenMod)
FileAppend("#Requires AutoHotkey v2.0`nMsgBox(`"unterminated`n", brokenMod, "UTF-8")
idx2 := dir "\fx_index2.ahk"
try FileDelete(idx2)
FileAppend('#Include "' brokenMod '"' "`n", idx2, "UTF-8")
FileAppend('#Requires AutoHotkey v2.0`n#Include "' idx2 '"`n', host, "UTF-8")
Check("host with broken module fails", AhkValidate(host).ok = false)
CommentOutLinesContaining(idx2, "hotkeys_broken.ahk", "quarantined selftest")
Check("host loads once parked", AhkValidate(host).ok = true)

; ---- 7. body status -------------------------------------------------
; A long-running hotkey body publishes where it has got to; the home window
; reads it back. Both halves live in _Common.ahk, so this is where they are
; tested. `dir` stands in for the repo root, so nothing touches the user's
; real logs\ folder. (The Python read half has its own conformance test —
; it parses the same file independently.)
Check("nothing published yet reads as nothing", BodyStatusRead("ZzProbe", dir) = "")
BodyStatus("ZzProbe", "3 / 766  -  Acme Holdings", dir)
st := BodyStatusRead("ZzProbe", dir)
Check("a published line reads back", IsObject(st))
Check("...with its text intact", IsObject(st) && st.text = "3 / 766  -  Acme Holdings",
    IsObject(st) ? st.text : "nothing")
Check("...and an age in seconds", IsObject(st) && IsInteger(st.age) && st.age >= 0 && st.age < 120,
    IsObject(st) ? "age=" st.age : "nothing")
BodyStatusDone("ZzProbe", "766 done", dir)
Check("publishing again overwrites (it is 'where am I', not a log)",
    BodyStatusRead("ZzProbe", dir).text = "766 done")
; A multi-line status would break the one-line format both readers assume.
BodyStatus("ZzProbe", "line one`nline two", dir)
Check("newlines are folded so the format survives",
    !InStr(BodyStatusRead("ZzProbe", dir).text, "`n"), BodyStatusRead("ZzProbe", dir).text)
; The base names the file, so it must not be able to escape logs\.
BodyStatus("../../evil Zz", "nope", dir)
Check("a hostile base is sanitized, not obeyed",
    !DirExist(dir "\..\..\evil") && FileExist(dir "\logs\body-status-evilZz.txt"))
BodyStatusClear("ZzProbe", dir)
Check("clearing removes it", BodyStatusRead("ZzProbe", dir) = "")

; ---- 8. RobustMove --------------------------------------------------
; The "move a file an app just touched" race, extracted from Split Pages
; (2026-08-05 feedback): a rename is blocked by ANY open handle without
; delete-sharing, so RobustMove retries, then falls back to copying (a
; read lock blocks renaming, not reading), and never throws.
mvSrc := dir "\mv_src.txt", mvDst := dir "\mv_dst.txt"
FileAppend("payload", mvSrc, "UTF-8")
Check("RobustMove moves an unheld file", RobustMove(mvSrc, mvDst, 300) = "moved")
Check("...source gone", !FileExist(mvSrc))
Check("...destination there", FileExist(mvDst) != "")

; The viewer-style lock: a handle sharing read/write but DENYING delete —
; rename blocked, reading allowed. Exactly what a PDF viewer holds for a
; beat after its window closes.
lk := dir "\mv_locked.txt", lkDst := dir "\mv_locked_dst.txt"
FileAppend("payload2", lk, "UTF-8")
h := FileOpen(lk, "r-d")
got := RobustMove(lk, lkDst, 400)
Check("a delete-denying lock falls back to copy", got = "copied", "got=" got)
Check("...destination has the bytes", FileRead(lkDst, "UTF-8") = "payload2")
Check("...source left behind for later cleanup", FileExist(lk) != "")
h.Close()

; An exclusive lock beats even the copy: quiet "", no exception, nothing
; half-written.
h2 := FileOpen(lk, "r-rwd")
got2 := RobustMove(lk, dir "\mv_never.txt", 300)
Check("an exclusive lock fails quietly", got2 = "", "got=" got2)
Check("...nothing written", !FileExist(dir "\mv_never.txt"))
h2.Close()
Check("a missing source fails quietly too", RobustMove(dir "\mv_ghost.txt", dir "\mv_x.txt", 100) = "")

; ---- 9. uncaught-error capture --------------------------------------
; _Common.ahk registers LogUncaughtError during its include, so a macro
; that dies leaves its error text in logs\errors.log instead of only a
; dismissed dialog (2026-08-05 feedback: "it keeps crashing" had to be
; reconstructed by interview). The helpers first, then the real thing:
; a child process that includes a COPY of _Common (so its A_LineFile-
; derived root is our fixture dir, and the user's real log stays clean)
; and throws.
line := ErrorLogLine(Error("boom message"))
Check("ErrorLogLine carries the message", InStr(line, "boom message") > 0, line)
Check("ErrorLogLine names file and line", InStr(line, "preflight-selftest.ahk line ") > 0, line)
Check("ErrorLogLine survives a non-Error throw", ErrorLogLine("bare string") = "bare string")
ErrorLogAppend("probe line Zz", dir)
Check("ErrorLogAppend writes under the given root",
    InStr(FileRead(dir "\logs\errors.log", "UTF-8"), "probe line Zz") > 0)

DirCreate(dir "\lib")
FileCopy(A_ScriptDir "\..\lib\_Common.ahk", dir "\lib\_Common.ahk", 1)
child := dir "\fx_err.ahk"
try FileDelete(child)
; The child suppresses the error DIALOG with its own OnError registered
; AFTER the include — _Common's logger runs first (registration order),
; then this returns 1 so RunWait comes straight back instead of wedging
; on a modal.
FileAppend("#Requires AutoHotkey v2.0`n"
    . "#SingleInstance Off`n"
    . '#Include "' dir '\lib\_Common.ahk"' "`n"
    . "OnError((e, m) => 1)`n"
    . 'throw Error("BoomProbeZz")' "`n", child, "UTF-8")
RunWait('"' A_AhkPath '" /ErrorStdOut "' child '"', , "Hide")
errTxt := ""
try errTxt := FileRead(dir "\logs\errors.log", "UTF-8")
Check("an uncaught error lands in errors.log", InStr(errTxt, "BoomProbeZz") > 0,
    SubStr(StrReplace(errTxt, "`n", " | "), 1, 120))
Check("...tagged with the script that hit it", InStr(errTxt, "| fx_err.ahk |") > 0)
Check("...naming the failing line", InStr(errTxt, "line 5") > 0)

; ---- 10. a module file that no longer exists ------------------------
; AutoHotkey blames the MANIFEST for a missing #Include, not the module:
;   ...\hotkeys\_index.ahk (3) : ==> #Include file "...\hotkeys\Gone.ahk" cannot be opened.
; and the manifest can't park itself — so the preflight used to refuse
; every reload, and the launcher refused to start VoiceKit at login.
eMiss := 'C:\VK\hotkeys\_index.ahk (3) : ==> #Include file "C:\VK\hotkeys\Gone Module.ahk" cannot be opened.'
Check("missing module is named, not the manifest",
    MasterErrorModule(eMiss) = "hotkeys\Gone Module.ahk", "got=" MasterErrorModule(eMiss))
; A missing file included from INSIDE a module still blames that module.
eInner := 'C:\VK\hotkeys\Foo.ahk (2) : ==> #Include file "C:\VK\hotkeys\helper.ahk" cannot be opened.'
Check("a module's own missing include parks the module",
    MasterErrorModule(eInner) = "hotkeys\Foo.ahk", "got=" MasterErrorModule(eInner))
Check("the manifest itself is never returned",
    MasterErrorModule('C:\VK\hotkeys\_index.ahk (4) : ==> Missing "}"') = "")

; End to end against a scratch master in %TEMP% (never the real one).
fr := dir "\fx_root"
DirCreate(fr "\hotkeys")
FileAppend("#Requires AutoHotkey v2.0`n#Include `"%A_ScriptDir%\hotkeys\_index.ahk`"`n",
    fr "\VoiceKit.ahk", "UTF-8")
FileAppend("keepProbe := 1`n", fr "\hotkeys\Keep.ahk", "UTF-8")
FileAppend("#Requires AutoHotkey v2.0`n"
    . '#Include "%A_ScriptDir%\hotkeys\Keep.ahk"' "`n"
    . '#Include "%A_ScriptDir%\hotkeys\Gone Module.ahk"' "`n", fr "\hotkeys\_index.ahk", "UTF-8")
r := MasterPreflight(fr, 15000)
idxTxt := FileRead(fr "\hotkeys\_index.ahk", "UTF-8")
Check("preflight parks a missing module and loads", r.ok = true, r.note)
Check("...its manifest line is commented out, saying why",
    InStr(idxTxt, semi ' #Include "%A_ScriptDir%\hotkeys\Gone Module.ahk"') && InStr(idxTxt, "missing"),
    StrReplace(idxTxt, "`n", " | "))
Check("...and the healthy module stays on",
    InStr(idxTxt, "`n#Include `"%A_ScriptDir%\hotkeys\Keep.ahk`""))
Check("...and the note names it", InStr(r.note, "Gone Module.ahk") > 0)

; ---- 11. a #Warn warning can't hang the load check ------------------
; /validate /ErrorStdOut still pops #Warn's message box (hidden, with the
; Hide flag), so an unbounded check waited forever. Bounded now: the tree
; is killed, the result says what blocked it, and nothing is left running.
warnFx := dir "\fx_warn.ahk"
FileAppend("#Requires AutoHotkey v2.0`n#Warn`nMsgBox(neverAssignedZz)`n", warnFx, "UTF-8")
t0 := A_TickCount
w := AhkValidate(warnFx, 3000)
took := A_TickCount - t0
Check("#Warn fixture fails the check", w.ok = false)
Check("...flagged as timed out", w.timedOut = true)
Check("...within the bound", took < 9000, "took=" took "ms")
Check("...saying a #Warn/dialog blocked it", InStr(w.text, "#Warn") > 0, SubStr(w.text, 1, 90))
Sleep(300)
leftover := 0
for proc in ComObjGet("winmgmts:").ExecQuery("Select CommandLine from Win32_Process"
        . " where Name = 'AutoHotkey64.exe' or Name = 'cmd.exe'")
    if InStr(proc.CommandLine, "fx_warn.ahk")
        leftover += 1
Check("...and no process is left behind", leftover = 0, "leftover=" leftover)
t0 := A_TickCount
Check("a normal file still checks fast", AhkValidate(good).ok && A_TickCount - t0 < 5000,
    "took=" (A_TickCount - t0) "ms")

; The preflight parks the #Warn module (the only suspect) and loads.
FileAppend("#Warn`nwarnProbe := neverAssignedZz2`n", fr "\hotkeys\Warny.ahk", "UTF-8")
FileAppend('#Include "%A_ScriptDir%\hotkeys\Warny.ahk"' "`n", fr "\hotkeys\_index.ahk", "UTF-8")
r := MasterPreflight(fr, 3000)
idxTxt := FileRead(fr "\hotkeys\_index.ahk", "UTF-8")
Check("preflight parks a #Warn module whose warning blocks the check", r.ok = true, r.note)
Check("...commenting out its line", InStr(idxTxt, semi ' #Include "%A_ScriptDir%\hotkeys\Warny.ahk"') > 0)

; ---- 12. watchdog decisions (pure) ----------------------------------
; Resume from sleep used to read as a crash: the watchdog's poll and the
; master's heartbeat both come due at wake, and a stale heartbeat alone
; triggered a restart of a healthy master.
wdFacts := {statusExists: true, tickNow: 100000, lastTick: 97000, pollMs: 3000,
         holdActive: false, heartbeatFresh: false, cleanExit: false}
WdWith(over) {
    global wdFacts
    o := {}
    for k, v in wdFacts.OwnProps()
        o.%k% := v
    for k, v in over.OwnProps()
        o.%k% := v
    return o
}
Check("stale heartbeat, normal poll gap -> restart", WatchdogDecide(wdFacts) = "restart")
Check("stale heartbeat after a long gap -> resumed (hold, don't restart)",
    WatchdogDecide(WdWith({lastTick: 100000 - 3 * 3000 - 1})) = "resumed")
Check("a gap just inside 3 polls is still a normal poll",
    WatchdogDecide(WdWith({lastTick: 100000 - 3 * 3000})) = "restart")
Check("first poll (lastTick 0) never reads as a resume", WatchdogDecide(WdWith({lastTick: 0})) = "restart")
Check("fresh heartbeat -> alive", WatchdogDecide(WdWith({heartbeatFresh: true})) = "alive")
Check("hold active -> hold", WatchdogDecide(WdWith({holdActive: true})) = "hold")
Check("clean exit -> standdown", WatchdogDecide(WdWith({cleanExit: true})) = "standdown")
Check("no status file -> idle", WatchdogDecide(WdWith({statusExists: false})) = "idle")

now := "20260928120000"
old1 := DateAdd(now, -300, "Seconds"), in1 := DateAdd(now, -90, "Seconds"), in2 := DateAdd(now, -10, "Seconds")
kept := WatchdogStampsInWindow(old1 "," in1 ",junk, " in2 "," DateAdd(now, 60, "Seconds"), now, 120)
Check("stamps: only in-window ones survive", kept.Length = 2 && kept[1] = in1 && kept[2] = in2,
    "n=" kept.Length)
p1 := WatchdogRestartPlan(in1, now, 120, 3)
Check("restart plan: 2 in window is not a crash loop", p1.stamps.Length = 2 && !p1.crashLoop)
p2 := WatchdogRestartPlan(in1 "," in2, now, 120, 3)
Check("restart plan: the 3rd inside the window is", p2.stamps.Length = 3 && p2.crashLoop)
p3 := WatchdogRestartPlan(old1 "," old1, now, 120, 3)
Check("restart plan: stale stamps don't count", p3.stamps.Length = 1 && !p3.crashLoop)

; A hold only extends. A wake 2 minutes into the 10-minute crash-loop
; back-off used to overwrite it with the 20 s grace, and the next stale
; poll relaunched a master that was still crash-looping.
backoffEnd := DateAdd(now, 480, "Seconds")
Check("resume inside the back-off keeps the back-off",
    WatchdogHoldUntil(backoffEnd, now, 20) = backoffEnd, "got=" WatchdogHoldUntil(backoffEnd, now, 20))
Check("resume with no hold starts the grace",
    WatchdogHoldUntil("", now, 20) = DateAdd(now, 20, "Seconds"))
Check("an expired hold is replaced",
    WatchdogHoldUntil(DateAdd(now, -5, "Seconds"), now, 20) = DateAdd(now, 20, "Seconds"))
Check("a longer request extends a shorter hold",
    WatchdogHoldUntil(DateAdd(now, 10, "Seconds"), now, 600) = DateAdd(now, 600, "Seconds"))
Check("an unreadable stamp is ignored",
    WatchdogHoldUntil("junk", now, 20) = DateAdd(now, 20, "Seconds"))

try DirDelete(dir, true)
TestEnd()
