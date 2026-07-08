#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  New Automation — the automation that creates automations.
;  Say "open new automation"  (or press Ctrl+Alt+Shift+N).
;
;  It scaffolds the file from a template, wires it up, reloads
;  VoiceKit, and opens the new file so you only write the steps.
; ============================================================

#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")   ; parent of \macros
masterPath := root "\VoiceKit.ahk"

choice := ChooseType()
if (choice = 1)
    NewLaunchMacro(root)
else if (choice = 2)
    NewHotkeyModule(root, masterPath)
else if (choice = 3)
    NewSnippet(root, masterPath)
else if (choice = 4)
    RunAhk(root "\macros\WorkflowStudio.ahk")
ExitApp()

; ------------------------------------------------------------
ChooseType() {
    state := {choice: 0}
    g := Gui("+AlwaysOnTop", "New Automation")
    g.SetFont("s11", "Segoe UI")
    g.MarginX := 18, g.MarginY := 16
    g.AddText("xm w460", "What do you want to create?")
    g.SetFont("s9")
    subtitle := g.AddText("xm y+2 w460", "Every button below is voice-clickable — say “click” plus its name.")

    ; Each choice is a title button with a dim one-line description beneath,
    ; so the window scans top-to-bottom instead of packing a sentence into a
    ; caption. The short caption ("Launch Macro") stays the voice target.
    descs := []
    MakeCard(title, desc, choiceNum) {
        g.SetFont("s10 bold")
        b := g.AddButton("xm y+14 w460 h38", title)
        b.OnEvent("Click", (*) => (state.choice := choiceNum, g.Destroy()))
        g.SetFont("s9 norm")
        descs.Push(g.AddText("xm y+3 w460", desc))
    }
    MakeCard("Launch Macro",  "Runs a set of steps once. Voice-ready instantly — say “open <name>”.", 1)
    MakeCard("Hotkey Module", "An always-on key; pair a voice phrase to it once (~30 seconds).", 2)
    MakeCard("Text Snippet",  "Type a short abbreviation anywhere and it expands to full text.", 3)
    MakeCard("Step Workflow", "Record or build a multi-step automation in a dialog — no code.", 4)

    g.SetFont("s10")
    b5 := g.AddButton("xm y+20 w120 h32", "Cancel")
    b5.OnEvent("Click", (*) => g.Destroy())

    g.OnEvent("Close", (*) => g.Destroy())
    ThemeApply(g)
    pal := ThemePalette()
    descs.Push(subtitle)
    for d in descs                      ; dim the descriptions (ThemeApply makes all text primary)
        d.Opt("c" Format("{:06X}", pal.dim))
    hwnd := g.Hwnd
    g.Show()
    WinWaitClose("ahk_id " hwnd)
    return state.choice
}

; ------------------------------------------------------------
; Type 1: standalone macro + Start Menu entry.
; Voice-ready instantly — Voice Access launches anything in the
; Start Menu with "open <name>". Zero Voice Access config.
; ------------------------------------------------------------
NewLaunchMacro(root) {
    ib := InputBox("Name it — this becomes the voice phrase.`nExample: Meeting Notes", "New Launch Macro", "w440 h150")
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    phrase := CleanPhrase(ib.Value)
    fileBase := StrReplace(phrase, " ")
    if (fileBase = "" || IsReservedName(fileBase)) {
        MsgBox("'" Trim(ib.Value) "' isn't a usable name (empty after cleanup, or a reserved Windows name). Pick another.", "New Automation")
        return
    }
    newFile := root "\macros\" fileBase ".ahk"
    if FileExist(newFile) {
        MsgBox("A macro named '" fileBase "' already exists. Pick another name.", "New Automation")
        return
    }

    tpl := FileRead(root "\templates\launch-template.ahk", "UTF-8")
    tpl := StrReplace(tpl, "{{PHRASE}}", phrase)
    tpl := StrReplace(tpl, "{{DATE}}", FormatTime(A_Now, "yyyy-MM-dd"))
    FileAppend(tpl, newFile, "UTF-8")

    vmDir := A_Programs "\Voice Macros"
    if !DirExist(vmDir)
        DirCreate(vmDir)
    MakeAhkShortcut(vmDir "\" phrase ".lnk", newFile)

    Log(root, "launch | " phrase " | macros\" fileBase ".ahk")
    Run('notepad.exe "' newFile '"')
    MsgBox("Created. Write your steps in the file that just opened.`n`nTrigger it any time by saying:  open " phrase
        . "`n(Windows may take a few seconds to index the new entry.)", "New Automation")
}

; ------------------------------------------------------------
; Type 2: module loaded into VoiceKit + auto-assigned bridge key.
; The only manual step left on Earth: registering the phrase in
; Voice Access (no API exists for that — see README).
; ------------------------------------------------------------
NewHotkeyModule(root, masterPath) {
    ib := InputBox("Name it — also the suggested voice phrase.`nExample: Toggle Timer", "New Hotkey Module", "w440 h150")
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    phrase := CleanPhrase(ib.Value)
    fileBase := StrReplace(phrase, " ")
    if (fileBase = "" || IsReservedName(fileBase)) {
        MsgBox("'" Trim(ib.Value) "' isn't a usable name (empty after cleanup, or a reserved Windows name). Pick another.", "New Automation")
        return
    }
    newFile := root "\hotkeys\" fileBase ".ahk"
    if FileExist(newFile) {
        MsgBox("A module named '" fileBase "' already exists. Pick another name.", "New Automation")
        return
    }

    mapFile := root "\bridge-map.txt"
    key := AllocateBridgeKey(mapFile)
    if (key = "") {
        MsgBox("No free bridge keys left. Retire something in bridge-map.txt first.", "New Automation")
        return
    }

    tpl := FileRead(root "\templates\hotkey-template.ahk", "UTF-8")
    tpl := StrReplace(tpl, "{{PHRASE}}", phrase)
    tpl := StrReplace(tpl, "{{KEY}}", key)
    tpl := StrReplace(tpl, "{{DATE}}", FormatTime(A_Now, "yyyy-MM-dd"))
    FileAppend(tpl, newFile, "UTF-8")

    FileAppend('`n#Include "%A_ScriptDir%\hotkeys\' fileBase '.ahk"', root "\hotkeys\_index.ahk", "UTF-8")
    FileAppend("Ctrl+Alt+Shift+" key "|" phrase "|hotkeys\" fileBase ".ahk|" FormatTime(A_Now, "yyyy-MM-dd") "`n", mapFile, "UTF-8")

    RunAhk(masterPath)               ; reload VoiceKit so the hotkey is live now
    Log(root, "hotkey | " phrase " | Ctrl+Alt+Shift+" key " | hotkeys\" fileBase ".ahk")
    Run('notepad.exe "' newFile '"')
    MsgBox("Created and loaded. Trigger key:  Ctrl+Alt+Shift+" key
        . "`n`nTo add the voice phrase (one-time, ~30 sec):"
        . "`n  1. Say:  show voice shortcuts"
        . "`n  2. Create new shortcut -> When I say:  " phrase
        . "`n  3. Action: Press keys -> Ctrl + Alt + Shift + " key
        . "`n`nSaved to bridge-map.txt (your recreate list).", "New Automation")
}

; ------------------------------------------------------------
; Type 3: append a hotstring to Snippets.ahk. Fully automated,
; start to finish — no editor, no Voice Access setup.
; ------------------------------------------------------------
NewSnippet(root, masterPath) {
    ib1 := InputBox("Abbreviation to type (no spaces). A / prefix avoids accidents.`nExample: /invoice", "New Snippet — step 1 of 2", "w440 h150")
    if (ib1.Result != "OK" || Trim(ib1.Value) = "")
        return
    abbrev := RegExReplace(Trim(ib1.Value), "\s", "")
    if (abbrev = "" || InStr(abbrev, ":")) {
        MsgBox("The abbreviation can't be empty or contain a colon (:) — a colon breaks the hotstring format and would disable every snippet. Pick another.", "New Automation")
        return
    }

    ib2 := InputBox("Text it should expand to (single line):", "New Snippet — step 2 of 2", "w440 h150")
    if (ib2.Result != "OK" || ib2.Value = "")
        return
    expansion := StrReplace(ib2.Value, "``", "````")   ; escape literal backticks

    FileAppend("`n:*:" abbrev "::" expansion, root "\hotkeys\Snippets.ahk", "UTF-8")
    RunAhk(masterPath)               ; reload VoiceKit so it works immediately
    Log(root, "snippet | " abbrev)
    MsgBox("Done and loaded. Type  " abbrev "  anywhere to expand it.", "New Automation")
}

; ------------------------------------------------------------
; (CleanPhrase and Log live in lib\_Common.ahk — shared with
;  Workflow Studio.)

; E, N, R are VoiceKit's own hotkeys; X is Workflow Studio's
; stop-recording key.
AllocateBridgeKey(mapFile) {
    pool := "ABCDFGHIJKLMOPQSTUVWYZ0123456789"
    used := FileExist(mapFile) ? FileRead(mapFile) : ""
    Loop Parse pool {
        if !InStr(used, "Ctrl+Alt+Shift+" A_LoopField "|")
            return A_LoopField
    }
    return ""
}
