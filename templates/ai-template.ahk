#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  {{PHRASE}}   (AI text action, created {{DATE}})
;  Trigger by voice:  "open {{PHRASE}}"
;
;  Sends your SELECTED text (or, if nothing is selected, the text
;  on your clipboard) plus the saved prompt to OpenRouter, then
;  TYPES the answer back where your cursor is — so a selection is
;  replaced by the answer.
;
;  The prompt lives in:  prompts\{{BASE}}.prompt.txt  (edit freely)
;  Key / model:          say "open voice kit"  ->  AI Settings
; ============================================================
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"
#Include "%A_ScriptDir%\..\lib\AI.ahk"

root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
promptFile := root "\prompts\{{BASE}}.prompt.txt"
if !FileExist(promptFile) {
    MsgBox("This AI action's prompt file is missing:`n" promptFile, "{{PHRASE}}", "Iconx 262144")
    ExitApp()
}
prompt := Trim(FileRead(promptFile, "UTF-8"), " `t`r`n")

target := AIUsableTargetWin(WinExist("A"))   ; 0 if it's a shell host / VoiceKit window
input := target ? AIGrabInput(&fromSel) : ""
ToolTip("{{PHRASE}} — asking the AI...")
err := ""
answer := AIComplete(prompt "`n`nReply with plain text only — no markdown — because your reply is typed directly into an application."
    , input != "" ? input : "(There is no selected or clipboard text. Follow the instruction on its own.)"
    , &err)
ToolTip()
if (answer = "") {
    MsgBox(err != "" ? err : "The AI returned an empty answer.", "{{PHRASE}}", "Iconx 262144")
    ExitApp()
}
if target {
    try {
        WinActivate("ahk_id " target)
        WinWaitActive("ahk_id " target, , 2)
    }
}
if (target && WinActive("ahk_id " target)) {
    SendText(answer)
} else {
    A_Clipboard := answer
    MsgBox("Couldn't type into the original window, so the answer was copied instead — press Ctrl+V to paste it.", "{{PHRASE}}", "Icon! 262144")
}
