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

; Normalize a raw name into a clean, speakable Title Case phrase. Trimmed
; AFTER the strip too: "! foo" (or a leading newline, which Trim leaves)
; would otherwise keep a leading space that no base or .lnk name carries.
; voicekit_writer.clean_phrase mirrors this (test_generators_match_ahk).
CleanPhrase(raw) {
    p := RegExReplace(Trim(raw), "[^A-Za-z0-9 ]", "")
    p := RegExReplace(p, "\s+", " ")
    return StrTitle(Trim(p))
}

; "MorningTabs" -> "Morning Tabs" — the spoken phrase for a file base. The
; inverse convention to how bases are formed, so shortcuts regenerate the
; same name on any machine.
SpaceOut(camel) {
    return Trim(RegExReplace(camel, "([a-z0-9])([A-Z])", "$1 $2"))
}

; s cut to n characters (plus "...") for a one-line display.
Abbrev(s, n) {
    return StrLen(s) > n ? SubStr(s, 1, n) "..." : s
}

; ---- Generating AHK source ---------------------------------------------------
; The two escapes any generated string literal needs: the escape character
; itself first, then the quote. (Header comments that quote a phrase use
; this bare form; AhkStrLit below is the full literal.)
AhkStrEsc(s) {
    return StrReplace(StrReplace(s, "``", "````"), '"', '``"')
}

; A value as an AutoHotkey v2 double-quoted string literal. Every ";" is
; escaped too: one preceded by whitespace starts a COMMENT even inside a
; string (see the traps in CLAUDE.md), so an Always-On Hotkey typing
; "SELECT 1 ; SELECT 2" generated a module that couldn't load. `; decodes
; back to ; inside a string, so escaping every one is harmless.
; mcp\voicekit_writer.ahk_str_lit mirrors this byte for byte —
; test_ahk_str_lit_matches_ahk runs both on the same inputs.
AhkStrLit(s) {
    s := AhkStrEsc(s)
    s := StrReplace(s, ";", "``;")
    s := StrReplace(s, "`r", "")
    s := StrReplace(s, "`n", "``n")
    return '"' s '"'
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

; One hotstring line (":*:abbrev::text") -> {opts, abbrev, text}, or "" for
; any other line. opts is what sits between the first two colons ("*" for
; ours); text is the ON-DISK (still encoded) replacement. THE parser — Home's
; listing, its editor and delete, and New Automation all come through here.
; Compare abbreviations with = (caseless): hotstrings fire caselessly, so a
; case-differing duplicate would load but never fire.
SnippetParseLine(line) {
    return RegExMatch(line, "^:([^:]*):(.+?)::(.*)$", &m)
        ? {opts: m[1], abbrev: m[2], text: m[3]} : ""
}

; True when `file` already has a snippet for `abbr` (caselessly).
SnippetExists(file, abbr) {
    if !FileExist(file)
        return false
    Loop Parse FileRead(file, "UTF-8"), "`n", "`r" {
        s := SnippetParseLine(A_LoopField)
        if (IsObject(s) && s.abbrev = abbr)
            return true
    }
    return false
}

; Why (abbr, expansion) can't be a snippet, or "" when it can. abbr is
; already whitespace-stripped. Every rule exists because ONE bad line makes
; hotkeys\Snippets.ahk fail to load, and the reload preflight then parks the
; whole file — every snippet the user owns: a colon ends the abbreviation
; early, a backtick is AHK's escape character (measured: ":*:ab`::hello" is
; "Invalid hotkey"), and a lone "{" opens a code block. The expansion itself
; is safe once SnipEncode has escaped it. voicekit_writer.create_snippet
; applies the same rules.
SnippetValidate(abbr, expansion) {
    if (abbr = "")
        return "The abbreviation can't be empty."
    if (InStr(abbr, ":") || InStr(abbr, "``"))
        return "The abbreviation can't contain a colon (:) or a backtick (``) — either one breaks the snippets file."
    if (Trim(expansion, " `t`r`n") = "")
        return "Give it the text to expand into."
    if (Trim(expansion) = "{")
        return "The text can't be just '{' — that's code syntax in the snippets file. Add the rest of the text."
    return ""
}

; Remove one hotstring by its abbreviation. True if a line went.
RemoveSnippetLine(file, abbr) {
    if !FileExist(file)
        return false
    out := "", found := false
    Loop Parse FileRead(file, "UTF-8"), "`n", "`r" {
        s := SnippetParseLine(A_LoopField)
        if (IsObject(s) && s.abbrev = abbr) {
            found := true
            continue
        }
        out .= A_LoopField "`n"
    }
    if !found
        return false
    f := FileOpen(file, "w", "UTF-8")
    f.Write(RTrim(out, "`n") "`n")
    f.Close()
    return true
}

; Rewrite one hotstring in place, matched by its current abbreviation.
; Preserves its position, its options (:*: vs ::), and any comment above it —
; only the abbreviation and replacement change. True if it was found.
ReplaceSnippetLine(file, oldAbbr, newAbbr, encoded) {
    if !FileExist(file)
        return false
    out := "", found := false
    Loop Parse FileRead(file, "UTF-8"), "`n", "`r" {
        s := SnippetParseLine(A_LoopField)
        if (!found && IsObject(s) && s.abbrev = oldAbbr) {
            out .= ":" s.opts ":" newAbbr "::" encoded "`n"
            found := true
        } else {
            out .= A_LoopField "`n"
        }
    }
    if found {
        f := FileOpen(file, "w", "UTF-8")
        f.Write(RTrim(out, "`n") "`n")
        f.Close()
    }
    return found
}

; Change the snippets file through `change` (a function that edits it and
; returns true when it did), then load-check the result. A file that no
; longer loads is put back byte for byte — left in place, the next reload
; would park it and switch off every snippet. Returns true when the change
; stands; false with err = "" when change() found nothing to do, or with the
; load check's text when it was rolled back.
; (voicekit_writer.create_snippet does the same check-and-restore.)
SnippetFileChange(file, change, &err := "") {
    err := ""
    existed := FileExist(file) != ""
    before := existed ? FileRead(file, "RAW") : ""
    if !change()
        return false
    v := AhkValidate(file)
    if v.ok
        return true
    if existed {
        h := FileOpen(file, "w")               ; no encoding given = no BOM added:
        h.RawWrite(before)                     ; the old bytes go back exactly
        h.Close()
    } else
        try FileDelete(file)
    err := (v.text != "" ? v.text : "The snippets file failed its load check.")
    return false
}

; Append one line to logs\created.log.
Log(root, text) {
    EnsureDir(root "\logs")
    LogTrimIfOver(root "\logs\created.log")
    FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm") " | " text "`n", root "\logs\created.log", "UTF-8")
}

; The cap for logs\created.log and logs\errors.log: past it, the oldest half
; goes (cut at a line boundary so the file never starts mid-line). The same
; rule the engine's WfLogTrim applies to workflow-runs.log — the engine keeps
; its own copy on purpose (it includes no _Common). A crash-looping body or a
; year of watchdog lines used to grow these without bound.
; mcp\voicekit_writer._log_trim_if_over mirrors this (Python writes created.log too).
LogCapBytes() {
    return 1048576
}

; The kept half is written to a temp file beside the log and moved over it
; (never delete-then-append: a process killed between the two used to lose
; the WHOLE log). If the move is refused — another writer holds the log
; without delete-sharing — the log is left as it was, over the cap until
; the next append tries again.
LogTrimIfOver(path, cap := 0) {
    try {
        if !FileExist(path) || FileGetSize(path) <= (cap ? cap : LogCapBytes())
            return false
        txt := FileRead(path, "UTF-8")
        cut := InStr(txt, "`n", , StrLen(txt) // 2)
        return FileReplaceText(path, cut ? SubStr(txt, cut + 1) : "")
    }
    return false
}

; Replace a file's whole content crash-safely: write <path>.tmp-<pid>
; (UTF-8 with BOM, like FileAppend creating a file) and move it over the
; original, so a kill mid-write leaves the old file whole. True on success;
; on failure the original is untouched and the temp file removed. Never throws.
FileReplaceText(path, text) {
    tmp := path ".tmp-" DllCall("GetCurrentProcessId", "uint")
    try {
        try FileDelete(tmp)
        FileAppend(text, tmp, "UTF-8")
        FileMove(tmp, path, 1)
        return true
    }
    try FileDelete(tmp)
    return false
}

; Move a file that something may still be holding. The race every "save a
; file an app just showed" flow loses eventually: a rename is blocked by ANY
; open handle without delete-sharing, so a bare FileMove throws for the
; second or two a PDF viewer / indexer / AV scan outlives its window
; (Split Pages hit exactly this at its FileMove line — 2026-07-27). Retry
; briefly; if the lock outlives the timeout, fall back to copying (a read
; lock blocks renaming, not reading) — the caller keeps its source file in
; that case and cleans it up when it can. Never throws.
; Returns "moved", "copied", or "" (both failed — e.g. an exclusive lock).
RobustMove(src, dst, timeoutMs := 1200, overwrite := false) {
    deadline := A_TickCount + timeoutMs
    loop {
        try {
            FileMove(src, dst, overwrite)
            return "moved"
        }
        if (A_TickCount >= deadline)
            break
        Sleep(150)
    }
    try {
        FileCopy(src, dst, overwrite)
        return "copied"
    }
    return ""
}

; ============================================================
;  Uncaught-error capture — logs\errors.log
;
;  A macro or body process that hits an uncaught error pops a
;  modal dialog and leaves NOTHING behind once it's dismissed,
;  so "it keeps crashing" has to be reconstructed by interview
;  (2026-08-05 feedback, from the Split Pages debugging run).
;  Every script that includes _Common.ahk now logs the error
;  first: one line — script name, message, file+line, the same
;  text the dialog shows — readable back through the MCP's
;  read_log("errors"). Returning 0 keeps stock behavior (the
;  dialog still appears; a host's own OnError still runs after
;  this one), so this observes, never changes outcomes. The
;  MASTER's richer handler (VoiceKit.ahk MasterError: status
;  file + TrayTip + return 1) runs second, relies on this line,
;  and no longer writes its own.
; ============================================================

ErrorLogFile(root := "") {
    if (root = "")
        root := A_LineFile "\..\.."            ; lib\_Common.ahk -> repo root
    return root "\logs\errors.log"
}

; One line for a thrown value: message plus file and line when it has them.
ErrorLogLine(err) {
    txt := "unknown error"
    try txt := (err is Error)
        ? err.Message (err.HasProp("File") && err.File != "" ? "   [" err.File " line " err.Line "]" : "")
        : String(err)
    return StrReplace(StrReplace(txt, "`r", " "), "`n", " ")
}

; Append one stamped line. Root is overridable so the self-test never
; writes into the user's real logs\. Never throws — an error logger that
; can itself error would recurse into the hole it exists to close.
ErrorLogAppend(line, root := "") {
    try {
        f := ErrorLogFile(root)
        SplitPath(f, , &dir)
        EnsureDir(dir)
        LogTrimIfOver(f)
        FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | " A_ScriptName " | " line "`n",
            f, "UTF-8")
    }
}

LogUncaughtError(err, mode) {
    ErrorLogAppend(ErrorLogLine(err))
    return 0            ; observe only — dialogs and later handlers proceed
}
; Top-level on purpose: it registers during the include, so every host —
; macros, bodies, the Studio, the master — gets the log line with no code
; of its own. (This is _Common.ahk's one piece of auto-execute code.)
OnError(LogUncaughtError)

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
    vmDir := VoiceMacrosDir()
    EnsureDir(vmDir)
    MakeAhkShortcut(vmDir "\loop " phrase ".lnk", root "\lib\LoopRunner.ahk", root, '"' base '"')
}

; ---- Voice Macros (the Start Menu folder Voice Access opens from) ----------
; testDir: self-tests only — VoiceMacrosDir(sandbox) points every shortcut
; helper (create, collision check, delete) at a %TEMP% folder for the rest
; of that process, so a test can never touch the user's real entries (the
; MCP side's _sandbox retargets voicekit_writer.VOICE_MACROS the same way).
VoiceMacrosDir(testDir := "") {
    static dir := ""
    if (testDir != "")
        dir := testDir
    return (dir != "") ? dir : A_Programs "\Voice Macros"
}

; A macro base's Start Menu entry name, which IS its spoken phrase: SpaceOut
; of the base, with the one exception that the home window is "Voice Kit"
; (say "open voice kit"). The names must stay byte-identical to what
; mcp\voicekit_writer creates and checks — both sides' phrase-collision
; checks look for these exact files.
VoiceShortcutName(base) {
    return (base = "VoiceKitHome") ? "Voice Kit" : SpaceOut(base)
}

; Self-heal one entry: create <disp>.lnk for `script` if it's missing.
; Returns the .lnk path.
EnsureVoiceShortcut(disp, script) {
    dir := VoiceMacrosDir()
    EnsureDir(dir)
    lnk := dir "\" disp ".lnk"
    if !FileExist(lnk)
        MakeAhkShortcut(lnk, script)
    return lnk
}

; A new macro's name must be free wherever its voice phrase lives: no
; macros\<base>.ahk yet, and no Start Menu entry already answering to the
; phrase. Returns the entry name — SpaceOut(base), the name Home's list, its
; Delete and a reinstall all reconstruct, so they never drift (phrases with
; digits, like "Plan 9", don't round-trip through SpaceOut otherwise) — or
; "" after saying why in a MsgBox owned by the calling dialog.
ClaimNewMacroName(root, base, ownerHwnd, title := "New Automation") {
    if FileExist(root "\macros\" base ".ahk") {
        MsgBox("An automation named '" base "' already exists. Pick another name.",
            title, "Icon! Owner" ownerHwnd)
        return ""
    }
    disp := SpaceOut(base)
    if FileExist(VoiceMacrosDir() "\" disp ".lnk") {
        MsgBox("The voice phrase `"open " disp "`" is already taken by another entry. Pick another name.",
            title, "Icon! Owner" ownerHwnd)
        return ""
    }
    return disp
}

; ============================================================
;  VoiceKit's own tools — the ONE AHK list. Home shows them as
;  tools (not deletable, nothing to edit); the Studio refuses to
;  save a workflow over one (a workflow stub would overwrite the
;  tool's own source). mcp\voicekit_writer._BUILTINS mirrors the
;  names, and test_builtin_tools_match_ahk runs this code to
;  compare the two.
; ============================================================
VkBuiltinTools() {
    static tools := 0
    if !tools {
        tools := Map()
        tools.CaseSense := false        ; "Ask AI" cleans to base AskAi; NTFS matches AskAI.ahk
        tools.Set("NewAutomation",  "create any new automation",
                  "WorkflowStudio", "record or edit step workflows",
                  "RecordMySteps",  "start recording a new workflow now",
                  "AskAI",          "ask the AI anything, hands-free",
                  "VoiceKitHome",   "this window",
                  "VoiceKitHelp",   "this window (older phrase)")
    }
    return tools
}

; Shipped tools that are delete-protected but stay EDITABLE — hand-written
; scripts someone may well need to fix in place (Split Pages is the case that
; prompted it). voicekit_writer._DELETE_PROTECTED_LOWER mirrors the union.
VkEditableTools() {
    return ["SplitPages"]
}

; True for anything in either list (caseless).
VkDeleteProtected(base) {
    if VkBuiltinTools().Has(base)
        return true
    for t in VkEditableTools()
        if (t = base)
            return true
    return false
}

; ============================================================
;  Workflow Studio, seen from outside. It is #SingleInstance
;  Force, so launching it over an open session silently kills
;  that session, unsaved steps and all — and it HIDES its main
;  window while recording or testing, so a plain WinExist says
;  "not open" at exactly the moment a relaunch loses the most.
; ============================================================

; {hwnd, visible}: hwnd 0 = not running; visible false = busy (recording or
; testing). The caller's hidden-window setting is restored, not forced off.
StudioWindow() {
    prev := A_DetectHiddenWindows
    DetectHiddenWindows(true)
    hwnd := 0
    try hwnd := WinExist("Workflow Studio ahk_class AutoHotkeyGUI")
    DetectHiddenWindows(prev)
    return {hwnd: hwnd, visible: hwnd ? !!DllCall("IsWindowVisible", "ptr", hwnd) : false}
}

; Open the Studio without ever replacing a live one. arg (optional) is its
; command-line argument — a steps file to load, or /record. Returns:
;   "launched"   none was running; started with arg
;   "activated"  one is open and idle — brought to the front; arg NOT applied
;   "busy"       one is recording or testing (window hidden) — left alone;
;                busyMsg, when given, is shown in an always-on-top MsgBox
OpenStudioSafely(root, arg := "", busyMsg := "") {
    s := StudioWindow()
    if (s.hwnd && !s.visible) {
        if (busyMsg != "")
            MsgBox(busyMsg, "VoiceKit", "Icon! 262144")
        return "busy"
    }
    if s.hwnd {
        try WinActivate("ahk_id " s.hwnd)
        return "activated"
    }
    cmd := '"' A_AhkPath '" "' root '\macros\WorkflowStudio.ahk"'
    if (arg != "")
        cmd .= ' "' arg '"'
    Run(cmd)
    return "launched"
}

; The line every generated workflow stub (macros\<Base>.ahk) carries. The
; Studio's overwrite guard and DeleteWorkflowArtifacts look for it, so a
; hand-written macro is never clobbered. The full line, not just "Workflow
; Studio": several of VoiceKit's own tools merely MENTION the Studio, and
; the looser check let a workflow named "New Automation" overwrite that
; tool. voicekit_writer.STUDIO_MARKER is the same string.
IsWorkflowStub(file) {
    txt := ""
    try txt := FileRead(file, "UTF-8")
    return InStr(txt, "Generated by Workflow Studio") > 0
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
; Caseless (InStr's default). True if any line went.
RemoveLinesContaining(file, needle) {
    if !FileExist(file)
        return false
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
        return false
    f := FileOpen(file, "w", "UTF-8")
    f.Write(RTrim(out, "`n") "`n")
    f.Close()
    return true
}

; Comment out every line of `file` that contains `needle` (lines already
; commented are left alone), tagging each with why. hotkeys\_index.ahk's
; own header documents ";" as the way to disable a module — this is that,
; done for the user when a module won't load.
CommentOutLinesContaining(file, needle, note := "") {
    if !FileExist(file)
        return false
    out := "", found := false
    Loop Parse FileRead(file, "UTF-8"), "`n", "`r" {
        line := A_LoopField
        if (InStr(line, needle) && SubStr(LTrim(line), 1, 1) != ";") {
            found := true
            ; No second ";" in the tag — the whole line is a comment now.
            ; (A space-preceded ";" inside a string starts a comment in AHK
            ;  v2 and would break this file; see SnipEncode for the same trap.)
            line := "; " line (note != "" ? "    " note : "")
        }
        out .= line "`n"
    }
    if !found
        return false
    f := FileOpen(file, "w", "UTF-8")
    f.Write(RTrim(out, "`n") "`n")
    f.Close()
    return true
}

; ============================================================
;  Reloading the master — the one chokepoint.
;
;  VoiceKit.ahk pulls hotkeys\_index.ahk in at COMPILE time, so a
;  single module that doesn't parse means the master never starts:
;  every hotkey AND every snippet dies with it, and it stays dead
;  until someone restarts it by hand. So: never reload into a
;  config that hasn't been load-checked first. A module that fails
;  is parked (its #Include commented out) and everything else
;  keeps working; a broken CORE file leaves the running master
;  alone entirely.
; ============================================================

; The command interpreter, even from a stripped environment. A_ComSpec is
; the ComSpec environment variable, and a process started with a scrubbed
; environment has none (errors.log, 2026-08-05: the launcher died at login
; because RunWait was handed an empty program) — and then no SystemRoot
; either, so that is no fallback. A_WinDir comes from GetWindowsDirectory,
; not the environment, so it survives.
ComSpecPath() {
    return (A_ComSpec != "") ? A_ComSpec : A_WinDir "\System32\cmd.exe"
}

; Load-check a script. Returns {ok, text, timedOut} — text is the
; /ErrorStdOut output, whose first line names the file and line that failed.
;
; The output goes through a cmd.exe file redirect, not a pipe: AutoHotkey
; is a GUI-subsystem exe, so /ErrorStdOut only lands somewhere when a real
; stdout handle exists, and a WScript.Shell.Exec pipe does NOT qualify —
; it comes back empty, which would silently disable quarantining (an empty
; error text names no module to park). Measured, not assumed.
;
; Bounded, because /validate is NOT always dialog-free: a #Warn warning
; still pops its MsgBox under /validate /ErrorStdOut (measured — and with
; the Hide flag nobody can even see it), so an unbounded wait hung every
; reload, every preflight and the login launcher forever. After timeoutMs
; the whole tree (cmd + its AutoHotkey child) is killed and the check
; fails with timedOut=true and a note saying what blocked it.
AhkValidate(file, timeoutMs := 20000) {
    outFile := A_Temp "\voicekit-validate-" DllCall("GetCurrentProcessId") "-" A_TickCount ".txt"
    try FileDelete(outFile)
    cmd := ComSpecPath() ' /c ""' A_AhkPath '" /ErrorStdOut=UTF-8 /validate "' file '"'
        . ' > "' outFile '" 2>&1"'
    readOut() {
        t := ""
        try t := Trim(FileRead(outFile, "UTF-8"))
        try FileDelete(outFile)
        return t
    }
    pid := 0
    try Run(cmd, , "Hide", &pid)
    catch as e {
        readOut()
        return {ok: false, timedOut: false,
            text: "Couldn't run the load check for " file ": " e.Message}
    }
    ; SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION: a handle keeps the
    ; exit code readable after the process ends.
    h := DllCall("OpenProcess", "uint", 0x101000, "int", 0, "uint", pid, "ptr")
    deadline := A_TickCount + timeoutMs
    if !h {
        ; No handle (in practice: already gone before we could look), so no
        ; exit code either. Still bounded: wait out the same deadline by PID,
        ; then judge by the output — /ErrorStdOut writes text only on failure.
        while ProcessExist(pid) {
            if (A_TickCount >= deadline) {
                try RunWait('"' A_WinDir '\System32\taskkill.exe" /T /F /PID ' pid, , "Hide")
                readOut()
                return {ok: false, timedOut: true,
                    text: "The load check of " file " didn't finish within "
                    . Round(timeoutMs / 1000) " s, so it was stopped."}
            }
            Sleep(30)
        }
        t := readOut()
        return {ok: (t = ""), timedOut: false, text: t}
    }
    timedOut := false
    while (DllCall("WaitForSingleObject", "ptr", h, "uint", 0, "uint") = 258) {   ; WAIT_TIMEOUT
        if (A_TickCount >= deadline) {
            timedOut := true
            break
        }
        Sleep(30)                       ; pumps messages, like RunWait did
    }
    if timedOut {
        ; /T takes the AutoHotkey child with the cmd.exe that started it.
        try RunWait('"' A_WinDir '\System32\taskkill.exe" /T /F /PID ' pid, , "Hide")
        DllCall("WaitForSingleObject", "ptr", h, "uint", 3000, "uint")
        DllCall("CloseHandle", "ptr", h)
        partial := readOut()
        return {ok: false, timedOut: true,
            text: "The load check of " file " didn't finish within " Round(timeoutMs / 1000)
            . " s, so it was stopped. Something in it is waiting on a dialog nobody can see"
            . " — almost always a #Warn warning, which pops a message box even during a"
            . " load check. Remove #Warn (or fix what it warns about) and try again."
            . (partial != "" ? "`n" partial : "")}
    }
    rc := 1
    DllCall("GetExitCodeProcess", "ptr", h, "uint*", &rc)
    DllCall("CloseHandle", "ptr", h)
    return {ok: (rc = 0), timedOut: false, text: readOut()}
}

; The repo-relative module an AHK load error points at ("hotkeys\Foo.ahk"),
; or "" when the failure isn't in a module we're allowed to park. Error
; lines look like:  C:\...\hotkeys\Foo.ahk (12) : ==> Missing "}"
MasterErrorModule(errText) {
    if (errText = "")
        return ""
    if !RegExMatch(errText, "m)^\s*(\S.*?\.ahk) \(\d+\)", &m)
        return ""
    ; A module whose FILE is gone (deleted by hand, or a delete that missed
    ; its manifest line): AutoHotkey blames the file doing the including,
    ;   ...\hotkeys\_index.ahk (7) : ==> #Include file "...\hotkeys\Gone.ahk" cannot be opened.
    ; and the manifest can't park itself — so name the MISSING module, whose
    ; line in the manifest is what gets commented out. Only when the manifest
    ; is the includer: a missing file included from inside a module already
    ; blames that module, which is the right one to park.
    if RegExMatch(m[1], "i)\\hotkeys\\_index\.ahk$")
        return RegExMatch(errText, 'i)#Include file "[^"]*\\(hotkeys\\[^"\\]+\.ahk)" cannot be opened', &miss)
            ? miss[1] : ""
    ; Only hotkeys\ modules get parked. A broken lib\ or VoiceKit.ahk is
    ; ours to fix — disabling it would just break VoiceKit differently.
    return RegExMatch(m[1], "i)\\(hotkeys\\[^\\]+\.ahk)$", &rel) ? rel[1] : ""
}

; Active modules that carry a #Warn directive — the suspects when the
; master's load check times out (see AhkValidate: a #Warn warning is the
; one thing that turns /validate into a dialog nobody can see).
MasterWarnModules(root) {
    out := []
    for rel in IndexModules(root).active {
        txt := ""
        try txt := FileRead(root "\" rel, "UTF-8")
        if RegExMatch(txt, "im)^[ \t]*#Warn\b")
            out.Push(rel)
    }
    return out
}

; Make sure the master will load, parking broken modules until it does.
; Returns {ok, note}: ok=false means don't reload (the note explains why);
; a non-empty note with ok=true means it will load, but something was
; parked and the user should hear about it.
MasterPreflight(root, validateMs := 20000) {   ; validateMs: per-check bound (tests shorten it)
    master := root "\VoiceKit.ahk"
    index  := root "\hotkeys\_index.ahk"
    parked := []
    stamp  := FormatTime(A_Now, "yyyy-MM-dd")
    ; The live per-user files first: a fresh install has none (they are
    ; made from the shipped *.default files), and an upgrade may ship a
    ; hotkey the live manifest doesn't list yet. Every start path — the
    ; launcher, every reload, the MCP — comes through here.
    SeedUserFilesLogged(root)
    Loop 6 {                        ; one broken module can hide the next
        v := AhkValidate(master, validateMs)
        ; A timeout is USUALLY a #Warn dialog, but a slow login, an
        ; antivirus scan or disk contention can do it too — and parking
        ; (or refusing to start) on that would punish modules that load
        ; fine. So one retry at twice the bound before believing it.
        if v.timedOut
            v := AhkValidate(master, validateMs * 2)
        if v.ok
            return {ok: true, note: parked.Length ? MasterParkedNote(parked) : ""}
        if v.timedOut {
            ; No error text to read — a dialog blocked the check. The
            ; suspects are the modules carrying #Warn; park them all at once.
            hit := false
            for rel in MasterWarnModules(root) {
                if !CommentOutLinesContaining(index, "\" rel,
                        "quarantined " stamp " — its #Warn warning blocked the load check")
                    continue
                hit := true
                parked.Push(rel)
                Log(root, "quarantined | " rel " | #Warn blocked the load check")
            }
            if !hit
                return {ok: false, note: MasterBrokenNote(parked, v.text)}
            continue
        }
        rel := MasterErrorModule(v.text)
        why := (rel != "" && !FileExist(root "\" rel)) ? "this file is missing"
                                                       : "this file failed to load"
        if (rel = "" || !CommentOutLinesContaining(index, "\" rel,
                "quarantined " stamp " — " why))
            return {ok: false, note: MasterBrokenNote(parked, v.text)}
        parked.Push(rel)
        Log(root, "quarantined | " rel " | " StrReplace(StrReplace(v.text, "`r", " "), "`n", " "))
    }
    v := AhkValidate(master, validateMs)       ; six in a row — stop churning the manifest
    return v.ok ? {ok: true, note: MasterParkedNote(parked)}
                : {ok: false, note: MasterBrokenNote(parked, v.text)}
}

MasterParkedNote(parked) {
    list := ""
    for p in parked
        list .= "`n    • " p
    return "VoiceKit turned off " parked.Length " file" (parked.Length = 1 ? "" : "s")
        . " that wouldn't load, so everything else keeps working:" list
        . "`n`nFix the file and reload VoiceKit (Ctrl+Alt+Shift+R) — each one's line in "
        . "hotkeys\_index.ahk is commented out, ready to turn back on."
}

MasterBrokenNote(parked, errText) {
    note := "VoiceKit couldn't be reloaded: the files as they stand won't load, so the "
        . "copy that's already running was left alone."
    if parked.Length
        note .= "`n`n" MasterParkedNote(parked)
    return note (errText != "" ? "`n`n" errText : "")
}

; Reload the resident master so a new module / snippet goes live — after
; making sure it will actually load (a refused reload leaves the running
; master intact, which is the entire point). Speaks up if anything had to
; be parked or the reload was refused; returns that note ("" = all well).
; The message goes up BEFORE the relaunch on purpose: when the MASTER
; itself calls this (Ctrl+Alt+Shift+R), the new instance replaces this
; process the moment RunAhk returns, taking any dialog it owns with it.
; launched (optional out-param) is true when a replacement master was
; started — a master calling this from its own auto-execute section must
; then stop at once (see VoiceKit.ahk), not race its replacement.
ReloadMasterNotify(root, &launched := false) {
    launched := false
    r := MasterPreflight(root)
    if (r.note != "")
        MsgBox(r.note, "VoiceKit", "Icon! 262144")   ; 262144 = always-on-top
    if r.ok {
        RunAhk(root "\VoiceKit.ahk")
        launched := true
    }
    return r.note
}

; Join an array into a delimited string.
JoinList(arr, sep := "|") {
    out := ""
    for v in arr
        out .= (out != "" ? sep : "") v
    return out
}

; The modules hotkeys\_index.ahk lists, split into the ones that load and
; the ones the preflight parked. Both are repo-relative ("hotkeys\Foo.ahk").
; mcp\voicekit_writer.index_modules mirrors this.
IndexModules(root) {
    active := [], parked := []
    idx := root "\hotkeys\_index.ahk"
    if FileExist(idx) {
        Loop Parse FileRead(idx, "UTF-8"), "`n", "`r" {
            line := Trim(A_LoopField)
            if !RegExMatch(line, "i)#Include\s+`"%A_ScriptDir%\\(hotkeys\\[^`"]+)`"", &m)
                continue
            (SubStr(line, 1, 1) = ";") ? parked.Push(m[1]) : active.Push(m[1])
        }
    }
    return {active: active, quarantined: parked}
}

; ============================================================
;  Per-user files: shipped defaults vs live copies (2026-09-30)
;
;  hotkeys\_index.ahk, bridge-map.txt and hotkeys\Snippets.ahk are
;  both what VoiceKit ships AND what every create/delete rewrites,
;  so tracking them in git kept personal wiring one `commit -a`
;  away from the remote, and an upgrade could not add a newly
;  shipped hotkey without overwriting the user's copy (the
;  RecordMySteps ^!+W companion never reached upgraded installs).
;  Now git tracks <name>.default.<ext>; the live files are
;  gitignored, never shipped, and made here on every start:
;   - a missing live file is created from its default (byte copy);
;   - a SHIPPED _index include / bridge-map line missing from the
;     live file is appended — never reordering or duplicating user
;     lines, and never resurrecting one the user commented out (a
;     commented copy counts as present). Keyed by the module FILE,
;     so a companion whose key the user changed is still "present".
;     Skipped when the module file doesn't exist (a removed
;     companion stays removed) or when its key is already taken by
;     another line (two ^!+<k> definitions would stop the master
;     loading).
;  Snippets.ahk is seeded only, never merged: a snippet deleted in
;  Home must stay deleted.
;  Mirrored by mcp\voicekit_writer.seed_user_files — keep in step.
; ============================================================
UserFilePairs() {
    return [["hotkeys\_index.ahk", "hotkeys\_index.default.ahk"],
            ["bridge-map.txt", "bridge-map.default.txt"],
            ["hotkeys\Snippets.ahk", "hotkeys\Snippets.default.ahk"]]
}

; Returns {created: [rel...], merged: [line...], indexChanged: bool}.
; Never throws — this runs before the master exists.
SeedUserFiles(root) {
    out := {created: [], merged: [], indexChanged: false}
    for pair in UserFilePairs() {
        live := root "\" pair[1], def := root "\" pair[2]
        if (FileExist(live) || !FileExist(def))
            continue
        try {
            SplitPath(live, , &dir)
            EnsureDir(dir)
            FileCopy(def, live)
            out.created.Push(pair[1])
            if (pair[1] = "hotkeys\_index.ahk")
                out.indexChanged := true
        }
    }
    try SeedMergeShipped(root, out)
    return out
}

; SeedUserFiles, with anything it did written to logs\created.log.
SeedUserFilesLogged(root) {
    s := SeedUserFiles(root)
    for rel in s.created
        try Log(root, "seeded | " rel " | created from its shipped default")
    for l in s.merged
        try Log(root, "seeded | shipped line added | " l)
    return s
}

; The repo-relative module an _index line includes ("hotkeys\X.ahk"),
; commented-out lines included; "" when the line is no #Include of one.
SeedIncludeRel(line) {
    return RegExMatch(line, "i)#Include\s+`"%A_ScriptDir%\\(hotkeys\\[^`"]+)`"", &m) ? m[1] : ""
}

; {combo, file} of a bridge-map record line (a leading ; is stripped, so a
; commented-out record still parses), or "" for headers/blank/short lines.
SeedMapRecord(line) {
    line := LTrim(line, "; `t")
    parts := StrSplit(line, "|")
    if (parts.Length < 3 || Trim(parts[1]) = "" || Trim(parts[3]) = "")
        return ""
    return {combo: Trim(parts[1]), file: Trim(parts[3])}
}

SeedMergeShipped(root, out) {
    idx := root "\hotkeys\_index.ahk", idxDef := root "\hotkeys\_index.default.ahk"
    bmap := root "\bridge-map.txt", bmapDef := root "\bridge-map.default.txt"
    readOr(f) {
        t := ""
        try t := FileRead(f, "UTF-8")
        return t
    }
    liveIdx := readOr(idx), liveMap := readOr(bmap)
    ; Shipped includes (active lines only) and shipped records, by file.
    shipInc := [], shipRec := Map()
    shipRec.CaseSense := false
    if FileExist(idxDef)
        Loop Parse readOr(idxDef), "`n", "`r" {
            if (SubStr(LTrim(A_LoopField), 1, 1) != ";" && (rel := SeedIncludeRel(A_LoopField)) != "")
                shipInc.Push({rel: rel, line: Trim(A_LoopField)})
        }
    if FileExist(bmapDef)
        Loop Parse readOr(bmapDef), "`n", "`r" {
            if (SubStr(LTrim(A_LoopField), 1, 1) != ";" && IsObject(r := SeedMapRecord(A_LoopField)))
                shipRec[r.file] := {combo: r.combo, line: Trim(A_LoopField)}
        }
    ; What the live files already hold (commented-out lines count).
    haveInc := Map(), haveRec := Map()
    haveInc.CaseSense := false, haveRec.CaseSense := false
    Loop Parse liveIdx, "`n", "`r"
        if ((rel := SeedIncludeRel(A_LoopField)) != "")
            haveInc[rel] := true
    Loop Parse liveMap, "`n", "`r"
        if IsObject(r := SeedMapRecord(A_LoopField))
            haveRec[r.file] := true
    free := Map()
    for k in BridgeFreeKeys(bmap)
        free[k] := true
    prefix := "Ctrl+Alt+Shift+"
    keyFree(combo) => (SubStr(combo, 1, StrLen(prefix)) = prefix)
        && free.Has(StrUpper(SubStr(combo, StrLen(prefix) + 1)))

    addIdx := [], addMap := []
    blocked := Map()
    blocked.CaseSense := false
    ; A shipped record is merged only when its key is free; if it isn't,
    ; its include is held back too (the module would bind a taken key).
    for file, rec in shipRec {
        if (haveRec.Has(file) || !FileExist(root "\" file))
            continue
        if !keyFree(rec.combo) {
            blocked[file] := true
            continue
        }
        addMap.Push(rec.line)
        free.Delete(StrUpper(SubStr(rec.combo, StrLen(prefix) + 1)))
    }
    for inc in shipInc {
        if (haveInc.Has(inc.rel) || blocked.Has(inc.rel) || !FileExist(root "\" inc.rel))
            continue
        addIdx.Push(inc.line)
    }
    if addIdx.Length && SeedAppendLines(idx, liveIdx, addIdx)
        out.indexChanged := true
    if addMap.Length
        SeedAppendLines(bmap, liveMap, addMap)
    for l in addIdx
        out.merged.Push(l)
    for l in addMap
        out.merged.Push(l)
}

; Append lines to a live file in its own line-ending style, after a
; separator if its last line is unterminated. True on success.
SeedAppendLines(file, current, lines) {
    eol := InStr(current, "`r`n") ? "`r`n" : "`n"
    txt := (current != "" && SubStr(current, -1) != "`n") ? eol : ""
    for l in lines
        txt .= l eol
    try {
        FileAppend(txt, file, "UTF-8")
        return true
    }
    return false
}

; ============================================================
;  Master status — logs\master-status.ini
;
;  A heartbeat the watchdog reads to tell "crashed" apart from
;  "reloaded" (#SingleInstance Force kills the old process on
;  every reload, so a vanished PID proves nothing on its own),
;  and the file mcp\voicekit_writer._health() reports from, so
;  every MCP response can say whether the layer is actually up.
; ============================================================

MasterStatusFile(root) {
    return root "\logs\master-status.ini"
}

; True when the watchdog had to start the master with every module
; parked after a crash loop.
SafeModeFlag(root) {
    return root "\logs\safe-mode.flag"
}

; Stamp a fresh run: pid, start time, generation, module counts.
MasterStatusInit(root) {
    EnsureDir(root "\logs")
    f := MasterStatusFile(root)
    gen := 0
    try gen := Integer(IniRead(f, "Master", "generation", "0"))
    mods := IndexModules(root)
    try {
        IniWrite(DllCall("GetCurrentProcessId"), f, "Master", "pid")
        IniWrite(A_Now, f, "Master", "started")
        IniWrite(A_Now, f, "Master", "heartbeat")
        IniWrite(gen + 1, f, "Master", "generation")
        IniWrite(mods.active.Length, f, "Master", "modules")
        IniWrite(JoinList(mods.quarantined), f, "Master", "quarantined")
        IniWrite(FileExist(SafeModeFlag(root)) ? 1 : 0, f, "Master", "safe_mode")
        IniWrite(0, f, "Master", "clean_exit")
    }
}

; Called on a timer — the only thing the watchdog actually watches.
MasterStatusBeat(root) {
    try IniWrite(A_Now, MasterStatusFile(root), "Master", "heartbeat")
}

; Record that this exit was deliberate, so the watchdog stands down
; instead of resurrecting a master the user just closed. Also clears the
; watchdog's restart tally: a deliberate stop means the user is in
; control, and stale stamps must not count toward a later crash loop.
MasterStatusCleanExit(root) {
    try {
        IniWrite(1, MasterStatusFile(root), "Master", "clean_exit")
        IniWrite("", MasterStatusFile(root), "Watchdog", "restarts")
        IniWrite("", MasterStatusFile(root), "Watchdog", "hold_until")
    }
}

; Start the watchdog unless it's already up (Watchdog.ahk is #SingleInstance
; Ignore, so re-running after a reload leaves the running one in place — it
; keeps its restart stamps on disk and watches whichever master heartbeats). It is
; the only thing that can recover a HARD crash — an access violation from
; a bad ComCall leaves no exception to catch and no dialog to dismiss.
StartWatchdog(root) {
    wd := root "\lib\Watchdog.ahk"
    if FileExist(wd)
        try RunAhk(wd)
}

; ---- Watchdog decisions ---------------------------------------------
; Pure (no I/O): lib\Watchdog.ahk gathers the facts, these decide, and
; tests\preflight-selftest.ahk drives every branch without a master or a
; watchdog process in sight. They live here, not in Watchdog.ahk, because
; that file starts its poll timer the moment it is included.

; One poll's verdict. f = {statusExists, tickNow, lastTick, pollMs,
; holdActive, heartbeatFresh, cleanExit}; tickNow/lastTick are A_TickCount
; readings (lastTick 0 = first poll). Returns:
;   "idle"       no status file — nothing has ever started
;   "resumed"    this poll timer was frozen far past its interval, i.e. the
;                machine slept. On wake the watchdog's 3 s timer and the
;                master's 5 s heartbeat both come due at once, and whichever
;                runs first wins — so every heartbeat looks hours stale for
;                a moment, and a healthy master used to get "restarted" after
;                most resumes (114 such lines in one errors.log, each lining
;                up with a Power-Troubleshooter resume event). The caller
;                holds for the grace period instead. GetTickCount keeps
;                counting through sleep, which is what makes the gap visible.
;   "hold"       a hold (post-restart grace, resume, back-off) is running
;   "alive"      heartbeat fresh
;   "standdown"  the master exited on purpose
;   "restart"    stale heartbeat, no clean exit — it died
WatchdogDecide(f) {
    if !f.statusExists
        return "idle"
    if (f.lastTick && f.tickNow - f.lastTick > 3 * f.pollMs)
        return "resumed"
    if f.holdActive
        return "hold"
    if f.heartbeatFresh
        return "alive"
    if f.cleanExit
        return "standdown"
    return "restart"
}

; Restart stamps (a comma-separated list of A_Now values) still inside the
; crash window as of `now`, oldest first. Unreadable and future stamps drop.
WatchdogStampsInWindow(raw, now, windowS) {
    out := []
    for t in StrSplit(raw, ",") {
        t := Trim(t)
        if (t = "")
            continue
        age := -1
        try age := DateDiff(now, t, "Seconds")
        catch
            continue
        if (age >= 0 && age <= windowS)
            out.Push(t)
    }
    return out
}

; The bookkeeping for one restart about to happen at `now`: the stamps to
; save (in-window ones plus this one) and whether that makes a crash loop.
WatchdogRestartPlan(raw, now, windowS, limit) {
    stamps := WatchdogStampsInWindow(raw, now, windowS)
    stamps.Push(now)
    return {stamps: stamps, crashLoop: stamps.Length >= limit}
}

; The hold_until to save when asking for `seconds` of hold at `now`, given
; the one already saved (`existing`, "" = none). A hold only ever EXTENDS:
; a resume in the middle of the 10-minute crash-loop back-off must not cut
; it to the 20 s grace and relaunch a master that was still crash-looping
; (its restart stamps were cleared when the back-off began, so it would
; take three more crashes to back off again). An unreadable stamp is ignored.
WatchdogHoldUntil(existing, now, seconds) {
    target := DateAdd(now, seconds, "Seconds")
    if (existing != "") {
        later := false
        try later := DateDiff(existing, target, "Seconds") > 0
        if later
            return existing
    }
    return target
}

; ============================================================
;  Body status — logs\body-status-<Base>.txt
;
;  A hotkey body runs in its own process and can run for hours
;  (a queue of a few hundred items is a real case). Until now the
;  only way it could say where it had got to was its own ToolTip,
;  which nobody sees unless they're at the machine and which says
;  nothing once the run ends. So a body had no way to answer "is
;  it still going, and how far in?" — the same question the
;  master's heartbeat file answers for the layer itself.
;
;  Same shape as MasterStatusBeat, one file per body: overwrite a
;  single line, stamped, and let anyone read the latest. The home
;  window shows it on the module's row and list_automations
;  carries it, so the answer is one look or one MCP call away.
;
;  In a body:
;      #Include "%A_ScriptDir%\..\..\lib\_Common.ahk"
;      BodyStatus("MyModule", "3 / 766  —  Acme Holdings")
;      ...
;      BodyStatusDone("MyModule", "766 done")
;
;  Every call is try-wrapped: a status write must never be the
;  thing that stops the work it is reporting on.
;  (mcp\voicekit_writer.py body_status mirrors the read side.)
; ============================================================

; Where a body publishes. The base is sanitized rather than trusted: it
; usually comes from CleanPhrase, but a body may pass anything.
BodyStatusFile(base, root := "") {
    if (root = "")
        root := A_LineFile "\..\.."            ; lib\_Common.ahk -> repo root
    return root "\logs\body-status-" RegExReplace(base, "[^\w\-]") ".txt"
}

; Publish one line. Overwrites — this is "where am I now", not a log.
BodyStatus(base, text, root := "") {
    try {
        f := BodyStatusFile(base, root)
        SplitPath(f, , &dir)
        EnsureDir(dir)
        h := FileOpen(f, "w", "UTF-8")
        h.Write(A_Now "|" StrReplace(StrReplace(Trim(text), "`r", " "), "`n", " "))
        h.Close()
    }
    return text
}

; The finishing line. Nothing special on disk — it exists so a body reads
; as saying it FINISHED, rather than leaving its last progress line up
; forever looking like a run that stalled.
BodyStatusDone(base, text := "Finished", root := "") {
    return BodyStatus(base, text, root)
}

; Latest published line -> {text, when, age}, or "" if the body never
; published. `age` is seconds since it was written — a body that died
; leaves a line that simply stops getting older.
BodyStatusRead(base, root := "") {
    f := BodyStatusFile(base, root)
    if !FileExist(f)
        return ""
    txt := ""
    try txt := FileRead(f, "UTF-8")
    catch
        return ""
    txt := Trim(txt, " `t`r`n")
    if (txt = "")
        return ""
    p := InStr(txt, "|")
    when := p ? SubStr(txt, 1, p - 1) : ""
    text := p ? SubStr(txt, p + 1) : txt
    age := ""
    try age := DateDiff(A_Now, when, "Seconds")
    return {text: text, when: when, age: age}
}

BodyStatusClear(base, root := "") {
    try FileDelete(BodyStatusFile(base, root))
}

; ---- cooperative stop (2026-08-03) -------------------------------------
;  The status channel's other half: BodyStatus says where a body IS,
;  the stop flag says it should STOP. The MCP's stop_module drops
;  logs\body-stop-<Base>.flag and waits its grace period; a body that
;  checks BodyStopRequested() each loop pass gets to finish the item in
;  hand and exit cleanly instead of being force-killed mid-write.
;  Checking is opt-in — a body that never checks is force-killed after
;  the grace period, which is no worse than what happened before.

; Where a stop is requested. Mirrors BodyStatusFile: same root default,
; same sanitize — the two sides (this and voicekit_writer._body_stop_file)
; must derive the same name or a graceful stop can never happen.
BodyStopFile(base, root := "") {
    if (root = "")
        root := A_LineFile "\..\.."            ; lib\_Common.ahk -> repo root
    return root "\logs\body-stop-" RegExReplace(base, "[^\w\-]") ".flag"
}

; True once per request: the flag is CONSUMED on sight, so one request
; stops one run and a stale flag can't kill the next press.
BodyStopRequested(base, root := "") {
    f := BodyStopFile(base, root)
    if !FileExist(f)
        return false
    try FileDelete(f)
    return true
}

; ---- one instance per body (2026-08-03) --------------------------------
;  #SingleInstance is not enough for a body: it compares hidden-window
;  titles, and a starting script only creates that window once it has
;  finished loading — so two launches inside that gap BOTH pass the
;  check. Measured while investigating a real duplicate-scraper report:
;  two no-gap launches of a "#SingleInstance Ignore" script both
;  survived, while the other suspects were cleared (replacing the file
;  mid-run and a message-blocked instance were both still detected).
;  A kernel mutex is claimed atomically, so the second process ALWAYS
;  sees it, however narrow the gap. Generated bodies call this first
;  thing; the handle is held for the life of the process on purpose.
BodySingleInstance(base) {
    static hMutex := 0
    if hMutex                          ; this process already holds it
        return true
    name := "Local\VoiceKitBody_" RegExReplace(base, "[^\w\-]")
    hMutex := DllCall("CreateMutexW", "ptr", 0, "int", 0, "wstr", name, "ptr")
    if (A_LastError = 183) {           ; ERROR_ALREADY_EXISTS — another run won
        try DllCall("CloseHandle", "ptr", hMutex)
        ExitApp(0)                     ; mirror #SingleInstance Ignore: leave quietly
    }
    if !hMutex
        hMutex := 0                    ; CreateMutex failed outright — never let
    return true                        ; the guard stop legitimate work
}

; ============================================================
;  Bridge keys (Ctrl+Alt+Shift+<key>) — shared by the scaffolder
;  and the home window so they draw from ONE pool.
; ============================================================

; The allocatable keys, iterated one CHARACTER at a time. E, N, R are
; VoiceKit's own hotkeys, X is Workflow Studio's stop-recording / loop-stop
; key, and H / I / C are its mark-hover, ask-for-input and collect keys while
; recording — all seven stay out.
;
; Punctuation comes AFTER the letters and digits so auto-allocation still
; hands out a letter first and the symbols stay available for someone who
; asks for one. Every symbol here was measured (2026-07-31) to satisfy all
; three requirements: a generated module using it LOADS, Hotkey() can
; register ^!+<k>, and a synthesized `Send "^!+<k>"` at SendLevel 1 actually
; fires it (Ctrl+Alt+Shift+[ must not arrive as "{"). Deliberately absent:
; `"` breaks the string literals the generators emit, backtick is AHK's
; escape character, `|` is bridge-map.txt's field delimiter, and Space /
; Enter register fine but a synthesized press never fires them.
; (mcp\voicekit_writer.py BRIDGE_POOL mirrors this string.)
BridgeKeyPool() {
    return "ABDFGJKLMOPQSTUVWYZ0123456789[];',./-=\"
}

; Pool keys bridge-map.txt doesn't already hold, in pool order. THE rule
; for "is this key taken" — voicekit_writer._used_bridge_keys applies the
; identical one (test_used_bridge_keys_match_ahk runs both on one tricky
; map), because two rules that disagreed handed a key out twice. A key is
; used when EITHER
;   - the raw text holds "Ctrl+Alt+Shift+<k>|" anywhere (caseless), or
;   - a line — commented-out lines too, leading ; and blanks stripped — has
;     a first "|" field that, trimmed, is "Ctrl+Alt+Shift+<k>" (so a
;     hand-padded "Ctrl+Alt+Shift+B | ..." counts).
; Commented lines count on purpose: a parked registration may be switched
; back on, and handing its key to something else would make them collide.
BridgeFreeKeys(mapFile) {
    text := FileExist(mapFile) ? FileRead(mapFile, "UTF-8") : ""
    prefix := "Ctrl+Alt+Shift+"
    used := Map()
    Loop Parse text, "`n", "`r" {
        line := LTrim(A_LoopField, "; `t")
        bar := InStr(line, "|")                 ; (StrSplit("") is an EMPTY array)
        first := Trim(bar ? SubStr(line, 1, bar - 1) : line, " `t")
        if (SubStr(first, 1, StrLen(prefix)) = prefix) {       ; = is caseless
            k := StrUpper(Trim(SubStr(first, StrLen(prefix) + 1), " `t"))
            if (StrLen(k) = 1)
                used[k] := true
        }
    }
    free := []
    Loop Parse BridgeKeyPool() {
        if !used.Has(A_LoopField) && !InStr(text, prefix A_LoopField "|")
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
;  Isolated hotkey modules.
;
;  VoiceKit is ONE process holding every always-on hotkey and
;  every snippet. Custom module code can end that process
;  outright — a bad ComCall offset, an unpinned COM vtable (see
;  lib\Acc.ahk) — with no exception to catch: every other hotkey
;  and every snippet dies with it. So custom code doesn't live in
;  the master any more. hotkeys\<Base>.ahk is a key binding that
;  launches hotkeys\bodies\<Base>.body.ahk in its OWN process; a
;  crash there ends one short-lived process and nothing else.
;
;  The no-code generators (Open Something / Type Text) stay
;  in-process: they emit a single Run() or SendText() line that
;  cannot crash, and a process launch would only add latency.
;
;  mcp\voicekit_writer.py mirrors this convention (BODY_SUBDIR,
;  _body_rel, _hotkey_launcher_content, _hotkey_body_content).
; ============================================================

; <base>'s body script, repo-relative. The one definition of the layout.
HotkeyBodyRel(base) {
    return "hotkeys\bodies\" base ".body.ahk"
}

HotkeyBodyFile(root, base) {
    return root "\" HotkeyBodyRel(base)
}

; The key binding that goes in hotkeys\ and gets #Included by the master.
; date ("yyyy-MM-dd", default today) is only ever passed by the generator
; parity check (mcp\_conformance\generators.ahk), which pins it.
HotkeyLauncherContent(phrase, base, key, date := "") {
    ; A_ScriptDir below resolves to VoiceKit.ahk's folder, not this file's —
    ; the module is #Included into the master, like the companion modules.
    return "#Requires AutoHotkey v2.0`n"
        . "; ============================================================`n"
        . ";  " phrase "   (created " VkDateStamp(date) ")`n"
        . ";  Loaded by VoiceKit.ahk — do not run this file directly.`n"
        . ";`n"
        . ";  Trigger key:  Ctrl+Alt+Shift+" key "`n"
        . ";`n"
        . ";  EDIT THE STEPS IN:  " HotkeyBodyRel(base) "`n"
        . ";  They run in their own process on purpose. VoiceKit is one`n"
        . ";  process holding every hotkey and every snippet, and code that`n"
        . ";  crashes hard would take the whole lot down with it. Out there,`n"
        . ";  a crash ends one short-lived process and nothing else.`n"
        . ";`n"
        . ";  To trigger it by voice (one-time setup, ~30 seconds):`n"
        . ';    1. Say: "show voice shortcuts"`n'
        . ";    2. Create new shortcut  ->  When I say:  " phrase "`n"
        . ";    3. Action: Press keys   ->  Ctrl + Alt + Shift + " key "`n"
        . ";  This pairing is recorded in bridge-map.txt.`n"
        . "; ============================================================`n`n"
        . "^!+" key ":: {`n"
        . '    body := A_ScriptDir "\' HotkeyBodyRel(base) '"`n'
        . "    if !FileExist(body) {`n"
        ; ``n, not `n: single-quoted strings still process backtick escapes in
        ; AHK v2, so a bare `n here would put a REAL newline in the generated
        ; file and leave that TrayTip string unterminated. The trailing `n IS
        ; meant to be a real newline — it ends this output line.
        . '        TrayTip("The steps for Ctrl+Alt+Shift+' key ' are missing:``n" body, "VoiceKit")`n'
        . "        return`n"
        . "    }`n"
        . "    q := Chr(34)                     `; association-proof: run via the interpreter`n"
        . "    Run(q A_AhkPath q ' ' q body q)`n"
        . "}`n"
}

; The body script itself. `body` is the user's code (blank = a placeholder
; that says where to type).
HotkeyBodyContent(phrase, base, key, body := "", date := "") {
    say := AhkStrEsc(phrase)
    if (Trim(body) = "")
        body := "`; ==== YOUR STEPS BELOW — delete the MsgBox once it works ====`n"
            . 'MsgBox("' "'" say "'" ' is wired up! Now edit this file:``n" A_LineFile)'   ; ``n stays literal
    return "#Requires AutoHotkey v2.0`n"
        . "#SingleInstance Ignore`n"
        . "; ============================================================`n"
        . ';  Steps for "' say '"  —  Ctrl+Alt+Shift+' key "   (created "
        . VkDateStamp(date) ")`n"
        . ";`n"
        . ";  Runs in its own process, started by hotkeys\" base ".ahk every`n"
        . ";  time the key is pressed. A crash in here ends only this`n"
        . ";  process — VoiceKit, the other hotkeys and the snippets carry on.`n"
        . ";`n"
        . ";  #SingleInstance Ignore: pressing the key again while this is`n"
        . ";  still running is ignored rather than piling up processes.`n"
        . ";`n"
        . ";  Long job? Say where you are with BodyStatus — the Voice Kit`n"
        . ";  home window and the MCP listing both show the latest line, so`n"
        . ";  progress is visible without watching a ToolTip:`n"
        . ';    BodyStatus("' base '", "3 / 766  -  Acme Holdings")`n'
        . ';    BodyStatusDone("' base '", "766 done")`n'
        . ";`n"
        . ";  Long LOOP? Check the stop flag each pass - the stop_module`n"
        . ";  tool asks nicely (BodyStopRequested), waits, then force-kills:`n"
        . ';    if BodyStopRequested("' base '")`n'
        . ";        ExitApp()`n"
        . "; ============================================================`n"
        . '#Include "%A_ScriptDir%\..\..\lib\_Common.ahk"' "`n"
        . "`n"
        . "; One instance per module: #SingleInstance can lose a startup race`n"
        . "; (two presses in quick succession); the kernel mutex below cannot.`n"
        . 'BodySingleInstance("' base '")' "`n"
        . "`n"
        . body "`n"
}

; An always-on NO-CODE module (New Automation's Open Something / Type Text
; choices): one Run() or SendText() line, kept in-process — it can't crash,
; and launching a process would only add latency. actionLine is already
; valid AHK (build its literal with AhkStrLit); actionDesc is the header's
; one-line description of it.
HotkeyInProcessContent(phrase, key, actionLine, actionDesc) {
    return "#Requires AutoHotkey v2.0`n"
        . "; ============================================================`n"
        . ";  " phrase "   (created " FormatTime(A_Now, "yyyy-MM-dd") ")`n"
        . ";  Loaded by VoiceKit.ahk — do not run this file directly.`n"
        . ";  Trigger key:  Ctrl+Alt+Shift+" key "`n"
        . ";  " actionDesc "`n"
        . ";`n"
        . ";  Voice pairing (one-time, ~30 sec):`n"
        . ';    1. Say: "show voice shortcuts"`n'
        . ";    2. Create new shortcut  ->  When I say:  " phrase "`n"
        . ";    3. Action: Press keys   ->  Ctrl + Alt + Shift + " key "`n"
        . ";  This pairing is recorded in bridge-map.txt.`n"
        . "; ============================================================`n`n"
        . "^!+" key ":: {`n"
        . "    " actionLine "`n"
        . "}`n"
}

; New Automation's no-code "Open Something" launch macro: a header plus one
; Run() line. Keep the ";  Opens:  <target>" header line — the home window
; parses it for the row's detail text. An existing path with a space gets
; embedded quotes (Run needs them). mcp\voicekit_writer._opens_content
; mirrors this byte for byte (test_generators_match_ahk runs both).
VkOpensMacroContent(phrase, target, date := "") {
    runArg := (InStr(target, " ") && FileExist(target)) ? '"' target '"' : target
    return "#Requires AutoHotkey v2.0`n"
        . "#SingleInstance Force`n"
        . "; ============================================================`n"
        . ";  " phrase "   (created " VkDateStamp(date) ")`n"
        . ';  Trigger by voice:  "open ' phrase '"`n'
        . ";  Opens:  " target "`n"
        . ";`n"
        . ";  Created by New Automation — no code needed. To add steps,`n"
        . ";  edit below (building blocks: templates\launch-template.ahk).`n"
        . "; ============================================================`n"
        . '#Include "%A_ScriptDir%\..\lib\_Common.ahk"`n'
        . "Run(" AhkStrLit(runArg) ")`n"
}

; The header date the generators stamp: date as given, else today.
VkDateStamp(date := "") {
    return (date != "") ? date : FormatTime(A_Now, "yyyy-MM-dd")
}

; Write a generated script and load-check it BEFORE anything wires it in
; (a module that doesn't parse would take every hotkey and snippet down on
; the next reload); on failure it is deleted again. Returns true, or false
; with err set — the load check's own text included, so the message can
; name the line that broke.
AhkWriteChecked(file, content, &err := "") {
    err := ""
    SplitPath(file, , &dir)
    EnsureDir(dir)
    try FileDelete(file)
    FileAppend(content, file, "UTF-8")
    v := AhkValidate(file)
    if v.ok
        return true
    try FileDelete(file)
    err := "The generated file failed its load check — nothing was changed."
        . (v.text != "" ? "`n`n" v.text : "")
    return false
}

; The same for a hotkeys\ module (rel is repo-relative, "hotkeys\X.ahk").
HotkeyWriteChecked(root, rel, content, &err := "") {
    return AhkWriteChecked(root "\" rel, content, &err)
}

; Write both halves of an isolated module and load-check the launcher BEFORE
; the caller wires anything in. Returns "" on success, else the error (and
; neither file is left behind).
HotkeyIsolatedCreate(root, base, phrase, key, body := "") {
    EnsureDir(root "\hotkeys\bodies")
    bodyFile := HotkeyBodyFile(root, base)
    try FileDelete(bodyFile)
    FileAppend(HotkeyBodyContent(phrase, base, key, body), bodyFile, "UTF-8")
    ; Only the LAUNCHER is load-checked: it's the half the master #Includes,
    ; so a parse error there would take every hotkey down on the next reload.
    ; The body is deliberately not gated — it runs in its own process, where a
    ; mistake costs that process and nothing else, and the user is usually
    ; about to edit it anyway.
    if !HotkeyWriteChecked(root, "hotkeys\" base ".ahk", HotkeyLauncherContent(phrase, base, key), &err) {
        try FileDelete(bodyFile)
        return err
    }
    return ""
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

; The companion module's text. sayPhrase is the spoken phrase.
HotkeyCompanionContent(base, sayPhrase, key) {
    ; base/say come from our own generators, but hand-dropped macro
    ; files can be named anything — escape ` and " for the literals.
    say := AhkStrEsc(sayPhrase)
    return "#Requires AutoHotkey v2.0`n"
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
}

; Give <base> the companion key `key` — replacing the one it has, if any —
; load-checked BEFORE anything is wired in (a module that fails to parse
; would take every hotkey and snippet down when the master reloads).
; Returns "" on success, else an error message, and then NOTHING changed:
; the new module is checked in a scratch file first, so an automation that
; already had a key never loses it to a replacement that won't load.
; The CALLER reloads the master. sayPhrase is the spoken phrase.
HotkeyCompanionCreate(root, base, sayPhrase, key) {
    content := HotkeyCompanionContent(base, sayPhrase, key)
    scratch := A_Temp "\vk-companion-check-" DllCall("GetCurrentProcessId") "-" A_TickCount ".ahk"
    ok := AhkWriteChecked(scratch, content, &err)   ; self-contained: loads the same anywhere
    try FileDelete(scratch)
    if !ok
        return err
    HotkeyCompanionRemove(root, base)                ; a replace retires the old key (no-op if none)
    modFile := HotkeyCompanionFile(root, base)
    try FileDelete(modFile)
    FileAppend(content, modFile, "UTF-8")            ; the exact bytes that just passed
    BridgeRegisterModule(root, key, sayPhrase, HotkeyCompanionRel(base))
    return ""
}

; Take a module out of the master: delete its file and its _index.ahk and
; bridge-map.txt lines (caselessly — NTFS names are). rel is repo-relative
; ("hotkeys\X.ahk"). True if there was anything to remove. The CALLER
; reloads the master so the key stops working now.
HotkeyModuleUnwire(root, rel) {
    f := root "\" rel
    had := FileExist(f) != ""
    try FileDelete(f)
    inIdx := RemoveLinesContaining(root "\hotkeys\_index.ahk", "\" rel)
    inMap := RemoveLinesContaining(root "\bridge-map.txt", "|" rel "|")
    return had || inIdx || inMap
}

; Remove <base>'s companion hotkey (module + _index + bridge-map lines).
; Returns true if there was one — the caller reloads the master so the
; key stops working now. No-op (and no file churn) when none exists.
HotkeyCompanionRemove(root, base) {
    if (!FileExist(HotkeyCompanionFile(root, base)) && HotkeyCompanionKey(root, base) = "")
        return false
    HotkeyModuleUnwire(root, HotkeyCompanionRel(base))
    return true
}

; Remove <base>'s companion and, when there was one, reload the master
; so the key stops working now — the delete flows' one-liner.
HotkeyCompanionRetire(root, base) {
    if HotkeyCompanionRemove(root, base)
        ReloadMasterNotify(root)
}

; ---- Deleting (Home's Delete and the Studio's; the MCP's delete_automation
; is the Python mirror and keeps the same artifact lists) -------------------

; The one-step-deep undo copies the MCP banks when a replace/update
; overwrites a module or a macro (voicekit_writer._module_backup_file /
; _macro_backup_file). A delete must take them too: left behind, a later
; automation given the same name would offer the deleted one's code as
; its "previous" version.
ModuleBackupFile(root, base) {
    return root "\logs\module-backups\" base ".prev.ahk"
}
MacroBackupFile(root, base) {
    return root "\logs\macro-backups\" base ".prev.ahk"
}

; Delete a hotkey module and everything it leaves behind: the key binding
; and its wiring, the isolated body, the undo backup, its status line and
; any pending stop flag — so a module later given the same name inherits
; nothing (a stale status line would show up as its progress). Refuses
; VoiceKit's own files in hotkeys\ — Snippets.ahk holds every snippet the
; user owns. True if it deleted. The CALLER reloads the master.
DeleteHotkeyModuleArtifacts(root, base) {
    if (base = "Snippets" || base = "_index")
        return false
    HotkeyModuleUnwire(root, "hotkeys\" base ".ahk")
    try FileDelete(HotkeyBodyFile(root, base))
    try FileDelete(ModuleBackupFile(root, base))
    BodyStatusClear(base, root)
    try FileDelete(BodyStopFile(base, root))
    return true
}

; Delete a launch macro or an AI action (isAi: its prompts\ file too): the
; script, its Start Menu entry (disp = the entry name), the undo backup, and
; any companion hotkey (reloading the master if there was one). Refuses
; VoiceKit's own tools. True if it deleted.
DeleteMacroArtifacts(root, base, disp, isAi := false) {
    if VkDeleteProtected(base)
        return false
    try FileDelete(root "\macros\" base ".ahk")
    if isAi
        try FileDelete(root "\prompts\" base ".prompt.txt")
    try FileDelete(VoiceMacrosDir() "\" disp ".lnk")
    try FileDelete(MacroBackupFile(root, base))
    HotkeyCompanionRetire(root, base)
    return true
}

; Delete a saved workflow's artifacts, all of them: steps file, loop
; inputs sheet, generated stub (only when it IS a generated stub — see
; IsWorkflowStub — and never one of VoiceKit's own tools), the phrase
; and "loop <phrase>" Start Menu entries, and any companion hotkey
; (reloading the master if one existed). disp is the spoken/display
; phrase the .lnk files are named by. Home and Workflow Studio both
; delete through here. A tool's name keeps the tool's companion hotkey
; as well as its script: the companion is keyed by base, so retiring it
; here would take the TOOL's key (RecordMySteps ships ^!+W).
DeleteWorkflowArtifacts(root, base, disp) {
    try FileDelete(root "\workflows\" base ".steps.txt")
    try FileDelete(root "\workflows\" base ".inputs.csv")
    try FileDelete(root "\workflows\" base ".results.csv")   ; collect overflow (sheet was locked)
    ; Unsaved loop results (lib\WorkflowLoop.ahk's journal) — left behind they
    ; would be merged into the sheet of the NEXT workflow given this name.
    try {
        Loop Files root "\logs\loop-journal\" base ".*.jnl"
            if RegExMatch(A_LoopFileName, "^\Q" base "\E\.\d{14}-\d+\.jnl$")
                try FileDelete(A_LoopFileFullPath)
    }
    stub := root "\macros\" base ".ahk"
    ; A tool's name (only reachable from a workflow saved before the Studio
    ; refused them) keeps its script, its Start Menu entry AND its companion
    ; hotkey (below).
    tool := VkDeleteProtected(base)
    if (FileExist(stub) && !tool && IsWorkflowStub(stub))
        try FileDelete(stub)
    if !tool
        try FileDelete(VoiceMacrosDir() "\" disp ".lnk")
    try FileDelete(VoiceMacrosDir() "\loop " disp ".lnk")
    if !tool
        HotkeyCompanionRetire(root, base)
}
