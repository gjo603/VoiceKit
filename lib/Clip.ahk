#Requires AutoHotkey v2.0
; ============================================================
;  Clip.ahk — copy something through the clipboard WITHOUT losing
;  what the user had on it.
;
;  The save / clear / send-keys / ClipWait / restore dance was
;  written out five times (the engine's collect step, the AI text
;  actions' input grab, three Browser.ahk helpers), and two of the
;  copies had no `finally` — so anything that threw between the
;  clear and the restore left the user's clipboard empty. One
;  helper now, and it always restores.
;
;  Self-contained on purpose: lib\Workflow.ahk includes it, and the
;  engine takes no _Common / Theme dependency. Include it with a
;  %A_LineFile%-relative path (AutoHotkey resolves those to one full
;  path, so a host that reaches it through two libraries still gets
;  a single copy).
; ============================================================

; Clear the clipboard, run keysFn (e.g. () => Send("^c")), and wait up to
; timeoutSec for text to land. Returns that text ("" when nothing arrived)
; and sets ok. The caller's clipboard is put back in a `finally`, whatever
; keysFn does — including throw.
ClipCapture(keysFn, timeoutSec := 1, &ok?) {
    ok := false
    text := ""
    saved := ClipboardAll()
    try {
        A_Clipboard := ""
        keysFn.Call()
        ok := ClipWait(timeoutSec) != 0
        text := ok ? A_Clipboard : ""
    } finally {
        A_Clipboard := saved
    }
    return text
}
