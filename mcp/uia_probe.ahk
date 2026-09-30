#Requires AutoHotkey v2.0
; Read-only UIA inspection probe for the MCP server (inspect_focus /
; dump_uia_tree in voicekit_writer.py). Runs as its own short-lived process
; for the same reason every UIA user here does: lib\UIA.ahk must never run
; inside the resident master, and a probe that dies takes nothing with it.
;
; Usage:
;   AutoHotkey64.exe uia_probe.ahk <outfile> focus
;   AutoHotkey64.exe uia_probe.ahk <outfile> tree <window> [maxDepth] [maxLines] [nameFilter]
;
; <window> is an AutoHotkey WinTitle ("ahk_exe chrome.exe", a title
; substring, ...); empty means the active window. Output is UTF-8 key=value
; lines; tree mode follows the header with a blank line and the indented
; tree. A report starting "error=" is an ANSWER, not a crash — the exit code
; is 0 unless the invocation itself was malformed.
#Include "%A_ScriptDir%\..\lib\UIA.ahk"

#SingleInstance Off
SetTitleMatchMode 2
SetTimer(() => ExitApp(3), -25000)          ; never outlive the caller's wait

if (A_Args.Length < 2)
    ExitApp(2)
outFile := A_Args[1]
mode := A_Args[2]

; One line, always: a name/value with a newline in it must not break the
; key=value format the Python side parses.
OneLine(s) {
    return StrReplace(StrReplace(s, "`r", " "), "`n", " ")
}

Report(text) {
    global outFile
    try FileDelete(outFile)
    FileAppend(text, outFile, "UTF-8")
    ExitApp(0)
}

if !UiaAvailable()
    Report("error=UI Automation is not available on this system")

if (mode = "focus") {
    el := UiaFocused()
    if (el = "")
        Report("error=Nothing reports keyboard focus right now")
    tid := UiaControlType(el)
    out := "focused=1`n"
    out .= "name=" OneLine(UiaName(el)) "`n"
    out .= "control_type=" UiaControlTypeName(tid) "`n"
    out .= "control_type_id=" tid "`n"
    out .= "value=" OneLine(UiaValue(el)) "`n"
    out .= "automation_id=" OneLine(UiaAutomationId(el)) "`n"
    out .= "enabled=" (UiaEnabled(el) ? 1 : 0) "`n"
    r := UiaRect(el)
    out .= "rect=" (IsObject(r) ? r.x "," r.y "," r.w "," r.h : "") "`n"
    node := el
    Loop 3 {
        node := UiaParent(node)
        if (node = "")
            break
        out .= "ancestor_" A_Index "=" UiaControlTypeName(UiaControlType(node))
            . ' "' OneLine(UiaName(node)) '"' "`n"
    }
    fg := WinExist("A")
    if fg {
        try out .= "window_title=" OneLine(WinGetTitle(fg)) "`n"
        try out .= "window_class=" WinGetClass(fg) "`n"
        try out .= "window_exe=" WinGetProcessName(fg) "`n"
    }
    Report(out)
}

if (mode = "tree") {
    crit := A_Args.Length >= 3 ? A_Args[3] : ""
    maxDepth := 8, maxLines := 300, nameFilter := ""
    if (A_Args.Length >= 4 && A_Args[4] != "")
        try maxDepth := Max(1, Integer(A_Args[4]))
    if (A_Args.Length >= 5 && A_Args[5] != "")
        try maxLines := Max(1, Integer(A_Args[5]))
    if (A_Args.Length >= 6)
        nameFilter := A_Args[6]

    ; Retry briefly: the caller may have just launched the window.
    hwnd := 0
    deadline := A_TickCount + 3000
    loop {
        hwnd := (crit = "") ? WinExist("A") : WinExist(crit)
        if (hwnd || A_TickCount >= deadline)
            break
        Sleep(250)
    }
    if !hwnd
        Report("error=Window not found: " (crit = "" ? "(active window)" : OneLine(crit)))

    tree := UiaDumpTree(hwnd, maxDepth, nameFilter, maxLines)
    if (tree = "" && nameFilter = "")
        Report("error=UIA cannot read that window")
    cnt := (tree = "") ? 0 : StrSplit(tree, "`n").Length
    out := ""
    try out .= "window_title=" OneLine(WinGetTitle(hwnd)) "`n"
    try out .= "window_class=" WinGetClass(hwnd) "`n"
    try out .= "window_exe=" WinGetProcessName(hwnd) "`n"
    out .= "lines=" cnt "`n`n" tree
    Report(out)
}

ExitApp(2)
