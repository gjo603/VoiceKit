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
;  Explorer-selection lookup (and the viewer), so it can be tried
;  on a fixture file — e.g. MCP run_automation(args=[...]). No
;  test suite exercises it yet; harmless otherwise.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"
#Include "%A_ScriptDir%\..\lib\ExplorerSel.ahk"

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
EnsureVoiceShortcut(VoiceShortcutName("SplitPages"), A_ScriptFullPath)   ; self-heal "open split pages"

noPreview := (A_Args.Length >= 2 && A_Args[2] = "nopreview")
; The file: an argument (testing), else THE file selected in the front-most
; File Explorer window's active tab (lib\ExplorerSel.ahk — tab-correct).
sel := (A_Args.Length >= 1) ? [A_Args[1]] : ExplorerSelectedFiles()
if (sel.Length = 0) {
    InfoDialog("Nothing selected", "Click the document in File Explorer first, then say `"open split pages`".")
    ExitApp()
}
if (sel.Length > 1) {                        ; never guess which one was meant
    InfoDialog("One document at a time", sel.Length " files are selected. Select just the one PDF to split, then say `"open split pages`" again.")
    ExitApp()
}
src := sel[1]
if !FileExist(src) {
    InfoDialog("File not found", src)
    ExitApp()
}
if !(src ~= "i)\.pdf$") {
    InfoDialog("PDFs only (for now)", "That file isn't a PDF. Scans and receipts saved as PDF work best — print or export it to PDF first.")
    ExitApp()
}

; A fresh per-run subfolder: if a previous run's viewer never let go of a
; page file, the old folder can't fully delete — a unique name keeps that
; leftover from ever colliding with this run's pages.
splitBase := A_Temp "\VoiceKitSplit"
try DirDelete(splitBase, true)               ; best-effort sweep of old runs
splitDir := splitBase "\run " A_Now
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
    ok := SavePage(pageFile, target)
    while (!ok && RetrySaveDialog(i))
        ok := SavePage(pageFile, target)
    if ok
        saved += 1
}
try DirDelete(splitBase, true)
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
    ; Corner placement — never covers the page; activated over the
    ; just-opened viewer with the caret ready in the description box.
    ThemeShowModal(d, 0, [hint, ex], edDesc, ShowBottomRight)
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

; Description -> safe file-name fragment (strip illegal chars, tidy spaces;
; capped so a pasted paragraph can't push the path past Windows' limit).
CleanFileText(s) {
    s := RegExReplace(s, '[\\/:*?"<>|]', "")
    s := RegExReplace(Trim(s), "\s+", " ")
    return Trim(SubStr(s, 1, 120), " .")
}

; Close the viewer window showing temp page i (title contains the file name),
; and wait for it to actually vanish — WinClose only POSTS the close, and the
; save (and the next page's open) must not race a viewer mid-shutdown.
ClosePreview(i) {
    prev := A_TitleMatchMode
    SetTitleMatchMode(2)
    if WinExist("page " Format("{:03}", i)) {
        try WinClose()
        WinWaitClose("page " Format("{:03}", i), , 2)
    }
    SetTitleMatchMode(prev)
}

; Move the finished page into place. A bare FileMove here raced the viewer:
; the window may be gone while the process still holds the file for another
; beat (Acrobat especially), and a rename is blocked while ANY handle without
; delete-sharing is open — so runs started throwing once closes lagged.
; The retry-then-copy dance now lives in _Common.ahk as RobustMove (this
; race belongs to every "move a file an app just touched" flow, not just
; this one); a "copied" result leaves the temp original for the end-of-run
; cleanup, which is exactly what the old inline fallback did.
SavePage(pageFile, target) {
    return RobustMove(pageFile, target) != ""
}

; Shown only when SavePage gave up — the page (or the destination folder)
; is still busy. Voice-clickable, Try Again is the accented default.
RetrySaveDialog(i) {
    retry := false
    d := Gui("+AlwaysOnTop", "Split Pages")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 20, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "Page " i " couldn't be saved")
    d.SetFont("s10 norm")
    d.AddText("xm y+8 w440", "The file is still busy — usually the PDF viewer hasn't let go of it yet. Close any window still showing the page, then try again. Skipping leaves this page out; the original document keeps every page either way.")
    btnRetry := d.AddButton("xm y+14 w150 h34 Default", "Try Again")
    btnSkip := d.AddButton("x+8 w140 h34", "Skip Page")
    btnRetry.OnEvent("Click", (*) => (retry := true, d.Destroy()))
    btnSkip.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())
    ThemeShowModal(d)
    return retry
}

; ------------------------------------------------------------
;  The split itself — python + pypdf, with a consented one-time
;  install if pypdf is missing. Returns page count, or "" after
;  showing an error dialog.
; ------------------------------------------------------------
SplitPdf(src, outDir) {
    global root
    Loop 2 {                                 ; second pass = retry after install
        out := RunCapture(ComSpecPath() ' /c python "' root '\lib\split_pdf.py" "' src '" "' outDir '"')
        count := LastIntLine(out)
        if (count != "")
            return Integer(count)
        if InStr(out, "NEEDS_PYPDF") {
            if (A_Index = 2)
                break
            if !OfferInstall()
                return ""
            RunCapture(ComSpecPath() ' /c python -m pip install pypdf')
            continue
        }
        if InStr(out, "Couldn't run the command")    ; a failed launch, not a missing Python
            break
        if (InStr(out, "not recognized") || InStr(out, "not found")) {
            InfoDialog("Python is needed", "Split Pages needs Python 3 (free, python.org). Install it, then try again.")
            return ""
        }
        break
    }
    InfoDialog("Couldn't split it", out != "" ? out : "No output from the splitter — is Python working?")
    return ""
}

; The splitter prints the page count as its final stdout line — but
; RunCapture merges stderr into the same file, and a pypdf warning can land
; before OR after the count (stderr is unbuffered; redirected stdout is
; block-buffered). So the answer is the LAST line that is purely an integer.
; IsInteger() on the whole merged blob meant one warning turned a successful
; split into an error dialog.
LastIntLine(s) {
    ans := ""
    Loop Parse s, "`n", "`r" {
        if (Trim(A_LoopField) != "" && IsInteger(Trim(A_LoopField)))
            ans := Trim(A_LoopField)
    }
    return ans
}

; Run a console command hidden; return its combined output, trimmed.
; A launch that fails outright (no command interpreter) comes back as text
; the caller's error dialog shows, instead of an uncaught throw.
RunCapture(cmd) {
    outFile := A_Temp "\vk_split_out.txt"
    try FileDelete(outFile)
    try RunWait(cmd ' > "' outFile '" 2>&1', , "Hide")
    catch as e
        return "Couldn't run the command: " e.Message
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
    ThemeShowModal(d)
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
    ThemeShowModal(d)
}
