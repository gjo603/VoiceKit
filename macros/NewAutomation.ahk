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
    Run('"' root '\macros\WorkflowStudio.ahk"')
ExitApp()

; ------------------------------------------------------------
ChooseType() {
    state := {choice: 0}
    g := Gui("+AlwaysOnTop", "New Automation")
    g.SetFont("s11")
    g.AddText("w440", "What kind of automation? (buttons are voice-clickable)")

    b1 := g.AddButton("w440 h36", "Launch Macro — runs steps once. Say: open <its name>")
    b1.OnEvent("Click", (*) => (state.choice := 1, g.Destroy()))

    b2 := g.AddButton("w440 h36", "Hotkey Module — always-on key, pair a voice phrase once")
    b2.OnEvent("Click", (*) => (state.choice := 2, g.Destroy()))

    b3 := g.AddButton("w440 h36", "Text Snippet — type an abbreviation, get full text")
    b3.OnEvent("Click", (*) => (state.choice := 3, g.Destroy()))

    b4 := g.AddButton("w440 h36", "Step Workflow — record / build multi-step in a dialog, no code")
    b4.OnEvent("Click", (*) => (state.choice := 4, g.Destroy()))

    b5 := g.AddButton("w440 h30", "Cancel")
    b5.OnEvent("Click", (*) => g.Destroy())

    g.OnEvent("Close", (*) => g.Destroy())
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
    FileCreateShortcut(newFile, vmDir "\" phrase ".lnk", root "\macros")

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

    Run('"' masterPath '"')          ; reload VoiceKit so the hotkey is live now
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

    ib2 := InputBox("Text it should expand to (single line):", "New Snippet — step 2 of 2", "w440 h150")
    if (ib2.Result != "OK" || ib2.Value = "")
        return
    expansion := StrReplace(ib2.Value, "``", "````")   ; escape literal backticks

    FileAppend("`n:*:" abbrev "::" expansion, root "\hotkeys\Snippets.ahk", "UTF-8")
    Run('"' masterPath '"')          ; reload VoiceKit so it works immediately
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
