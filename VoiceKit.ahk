#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  VoiceKit — master script. Keep this running (tray icon).
;
;  Re-running this file REPLACES the old instance — that is
;  how VoiceKit "reloads" after a new module is added.
;
;  Reserved hotkeys (never used by bridge modules):
;    Ctrl+Alt+Shift+N  -> New Automation (the scaffolder)
;    Ctrl+Alt+Shift+R  -> Reload VoiceKit
;    Ctrl+Alt+Shift+E  -> Open the VoiceKit folder
;    Ctrl+Alt+Shift+X  -> Stop recording (Workflow Studio, while recording)
; ============================================================

#Include "%A_ScriptDir%\lib\_Common.ahk"
#Include "%A_ScriptDir%\lib\Theme.ahk"
; *i: the manifest is a per-user file made from hotkeys\_index.default.ahk
; (SeedUserFiles). Every supported start path seeds it before this compiles;
; a direct launch with it missing still starts (no modules) and seeds below.
#Include "*i %A_ScriptDir%\hotkeys\_index.ahk"

A_IconTip := "VoiceKit — say `"open voice kit`""

; A module that throws must not leave a modal dialog sitting in front of
; the user, and must not look like VoiceKit has hung. Installed before
; anything else runs so startup errors are caught too.
OnError(MasterError)
OnExit(MasterExit)

; The launcher and every reload seed the per-user files before this
; compiles; a direct launch of VoiceKit.ahk doesn't. If that left the
; manifest missing or without a shipped hotkey, it's fixed now and the
; master reloads (through the preflight) to pick it up — and THIS instance
; stops right there. The replacement's #SingleInstance Force would end it
; soon, but not before it had raced ahead writing installed.flag, showing
; the welcome window and starting a second watchdog. The exit is not a
; "clean" one (MasterExit is unhooked first): the replacement owns the
; status file now, and a clean_exit stamped after its start would read as
; VoiceKit having been closed.
if SeedUserFilesLogged(A_ScriptDir).indexChanged {
    ReloadMasterNotify(A_ScriptDir, &vkSeedRelaunched)   ; distinctive: master globals share one namespace with every in-process module
    if vkSeedRelaunched {
        OnExit(MasterExit, 0)
        ExitApp()
    }
}

InstallIfFirstRun()
EnsureCoreShortcuts()
MasterStatusInit(A_ScriptDir)
SetTimer(MasterHeartbeat, 5000)
StartWatchdog(A_ScriptDir)
ReportQuarantine()

^!+n:: RunAhk(A_ScriptDir "\macros\NewAutomation.ahk")
^!+r:: ReloadMasterNotify(A_ScriptDir)   ; load-checks first; parks a module that won't load
^!+e:: Run('explorer.exe "' A_ScriptDir '"')

; ------------------------------------------------------------
; An uncaught error in a hotkey thread normally opens a modal
; dialog and waits for a human — on a resident script that reads
; as "VoiceKit is hung", and every other hotkey looks dead until
; it's dismissed. Log it, say so in the tray, and end just that
; thread. Returning 1 suppresses the default dialog.
; ------------------------------------------------------------
MasterError(err, mode) {
    one := ErrorLogLine(err)
    ; The errors.log line is already written: _Common.ahk registers
    ; LogUncaughtError during its include, ahead of this handler — writing
    ; a second line here would double-log every master error.
    try {
        IniWrite(SubStr(one, 1, 300), MasterStatusFile(A_ScriptDir), "Master", "last_error")
        IniWrite(A_Now, MasterStatusFile(A_ScriptDir), "Master", "last_error_at")
    }
    try TrayTip("A VoiceKit hotkey hit an error — everything else is still running.`n"
        . SubStr(one, 1, 120) "`n(logged in logs\errors.log)", "VoiceKit", "Icon!")
    return 1
}

; Only a DELIBERATE exit sets the clean flag. A reload replaces this
; process (#SingleInstance Force, reason "Single") and a hard crash never
; reaches here at all — the watchdog must still act on both of those.
MasterExit(reason, code) {
    if (reason ~= "i)^(Menu|Close|Exit|Logoff|Shutdown)$")
        MasterStatusCleanExit(A_ScriptDir)
}

MasterHeartbeat(*) {
    MasterStatusBeat(A_ScriptDir)
}

; If the reload preflight (or the watchdog) had to park modules, say so
; once at startup. Silence was the original complaint: the layer went
; down and nothing anywhere mentioned it.
ReportQuarantine() {
    mods := IndexModules(A_ScriptDir)
    if !mods.quarantined.Length
        return
    n := mods.quarantined.Length
    TrayTip("VoiceKit started with " n " file" (n = 1 ? "" : "s")
        . " turned off because " (n = 1 ? "it wouldn't" : "they wouldn't") " load:`n"
        . JoinList(mods.quarantined, ", ")
        . (FileExist(SafeModeFlag(A_ScriptDir))
            ? "`nSafe mode after repeated crashes — see logs\errors.log." : ""),
        "VoiceKit", "Icon!")
}

; ------------------------------------------------------------
; First run only: put voice-launchable entries in the Start
; Menu so Voice Access can run them with "open <name>", then
; show the welcome window (Voice Access check, auto-start,
; the first phrase to try).
; ------------------------------------------------------------
InstallIfFirstRun() {
    marker := A_ScriptDir "\logs\installed.flag"
    if FileExist(marker)
        return

    EnsureDir(A_ScriptDir "\logs")
    vmDir := VoiceMacrosDir()
    EnsureDir(vmDir)

    ; A voice-launchable Start Menu entry for every macro in macros\ —
    ; the built-ins, plus anything carried over from another machine.
    ; The .lnk is named by the spoken phrase (VoiceShortcutName: SpaceOut of
    ; the filename, with the home window's phrase being "open voice kit").
    Loop Files A_ScriptDir "\macros\*.ahk" {
        base := StrReplace(A_LoopFileName, ".ahk")
        MakeAhkShortcut(vmDir "\" VoiceShortcutName(base) ".lnk", A_LoopFileFullPath)
    }

    ; A "loop <name>" companion for every saved workflow, so "open loop
    ; <name>" runs that workflow repeatedly (stop with the Stop Looping
    ; button or Ctrl+Alt+Shift+X). Covers workflows carried over too.
    Loop Files A_ScriptDir "\workflows\*.steps.txt" {
        wfBase := StrReplace(A_LoopFileName, ".steps.txt")
        MakeLoopShortcut(A_ScriptDir, wfBase, SpaceOut(wfBase))
    }

    FileAppend("installed " FormatTime(A_Now, "yyyy-MM-dd HH:mm") "`n", marker, "UTF-8")
    ShowWelcome()
}

; ------------------------------------------------------------
; Every start (not just first run): make sure the home window's
; "open voice kit" entry exists — installs upgraded from an older
; VoiceKit have installed.flag set, so InstallIfFirstRun never
; runs again and would leave the advertised phrase dead.
; ------------------------------------------------------------
EnsureCoreShortcuts() {
    EnsureVoiceShortcut(VoiceShortcutName("VoiceKitHome"), A_ScriptDir "\macros\VoiceKitHome.ahk")
    EnsureStartupViaLauncher()
}

; Installs made before the launcher existed have a Startup shortcut
; pointing straight at VoiceKit.ahk — so a module that stops compiling
; would leave the machine with no VoiceKit at all after a reboot, which
; is exactly the failure this is here to prevent. Repoint it once.
EnsureStartupViaLauncher() {
    lnk := A_Startup "\VoiceKit.lnk"
    launcher := A_ScriptDir "\VoiceKitLauncher.ahk"
    if (!FileExist(lnk) || !FileExist(launcher))
        return
    args := ""
    try FileGetShortcut(lnk, , , &args)
    catch
        return
    if (InStr(args, "VoiceKitLauncher.ahk") || !InStr(args, "VoiceKit.ahk"))
        return
    MakeAhkShortcut(lnk, launcher)
}

; ------------------------------------------------------------
; The first sixty seconds, on one calm screen (replaces the old
; MsgBox chain): is Voice Access on, start at login, what to say.
; ------------------------------------------------------------
ShowWelcome() {
    w := Gui("+AlwaysOnTop", "Welcome to VoiceKit")
    w.SetFont("s10", "Segoe UI")
    w.MarginX := 24, w.MarginY := 20
    w.SetFont("s16 bold")
    w.AddText("xm", "Welcome to VoiceKit")
    w.SetFont("s10 norm")
    tagline := w.AddText("xm y+4 w440", "Your voice runs this computer now. Sixty seconds of setup:")

    w.SetFont("s10 bold")
    w.AddText("xm y+18", "1.  Voice Access")
    w.SetFont("s10 norm")
    vaStatus := w.AddText("xm+16 y+6 w430", "Checking…")
    btnVA := w.AddButton("xm+16 y+8 w210 h32", "Turn On Voice Access")

    w.SetFont("s10 bold")
    w.AddText("xm y+18", "2.  Start with Windows")
    w.SetFont("s10 norm")
    chkStart := w.AddCheckBox("xm+16 y+6 Checked", "Start VoiceKit when I sign in  (recommended)")

    w.SetFont("s10 bold")
    w.AddText("xm y+18", "3.  Try it")
    w.SetFont("s10 norm")
    lead := w.AddText("xm+16 y+6", "Say:")
    w.SetFont("s13 bold")
    phraseCtrl := w.AddText("xm+16 y+2", "“open voice kit”")
    w.SetFont("s9 norm")
    tail := w.AddText("xm+16 y+6 w430", "Give Windows a few seconds to index the new Start Menu entries first.")

    w.SetFont("s10")
    btnDone := w.AddButton("xm y+22 w160 h36 Default", "Finish")

    UpdateVA(*) {
        running := ProcessExist("voiceaccess.exe")
        vaStatus.Text := running
            ? "●  Voice Access is running — you can talk to Windows."
            : "○  Voice Access is off. Turn it on, then talk to Windows."
        btnVA.Enabled := !running
        btnVA.Text := running ? "Voice Access Is On ✓" : "Turn On Voice Access"
    }
    TurnOnVA(*) {
        try Run("voiceaccess.exe")
        catch
            Send("#^s")              ; the Windows toggle for Voice Access
        ; NOTE: no one-shot SetTimer here — a function object has only ONE
        ; timer, so a -1500 one-shot would REPLACE the 2 s polling timer and
        ; kill the auto-refresh. The periodic poll picks the change up.
    }
    Finish(*) {
        ; Start via the launcher, not this file: it load-checks first, so a
        ; module that stops compiling can't leave a machine with no VoiceKit.
        if chkStart.Value
            MakeAhkShortcut(A_Startup "\VoiceKit.lnk", A_ScriptDir "\VoiceKitLauncher.ahk")
        SetTimer(UpdateVA, 0)
        w.Destroy()
    }
    btnVA.OnEvent("Click", TurnOnVA)
    btnDone.OnEvent("Click", Finish)
    ; X and Escape behave like Finish — the checkbox state still applies,
    ; instead of being silently dropped.
    w.OnEvent("Close", Finish)
    w.OnEvent("Escape", Finish)

    ThemeApply(w)
    ThemeDim(tagline)
    ThemeDim(lead)
    ThemeDim(tail)
    phraseCtrl.Opt("c" Format("{:06X}", ThemePalette().accent))
    UpdateVA()
    SetTimer(UpdateVA, 2000)
    w.Show()
}
