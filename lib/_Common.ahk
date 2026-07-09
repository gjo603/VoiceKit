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

; "MorningTabs" -> "Morning Tabs" — the spoken phrase for a file base. The
; inverse convention to how bases are formed, so shortcuts regenerate the
; same name on any machine. (LoopRunner.ahk keeps its own copy because it
; doesn't include _Common.)
SpaceOut(camel) {
    return Trim(RegExReplace(camel, "([a-z0-9])([A-Z])", "$1 $2"))
}

; Append one line to logs\created.log.
Log(root, text) {
    EnsureDir(root "\logs")
    FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm") " | " text "`n", root "\logs\created.log", "UTF-8")
}

; Launch an .ahk through the AutoHotkey interpreter explicitly, instead
; of relying on the .ahk file association (which a machine migrated from
; an old PC may have pointed at VS Code / Notepad++ / Notepad). A_AhkPath
; is the exe running the current script — always the v2 interpreter here.
RunAhk(ahkFile) {
    Run('"' A_AhkPath '" "' ahkFile '"')
}

; Create a Start Menu / Startup shortcut that runs an .ahk through the
; interpreter (association-proof). Voice Access "open <name>" opens the
; .lnk, which runs the exe with the script as its quoted argument — so
; it works even if .ahk is associated with something else. Defaults the
; working dir to the script's own folder. `args` are appended after the
; script path (already-quoted by the caller if they contain spaces).
MakeAhkShortcut(linkFile, ahkFile, workingDir := "", args := "") {
    if (workingDir = "")
        workingDir := RegExReplace(ahkFile, "\\[^\\]+$")
    target := '"' ahkFile '"'
    if (args != "")
        target .= " " args
    FileCreateShortcut(A_AhkPath, linkFile, workingDir, target)
}

; Create/refresh a "loop <phrase>" Start Menu entry that runs the workflow
; <base> repeatedly via lib\LoopRunner.ahk. Voice: "open loop <phrase>".
; root is the VoiceKit root folder; base is the workflow file base
; (e.g. MorningTabs); phrase is its spoken/display form (e.g. Morning Tabs).
MakeLoopShortcut(root, base, phrase) {
    vmDir := A_Programs "\Voice Macros"
    EnsureDir(vmDir)
    MakeAhkShortcut(vmDir "\loop " phrase ".lnk", root "\lib\LoopRunner.ahk", root, '"' base '"')
}

; True if a bare filename (no extension) is a reserved Windows device
; name. Writing "<name>.ahk" for these silently hits the device instead
; of creating a file, producing a broken automation with no error.
IsReservedName(name) {
    return name ~= "i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$"
}
