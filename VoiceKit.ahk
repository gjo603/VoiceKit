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
#Include "%A_ScriptDir%\hotkeys\_index.ahk"

A_IconTip := "VoiceKit — say `"open voice kit help`""

InstallIfFirstRun()

^!+n:: RunAhk(A_ScriptDir "\macros\NewAutomation.ahk")
^!+r:: Reload
^!+e:: Run('explorer.exe "' A_ScriptDir '"')

; ------------------------------------------------------------
; First run only: put voice-launchable entries in the Start
; Menu so Voice Access can run them with "open <name>", and
; offer to start VoiceKit automatically at login.
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
    ; The .lnk is named by the spoken phrase (SpaceOut of the filename).
    Loop Files A_ScriptDir "\macros\*.ahk"
        MakeAhkShortcut(vmDir "\" SpaceOut(StrReplace(A_LoopFileName, ".ahk")) ".lnk", A_LoopFileFullPath)

    if MsgBox("Start VoiceKit automatically when you log in?`n(Recommended — you can delete the shortcut from shell:startup later.)", "VoiceKit setup", "YesNo") = "Yes"
        MakeAhkShortcut(A_Startup "\VoiceKit.lnk", A_ScriptFullPath)

    FileAppend("installed " FormatTime(A_Now, "yyyy-MM-dd HH:mm") "`n", marker, "UTF-8")
    MsgBox("VoiceKit is set up.`n`nTry saying:  open new automation`n(Give Windows a few seconds to index the new Start Menu entries.)", "VoiceKit")
}

; "MorningTabs" -> "Morning Tabs" (the spoken phrase). Matches the names
; New Automation / Workflow Studio create, so shortcuts regenerate the
; same way when cloned to another machine.
SpaceOut(camel) {
    return Trim(RegExReplace(camel, "([a-z0-9])([A-Z])", "$1 $2"))
}
