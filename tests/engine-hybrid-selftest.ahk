#Requires AutoHotkey v2.0
; Self-test for the engine's HYBRID element lookup (lib\Workflow.ahk).
;
; Why this exists: the engine found things through Acc.ahk (MSAA) only, and
; current Chrome publishes no web page content over MSAA at all — so every
; named click inside a page failed, saved workflows included. WfFindElement
; now tries MSAA and UIA in alternating short passes. This proves both halves
; work, that the fallback actually fires for something MSAA cannot see, and
; that a miss still gives up inside its budget rather than doubling it.
;
; Since 2026-09-30 it also covers the READ side (`collect` from a named box,
; WfFieldValue): a box only UIA can see, the label-vs-input trap (the input
; is read, not the label sharing its name), MSAA still winning when both
; trees see a box, found-but-empty, trimmed names, and a miss inside its
; budget — plus the browser pacing (WfIsBrowserWindow): a Chrome-class
; window skips MSAA's retry turn, measured against a pretend browser.
;
; Drives a SEPARATE process (engine-hybrid-selftest-target.ahk): UIA against
; your own process deadlocks, so a same-process test would prove nothing.
; Writes PASS/FAIL to engine-hybrid-selftest.result; a missing result file
; means a step failed and its error MsgBox is blocking.
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("engine-hybrid-selftest")
wfLogFolder := A_Temp "\vk-selftest-logs"   ; keep test runs out of the user's real history

; The "about to:" lines are the hang diagnostic (same convention as
; uia-selftest): every Acc/UIA lookup is a cross-process call that can BLOCK
; rather than fail if the target's message pump wedges — when the runner's
; 120 s kill fires, the last line names the phase that never came back.

title := "VKHybridTarget_ZZ"
; TargetLaunch pins the window to the PID it just launched (see _harness.ahk).
; By the time the fresh window exists, #SingleInstance Force has already
; replaced any leftover target, so the title-only criteria the engine steps
; use are safe too.
if !(hwnd := TargetLaunch("engine-hybrid-selftest-target.ahk", title, &tpid))
    ExitApp(1)

; ---------- 1. both halves, on their own ---------------------------------
Say("about to: Acc and UIA lookups against the fresh target, hwnd=" hwnd)
accLoc := AccFindByName(hwnd, "Hybrid Button Zz", 3000)
Check("MSAA still finds the button (the path recorded workflows rely on)",
    IsObject(accLoc), IsObject(accLoc) ? accLoc.x "," accLoc.y " " accLoc.w "x" accLoc.h : "nothing")

uiaLoc := WfUiaRect(hwnd, "Hybrid Button Zz", 3000)
Check("the UIA half finds the same button", IsObject(uiaLoc),
    IsObject(uiaLoc) ? uiaLoc.x "," uiaLoc.y " " uiaLoc.w "x" uiaLoc.h : "nothing")
Check("and agrees with MSAA about where it is",
    IsObject(accLoc) && IsObject(uiaLoc) && Abs(accLoc.x - uiaLoc.x) <= 4
        && Abs(accLoc.y - uiaLoc.y) <= 4)

; ---------- 2. the combined lookup ---------------------------------------
loc := WfFindElement(title, "Hybrid Button Zz")
Check("WfFindElement finds it", IsObject(loc))
Check("WfFindElement returns a usable rect", IsObject(loc) && loc.w > 10 && loc.h > 5,
    IsObject(loc) ? loc.w "x" loc.h : "no rect")

Say("about to: UIA-only name (fallback proof)")
; The fallback proof. The caption buttons live in the window's NON-client
; area, which the engine's MSAA walk cannot reach (AccNodeOnce starts at
; OBJID_CLIENT) but which UIA lists in full. So "Minimize" is a name only
; the second half can find — the shape of the Chrome problem, reproduced
; without a browser. Measured, not assumed: the same probe says the window
; title IS in both trees, so it would have proved nothing.
;
; Found, never clicked. A generic name like this matches the app's own
; window chrome, and a workflow that search-and-clicks "Close" over a whole
; subtree closes the user's browser — the reason element names in real
; workflows should be page-unique.
accOnly := AccFindByName(hwnd, "Minimize", 700)
uiaOnly := WfUiaRect(hwnd, "Minimize", 1500)
Check("a name MSAA's client tree cannot see", !IsObject(accOnly))
Check("...is found by the UIA half", IsObject(uiaOnly))
Check("...and so WfFindElement finds it too", IsObject(WfFindElement(title, "Minimize")))

; ---------- 3. a miss still gives up on time -----------------------------
Say("about to: WfFindElement miss (Acc+UIA interleaved to deadline)")
t0 := A_TickCount
Check("a name in neither tree is a miss, not an error",
    WfFindElement(title, "No Such Element Zz") = "")
elapsed := A_TickCount - t0
Check("...within its budget (interleaved, not doubled)", elapsed < 6000, elapsed " ms")

; ---------- 4. conditions read both trees --------------------------------
Say("about to: WfElementPresent / WfTextVisible conditions")
Check("elementexists is true for a real element", WfElementPresent(title, "Hybrid Button Zz") = true)
t0 := A_TickCount
Check("elementexists is false for an absent one", WfElementPresent(title, "No Such Element Zz") = false)
elapsed := A_TickCount - t0
Check("...and stays a snapshot, not a wait", elapsed < 2500, elapsed " ms")
; On failure, say which layer went blind — WinGetText, Acc, or UIA — instead
; of a bare FAIL (this check flaked once under load and told us nothing).
TvDetail() {
    global title
    h := WinExist(title)
    wgt := ""
    try wgt := WinGetText("ahk_id " h)
    return "hwnd=" h " wgtLen=" StrLen(wgt) " wgtHit=" (InStr(wgt, "hybrid edit value zz") ? 1 : 0)
        . " acc=" (AccTextPresent(h, "hybrid edit value zz", 700) ? 1 : 0)
        . " uia=" (UiaAvailable() && UiaTextPresent(h, "hybrid edit value zz", 700) ? 1 : 0)
}
tv1 := WfTextVisible(title, "hybrid edit value zz")
Check("textvisible sees the edit's contents", tv1 = true, tv1 ? "" : TvDetail())
tv2 := WfTextVisible(title, "HYBRID EDIT VALUE ZZ")
Check("textvisible is case-insensitive", tv2 = true, tv2 ? "" : TvDetail())
Check("textvisible is false for absent text", WfTextVisible(title, "no such text zz") = false)

; ---------- 5. end to end, through a real click step ---------------------
Say("about to: real click steps")
before := Integer(TargetState("clicks"))
err := WfRunStep(["click", title, "Hybrid Button Zz", ""])
Sleep(700)
after := Integer(TargetState("clicks"))
Check("a click step reports success", err = "", err)
Check("and the target's handler really ran", after = before + 1, "clicks " before " -> " after)

; A named click with jitter turned up must still land on the button — the
; offset is clamped inside the rect, so however large the setting, the click
; cannot leave the element it was aimed at.
wfClickJitterPx := 40
before := after
err := WfRunStep(["click", title, "Hybrid Button Zz", ""])
Sleep(700)
after := Integer(TargetState("clicks"))
Check("a heavily jittered click still hits the element", after = before + 1,
    "clicks " before " -> " after (err != "" ? "  err: " err : ""))
wfClickJitterPx := 0

; ---------- 6. trimmed needles -------------------------------------------
; MSAA's walk always trimmed the name; UIA's exact-match condition did not,
; so a stray space around a UIA-only name used to be a miss.
Say("about to: trimmed names")
Check("a spaced name still finds an MSAA element",
    IsObject(WfFindElement(title, "  Hybrid Button Zz ")))
Check("...and a UIA-only one", IsObject(WfFindElement(title, " Minimize  ")))

; ---------- 7. collect from a named box: both trees ----------------------
; The form window (see the target) has a DEEP panel MSAA's walk can't reach
; and UIA can: the browser problem's shape. Every deep box sits after a
; Text sharing its name — the label-vs-input trap.
Say("about to: collect lookups (WfFieldValue)")
formT := "VKHybridForm_ZZ ahk_pid " tpid
webT := "VKHybridWeb_ZZ ahk_pid " tpid
hf := WinExist(formT), hw := WinExist(webT)
Check("the form and pretend-browser windows exist", hf && hw, "form=" hf " web=" hw)

; Preconditions first, so nothing below can pass for the wrong reason.
Check("precondition: MSAA cannot see the deep box",
    !AccValueByName(hf, "Deep Trap Zz", 500).found)
first := UiaFind(hf, "Deep Trap Zz", 1000)
Check("precondition: UIA's first match of that name is the LABEL (trap is live)",
    first && UiaControlType(first) = UIA_TYPE_TEXT(), first ? UiaControlType(first) : "none")
decoy := UiaFindEdit(hf, "Both Box Zz", 1000)
Check("precondition: UIA's first Edit named 'Both Box Zz' is the deep decoy",
    decoy && UiaValueOnly(decoy) = "deep decoy zz", decoy ? UiaValueOnly(decoy) : "none")

r := WfFieldValue(hf, "Deep Trap Zz")
Check("a UIA-only box is read, and it is the INPUT not its label",
    r.found && r.value == "deep trap value zz", r.found " '" r.value "'")
r := WfFieldValue(hf, "Both Box Zz")
Check("when both trees see a box, MSAA's answer wins (desktop unchanged)",
    r.found && r.value == "acc value zz", r.found " '" r.value "'")
t0 := A_TickCount
r := WfFieldValue(hf, "Deep Empty Zz")
elapsed := A_TickCount - t0
Check("a found-but-empty UIA box is a legitimate empty value",
    r.found && r.value == "", r.found " '" r.value "'")
Check("...reported at the deadline, like MSAA's (a box may fill in late)",
    elapsed >= 2500 && elapsed < 6000, elapsed " ms")
r := WfFieldValue(hf, "  Deep Trap Zz  ")
Check("a spaced box name is trimmed", r.found && r.value == "deep trap value zz", r.value)
t0 := A_TickCount
r := WfFieldValue(hf, "No Such Box Zz")
elapsed := A_TickCount - t0
Check("a box in neither tree is not found", !r.found)
Check("...within its budget (interleaved, not doubled)", elapsed < 6000, elapsed " ms")

; ---------- 8. browser pacing ---------------------------------------------
; A Chrome_WidgetWin_1 window gets ONE MSAA walk per round instead of the
; 400 ms retry turn (measured: ~580 ms -> ~45 ms for a UIA-only button).
; Best of three, so a busy machine can't fail it by one slow sample.
Say("about to: browser pacing")
Check("the pretend browser is recognised as one", WfIsBrowserWindow(hw) = true)
Check("an AutoHotkey window is not", WfIsBrowserWindow(hf) = false)
best := 99999, found := true
loop 3 {
    t0 := A_TickCount
    found := found && IsObject(WfFindElement(webT, "Web Button Zz"))
    best := Min(best, A_TickCount - t0)
}
Check("a UIA-only element in a browser is found", found)
Check("...without paying MSAA's retry turn first", best < 300, best " ms (was ~580)")
r := WfFieldValue(hw, "Web Field Zz")
Check("collect reads a browser's UIA-only box", r.found && r.value == "web value zz", r.value)
t0 := A_TickCount
Check("a browser miss is still a miss", WfFindElement(webT, "No Such Element Zz") = "")
elapsed := A_TickCount - t0
Check("...within its budget", elapsed < 6000, elapsed " ms")
before := Integer(TargetState("webclicks"))
err := WfRunStep(["click", webT, "Web Button Zz", ""])
Check("a click step lands in the browser's UIA-only button",
    err = "" && Integer(TargetState("webclicks", before + 1)) = before + 1,
    "err='" err "' webclicks " before " -> " TargetState("webclicks"))

; ---------- 9. collect end to end, through the engine ---------------------
; collect reads the ACTIVE window; quiet mode so a failure can't pop a modal.
Say("about to: collect steps end to end")
wfRunQuiet := true, wfTrayOff := true, wfRunName := "VKHybridCollectTest"
WinActivate(formT)
WinWaitActive(formT, , 3)
Check("the form is active for the collect steps", WinActive(formT))
got := Map(), got.CaseSense := false
ok := RunWorkflowSteps([["collect", "Trap", "Deep Trap Zz", ""],
                        ["collect", "Both", "Both Box Zz", ""],
                        ["collect", "Empty", "Deep Empty Zz", ""]], Map(), got)
Check("a run of collect steps succeeds", ok = true, WfRunOutcome())
Check("...reading the UIA-only input", got.Get("Trap", "?") == "deep trap value zz", got.Get("Trap", "?"))
Check("...MSAA's box where both can see one", got.Get("Both", "?") == "acc value zz", got.Get("Both", "?"))
Check("...and the empty box as empty", got.Has("Empty") && got["Empty"] == "")
WinActivate(formT)
WinWaitActive(formT, , 3)
ok := RunWorkflowSteps([["collect", "Nope", "No Such Box Zz", ""]], Map(), Map())
Check("a collect of a missing box fails the run", ok = false && WfRunOutcome() = "failed", WfRunOutcome())
Check("...naming the box in the reason", InStr(wfRun["reason"], "No Such Box Zz"), wfRun["reason"])
wfRunQuiet := false

TargetStop()
TestEnd()
