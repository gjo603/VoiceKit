#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Voice Kit — the home window. Say "open voice kit".
;
;  One calm place for everything: every automation you can speak,
;  searchable, with Run / Edit / Delete and the doorway to New
;  Automation and AI Settings. Replaces the old help text dump
;  ("open voice kit help" still lands here via VoiceKitHelp.ahk).
;
;  Every button is voice-clickable — say "click" plus its word.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"
#Include "%A_ScriptDir%\..\lib\AI.ahk"

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
masterPath := root "\VoiceKit.ahk"
EnsureHomeShortcut()

items := []        ; everything sayable/typable, in display order
rowItems := []     ; items currently shown, parallel to LV rows

; ---- window ----
g := Gui("+AlwaysOnTop", "VoiceKit")
g.SetFont("s10", "Segoe UI")
g.MarginX := 20, g.MarginY := 16
g.SetFont("s16 bold")
g.AddText("xm", "VoiceKit")
g.SetFont("s10 norm")
tagline := g.AddText("xm y+2 w700", "Everything you can say, in one place.")

edSearch := g.AddEdit("xm y+14 w700")
SendMessage(0x1501, 1, StrPtr("Search your automations…"), edSearch.Hwnd)   ; EM_SETCUEBANNER

lv := g.AddListView("xm y+10 w700 r15 -Multi Grid NoSortHdr NoSort", ["Say this", "Type", "Details"])

g.SetFont("s10")
btnRun  := g.AddButton("xm y+12 w110 h34", "▶  Run")
btnEdit := g.AddButton("x+6 w110 h34", "✎  Edit")
btnDel  := g.AddButton("x+6 w120 h34", "✕  Delete")
btnNew  := g.AddButton("x+24 w190 h34 Default", "＋  New Automation")
btnAI   := g.AddButton("x+6 w130 h34", "AI Settings")

g.SetFont("s9")
statusBar := g.AddText("xm y+12 w700 h30", "")

; ---- events ----
edSearch.OnEvent("Change", (*) => RefreshLV())
lv.OnEvent("DoubleClick", RunSelected)
btnRun.OnEvent("Click", RunSelected)
btnEdit.OnEvent("Click", EditSelected)
btnDel.OnEvent("Click", DeleteSelected)
btnNew.OnEvent("Click", (*) => (RunAhk(root "\macros\NewAutomation.ahk"), SB("New Automation is opening…")))
btnAI.OnEvent("Click", (*) => AISettingsDialog(g))
g.OnEvent("Close", (*) => ExitApp())
g.OnEvent("Escape", (*) => ExitApp())

ReloadItems()
ThemeApply(g, statusBar)
ThemeDim(tagline)
g.Show()
SB(items.Length " automations. Say any phrase in the list — or select a row and say “click run”.")

; ============================================================
;  Data
; ============================================================
ReloadItems() {
    global items
    items := CollectItems()
    RefreshLV()
}

CollectItems() {
    global root
    list := []
    tools := []
    ; Saved workflows (their macros\ stubs are folded into these rows).
    wfBases := Map()
    Loop Files root "\workflows\*.steps.txt" {
        base := StrReplace(A_LoopFileName, ".steps.txt")
        wfBases[base] := true
        disp := StrLower(SpaceOut(base))
        list.Push({say: "open " disp, kind: "workflow", kindLabel: "Workflow",
            detail: "repeat it:  “open loop " disp "”", baseName: base, file: A_LoopFileFullPath, key: ""})
    }
    ; Launch macros, AI actions, and VoiceKit's own tools.
    builtin := Map(
        "NewAutomation",  "create any new automation",
        "WorkflowStudio", "record or edit step workflows",
        "AskAI",          "ask the AI anything, hands-free",
        "VoiceKitHome",   "this window",
        "VoiceKitHelp",   "this window (older phrase)")
    Loop Files root "\macros\*.ahk" {
        base := StrReplace(A_LoopFileName, ".ahk")
        if wfBases.Has(base)
            continue
        disp := StrLower(SpaceOut(base))
        if builtin.Has(base) {
            say := (base = "VoiceKitHome") ? "open voice kit" : "open " disp
            tools.Push({say: say, kind: "tool", kindLabel: "VoiceKit",
                detail: builtin[base], baseName: base, file: A_LoopFileFullPath, key: ""})
            continue
        }
        if FileExist(root "\prompts\" base ".prompt.txt") {
            list.Push({say: "open " disp, kind: "ai", kindLabel: "AI action",
                detail: "select text first — the AI's answer replaces it", baseName: base, file: A_LoopFileFullPath, key: ""})
            continue
        }
        list.Push({say: "open " disp, kind: "macro", kindLabel: "Macro",
            detail: MacroDetail(A_LoopFileFullPath), baseName: base, file: A_LoopFileFullPath, key: ""})
    }
    ; Hotkey modules (bridge-map.txt is the registry).
    mapFile := root "\bridge-map.txt"
    if FileExist(mapFile) {
        Loop Parse FileRead(mapFile, "UTF-8"), "`n", "`r" {
            if (A_LoopField = "" || SubStr(A_LoopField, 1, 1) = ";")
                continue
            parts := StrSplit(A_LoopField, "|")
            if (parts.Length < 3)
                continue
            keyCombo := Trim(parts[1])                     ; "Ctrl+Alt+Shift+K"
            phrase := Trim(parts[2])
            modBase := RegExReplace(Trim(parts[3]), "^hotkeys\\|\.ahk$", "")
            list.Push({say: StrLower(phrase), kind: "hotkey", kindLabel: "Hotkey",
                detail: "or press  " keyCombo, baseName: modBase,
                file: root "\hotkeys\" modBase ".ahk", key: SubStr(keyCombo, StrLen("Ctrl+Alt+Shift+") + 1)})
        }
    }
    ; Snippets (typed, not spoken). An expansion of just "{" is a code-block
    ; hotstring (like /date) — show it as dynamic and protect it from the
    ; line-based delete, which would orphan its code block.
    snipFile := root "\hotkeys\Snippets.ahk"
    if FileExist(snipFile) {
        Loop Parse FileRead(snipFile, "UTF-8"), "`n", "`r" {
            if !RegExMatch(A_LoopField, "^:\*?[^:]*:(.+?)::(.*)$", &m)
                continue
            exp := Trim(m[2])
            dyn := (exp = "{" || exp = "")
            det := dyn ? "dynamic snippet (runs code)"
                : "expands to:  " Abbrev(StrReplace(exp, "``n", " ↵ "), 44)
            list.Push({say: "type " m[1], kind: "snippet", kindLabel: "Snippet",
                detail: det, baseName: m[1], file: snipFile, key: "", dyn: dyn})
        }
    }
    for t in tools
        list.Push(t)
    return list
}

; The one-line "Opens: ..." note New Automation writes into its macros.
MacroDetail(file) {
    try {
        txt := FileRead(file, "UTF-8")
        if RegExMatch(txt, "m)^;\s+Opens:\s+(.+)$", &m)
            return "opens  " Trim(m[1])
    }
    return "runs its steps"
}

; ============================================================
;  List + selection
; ============================================================
RefreshLV() {
    global lv, items, rowItems, edSearch
    q := StrLower(Trim(edSearch.Value))
    lv.Delete()
    rowItems := []
    for it in items {
        if (q != "" && !InStr(StrLower(it.say " " it.kindLabel " " it.detail), q))
            continue
        rowItems.Push(it)
        lv.Add(, "“" it.say "”", it.kindLabel, it.detail)
    }
    lv.ModifyCol(1, 240)
    lv.ModifyCol(2, 90)
    lv.ModifyCol(3, 350)
    if (q != "")
        SB(rowItems.Length " match" (rowItems.Length = 1 ? "" : "es") ".")
}

Selected() {
    global lv, rowItems
    r := lv.GetNext(0)
    if (!r || r > rowItems.Length) {
        SB("Select a row first (click it, or say its phrase directly).")
        return ""
    }
    return rowItems[r]
}

; ============================================================
;  Run / Edit / Delete
; ============================================================
RunSelected(*) {
    global root, g
    it := Selected()
    if !IsObject(it)
        return
    switch it.kind {
        case "ai":
            ; An AI action reads the SELECTION in the app you're working in —
            ; run from here it would grab nothing and type into this window.
            SB("Select text in the target app first, then say “" it.say "” there.")
        case "workflow", "macro", "tool":
            ; Get this AlwaysOnTop window out of the way: workflow clicks are
            ; physical and would land on it, and Ask AI would otherwise treat
            ; Home as the app to type back into.
            WinMinimize("ahk_id " g.Hwnd)
            RunAhk(root "\macros\" it.baseName ".ahk")
            SB("Running — you can also just say “" it.say "”.")
        case "hotkey":
            WinMinimize("ahk_id " g.Hwnd)
            SendLevel(1)                 ; so hook hotkeys in VoiceKit hear it
            Send("^!+" StrLower(it.key))
            SendLevel(0)
            SB("Pressed Ctrl+Alt+Shift+" it.key " for you.")
        case "snippet":
            SB("Snippets fire where you type — type  " it.baseName "  in any app.")
    }
}

EditSelected(*) {
    global root, g
    it := Selected()
    if !IsObject(it)
        return
    switch it.kind {
        case "workflow":
            if WinExist("Workflow Studio ahk_class AutoHotkeyGUI") {
                WinActivate("Workflow Studio ahk_class AutoHotkeyGUI")
                SB("Workflow Studio is already open — pick “" StrLower(SpaceOut(it.baseName)) "” in its dropdown.")
                return
            }
            Run('"' A_AhkPath '" "' root '\macros\WorkflowStudio.ahk" "' it.file '"')
            SB("Opening it in Workflow Studio…")
        case "ai":
            EditPromptDialog(it.baseName)
        case "macro", "hotkey":
            Run('notepad.exe "' it.file '"')
            SB("Opened the script in Notepad. Careful: it's AutoHotkey v2.")
        case "snippet":
            Run('notepad.exe "' it.file '"')
            SB("Snippets live in this one file — one  :*:abbrev::text  line each.")
        case "tool":
            SB("That's part of VoiceKit itself — nothing to edit here.")
    }
}

EditPromptDialog(base) {
    global root, g
    pFile := root "\prompts\" base ".prompt.txt"
    current := FileExist(pFile) ? FileRead(pFile, "UTF-8") : ""
    d := Gui("+AlwaysOnTop +Owner" g.Hwnd, "Edit AI Prompt")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 18, d.MarginY := 14
    d.AddText("xm", "What the AI does with your selected text (“open " StrLower(SpaceOut(base)) "”):")
    edP := d.AddEdit("xm y+6 w480 r7 +Wrap", Trim(current, " `t`r`n"))
    btnOK := d.AddButton("xm y+12 w130 h32 Default", "Save")
    btnCancel := d.AddButton("x+8 w110 h32", "Cancel")
    OK(*) {
        v := Trim(edP.Value, " `t`r`n")
        if (v = "")
            return
        f := FileOpen(pFile, "w", "UTF-8")
        f.Write(v "`n")
        f.Close()
        d.Destroy()
        SB("Prompt saved — it applies the next time you run it.")
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeApply(d)
    d.Show()
    g.Opt("+Disabled")
    WinWaitClose("ahk_id " d.Hwnd)
    g.Opt("-Disabled")
    WinActivate("ahk_id " g.Hwnd)
}

DeleteSelected(*) {
    global root, masterPath, g
    it := Selected()
    if !IsObject(it)
        return
    if (it.kind = "tool") {
        SB("That's part of VoiceKit itself — it can't be deleted from here.")
        return
    }
    if (it.kind = "snippet" && it.dyn) {
        SB("This snippet is a code block — click Edit and remove its whole block by hand.")
        return
    }
    if (MsgBox("Delete “" it.say "”?`n`nThis removes its files and Start Menu entries.",
        "VoiceKit", "YesNo Icon! Owner" g.Hwnd) != "Yes")
        return
    disp := SpaceOut(it.baseName)
    switch it.kind {
        case "workflow":
            try FileDelete(root "\workflows\" it.baseName ".steps.txt")
            macroFile := root "\macros\" it.baseName ".ahk"
            if (FileExist(macroFile) && InStr(FileRead(macroFile, "UTF-8"), "Workflow Studio"))
                try FileDelete(macroFile)
            try FileDelete(A_Programs "\Voice Macros\" disp ".lnk")
            try FileDelete(A_Programs "\Voice Macros\loop " disp ".lnk")
        case "ai":
            try FileDelete(root "\macros\" it.baseName ".ahk")
            try FileDelete(root "\prompts\" it.baseName ".prompt.txt")
            try FileDelete(A_Programs "\Voice Macros\" disp ".lnk")
        case "macro":
            try FileDelete(root "\macros\" it.baseName ".ahk")
            try FileDelete(A_Programs "\Voice Macros\" disp ".lnk")
        case "hotkey":
            try FileDelete(root "\hotkeys\" it.baseName ".ahk")
            RemoveLinesContaining(root "\hotkeys\_index.ahk", "\hotkeys\" it.baseName ".ahk")
            RemoveLinesContaining(root "\bridge-map.txt", "|hotkeys\" it.baseName ".ahk|")
            RunAhk(masterPath)          ; reload so the key stops working now
        case "snippet":
            RemoveSnippetLine(root "\hotkeys\Snippets.ahk", it.baseName)
            RunAhk(masterPath)
    }
    Log(root, "deleted " it.kind " | " it.say)
    ReloadItems()
    SB("Deleted." (it.kind = "hotkey" ? "  If you paired a voice phrase in Voice Access, remove it there too." : ""))
}

; Rewrite a text file without the lines that contain `needle`.
RemoveLinesContaining(file, needle) {
    if !FileExist(file)
        return
    out := ""
    Loop Parse FileRead(file, "UTF-8"), "`n", "`r" {
        if InStr(A_LoopField, needle)
            continue
        out .= A_LoopField "`n"
    }
    f := FileOpen(file, "w", "UTF-8")
    f.Write(RTrim(out, "`n") "`n")
    f.Close()
}

; Remove one hotstring by its abbreviation (line looks like :*:abbrev::text).
RemoveSnippetLine(file, abbrev) {
    if !FileExist(file)
        return
    out := ""
    Loop Parse FileRead(file, "UTF-8"), "`n", "`r" {
        if RegExMatch(A_LoopField, "^:\*?[^:]*:(.+?)::", &m) && (m[1] = abbrev)
            continue
        out .= A_LoopField "`n"
    }
    f := FileOpen(file, "w", "UTF-8")
    f.Write(RTrim(out, "`n") "`n")
    f.Close()
}

; ============================================================
;  Misc
; ============================================================
SB(text) {
    global statusBar
    statusBar.Text := text
}

Abbrev(s, n) {
    return StrLen(s) > n ? SubStr(s, 1, n) "..." : s
}

; Self-heal the "Voice Kit" Start Menu entry (the home phrase) so
; "open voice kit" works even on installs made before this existed.
EnsureHomeShortcut() {
    vmDir := A_Programs "\Voice Macros"
    EnsureDir(vmDir)
    if !FileExist(vmDir "\Voice Kit.lnk")
        MakeAhkShortcut(vmDir "\Voice Kit.lnk", A_ScriptFullPath)
}
