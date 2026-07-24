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

; ---- Snippets (hotstrings) --------------------------------------------------
; A snippet lives on ONE line of hotkeys\Snippets.ahk (:*:abbrev::replacement),
; so the replacement text is stored escaped: real newlines are folded into `n
; (an AHK escape the hotstring expands back to a newline when it fires), so a
; multi-line snippet still occupies a single line the listing/delete/edit code
; can match. SnipEncode/SnipDecode are inverses.

; Plain (possibly multi-line) text -> its single-line on-disk form. Mirrors
; mcp\voicekit_writer.create_snippet's escaping EXACTLY — keep them in sync.
SnipEncode(text) {
    text := StrReplace(text, "``", "````")     ; literal backticks first (the escape char)
    text := StrReplace(text, ";", "``;")       ; a bare ; would start a comment mid-line
    text := StrReplace(text, "`r`n", "`n")     ; normalize newlines...
    text := StrReplace(text, "`r", "`n")
    text := StrReplace(text, "`n", "``n")      ; ...then fold each into a literal `n
    return text
}

; On-disk replacement text -> plain text (newlines as CRLF, ready for a
; multi-line Edit). One left-to-right pass so backtick escapes decode cleanly;
; also handles `t and hand-edited `x from snippets we didn't generate.
SnipDecode(s) {
    out := "", i := 1, n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c = "``" && i < n) {
            switch SubStr(s, i + 1, 1) {
                case "n": out .= "`r`n"
                case "r": out .= ""            ; encode folds CR into `n; drop a stray one
                case "t": out .= "`t"
                default:  out .= SubStr(s, i + 1, 1)   ; `; -> ;   `` -> `   `x -> x
            }
            i += 2
        } else {
            out .= c
            i += 1
        }
    }
    return out
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

; Rewrite a text file without the lines that contain `needle`.
; (Used to retire hotkey modules from _index.ahk / bridge-map.txt.)
; Left untouched when nothing matches — no churn on unrelated files.
RemoveLinesContaining(file, needle) {
    if !FileExist(file)
        return
    out := ""
    found := false
    Loop Parse FileRead(file, "UTF-8"), "`n", "`r" {
        if InStr(A_LoopField, needle) {
            found := true
            continue
        }
        out .= A_LoopField "`n"
    }
    if !found
        return
    f := FileOpen(file, "w", "UTF-8")
    f.Write(RTrim(out, "`n") "`n")
    f.Close()
}

; ============================================================
;  Bridge keys (Ctrl+Alt+Shift+<key>) — shared by the scaffolder
;  and the home window so they draw from ONE pool.
; ============================================================

; The allocatable keys. E, N, R are VoiceKit's own hotkeys, X is Workflow
; Studio's stop-recording / loop-stop key, and H / I are its mark-hover and
; ask-for-input keys while recording — all six stay out.
; (mcp\voicekit_writer.py BRIDGE_POOL mirrors this string.)
BridgeKeyPool() {
    return "ABCDFGJKLMOPQSTUVWYZ0123456789"
}

; Pool keys not yet registered in bridge-map.txt, in pool order.
; Deliberately a raw-text scan (not BridgeMapEntries): a commented-out
; line still counts as used, exactly like the Python allocator
; (voicekit_writer.allocate_bridge_key) — the two must never diverge
; on which key is "free".
BridgeFreeKeys(mapFile) {
    used := FileExist(mapFile) ? FileRead(mapFile, "UTF-8") : ""
    free := []
    Loop Parse BridgeKeyPool() {
        if !InStr(used, "Ctrl+Alt+Shift+" A_LoopField "|")
            free.Push(A_LoopField)
    }
    return free
}

; Parse bridge-map.txt into an Array of {combo, key, phrase, file}
; (fields Trim'd; comments/blank/short lines skipped). The one AHK
; reader of the record format — voicekit_writer.get_bridge_map mirrors it.
BridgeMapEntries(root) {
    entries := []
    mapFile := root "\bridge-map.txt"
    if !FileExist(mapFile)
        return entries
    Loop Parse FileRead(mapFile, "UTF-8"), "`n", "`r" {
        if (A_LoopField = "" || SubStr(A_LoopField, 1, 1) = ";")
            continue
        parts := StrSplit(A_LoopField, "|")
        if (parts.Length < 3)
            continue
        combo := Trim(parts[1])
        entries.Push({combo: combo, key: SubStr(combo, StrLen("Ctrl+Alt+Shift+") + 1),
            phrase: Trim(parts[2]), file: Trim(parts[3])})
    }
    return entries
}

; Wire a module in: manifest line + bridge-map record. The one AHK
; writer of both formats — NewAutomation and the companion creator
; both come through here. relModule is repo-relative ("hotkeys\X.ahk").
BridgeRegisterModule(root, key, phrase, relModule) {
    FileAppend('`n#Include "%A_ScriptDir%\' relModule '"', root "\hotkeys\_index.ahk", "UTF-8")
    FileAppend("Ctrl+Alt+Shift+" key "|" phrase "|" relModule "|" FormatTime(A_Now, "yyyy-MM-dd") "`n",
        root "\bridge-map.txt", "UTF-8")
}

; ============================================================
;  Companion hotkeys — "also press Ctrl+Alt+Shift+<key>" for any
;  voice automation, assigned from the Voice Kit home window (for
;  when voice isn't available). One generated module per
;  assignment: hotkeys\<Base>.hotkey.ahk — the .hotkey suffix is
;  the marker (scaffolded names come from CleanPhrase and can
;  never contain a dot). The module registers in _index.ahk and
;  bridge-map.txt like any other, so the key allocator and MCP
;  press_hotkey see it; listings fold it into its automation's
;  row instead of showing a second entry.
; ============================================================

; The convention's single source of truth: <base>'s companion module is
; hotkeys\<Base>.hotkey.ahk, repo-relative (the bridge-map FILE field).
; voicekit_writer.py COMPANION_SUFFIX mirrors the suffix.
HotkeyCompanionRel(base) {
    return "hotkeys\" base ".hotkey.ahk"
}

; Parent automation base for a bridge-map FILE field, or "" when the
; file isn't a companion module. The one recognizer.
HotkeyCompanionParent(relFile) {
    return RegExMatch(relFile, "i)^hotkeys\\(.+)\.hotkey\.ahk$", &m) ? m[1] : ""
}

; The companion module's full path for an automation base.
HotkeyCompanionFile(root, base) {
    return root "\" HotkeyCompanionRel(base)
}

; The key currently assigned to <base>, or "".
HotkeyCompanionKey(root, base) {
    rel := HotkeyCompanionRel(base)
    for e in BridgeMapEntries(root)
        if (e.file = rel)
            return e.key
    return ""
}

; Create <base>'s companion module, load-check it, then wire it into
; _index.ahk + bridge-map.txt. Returns "" on success, else an error
; message (and nothing is wired). The CALLER reloads the master.
; sayPhrase is the spoken phrase (e.g. "open morning tabs").
HotkeyCompanionCreate(root, base, sayPhrase, key) {
    modFile := HotkeyCompanionFile(root, base)
    ; base/say come from our own generators, but hand-dropped macro
    ; files can be named anything — escape ` and " for the literals.
    say := StrReplace(StrReplace(sayPhrase, "``", "````"), '"', '``"')
    content := "#Requires AutoHotkey v2.0`n"
        . "; ============================================================`n"
        . ';  Hotkey for "' say '"   (created ' FormatTime(A_Now, "yyyy-MM-dd") ")`n"
        . ";  Loaded by VoiceKit.ahk — do not run this file directly.`n"
        . ";`n"
        . ";  Trigger key:  Ctrl+Alt+Shift+" key "`n"
        . ";  Runs:  macros\" base ".ahk — the same automation as saying`n"
        . ';  "' say '".`n'
        . ";`n"
        . ';  Companion hotkey, managed in Voice Kit (say "open voice kit",`n'
        . ";  select the automation, click Hotkey). No Voice Access pairing`n"
        . ";  needed — this key is for when you can't use your voice.`n"
        . "; ============================================================`n`n"
        . "^!+" key ":: {`n"
        . '    target := A_ScriptDir "\macros\' base '.ahk"`n'
        . "    if !FileExist(target) {`n"
        . '        TrayTip("The automation for Ctrl+Alt+Shift+' key ' is gone — remove its hotkey in Voice Kit.", "VoiceKit")`n'
        . "        return`n"
        . "    }`n"
        . "    q := Chr(34)                     `; association-proof: run via the interpreter`n"
        . "    Run(q A_AhkPath q ' ' q target q)`n"
        . "}`n"
    try FileDelete(modFile)
    FileAppend(content, modFile, "UTF-8")
    ; Load-check BEFORE wiring it in: a module that fails to parse would
    ; take every hotkey and snippet down when the master reloads.
    rc := RunWait('"' A_AhkPath '" /ErrorStdOut /validate "' modFile '"', , "Hide")
    if (rc != 0) {
        try FileDelete(modFile)
        return "The generated hotkey file failed its load check — nothing was changed."
    }
    BridgeRegisterModule(root, key, sayPhrase, HotkeyCompanionRel(base))
    return ""
}

; Remove <base>'s companion hotkey (module + _index + bridge-map lines).
; Returns true if there was one — the caller reloads the master so the
; key stops working now. No-op (and no file churn) when none exists.
HotkeyCompanionRemove(root, base) {
    modFile := HotkeyCompanionFile(root, base)
    if (!FileExist(modFile) && HotkeyCompanionKey(root, base) = "")
        return false
    rel := HotkeyCompanionRel(base)
    try FileDelete(modFile)
    RemoveLinesContaining(root "\hotkeys\_index.ahk", "\" rel)
    RemoveLinesContaining(root "\bridge-map.txt", "|" rel "|")
    return true
}

; Remove <base>'s companion and, when there was one, reload the master
; so the key stops working now — the delete flows' one-liner.
HotkeyCompanionRetire(root, base) {
    if HotkeyCompanionRemove(root, base)
        RunAhk(root "\VoiceKit.ahk")
}

; Delete a saved workflow's artifacts, all five: steps file, generated
; stub (only when it carries the "Workflow Studio" marker — hand-written
; macros are never clobbered), the phrase and "loop <phrase>" Start Menu
; entries, and any companion hotkey (reloading the master if one
; existed). disp is the spoken/display phrase the .lnk files are named
; by. Home and Workflow Studio both delete through here.
DeleteWorkflowArtifacts(root, base, disp) {
    try FileDelete(root "\workflows\" base ".steps.txt")
    stub := root "\macros\" base ".ahk"
    if (FileExist(stub) && InStr(FileRead(stub, "UTF-8"), "Workflow Studio"))
        try FileDelete(stub)
    try FileDelete(A_Programs "\Voice Macros\" disp ".lnk")
    try FileDelete(A_Programs "\Voice Macros\loop " disp ".lnk")
    HotkeyCompanionRetire(root, base)
}
