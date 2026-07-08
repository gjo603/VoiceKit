#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  Clean Screenshots — say "open clean screenshots"
;  EXAMPLE: moves every .png off the Desktop into
;  Pictures\Screenshots\YYYY-MM. Adjust pattern/folders freely.
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"

dest := A_MyDocuments "\..\Pictures\Screenshots\" FormatTime(A_Now, "yyyy-MM")
EnsureDir(dest)

moved := 0
Loop Files A_Desktop "\*.png" {
    FileMove(A_LoopFileFullPath, dest "\" A_LoopFileName, 1)
    moved += 1
}

Notify("Moved " moved " screenshot(s) to " dest)
