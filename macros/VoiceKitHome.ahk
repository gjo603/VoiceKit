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
tagline := g.AddText("xm y+2 w760", "Everything you can say, in one place.")

edSearch := g.AddEdit("xm y+14 w760")
SendMessage(0x1501, 1, StrPtr("Search your automations…"), edSearch.Hwnd)   ; EM_SETCUEBANNER

lv := g.AddListView("xm y+10 w760 r15 -Multi Grid NoSortHdr NoSort", ["Say this", "Type", "Hotkey", "Details"])

g.SetFont("s10")
btnRun  := g.AddButton("xm y+12 w100 h34", "▶  Run")
btnEdit := g.AddButton("x+6 w95 h34", "✎  Edit")
btnKey  := g.AddButton("x+6 w110 h34", "⌨  Hotkey")
btnDel  := g.AddButton("x+6 w105 h34", "✕  Delete")
btnNew  := g.AddButton("x+22 w185 h34 Default", "＋  New Automation")
btnAI   := g.AddButton("x+6 w120 h34", "AI Settings")

g.SetFont("s9")
statusBar := g.AddText("xm y+12 w760 h30", "")

; ---- events ----
edSearch.OnEvent("Change", (*) => RefreshLV())
lv.OnEvent("DoubleClick", RunSelected)
btnRun.OnEvent("Click", RunSelected)
btnEdit.OnEvent("Click", EditSelected)
btnKey.OnEvent("Click", HotkeySelected)
btnDel.OnEvent("Click", DeleteSelected)
btnNew.OnEvent("Click", (*) => (RunAhk(root "\macros\NewAutomation.ahk"), SB("New Automation is opening…")))
btnAI.OnEvent("Click", (*) => AISettingsDialog(g))
g.OnEvent("Close", (*) => ExitApp())
g.OnEvent("Escape", (*) => ExitApp())

ReloadItems()
ThemeApply(g, statusBar)
ThemeDim(tagline)
g.Show()
SB(items.Length " automations. Say any phrase in the list — or select a row for Run, Edit, Delete, or Hotkey (a Ctrl+Alt+Shift key for when you can't use your voice).")

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
    ; Bridge registry first (bridge-map.txt): hand-written hotkey modules
    ; become rows of their own; companion hotkeys (hotkeys\<Base>.hotkey.ahk,
    ; assigned with this window's Hotkey button) fold into their automation's
    ; row as its Hotkey column instead of appearing twice.
    hotkeyRows := []
    ; lower(parent base) -> {key, parent}. NB: the property is "parent", never
    ; "base" — `base:` in an AHK v2 object literal sets the PROTOTYPE and
    ; throws at runtime for a string value.
    compKeys := Map()
    for e in BridgeMapEntries(root) {
        parentBase := HotkeyCompanionParent(e.file)
        if (parentBase != "") {
            compKeys[StrLower(parentBase)] := {key: e.key, parent: parentBase}
            continue
        }
        modBase := RegExReplace(e.file, "^hotkeys\\|\.ahk$", "")
        hotkeyRows.Push({say: StrLower(e.phrase), kind: "hotkey", kindLabel: "Hotkey",
            detail: "always-on while VoiceKit runs", baseName: modBase,
            file: root "\hotkeys\" modBase ".ahk", key: e.key})
    }
    TakeCompanionKey(base) {
        b := StrLower(base)
        return compKeys.Has(b) ? compKeys.Delete(b).key : ""
    }
    ; Saved workflows (their macros\ stubs are folded into these rows).
    wfBases := Map()
    Loop Files root "\workflows\*.steps.txt" {
        base := StrReplace(A_LoopFileName, ".steps.txt")
        wfBases[base] := true
        disp := StrLower(SpaceOut(base))
        list.Push({say: "open " disp, kind: "workflow", kindLabel: "Workflow",
            detail: "repeat it:  “open loop " disp "”", baseName: base, file: A_LoopFileFullPath,
            key: TakeCompanionKey(base)})
    }
    ; Launch macros, AI actions, and VoiceKit's own tools.
    builtin := Map(
        "NewAutomation",  "create any new automation",
        "WorkflowStudio", "record or edit step workflows",
        "RecordMySteps",  "start recording a new workflow now",
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
                detail: builtin[base], baseName: base, file: A_LoopFileFullPath,
                key: TakeCompanionKey(base)})
            continue
        }
        if FileExist(root "\prompts\" base ".prompt.txt") {
            list.Push({say: "open " disp, kind: "ai", kindLabel: "AI action",
                detail: "select text first — the AI's answer replaces it", baseName: base,
                file: A_LoopFileFullPath, key: TakeCompanionKey(base)})
            continue
        }
        list.Push({say: "open " disp, kind: "macro", kindLabel: "Macro",
            detail: MacroDetail(A_LoopFileFullPath), baseName: base, file: A_LoopFileFullPath,
            key: TakeCompanionKey(base)})
    }
    ; Hand-written hotkey modules keep their own rows.
    for hr in hotkeyRows
        list.Push(hr)
    ; Companion hotkeys whose automation is gone (deleted outside this window):
    ; surface them so Delete can retire the key like any hotkey row (the
    ; module base comes from the same rel-file transform as normal rows).
    for , c in compKeys {
        rel := HotkeyCompanionRel(c.parent)
        modBase := RegExReplace(rel, "^hotkeys\\|\.ahk$", "")
        list.Push({say: StrLower(SpaceOut(c.parent)) " (missing)", kind: "hotkey", kindLabel: "Hotkey",
            detail: "runs a deleted automation — delete this hotkey", baseName: modBase,
            file: root "\" rel, key: c.key})
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
            preview := StrReplace(SnipDecode(exp), "`r`n", " ↵ ")   ; newlines shown inline
            det := dyn ? "dynamic snippet (runs code)"
                : "expands to:  " Abbrev(preview, 44)
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
        combo := it.key != "" ? "Ctrl+Alt+Shift+" it.key : ""
        if (q != "" && !InStr(StrLower(it.say " " it.kindLabel " " it.detail " " combo), q))
            continue
        rowItems.Push(it)
        lv.Add(, "“" it.say "”", it.kindLabel, combo, it.detail)
    }
    lv.ModifyCol(1, 235)
    lv.ModifyCol(2, 85)
    lv.ModifyCol(3, 125)
    lv.ModifyCol(4, 285)     ; 730 total — inside the client area even with a scrollbar
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
            ; A code-block snippet (like /date) is real AHK code, not plain
            ; text — it can't round-trip through the text editor, so it opens
            ; in Notepad. Everything else gets the in-app snippet editor.
            if it.dyn {
                Run('notepad.exe "' it.file '"')
                SB("This snippet runs code — opened Snippets.ahk in Notepad. Careful: it's AutoHotkey v2.")
            } else {
                EditSnippetDialog(it)
            }
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

; Edit a text snippet in place — its abbreviation and its (multi-line)
; expansion — without hand-editing Snippets.ahk. Only plain-text snippets
; reach here; code-block ones open in Notepad (they can't round-trip through
; a text box). The on-disk text is decoded for editing and re-encoded on save
; (real newlines <-> `n), so multi-line snippets stay on their single line.
EditSnippetDialog(it) {
    global root, masterPath, g
    snipFile := it.file
    oldAbbrev := it.baseName
    current := ""
    Loop Parse FileRead(snipFile, "UTF-8"), "`n", "`r" {
        if (RegExMatch(A_LoopField, "^:\*?[^:]*:(.+?)::(.*)$", &m) && m[1] = oldAbbrev) {
            current := SnipDecode(m[2])
            break
        }
    }
    d := Gui("+AlwaysOnTop +Owner" g.Hwnd, "Edit Snippet")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 18, d.MarginY := 14
    d.SetFont("s12 bold")
    d.AddText("xm", "Edit a text snippet")
    d.SetFont("s10 norm")
    d.AddText("xm y+12", "Abbreviation to type:")
    edAbbrev := d.AddEdit("xm y+4 w200", oldAbbrev)
    d.AddText("xm y+12", "Expands to:")
    edText := d.AddEdit("xm y+4 w480 r8 +Wrap", current)
    hint := d.AddText("xm y+3 w480", "Press Enter for line breaks. Typing the abbreviation anywhere replaces it with this text.")
    btnOK := d.AddButton("xm y+14 w120 h34 Default", "🖫  Save")
    btnCancel := d.AddButton("x+8 w100 h34", "Cancel")
    btnFile := d.AddButton("x+8 w150 h34", "Open File…")

    OK(*) {
        newAbbrev := RegExReplace(Trim(edAbbrev.Value), "\s", "")
        if (newAbbrev = "" || InStr(newAbbrev, ":")) {
            MsgBox("The abbreviation can't be empty or contain a colon (:).", "VoiceKit", "Icon! Owner" d.Hwnd)
            return
        }
        expansion := edText.Value
        if (Trim(expansion, " `t`r`n") = "") {
            MsgBox("Give it the text to expand into.", "VoiceKit", "Icon! Owner" d.Hwnd)
            return
        }
        if (Trim(expansion) = "{") {
            MsgBox("The text can't be just '{' — that's code syntax in the snippets file.", "VoiceKit", "Icon! Owner" d.Hwnd)
            return
        }
        ; Renaming onto another snippet's abbreviation would silently shadow it.
        if (newAbbrev != oldAbbrev) {
            Loop Parse FileRead(snipFile, "UTF-8"), "`n", "`r" {
                if (RegExMatch(A_LoopField, "^:\*?[^:]*:(.+?)::", &m) && m[1] = newAbbrev) {
                    MsgBox("A snippet  " newAbbrev "  already exists. Pick another abbreviation.", "VoiceKit", "Icon! Owner" d.Hwnd)
                    return
                }
            }
        }
        if !ReplaceSnippetLine(snipFile, oldAbbrev, newAbbrev, SnipEncode(expansion)) {
            MsgBox("Couldn't find that snippet to update — it may have changed already. Close and reopen Voice Kit.",
                "VoiceKit", "Icon! Owner" d.Hwnd)
            return
        }
        RunAhk(masterPath)                    ; reload so the edit is live now
        Log(root, "snippet-edit | " oldAbbrev (newAbbrev != oldAbbrev ? " -> " newAbbrev : ""))
        d.Destroy()
        ReloadItems()
        SB("Saved — type  " newAbbrev "  anywhere to use it.")
    }
    OpenFile(*) {
        d.Destroy()
        Run('notepad.exe "' snipFile '"')
        SB("Opened Snippets.ahk in Notepad. Careful: it's AutoHotkey v2.")
    }
    btnOK.OnEvent("Click", OK)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    btnFile.OnEvent("Click", OpenFile)
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeApply(d)
    ThemeDim(hint)
    d.Show()
    g.Opt("+Disabled")
    WinWaitClose("ahk_id " d.Hwnd)
    g.Opt("-Disabled")
    WinActivate("ahk_id " g.Hwnd)
}

; ============================================================
;  Hotkey — give any voice automation a Ctrl+Alt+Shift key, for
;  when voice isn't available. The generated companion module
;  (hotkeys\<Base>.hotkey.ahk) runs the same macro the phrase does.
; ============================================================
HotkeySelected(*) {
    it := Selected()
    if !IsObject(it)
        return
    switch it.kind {
        case "hotkey":
            SB(it.key != "" ? "That's already a key — press Ctrl+Alt+Shift+" it.key " any time."
                : "That's already a hotkey module.")
        case "snippet":
            SB("Snippets are typed, not keyed — typing  " it.baseName "  anywhere expands it.")
        default:
            HotkeyDialog(it)
    }
}

HotkeyDialog(it) {
    global root, masterPath, g
    keys := []
    if (it.key != "")
        keys.Push(it.key)                     ; current assignment stays pickable
    for k in BridgeFreeKeys(root "\bridge-map.txt")
        keys.Push(k)
    if (keys.Length = 0) {
        MsgBox("No free Ctrl+Alt+Shift keys are left — remove one first (bridge-map.txt lists them all).",
            "VoiceKit", "Icon! Owner" g.Hwnd)
        return
    }
    d := Gui("+AlwaysOnTop +Owner" g.Hwnd, "Hotkey")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 18, d.MarginY := 14
    d.SetFont("s12 bold")
    d.AddText("xm", "A key that runs “" it.say "”")
    d.SetFont("s10 norm")
    why := d.AddText("xm y+4 w440", "For when you can't use your voice — the key works whenever "
        . "VoiceKit is running, and the phrase keeps working too.")
    d.AddText("xm y+16", "Press:")
    d.SetFont("s11 bold")
    d.AddText("x+8 yp", "Ctrl + Alt + Shift  +")
    ddl := d.AddDropDownList("x+8 yp-2 w62 Choose1", keys)
    d.SetFont("s10 norm")
    btnSave := d.AddButton("xm y+20 w150 h34 Default", "Save Hotkey")
    btnRemove := d.AddButton("x+8 w150 h34", "Remove Hotkey")
    btnCancel := d.AddButton("x+8 w100 h34", "Cancel")
    btnRemove.Enabled := it.key != ""

    Done(msg) {
        RunAhk(masterPath)                    ; reload so the change is live now
        d.Destroy()
        ReloadItems()
        SB(msg)
    }
    Save(*) {
        chosen := ddl.Text
        if (chosen = "")
            return
        if (chosen = it.key) {                ; nothing to change
            d.Destroy()
            return
        }
        if (it.key != "")
            HotkeyCompanionRemove(root, it.baseName)
        err := HotkeyCompanionCreate(root, it.baseName, it.say, chosen)
        if (err != "") {
            MsgBox(err, "VoiceKit", "Icon! Owner" d.Hwnd)
            return
        }
        Log(root, "hotkey-assign | " it.say " | Ctrl+Alt+Shift+" chosen)
        Done("Ctrl+Alt+Shift+" chosen "  now runs “" it.say "” — no voice needed.")
    }
    Remove(*) {
        HotkeyCompanionRemove(root, it.baseName)
        Log(root, "hotkey-remove | " it.say)
        Done("Hotkey removed — “" it.say "” is back to voice only.")
    }
    btnSave.OnEvent("Click", Save)
    btnRemove.OnEvent("Click", Remove)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeApply(d)
    ThemeDim(why)
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
            DeleteWorkflowArtifacts(root, it.baseName, disp)
        case "ai":
            try FileDelete(root "\macros\" it.baseName ".ahk")
            try FileDelete(root "\prompts\" it.baseName ".prompt.txt")
            try FileDelete(A_Programs "\Voice Macros\" disp ".lnk")
            HotkeyCompanionRetire(root, it.baseName)      ; companion key too
        case "macro":
            try FileDelete(root "\macros\" it.baseName ".ahk")
            try FileDelete(A_Programs "\Voice Macros\" disp ".lnk")
            HotkeyCompanionRetire(root, it.baseName)
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

; (RemoveLinesContaining moved to lib\_Common.ahk — the companion-hotkey
; helpers there need it too.)

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

; Rewrite one hotstring in place, matched by its current abbreviation.
; Preserves its position, its options (:*: vs ::), and any comment above it —
; only the abbreviation and replacement change. Returns true if it was found.
ReplaceSnippetLine(file, oldAbbrev, newAbbrev, encoded) {
    if !FileExist(file)
        return false
    out := "", found := false
    Loop Parse FileRead(file, "UTF-8"), "`n", "`r" {
        if (!found && RegExMatch(A_LoopField, "^:([^:]*):(.+?)::", &m) && m[2] = oldAbbrev) {
            out .= ":" m[1] ":" newAbbrev "::" encoded "`n"
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
