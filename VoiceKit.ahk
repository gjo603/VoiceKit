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
#Include "%A_ScriptDir%\hotkeys\_index.ahk"

A_IconTip := "VoiceKit — say `"open voice kit`""

InstallIfFirstRun()
EnsureCoreShortcuts()

^!+n:: RunAhk(A_ScriptDir "\macros\NewAutomation.ahk")
^!+r:: Reload
^!+e:: Run('explorer.exe "' A_ScriptDir '"')

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
    vmDir := A_Programs "\Voice Macros"
    EnsureDir(vmDir)

    ; A voice-launchable Start Menu entry for every macro in macros\ —
    ; the built-ins, plus anything carried over from another machine.
    ; The .lnk is named by the spoken phrase (SpaceOut of the filename);
    ; the home window is special-cased so its phrase is "open voice kit".
    Loop Files A_ScriptDir "\macros\*.ahk" {
        base := StrReplace(A_LoopFileName, ".ahk")
        disp := (base = "VoiceKitHome") ? "Voice Kit" : SpaceOut(base)
        MakeAhkShortcut(vmDir "\" disp ".lnk", A_LoopFileFullPath)
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
    vmDir := A_Programs "\Voice Macros"
    EnsureDir(vmDir)
    if !FileExist(vmDir "\Voice Kit.lnk")
        MakeAhkShortcut(vmDir "\Voice Kit.lnk", A_ScriptDir "\macros\VoiceKitHome.ahk")
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
        if chkStart.Value
            MakeAhkShortcut(A_Startup "\VoiceKit.lnk", A_ScriptFullPath)
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
