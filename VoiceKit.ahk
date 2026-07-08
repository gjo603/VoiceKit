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

^!+n:: Run('"' A_ScriptDir '\macros\NewAutomation.ahk"')
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

    FileCreateShortcut(A_ScriptDir "\macros\NewAutomation.ahk",    vmDir "\New Automation.lnk",    A_ScriptDir "\macros")
    FileCreateShortcut(A_ScriptDir "\macros\WorkflowStudio.ahk",   vmDir "\Workflow Studio.lnk",   A_ScriptDir "\macros")
    FileCreateShortcut(A_ScriptDir "\macros\VoiceKitHelp.ahk",     vmDir "\Voice Kit Help.lnk",    A_ScriptDir "\macros")
    FileCreateShortcut(A_ScriptDir "\macros\WorkLayout.ahk",       vmDir "\Work Layout.lnk",       A_ScriptDir "\macros")
    FileCreateShortcut(A_ScriptDir "\macros\MorningTabs.ahk",      vmDir "\Morning Tabs.lnk",      A_ScriptDir "\macros")
    FileCreateShortcut(A_ScriptDir "\macros\CleanScreenshots.ahk", vmDir "\Clean Screenshots.lnk", A_ScriptDir "\macros")

    if MsgBox("Start VoiceKit automatically when you log in?`n(Recommended — you can delete the shortcut from shell:startup later.)", "VoiceKit setup", "YesNo") = "Yes"
        FileCreateShortcut(A_ScriptFullPath, A_Startup "\VoiceKit.lnk", A_ScriptDir)

    FileAppend("installed " FormatTime(A_Now, "yyyy-MM-dd HH:mm") "`n", marker, "UTF-8")
    MsgBox("VoiceKit is set up.`n`nTry saying:  open new automation`n(Give Windows a few seconds to index the new Start Menu entries.)", "VoiceKit")
}
