#Requires AutoHotkey v2.0
#SingleInstance Off
; Self-test for lib\ExplorerSel.ahk - which files are selected in File
; Explorer, read from the ACTIVE tab (Windows 11 tabs share one HWND).
;
; Part 1 (always): the failure paths return []/"" and never throw, and the
; file-system filter keeps drive/UNC paths only - on fake shell objects.
;
; Part 2 (live): ONLY when no File Explorer window is open at the start -
; the user's windows are never touched, so with any open this part is
; skipped (SKIP lines, not failures). It opens its OWN window on a %TEMP%
; folder, identifies it by the hwnd that appeared and the folder it shows,
; opens a second tab in it (Ctrl+T - the only keystrokes, sent to that
; window only after activating it), selects items through the shell's COM
; interface, and closes every tab it opened at the end.
;
; Writes PASS/FAIL to explorer-selftest.result (see _harness.ahk).
#Include "%A_ScriptDir%\..\lib\ExplorerSel.ahk"
#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("explorer-selftest")

; ---------- 1. failure paths and the filter ------------------------------
IsEmptyArr(v) => (v is Array) && v.Length = 0

r := ExplorerSelectedFiles(0x7FFFFFF0)                   ; no such window
Check("bogus hwnd -> []", IsEmptyArr(r))
r := ExplorerSelectedFiles(A_ScriptHwnd)                 ; a window, but not Explorer
Check("non-Explorer hwnd -> []", IsEmptyArr(r))
Check("bogus hwnd -> no folder", ExplorerFolderPath(0x7FFFFFF0) = "")
Check("bogus hwnd -> no tab", ExplorerActiveTab(0x7FFFFFF0) = "")
Check("tab hwnd of a non-COM value is 0", ExplorerTabHwnd({}) = 0)
Check("selection of a broken tab -> []", IsEmptyArr(ExplorerTabSelection({})))

FakeItem(fs, path) => {IsFileSystem: fs, Path: path}
fakeItems := [FakeItem(true, "C:\Clients\Invoice 2025.pdf")
    , FakeItem(false, "C:\Clients\pack.zip\inner.pdf")           ; zip-internal
    , FakeItem(true, "::{20D04FE0-3AEA-1069-A2D8-08002B30309D}")  ; This PC
    , FakeItem(true, "\\server\share\a b.pdf")                    ; UNC
    , {}]                                                          ; throws on read
fakeTab := {Document: {SelectedItems: (this) => fakeItems}}
got := ExplorerTabSelection(fakeTab)
Check("filter keeps drive + UNC paths only", got.Length = 2
    && got[1] = "C:\Clients\Invoice 2025.pdf" && got[2] = "\\server\share\a b.pdf",
    "got " got.Length)

preOpen := WinGetList("ahk_class CabinetWClass")        ; visible Explorer windows only
if preOpen.Length {
    Say("SKIP  live Explorer checks: " preOpen.Length " File Explorer window(s) already open - "
        . "the test never touches the user's windows. Close them to run this part.")
    TestEnd()
}
Check("no Explorer open -> [] (hwnd 0)", IsEmptyArr(ExplorerSelectedFiles()))

; ---------- 2. live, against a throwaway window --------------------------
base := A_Temp "\vk-explorer-selftest"
try DirDelete(base, true)
DirCreate(base "\A"), DirCreate(base "\B")
fa1 := base "\A\one two.pdf", fa2 := base "\A\b&c.txt", fb1 := base "\B\three.txt"
FileAppend("1", fa1), FileAppend("2", fa2), FileAppend("3", fb1)
zipOk := false
try {
    RunWait('tar.exe -a -cf "' base '\A\pack.zip" "three.txt"', base "\B", "Hide")
    zipOk := FileExist(base "\A\pack.zip") != ""
}

myHwnd := 0
Cleanup() {
    global myHwnd, base
    if myHwnd {
        loop 3 {
            for w in ExplorerTabsOf(myHwnd)
                try w.Quit()
            if WinWaitClose("ahk_id " myHwnd, , 3)
                break
        }
    }
    try DirDelete(base, true)
}
Bail(why) {
    Check(why, false)
    Cleanup()
    TestEnd()
}

; Every Shell.Application entry (tab) belonging to hwnd.
ExplorerTabsOf(hwnd) {
    out := []
    try {
        for w in ComObject("Shell.Application").Windows {
            try {
                if (w.HWND = hwnd)
                    out.Push(w)
            }
        }
    }
    return out
}
TabPath(w) {
    try return w.Document.Folder.Self.Path
    return ""
}
; Select `names` (in that tab's folder) and nothing else. [] = select none.
SelectOnly(w, names) {
    doc := w.Document
    was := []
    for it in doc.SelectedItems()
        was.Push(it)
    for it in was
        doc.SelectItem(it, 0)                            ; 0 = deselect
    first := true
    for nm in names {
        doc.SelectItem(doc.Folder.ParseName(nm), first ? (1 | 4 | 16) : 1)   ; select (+deselect others, focus)
        first := false
    }
    Sleep(300)
}
Same(arr, want*) {
    if (arr.Length != want.Length)
        return false
    for i, v in want
        if (arr[i] != v)
            return false
    return true
}
Show(arr) {
    s := ""
    for v in arr
        s .= (s = "" ? "" : " | ") v
    return "got [" s "]"
}

Run('explorer.exe "' base '\A"')
deadline := A_TickCount + 10000
while (!myHwnd && A_TickCount < deadline) {
    for h in WinGetList("ahk_class CabinetWClass") {
        tabs := ExplorerTabsOf(h)
        if (tabs.Length = 1 && TabPath(tabs[1]) = base "\A")
            myHwnd := h
    }
    Sleep(150)
}
if !myHwnd
    Bail("opened a throwaway Explorer window on the temp folder")
Check("opened a throwaway Explorer window on the temp folder", true)
tabA := ExplorerTabsOf(myHwnd)[1]
; the view needs a moment before it takes selections
loop 30 {
    try {
        if IsObject(tabA.Document.Folder.ParseName("one two.pdf"))
            break
    }
    Sleep(150)
}

SelectOnly(tabA, ["one two.pdf"])
Check("one file selected", Same(ExplorerSelectedFiles(myHwnd), fa1), Show(ExplorerSelectedFiles(myHwnd)))
Check("...found with hwnd 0 (topmost Explorer)", Same(ExplorerSelectedFiles(), fa1), Show(ExplorerSelectedFiles()))
Check("folder path of the window", ExplorerFolderPath(myHwnd) = base "\A", ExplorerFolderPath(myHwnd))
SelectOnly(tabA, ["one two.pdf", "b&c.txt"])
sel := ExplorerSelectedFiles(myHwnd)
Check("multi-select returns both", sel.Length = 2
    && ((sel[1] = fa1 && sel[2] = fa2) || (sel[1] = fa2 && sel[2] = fa1)), Show(sel))
SelectOnly(tabA, [])
Check("nothing selected -> []", IsEmptyArr(ExplorerSelectedFiles(myHwnd)), Show(ExplorerSelectedFiles(myHwnd)))
Check("nothing selected -> [] (hwnd 0)", IsEmptyArr(ExplorerSelectedFiles()))

; A file INSIDE a .zip is a virtual item - not something a command can open.
if zipOk {
    zipView := false
    try {
        tabA.Navigate2(base "\A\pack.zip")
        loop 40 {
            Sleep(150)
            if InStr(TabPath(tabA), "pack.zip") {
                zipView := true
                break
            }
        }
    }
    if zipView {
        inner := ""
        loop 20 {
            try inner := tabA.Document.Folder.ParseName("three.txt")
            if IsObject(inner)
                break
            Sleep(150)
        }
        try SelectOnly(tabA, ["three.txt"])
        n := 0
        try n := tabA.Document.SelectedItems().Count
        if (n = 1)
            Check("an item inside a .zip is excluded", IsEmptyArr(ExplorerSelectedFiles(myHwnd)),
                Show(ExplorerSelectedFiles(myHwnd)))
        else
            Say("SKIP  zip-internal check: couldn't select inside the zip view")
    } else
        Say("SKIP  zip-internal check: the window didn't open the zip")
    try tabA.Navigate2(base "\A")
    loop 40 {
        Sleep(150)
        if (TabPath(tabA) = base "\A")
            break
    }
} else
    Say("SKIP  zip-internal check: couldn't build a zip (tar.exe)")

; ---- two tabs: the ACTIVE one must win ----
; Ctrl+T is sent only once our own window is verifiably the active one.
tabB := ""
try {
    WinActivate("ahk_id " myHwnd)
    if WinWaitActive("ahk_id " myHwnd, , 3) {
        Send("^t")
        loop 40 {
            Sleep(150)
            tabs := ExplorerTabsOf(myHwnd)
            if (tabs.Length = 2) {
                for w in tabs
                    if (TabPath(w) != base "\A")
                        tabB := w
                break
            }
        }
    }
}
if !IsObject(tabB) {
    Say("SKIP  tab checks: couldn't open a second tab in the test window (it never became active)")
} else {
    tabB.Navigate2(base "\B")
    loop 40 {
        Sleep(150)
        if (TabPath(tabB) = base "\B")
            break
    }
    loop 20 {
        try {
            if IsObject(tabB.Document.Folder.ParseName("three.txt"))
                break
        }
        Sleep(150)
    }
    SelectOnly(tabA, ["one two.pdf"])
    SelectOnly(tabB, ["three.txt"])
    ; Both tabs hold a selection; the new tab (B) is the one on screen. The old
    ; lookup took the first entry in Shell.Application's list - tab A here.
    first := ExplorerTabsOf(myHwnd)[1]
    Say("info  Shell.Application lists the " (TabPath(first) = base "\A" ? "BACKGROUND" : "active")
        . " tab first (the old code read that one)")
    Check("two tabs: the active tab's file is returned", Same(ExplorerSelectedFiles(myHwnd), fb1),
        Show(ExplorerSelectedFiles(myHwnd)))
    Check("...and its folder", ExplorerFolderPath(myHwnd) = base "\B", ExplorerFolderPath(myHwnd))
    Check("...also via hwnd 0", Same(ExplorerSelectedFiles(), fb1), Show(ExplorerSelectedFiles()))
    switched := false
    try {
        WinActivate("ahk_id " myHwnd)
        if WinWaitActive("ahk_id " myHwnd, , 3) {
            Send("^{Tab}")
            loop 20 {
                Sleep(150)
                if (ExplorerFolderPath(myHwnd) = base "\A") {
                    switched := true
                    break
                }
            }
        }
    }
    if switched
        Check("after switching tabs, the other tab's file", Same(ExplorerSelectedFiles(myHwnd), fa1),
            Show(ExplorerSelectedFiles(myHwnd)))
    else
        Say("SKIP  tab-switch check: Ctrl+Tab didn't switch tabs")
}

Cleanup()
Check("the throwaway window is gone", !WinExist("ahk_id " myHwnd))
TestEnd()
