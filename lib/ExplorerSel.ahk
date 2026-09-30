#Requires AutoHotkey v2.0
; ============================================================
;  ExplorerSel.ahk — what is selected in File Explorer.
;
;  ExplorerSelectedFiles(hwnd := 0)  -> Array of full paths
;  ExplorerFolderPath(hwnd)          -> the folder a window shows
;
;  The one copy of this logic. It used to live twice (Workflow
;  Studio's recorder and Split Pages), and both copies had the
;  same Windows 11 bug: every Explorer TAB is its own entry in
;  Shell.Application's window list, and all of a window's tabs
;  report the SAME top-level HWND. Matching on `w.HWND = hwnd`
;  and taking the first entry with a selection therefore read a
;  BACKGROUND tab whenever that tab came first in the list —
;  i.e. the file acted on was not the one the user was looking
;  at. For an office handling client files that is the wrong client's document.
;
;  How the ACTIVE tab is found (measured on Windows 11 25H2,
;  build 26200, 2026-09-30, against throwaway Explorer windows):
;    - each tab owns a ShellTabWindowClass child of the frame;
;      IsWindowVisible is 1 for ALL of them, so visibility can't
;      tell them apart;
;    - the ACTIVE tab's child is always ShellTabWindowClass1 —
;      Ctrl+Tab swapped ShellTabWindowClass1/2 every time;
;    - each Shell.Application entry answers
;      IServiceProvider::QueryService(SID_STopLevelBrowser,
;      IID_IShellBrowser), and IShellBrowser's IOleWindow::
;      GetWindow (vtable slot 3: after IUnknown's 0-2) returns
;      exactly that tab's ShellTabWindowClass hwnd.
;  So: the entry whose GetWindow equals ShellTabWindowClass1 is
;  the tab on screen. If nothing matches, a window with a single
;  entry is unambiguous (older Explorer, no tabs); a window with
;  several entries and no match gives [] — never a guess.
;
;  Not verified here: Windows 10 (no tabs — covered by the
;  single-entry rule, by reasoning rather than measurement) and
;  the desktop (Progman/WorkerW needs a different COM path; "select
;  it in File Explorer" is the documented contract, desktop icons
;  are deliberately not supported).
;
;  Only real file-system items are returned (IsFileSystem, and a
;  drive-letter or UNC path): a file inside a .zip, "This PC",
;  Control Panel entries and other virtual items are skipped.
;
;  Everything is wrapped: any failure returns [] / "", never an
;  error. The vtable call is raw (ComCall), so a wrong slot would
;  be an access violation rather than a catchable error — which
;  is why it is written down above and why this file is only
;  ever used by short-lived processes (workflow stubs, the loop
;  runner, the Studio, Split Pages), never the resident master.
;
;  Self-contained: no #Include, so any script can take it —
;      #Include "%A_ScriptDir%\..\lib\ExplorerSel.ahk"
;  (lib\Workflow.ahk already includes it. Including it again via
;  a different relative spelling is harmless — measured: #Include
;  resolves the path and skips a file it already has.)
; ============================================================

; Full paths of the file-system items selected in the ACTIVE tab of an
; Explorer window. hwnd 0 = the topmost (z-order) File Explorer window whose
; active tab has a selection. [] when nothing is selected, no Explorer window
; is open, or anything at all goes wrong.
ExplorerSelectedFiles(hwnd := 0) {
    out := []
    try {
        if hwnd {
            tab := ExplorerActiveTab(hwnd)
            return IsObject(tab) ? ExplorerTabSelection(tab) : out
        }
        for h in WinGetList("ahk_class CabinetWClass") {      ; z-order: topmost first
            if !DllCall("IsWindowVisible", "ptr", h)            ; Explorer keeps a hidden spare frame
                continue
            tab := ExplorerActiveTab(h)
            if !IsObject(tab)
                continue
            sel := ExplorerTabSelection(tab)
            if sel.Length
                return sel
        }
    }
    return out
}

; The folder the ACTIVE tab of an Explorer window is showing ("" on failure).
; A virtual location ("This PC", Home) comes back as its ::{GUID} parsing
; name, which explorer.exe accepts as an argument — the recorder relies on that.
ExplorerFolderPath(hwnd) {
    try {
        tab := ExplorerActiveTab(hwnd)
        if IsObject(tab)
            return tab.Document.Folder.Self.Path
    }
    return ""
}

; The Shell.Application window object for the tab on screen in Explorer
; window hwnd, or "" when there is no such window or the active tab can't be
; told apart from the others.
ExplorerActiveTab(hwnd) {
    try {
        if (WinGetClass("ahk_id " hwnd) != "CabinetWClass")
            return ""
        cands := []
        for w in ComObject("Shell.Application").Windows {
            try {
                if (w.HWND = hwnd)
                    cands.Push(w)
            }
        }
        if !cands.Length
            return ""
        active := 0
        try active := ControlGetHwnd("ShellTabWindowClass1", "ahk_id " hwnd)
        if active {
            for w in cands {
                if (ExplorerTabHwnd(w) = active)
                    return w
            }
        }
        return cands.Length = 1 ? cands[1] : ""
    }
    return ""
}

; A tab's own window (its ShellTabWindowClass hwnd), or 0.
;   IServiceProvider::QueryService(SID_STopLevelBrowser, IID_IShellBrowser)
;   IShellBrowser : IOleWindow — GetWindow is vtable slot 3.
ExplorerTabHwnd(w) {
    static SID_STopLevelBrowser := "{4C96BE40-915C-11CF-99D3-00AA004AE837}"
    static IID_IShellBrowser := "{000214E2-0000-0000-C000-000000000046}"
    th := 0
    try {
        sb := ComObjQuery(w, SID_STopLevelBrowser, IID_IShellBrowser)
        ComCall(3, sb, "ptr*", &th)
    }
    return th
}

; The real file-system paths among a tab's selected items.
ExplorerTabSelection(tab) {
    out := []
    try {
        for it in tab.Document.SelectedItems() {
            try {
                if !it.IsFileSystem
                    continue
                p := it.Path
                if (p ~= "^(?:[A-Za-z]:\\|\\\\[^\\])")       ; drive letter or UNC
                    out.Push(p)
            }
        }
    }
    return out
}
