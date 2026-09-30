#Requires AutoHotkey v2.0
; ============================================================
;  VoiceKitLauncher — the safe way to start VoiceKit.
;
;  VoiceKit.ahk pulls hotkeys\_index.ahk in at COMPILE time, so a
;  single module that stops parsing means the master never starts:
;  every always-on hotkey AND every snippet dies with it, and it
;  stays dead until a human notices and restarts it. Reloads go
;  through ReloadMasterNotify, which load-checks first — but a reboot
;  runs the Startup shortcut straight at the master, with nothing
;  in between. This is that missing step.
;
;  Make the per-user files (hotkeys\_index.ahk, bridge-map.txt,
;  hotkeys\Snippets.ahk) from their shipped *.default copies when
;  missing, and add any newly shipped hotkey line (SeedUserFiles —
;  MasterPreflight's first step); load-check, park whatever won't
;  load (its #Include is commented out in hotkeys\_index.ahk, ready
;  to switch back on), then start the master, which reports anything
;  parked in its own tray note.
;
;  Only lib\_Common.ahk is included, and that file includes nothing
;  itself, so no user module can break this one.
; ============================================================
; Off, explicitly: with no directive v2 defaults to Prompt, and a second
; launch while the first is still load-checking (two reloads back to back,
; the watchdog racing a reload) sat on an "already running — replace it?"
; modal until somebody answered it. A second preflight over files that
; already load is harmless, and the master's own #SingleInstance Force
; settles a double start.
#SingleInstance Off
#Include "%A_ScriptDir%\lib\_Common.ahk"

r := MasterPreflight(A_ScriptDir)

; Start first, talk after: at login the whole point is that VoiceKit
; comes up. Anything parked is announced by the master's own startup
; TrayTip (ReportQuarantine), so there's nothing to add here.
if r.ok {
    RunAhk(A_ScriptDir "\VoiceKit.ahk")
    ExitApp(0)
}

; Couldn't be fixed by parking a module — a core file is broken, so
; there is no VoiceKit at all. That has to be loud.
MsgBox(r.note, "VoiceKit couldn't start", "Iconx 262144")   ; 262144 = always-on-top
ExitApp(1)
