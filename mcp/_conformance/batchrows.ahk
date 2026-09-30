#Requires AutoHotkey v2.0
#SingleInstance Off
; Conformance harness: read a batch CSV the way a headless loop does — the
; REAL WfLoopCsvRows (lib\WorkflowLoop.ahk), fed by the same
; FileRead(batchFile, "UTF-8") RunWorkflowLoop uses — and write back what it
; got, so the Python test can prove run_workflow_batch's file arrives intact.
;
; This is the Python-writes / AHK-reads seam of run_workflow_batch(source=):
; commas, quotes, newlines, unicode, leading zeros and the metadata column
; must all survive, and no row may be dropped (pass N = row N).
;
; Usage:  AutoHotkey64.exe batchrows.ahk <batch.csv> <out.txt> <label1> [label2 ...]
; Output (UTF-8): one line per row, "<srcRec>|<value1>|<value2>..." with each
; value WfEncode'd; or a single "ERR|<message>" line.
;
;         AutoHotkey64.exe batchrows.ahk /ownsheet <batch path> <out.txt> <root> <Base>
; Writes "1" or "0": would a headless loop treat <batch path> as <Base>'s own
; inputs sheet? The sheet path is derived exactly as LoopRunner +
; RunWorkflowLoop derive it ("<root>\lib\..\workflows\<Base>.steps.txt"), and
; the answer comes from the REAL WfLoopIsOwnSheet.
#Include "%A_ScriptDir%\..\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\..\lib\WorkflowLoop.ahk"

if (A_Args.Length = 5 && A_Args[1] = "/ownsheet") {
    stepsFile := A_Args[4] "\lib\..\workflows\" A_Args[5] ".steps.txt"
    SplitPath(stepsFile, &fname, &fdir)
    sheetPath := fdir "\" RegExReplace(fname, "i)\.steps\.txt$") ".inputs.csv"
    f := FileOpen(A_Args[3], "w", "UTF-8")
    f.Write(WfLoopIsOwnSheet(A_Args[2], sheetPath) ? "1" : "0")
    f.Close()
    ExitApp(0)
}
if (A_Args.Length < 3)
    ExitApp(2)
labels := []
Loop A_Args.Length - 2
    labels.Push(A_Args[A_Index + 2])
err := ""
rows := WfLoopCsvRows(labels, FileRead(A_Args[1], "UTF-8"), &err)
f := FileOpen(A_Args[2], "w", "UTF-8")
if !IsObject(rows) {
    f.Write("ERR|" WfEncode(err) "`n")
    f.Close()
    ExitApp(0)
}
for row in rows {
    line := row.srcRec
    for l in labels
        line .= "|" WfEncode(row[l])
    f.Write(line "`n")
}
f.Close()
ExitApp(0)
