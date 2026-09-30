#Requires AutoHotkey v2.0
; #SingleInstance Ignore, NOT Force: the master calls StartWatchdog on
; every start, so Force would replace this process on each restart and
; wipe whatever it was keeping track of. Ignore lets the original keep
; watching; a new one only starts when none is running.
#SingleInstance Ignore
; ============================================================
;  VoiceKit watchdog.
;
;  The master is a single AutoHotkey process holding every
;  always-on hotkey and every snippet. Some things a module can
;  do end that process outright — an unpinned COM vtable call
;  (see lib\Acc.ahk), a bad ComCall offset — with no exception
;  to catch and no dialog to dismiss. Nothing running INSIDE the
;  master can recover from that, so this watches from outside.
;
;  Rule: the master is alive while its heartbeat in
;  logs\master-status.ini stays fresh. A reload is invisible here
;  (the file is only ~1 s stale while the new process takes over),
;  while a crash goes stale and stays stale. If it does, restart
;  through VoiceKitLauncher.ahk, which load-checks first.
;
;  If restarting keeps happening, stop trusting the modules: park
;  them all and come up bare. Hotkeys off is bad; a dead layer
;  nobody mentions is worse — that was the original bug.
;
;  Started by VoiceKit.ahk. Only _Common.ahk is included, and it
;  pulls in nothing itself, so no user module can break this file.
; ============================================================
#Include "%A_LineFile%\..\_Common.ahk"

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")   ; parent of \lib

; Heartbeat is written every 5 s; 20 s of silence is well past any
; reload gap but still a quick recovery.
STALE_SECONDS  := 20
POLL_MS        := 3000
GRACE_SECONDS  := 20     ; after a restart, give the new master room to appear
CRASH_WINDOW_S := 120    ; restarts inside this window...
CRASH_LIMIT    := 3      ; ...this many, and the modules lose our trust
BACKOFF_SECONDS := 600   ; still crashing with nothing left to park: stand back

SetTimer(Watch, POLL_MS)     ; a live timer keeps the script persistent

Watch() {
    global root, POLL_MS, GRACE_SECONDS
    static lastTick := 0
    ; The decision itself is WatchdogDecide in _Common.ahk (pure, so the
    ; self-test can drive it); this only gathers the facts and acts.
    tickNow := A_TickCount
    f := {statusExists: FileExist(MasterStatusFile(root)) != "",
          tickNow: tickNow, lastTick: lastTick, pollMs: POLL_MS,
          holdActive: HoldActive(root), heartbeatFresh: MasterHeartbeatFresh(root),
          cleanExit: MasterExitedCleanly(root)}
    lastTick := tickNow
    switch WatchdogDecide(f) {
        case "resumed":
            ; Woke from sleep: the master's own heartbeat is just as overdue
            ; as this poll was. Give it the grace period to land — quietly;
            ; a line per wake would bury real crashes in errors.log. A longer
            ; hold already running (the crash-loop back-off) is kept whole.
            SetHold(root, GRACE_SECONDS)
        case "standdown":
            ; The user closed it on purpose — stand down and let go.
            WatchdogLog(root, "master exited cleanly — watchdog stopping")
            ExitApp(0)
        case "restart":
            RestartMaster()
    }
}

; The master is alive while its heartbeat is recent. Deliberately the ONLY
; liveness test: a PID check would misfire on every reload, because
; #SingleInstance Force kills the old process each time.
MasterHeartbeatFresh(root) {
    global STALE_SECONDS
    hb := ""
    try hb := IniRead(MasterStatusFile(root), "Master", "heartbeat", "")
    if (hb = "")
        return false
    age := 0
    try age := DateDiff(A_Now, hb, "Seconds")
    catch
        return false            ; unreadable stamp — treat as not alive
    return age <= STALE_SECONDS
}

MasterExitedCleanly(root) {
    v := "0"
    try v := IniRead(MasterStatusFile(root), "Master", "clean_exit", "0")
    return v = "1"
}

; ---- restart bookkeeping ------------------------------------------------
; Kept on disk, not in memory. This process can itself be restarted (or
; killed), and an in-memory counter then resets on every crash and never
; reaches the limit — measured: the log read "1 restart in the last 120s"
; three consecutive crashes running, and safe mode never fired.

HoldActive(root) {
    heldTo := ""            ; not "until" — that's a reserved word in AHK v2
    try heldTo := IniRead(MasterStatusFile(root), "Watchdog", "hold_until", "")
    if (heldTo = "")
        return false
    try return DateDiff(heldTo, A_Now, "Seconds") > 0
    return false
}

; Extends a running hold, never shortens it (WatchdogHoldUntil) — a resume
; during the crash-loop back-off must not cut the back-off to the grace.
SetHold(root, seconds) {
    existing := ""
    try existing := IniRead(MasterStatusFile(root), "Watchdog", "hold_until", "")
    try IniWrite(WatchdogHoldUntil(existing, A_Now, seconds), MasterStatusFile(root),
        "Watchdog", "hold_until")
}

; The raw restart-stamp list as saved (WatchdogRestartPlan prunes it).
RestartStampsRaw(root) {
    raw := ""
    try raw := IniRead(MasterStatusFile(root), "Watchdog", "restarts", "")
    return raw
}

SaveRestartStamps(root, stamps) {
    try IniWrite(JoinList(stamps, ","), MasterStatusFile(root), "Watchdog", "restarts")
}

RestartMaster() {
    global root, CRASH_WINDOW_S, CRASH_LIMIT, GRACE_SECONDS, BACKOFF_SECONDS
    plan := WatchdogRestartPlan(RestartStampsRaw(root), A_Now, CRASH_WINDOW_S, CRASH_LIMIT)
    stamps := plan.stamps
    SaveRestartStamps(root, stamps)

    if plan.crashLoop {
        SaveRestartStamps(root, [])
        if !EnterSafeMode() {
            ; Nothing left to turn off and it is STILL dying — the fault is
            ; in VoiceKit itself, not a module. Restarting on a loop would
            ; just churn, so back off and leave a note.
            WatchdogLog(root, "crash loop with no modules left to park — backing off for "
                . (BACKOFF_SECONDS // 60) " minutes. See logs\errors.log.")
            SetHold(root, BACKOFF_SECONDS)
            return
        }
    }
    launcher := root "\VoiceKitLauncher.ahk"
    target := FileExist(launcher) ? launcher : root "\VoiceKit.ahk"
    try RunAhk(target)
    catch as e {
        WatchdogLog(root, "couldn't restart the master: " e.Message)
        return
    }
    WatchdogLog(root, "master was gone — restarted it (" stamps.Length
        . " restart(s) inside the crash window)")
    SetHold(root, GRACE_SECONDS)
}

; Repeated crashes mean one of the modules is killing the process. We
; can't tell which — a hard crash leaves no stack — so park them all,
; drop a flag the master reports at startup, and come up bare.
; Returns false when there was nothing left to park.
EnterSafeMode() {
    global root
    mods := IndexModules(root)
    if !mods.active.Length
        return false
    stamp := FormatTime(A_Now, "yyyy-MM-dd")
    for rel in mods.active
        CommentOutLinesContaining(root "\hotkeys\_index.ahk", "\" rel,
            "safe mode " stamp " — VoiceKit kept crashing with this loaded")
    try FileAppend("safe mode entered " FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "`n",
        SafeModeFlag(root), "UTF-8")
    WatchdogLog(root, "SAFE MODE — parked " mods.active.Length
        . " module(s) after repeated crashes")
    try TrayTip("VoiceKit kept crashing, so it restarted with all hotkey modules turned off."
        . "`nTurn them back on one at a time in hotkeys\_index.ahk.", "VoiceKit", "Icon!")
    return true
}

; errors.log through the one writer (never throws). The line's script
; column reads "Watchdog.ahk", so read_log("errors", filter="watchdog")
; still finds every one of these.
WatchdogLog(root, msg) {
    ErrorLogAppend(msg, root)
}
