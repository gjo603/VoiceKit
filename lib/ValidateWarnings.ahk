; ============================================================
;  lib\ValidateWarnings.ahk — loaded with AutoHotkey's /include switch
;  by the load checks (AhkValidate in lib\_Common.ahk, validate_ahk in
;  mcp\voicekit_writer.py), never #Include'd.
;
;  Why: AutoHotkey v2 warns at load by DEFAULT (an unassigned variable, a
;  name used before the function it calls exists — what a half-finished
;  edit looks like), and the default shows the warning as a DIALOG — even
;  under /validate /ErrorStdOut. Launched hidden, nobody can answer it, so
;  every such check hung until its timeout (measured 2026-10-14: 20 s per
;  check). Routed here to stdout instead, the check ends at once and the
;  warning text comes back like a load error does — and the checks FAIL on
;  it, because the same warning is a dialog at every real run.
;
;  Only the two types that are ON by default (measured 2026-10-14 on
;  2.0.26: VarUnset and Unreachable each blocked an include-less check;
;  LocalSameAsGlobal did not — it is off). NOT "#Warn All": that would turn
;  LocalSameAsGlobal on and fail scripts that run without a word.
;
;  A script's OWN #Warn line still wins (it comes later), which is why the
;  checks skip this include for a file that carries one: its author chose.
; ============================================================
#Warn VarUnset, StdOut
#Warn Unreachable, StdOut
