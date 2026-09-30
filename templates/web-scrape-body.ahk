#Requires AutoHotkey v2.0
#SingleInstance Ignore
; ============================================================
;  WORKED REFERENCE: scrape a site through the user's browser.
;
;  Not a generator template — nothing fills this in. It is a
;  complete, load-checked body to COPY into
;  hotkeys\bodies\<YourModule>.body.ahk and edit. MCP agents can
;  read it with read_reference("web-scrape").
;
;  The shape below is what survived a real harvest (hundreds of listings,
;  five rewrites): search term -> walk the results by keyboard ->
;  open each hit in a background tab -> capture -> dedupe ->
;  resumable queue. Nearly every scraping job is a variant of it.
;
;  EDIT THE FIVE LINES UNDER "CONFIGURE ME". The rest is the
;  machinery, and every part of it is there because its absence
;  cost a failed run:
;
;   - the domain guard, or a typed query becomes a GOOGLE search
;   - the readback, or a missed click sends the query nowhere
;     and Enter submits it anyway
;   - Ctrl+Enter / capture / Ctrl+W, because back-navigation
;     loses keyboard focus and restarts the walk from the top
;   - the URL check before Ctrl+W, or a failed tab-open closes
;     one of the USER'S tabs
;   - focused-name matching, because an element's accessible name
;     while focused often differs from its copied page text
;   - the KEYBOARD walk instead of UiaFind-and-click, because web
;     pages VIRTUALIZE: only content near the viewport exists in
;     the UIA tree, so finds miss and rect-less clicks go nowhere
;     — Tab both scrolls and realizes the next result
;   - the seen-file and the queue rewrite, so stopping mid-run and
;     pressing the key again RESUMES instead of starting over
;   - varied pauses, because a metronome is the cheapest bot
;     signal there is
;
;  WHILE IT RUNS IT OWNS THE KEYBOARD AND THE BROWSER. Say so.
;  Stop it with Esc, or from an agent with stop_module.
; ============================================================
#Include "%A_ScriptDir%\..\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\..\lib\Browser.ahk"

; ---- CONFIGURE ME -----------------------------------------------------
BASE      := "WebScrape"                       ; this module's file base
DOMAIN    := "example.com/search"              ; must be in the URL before typing
SEARCHBOX := "Search"                          ; the box's accessible name
ITEM_URL  := "example\.com/item/"              ; RegEx an item tab's URL must match
WORKDIR   := A_ScriptDir "\..\..\logs\" BASE   ; queue, seen list and results
; A focused result's accessible name -> a stable dedupe key ("" = not a
; result). Read real names with inspect_focus / dump_uia_tree first: this
; pattern is the single most site-specific line in the file.
ItemKey(name) {
    return RegExMatch(name, "i),\s*item\s+(\d+)\s*$", &m) ? "item:" m[1] : ""
}
MAX_PER_TERM := 40                             ; stop a term after this many
; -----------------------------------------------------------------------

; One instance per module. #SingleInstance above can lose a startup race
; (two presses in quick succession); this cannot.
BodySingleInstance(BASE)

EnsureDir(WORKDIR)
queueFile := WORKDIR "\queue.txt"              ; one search term per line
seenFile  := WORKDIR "\seen.txt"               ; dedupe keys, one per line
outFile   := WORKDIR "\captured.txt"

global gStop := false

if !FileExist(queueFile) {
    MsgBox("Put one search term per line in:`n" queueFile, "Nothing queued")
    ExitApp()
}
terms := []
for line in StrSplit(FileRead(queueFile, "UTF-8"), "`n", "`r") {
    line := Trim(StrReplace(line, Chr(0xFEFF)))     ; a BOM would join term 1
    if (line != "")
        terms.Push(line)
}
if !terms.Length {
    MsgBox("The queue is empty: " queueFile, "Nothing to do")
    ExitApp()
}

seen := Map()
if FileExist(seenFile) {
    for line in StrSplit(FileRead(seenFile, "UTF-8"), "`n", "`r")
        if (line := Trim(line)) != ""
            seen[line] := true
}

hwnd := WinExist("ahk_exe chrome.exe")         ; TODO: your browser
if !hwnd {
    MsgBox("No browser window found — open " DOMAIN " first.", "Nothing to drive")
    ExitApp()
}

captured := 0
for ti, term in terms {
    if gStop || !WinExist("ahk_id " hwnd)
        break
    BodyStatus(BASE, "term " ti "/" terms.Length ": " term "  (" captured " captured)")

    ; The guard that stops a query becoming a Google search.
    if !BrowserEnsureDomain(hwnd, DOMAIN) {
        Save(outFile, term, "ERROR: could not reach " DOMAIN)
        MarkDone(queueFile, terms, ti)
        continue
    }
    ; Type it, and PROVE it landed before pressing Enter. If the field
    ; can't be verified, take the URL route rather than submitting blind.
    if BrowserTypeVerified(hwnd, SEARCHBOX, term) {
        BrowserSend("{Enter}")
    } else if !BrowserEnsureDomain(hwnd, DOMAIN "?q=" UriEncode(term)) {
        Save(outFile, term, "ERROR: search box unverifiable and URL route failed")
        MarkDone(queueFile, terms, ti)
        continue
    }
    if Pause(3000, 5500)
        break
    BrowserGrabPage(hwnd)                      ; puts keyboard focus in the page

    ; ---- walk the results with Tab (it scrolls the page for you) ------
    done := 0, dry := 0
    while (!gStop && done < MAX_PER_TERM && dry < 150) {
        BrowserSend("{Tab}")
        Sleep(Random(250, 550))
        key := ItemKey(UiaName(UiaFocused()))
        if (key = "" || seen.Has(key)) {
            dry += 1
            continue
        }
        ; Mark it BEFORE opening: a result that fails to open must not be
        ; retried forever.
        seen[key] := true
        FileAppend(key "`n", seenFile, "UTF-8")
        dry := 0, done += 1

        BrowserSend("^{Enter}")                ; open in a BACKGROUND tab, so
        Sleep(Random(1800, 3200))              ; the grid keeps scroll + focus
        BrowserSend("^{Tab}")
        Sleep(Random(1500, 3000))

        ; Never Ctrl+W on faith: if the open failed, that would close one of
        ; the user's own tabs.
        if !RegExMatch(BrowserUrl(hwnd), ITEM_URL) {
            BrowserSend("^+{Tab}")             ; back to the results tab
            Sleep(Random(800, 1500))
            continue
        }
        page := BrowserGrabPage(hwnd)
        if (page != "") {
            Save(outFile, BrowserUrl(hwnd), page)
            captured += 1
            BodyStatus(BASE, "term " ti "/" terms.Length ": " term
                . "  —  " done " here, " captured " captured")
        }
        BrowserSend("^w")
        Sleep(Random(1500, 3000))
        if Pause(6000, 14000) || (Random(1, 8) = 1 && Pause(30000, 90000))
            break
    }
    MarkDone(queueFile, terms, ti)             ; resumable from here
}

BodyStatusDone(BASE, (gStop ? "stopped" : "finished") " — " captured " captured")
MsgBox("Run " (gStop ? "stopped" : "finished") ".`n" captured " captured.`n`n" outFile,
    "Scrape")
ExitApp()

; ---------------------------------------------------------------- helpers ---

; Sleep a varied amount, staying stoppable: Esc (the user is at the machine)
; and the stop flag (an agent called stop_module). True = stop now.
Pause(minMs, maxMs) {
    global gStop, BASE                         ; declared: a function reads no
                                               ; outer variable by accident
    endAt := A_TickCount + Random(minMs, maxMs)
    while (A_TickCount < endAt) {
        if (GetKeyState("Esc", "P") || BodyStopRequested(BASE)) {
            gStop := true
            return true
        }
        Sleep(200)
    }
    return false
}

Save(file, what, text) {
    FileAppend("`n" StrReplace(Format("{:50}", ""), " ", "=") "`n"
        . what "`n" FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n"
        . StrReplace(Format("{:50}", ""), " ", "=") "`n" text "`n", file, "UTF-8")
}

; Drop every term up to and including justDone, so a stopped run resumes
; where it left off. UTF-8-RAW: a BOM here would corrupt the next term read.
MarkDone(queueFile, terms, justDone) {
    remaining := ""
    loop terms.Length - justDone
        remaining .= terms[justDone + A_Index] "`n"
    f := FileOpen(queueFile, "w", "UTF-8-RAW")
    f.Write(remaining)
    f.Close()
}

; Percent-encode for a query string, UTF-8 byte by byte (so accented and
; non-Latin terms survive the URL route).
UriEncode(s) {
    buf := Buffer(StrPut(s, "UTF-8"))
    StrPut(s, buf, "UTF-8")
    out := ""
    loop buf.Size - 1 {                        ; -1: skip the terminating NUL
        b := NumGet(buf, A_Index - 1, "UChar")
        ch := Chr(b)
        out .= RegExMatch(ch, "[A-Za-z0-9\-_.~]") ? ch : Format("%{:02X}", b)
    }
    return out
}
