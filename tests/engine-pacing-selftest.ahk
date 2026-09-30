#Requires AutoHotkey v2.0
; Self-test for the engine's pacing and aim (lib\Workflow.ahk):
; the `wait` step's random RANGE and the click-position jitter.
;
; Both exist because a workflow looping against a website with identical
; pauses and pixel-identical clicks is the cheapest bot signal there is.
; Neither may make a run non-deterministic in any way that matters, so what
; this suite really guards is the boundaries: a plain millisecond wait still
; means exactly what it always did, junk is still rejected, and a jittered
; click can never leave the element it was aimed at.
;
; No target window needed — these are pure functions plus one real Sleep.
; Writes PASS/FAIL to engine-pacing-selftest.result.
#Include "%A_ScriptDir%\..\lib\Workflow.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("engine-pacing-selftest")
wfLogFolder := A_Temp "\vk-selftest-logs"   ; keep test runs out of the user's real history

; ---------- 1. WfWaitMs: plain numbers still mean what they meant --------
Check("a plain number is that number", WfWaitMs("1500").ms = 1500)
Check("a plain number has no error", WfWaitMs("1500").err = "")
Check("surrounding spaces are ignored", WfWaitMs("  250  ").ms = 250)
Check("zero is a legitimate wait", WfWaitMs("0").ms = 0 && WfWaitMs("0").err = "")
Check("junk is rejected, not guessed at", WfWaitMs("soon").err != "")
Check("half a range is still junk", WfWaitMs("600-").err != "")
Check("a decimal is not whole milliseconds", WfWaitMs("1.5").err != "")
Check("an empty wait is rejected", WfWaitMs("").err != "")

; ---------- 2. WfWaitMs: ranges -----------------------------------------
inRange := true, sawTwo := Map()
loop 60 {
    w := WfWaitMs("600-1400")
    if (w.err != "" || w.ms < 600 || w.ms > 1400)
        inRange := false
    sawTwo[w.ms] := true
}
Check("every draw from a range lands inside it", inRange)
Check("and the draws are not all the same number", sawTwo.Count > 1, sawTwo.Count " distinct")
Check("spaces around the dash are allowed", WfWaitMs(" 700 - 700 ").ms = 700)
Check("a one-value range is that value", WfWaitMs("800-800").ms = 800)
w := WfWaitMs("1400-600")
Check("a backwards range is read the way it was meant",
    w.err = "" && w.ms >= 600 && w.ms <= 1400, "got " w.ms)

; ---------- 3. what the user is shown ------------------------------------
Check("plain ms still reads as before", WfDurDesc(800) = "800 ms", WfDurDesc(800))
Check("seconds still read as before", WfDurDesc(2600) = "2.6 s", WfDurDesc(2600))
Check("a range says it is random", InStr(WfDurDesc("600-1400"), "random") > 0, WfDurDesc("600-1400"))
; Each end is rendered on its own terms, so a sub-second end stays in ms
; rather than being forced into an awkward "0.6 s".
Check("a range shows both ends", InStr(WfDurDesc("600-1400"), "600 ms") > 0
    && InStr(WfDurDesc("600-1400"), "1.4 s") > 0, WfDurDesc("600-1400"))
; WfDesc draws the popup for the very step whose param may be junk.
Check("junk never throws in the description", WfDurDesc("soon") = "soon ms", WfDurDesc("soon"))
Check("a wait step describes itself", InStr(WfDesc(["wait", "600-1400", "", ""]), "random") > 0,
    WfDesc(["wait", "600-1400", "", ""]))

; ---------- 4. the range really is a pause -------------------------------
; One real run of the step, to prove the parsed number reaches WfSleep.
t0 := A_TickCount
WfRunStep(["wait", "300-400", "", ""])
took := A_TickCount - t0
; Upper bound is generous on purpose: WfSleep slices into 100 ms chunks and
; a loaded machine overshoots each slice — the claim under test is "the
; parsed range reached WfSleep", not "Sleep is precise under load".
Check("a range step actually pauses for a time inside it", took >= 250 && took < 2000, took " ms")
Check("a bad wait step fails with a message naming the problem",
    InStr(WfRunStep(["wait", "soon", "", ""]), "milliseconds") > 0)

; ---------- 5. click jitter ---------------------------------------------
wfClickJitterPx := 0
p := WfClickPoint({x: 100, y: 200, w: 60, h: 20})
Check("jitter off means dead centre", p.x = 130 && p.y = 210, p.x "," p.y)

wfClickJitterPx := 3
rect := {x: 100, y: 200, w: 60, h: 20}
inside := true, moved := false
loop 80 {
    q := WfClickPoint(rect)
    if (q.x < rect.x || q.x >= rect.x + rect.w || q.y < rect.y || q.y >= rect.y + rect.h)
        inside := false
    if (q.x != 130 || q.y != 210)
        moved := true
}
Check("a jittered click stays inside the element", inside)
Check("...but does not always land dead centre", moved)

; However big the setting, the offset is clamped to a third of the extent,
; so a jittered click can never walk off a small control.
wfClickJitterPx := 500
tiny := {x: 0, y: 0, w: 9, h: 9}
inside := true
loop 80 {
    q := WfClickPoint(tiny)
    if (q.x < 0 || q.x > 8 || q.y < 0 || q.y > 8)
        inside := false
}
Check("a huge jitter setting cannot leave a small element", inside)
Check("a zero-size extent gets no offset", WfJitter(9, 0) = 0)
Check("the offset never exceeds a third of the extent", Abs(WfJitter(99, 12)) <= 4)
wfClickJitterPx := 0

TestEnd()
