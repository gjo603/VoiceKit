#Requires AutoHotkey v2.0
; ============================================================
;  Shared helpers.
;  - VoiceKit.ahk includes this automatically.
;  - Standalone macros include it with:
;      #Include "%A_ScriptDir%\..\lib\_Common.ahk"
; ============================================================

; Create a folder (and parents) if it doesn't exist.
EnsureDir(path) {
    if !DirExist(path)
        DirCreate(path)
}

; Small tray notification. The Sleep keeps it visible even when
; a one-shot macro exits immediately after calling this.
Notify(text, ms := 2500) {
    TrayTip(text, "VoiceKit")
    Sleep(ms)
}

; Bring an app to the front if it's running, otherwise launch it.
;   winTitle: "ahk_exe notepad.exe"  or a window title
;   runCmd:   "notepad.exe"  or a full path
RunOrActivate(winTitle, runCmd) {
    if WinExist(winTitle) {
        WinActivate(winTitle)
        return
    }
    Run(runCmd)
    if WinWait(winTitle, , 10)
        WinActivate(winTitle)
}

; Normalize a raw name into a clean, speakable Title Case phrase.
CleanPhrase(raw) {
    p := RegExReplace(Trim(raw), "[^A-Za-z0-9 ]", "")
    p := RegExReplace(p, "\s+", " ")
    return StrTitle(p)
}

; Append one line to logs\created.log.
Log(root, text) {
    EnsureDir(root "\logs")
    FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm") " | " text "`n", root "\logs\created.log", "UTF-8")
}
