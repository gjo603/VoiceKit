#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Split Pages — file a multi-page scan one page at a time.
;  Say "open split pages" with a PDF selected in File Explorer.
;
;  It splits the selected PDF into pages and cycles through them:
;  each page opens in your PDF viewer, a small dialog asks what
;  it is, and the page is saved next to the original named
;      <today's date> <your description>.pdf
;  e.g.  "2026-07-23 Home Depot receipt.pdf"
;  Made for granular filing — receipts, statements, scans.
;  The original document is never modified or deleted.
;
;  Needs Python 3 with the small offline pypdf library; if pypdf
;  is missing, a one-time install is offered (your consent first).
;
;  Testing hook: SplitPages.ahk <file.pdf> [nopreview] skips the
;  Explorer-selection lookup (and the viewer) — used by the
;  automated test, harmless otherwise.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
EnsureSplitShortcut()

noPreview := (A_Args.Length >= 2 && A_Args[2] = "nopreview")
src := (A_Args.Length >= 1) ? A_Args[1] : ExplorerSelectedFile()
if (src = "") {
    InfoDialog("Nothing selected", "Click the document in File Explorer first, then say `"open split pages`".")
    ExitApp()
}
if !FileExist(src) {
    InfoDialog("File not found", src)
    ExitApp()
}
if !(src ~= "i)\.pdf$") {
    InfoDialog("PDFs only (for now)", "That file isn't a PDF. Scans and receipts saved as PDF work best — print or export it to PDF first.")
    ExitApp()
}

splitDir := A_Temp "\VoiceKitSplit"
try DirDelete(splitDir, true)
pageCount := SplitPdf(src, splitDir)         ; shows its own error dialog on failure
if (pageCount = "")
    ExitApp()

destDir := RegExReplace(src, "\\[^\\]+$")
today := FormatTime(A_Now, "yyyy-MM-dd")
saved := 0
stopped := false
Loop pageCount {
    i := A_Index
    pageFile := splitDir "\page " Format("{:03}", i) ".pdf"
    if !noPreview {
        Run('"' pageFile '"')                ; default PDF viewer shows the page
        WaitViewer(i)                        ; let it open FIRST, so it can't steal
    }                                        ; focus from the dialog afterwards
    r := PageDialog(i, pageCount, today)
    if !noPreview
        ClosePreview(i)
    if (r.action = "stop") {
        stopped := true
        break
    }
    if (r.action = "skip")
        continue
    name := today (r.desc != "" ? " " r.desc : " Page " i)
    target := destDir "\" name ".pdf"
    k := 2
    while FileExist(target)                  ; two receipts, same words? keep both
        target := destDir "\" name " (" k++ ").pdf"
    FileMove(pageFile, target)
    saved += 1
}
try DirDelete(splitDir, true)
Log(root, "split-pages | " saved " of " pageCount " | " src)
InfoDialog(stopped ? "Stopped" : "Done ✓",
    saved " page" (saved = 1 ? "" : "s") " saved into:`n" destDir
    . "`n`nThe original document was not changed.")
ExitApp()

; ------------------------------------------------------------
;  One page's question: what is it, save/skip/stop.
; ------------------------------------------------------------
PageDialog(i, n, today) {
    state := {action: "stop", desc: ""}
    d := Gui("+AlwaysOnTop", "Split Pages")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "Page " i " of " n " — what is it?")
    d.SetFont("s10 norm")
    hint := d.AddText("xm y+6 w440", "The page is open in your PDF viewer. A few words is plenty.")
    edDesc := d.AddEdit("xm y+10 w440")
    ex := d.AddText("xm y+4 w440", "File name:  " today "  +  your words   (blank = `"Page " i "`")")
    btnSave := d.AddButton("xm y+14 w160 h34 Default", "Save && Next")
    btnSkip := d.AddButton("x+8 w130 h34", "Skip Page")
    btnStop := d.AddButton("x+8 w110 h34", "Stop")
    btnSave.OnEvent("Click", (*) => (state.action := "save", state.desc := CleanFileText(edDesc.Value), d.Destroy()))
    btnSkip.OnEvent("Click", (*) => (state.action := "skip", d.Destroy()))
    btnStop.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeApply(d)
    ThemeDim(hint)
    ThemeDim(ex)
    hwnd := d.Hwnd
    ShowBottomRight(d)                       ; corner placement — never covers the page
    WinActivate("ahk_id " hwnd)              ; focused over the just-opened viewer
    edDesc.Focus()                           ; caret in the input field, ready to type
    WinWaitClose("ahk_id " hwnd)
    return state
}

; Wait (briefly) for the viewer window showing temp page i, then let it
; settle — so the dialog shown next keeps focus and the caret stays in
; its input field. No viewer in 4 s (odd title, slow app) is fine: the
; dialog still opens; worst case the viewer takes focus and one click
; brings the dialog back.
WaitViewer(i) {
    prev := A_TitleMatchMode
    SetTitleMatchMode(2)
    WinWait("page " Format("{:03}", i), , 4)
    SetTitleMatchMode(prev)
    Sleep(400)
}

; Description -> safe file-name fragment (strip illegal chars, tidy spaces).
CleanFileText(s) {
    s := RegExReplace(s, '[\\/:*?"<>|]', "")
    s := RegExReplace(Trim(s), "\s+", " ")
    return Trim(s, " .")
}

; Close the viewer window showing temp page i (title contains the file name).
ClosePreview(i) {
    prev := A_TitleMatchMode
    SetTitleMatchMode(2)
    if WinExist("page " Format("{:03}", i))
        try WinClose()
    SetTitleMatchMode(prev)
}

; ------------------------------------------------------------
;  The split itself — python + pypdf, with a consented one-time
;  install if pypdf is missing. Returns page count, or "" after
;  showing an error dialog.
; ------------------------------------------------------------
SplitPdf(src, outDir) {
    global root
    Loop 2 {                                 ; second pass = retry after install
        out := RunCapture(A_ComSpec ' /c python "' root '\lib\split_pdf.py" "' src '" "' outDir '"')
        if IsInteger(out)
            return Integer(out)
        if InStr(out, "NEEDS_PYPDF") {
            if (A_Index = 2)
                break
            if !OfferInstall()
                return ""
            RunCapture(A_ComSpec ' /c python -m pip install pypdf')
            continue
        }
        if (InStr(out, "not recognized") || InStr(out, "not found")) {
            InfoDialog("Python is needed", "Split Pages needs Python 3 (free, python.org). Install it, then try again.")
            return ""
        }
        break
    }
    InfoDialog("Couldn't split it", out != "" ? out : "No output from the splitter — is Python working?")
    return ""
}

; Run a console command hidden; return its combined output, trimmed.
RunCapture(cmd) {
    outFile := A_Temp "\vk_split_out.txt"
    try FileDelete(outFile)
    RunWait(cmd ' > "' outFile '" 2>&1', , "Hide")
    return FileExist(outFile) ? Trim(FileRead(outFile, "UTF-8"), " `t`r`n") : ""
}

OfferInstall() {
    ok := false
    d := Gui("+AlwaysOnTop", "Split Pages")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "One-time setup")
    d.SetFont("s10 norm")
    d.AddText("xm y+8 w440", "Splitting PDFs needs a small free component (pypdf, ~2 MB). Install it now? This downloads once from the official Python package index.")
    btnYes := d.AddButton("xm y+14 w150 h34 Default", "Install")
    btnNo := d.AddButton("x+8 w110 h34", "Cancel")
    btnYes.OnEvent("Click", (*) => (ok := true, d.Destroy()))
    btnNo.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeApply(d)
    hwnd := d.Hwnd
    d.Show()
    WinWaitClose("ahk_id " hwnd)
    return ok
}

; ------------------------------------------------------------
;  Misc
; ------------------------------------------------------------
InfoDialog(title, text) {
    d := Gui("+AlwaysOnTop", "Split Pages")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", title)
    d.SetFont("s10 norm")
    d.AddText("xm y+8 w440", text)
    b := d.AddButton("xm y+14 w120 h34 Default", "OK")
    b.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeApply(d)
    hwnd := d.Hwnd
    d.Show()
    WinWaitClose("ahk_id " hwnd)
}

; Path of the file selected in the topmost File Explorer window, or "".
ExplorerSelectedFile() {
    shell := ""
    try shell := ComObject("Shell.Application")
    if !IsObject(shell)
        return ""
    for hwnd in WinGetList("ahk_class CabinetWClass") {   ; z-order: topmost first
        try {
            for w in shell.Windows {
                if (w.HWND != hwnd)
                    continue
                items := w.Document.SelectedItems()
                if (items.Count >= 1)
                    return items.Item(0).Path
            }
        }
    }
    return ""
}

; Self-heal the Start Menu entry so "open split pages" always works.
EnsureSplitShortcut() {
    vmDir := A_Programs "\Voice Macros"
    EnsureDir(vmDir)
    if !FileExist(vmDir "\Split Pages.lnk")
        MakeAhkShortcut(vmDir "\Split Pages.lnk", A_ScriptFullPath)
}
