#Requires AutoHotkey v2.0
; ============================================================
;  AI.ahk — the optional OpenRouter backend ("beef up" layer).
;
;  Strictly ADDITIVE: nothing in VoiceKit calls the network until
;  the user pastes an OpenRouter API key into AI Settings. The
;  deterministic workflow engine (lib\Workflow.ahk) knows nothing
;  about this file. Three features sit on top of it:
;    - AI text actions   (macros generated from templates\ai-template.ahk)
;    - Ask AI anywhere   (macros\AskAI.ahk)
;    - Draft with AI     (New Automation -> Workflow Studio review)
;
;  Key storage: DPAPI-encrypted (CryptProtectData, current user) and
;  base64-wrapped in logs\settings.ini — never plaintext on disk, and
;  unreadable from another Windows account.
;
;  Include requirements for hosts:
;    #Include _Common.ahk + Theme.ahk BEFORE this file (every VoiceKit
;    GUI already does). Json.ahk is pulled in here.
; ============================================================
#Include "%A_LineFile%\..\Json.ahk"

; ---- config storage ----------------------------------------

AIRoot() {
    return RegExReplace(A_LineFile, "\\lib\\[^\\]+$")
}

AISettingsIni() {
    return AIRoot() "\logs\settings.ini"
}

AIConfigured() {
    return AIGetKey() != ""
}

AIGetKey() {
    return AIUnprotect(IniRead(AISettingsIni(), "AI", "Key", ""))
}

AISetKey(key) {
    EnsureDir(AIRoot() "\logs")
    if (key = "") {
        try IniDelete(AISettingsIni(), "AI", "Key")
        return
    }
    IniWrite(AIProtect(key), AISettingsIni(), "AI", "Key")
}

; openrouter/auto lets OpenRouter pick a good model per request, so the
; default works without the user knowing any model names.
AIModel() {
    return IniRead(AISettingsIni(), "AI", "Model", "openrouter/auto")
}

AISetModel(model) {
    EnsureDir(AIRoot() "\logs")
    IniWrite(model != "" ? model : "openrouter/auto", AISettingsIni(), "AI", "Model")
}

; ---- the one network call ----------------------------------

; Chat completion via OpenRouter. Returns the assistant's text, or ""
; with err set to a user-readable message. The request runs in WinHttp
; ASYNC mode with a Sleep-poll loop, so the calling GUI keeps pumping
; messages (Close/Escape/voice clicks stay alive) instead of ghosting
; to "(Not Responding)" for the length of a slow request.
; keyOverride/modelOverride let AI Settings' Test button try values
; WITHOUT persisting them first.
AIComplete(systemPrompt, userText, &err := "", maxTokens := 2048, keyOverride := "", modelOverride := "") {
    err := ""
    key := (keyOverride != "") ? keyOverride : AIGetKey()
    model := (modelOverride != "") ? modelOverride : AIModel()
    if (key = "") {
        err := "No OpenRouter API key is set yet. Open AI Settings (say `"open voice kit`") and paste one from openrouter.ai/keys."
        return ""
    }
    body := '{"model":"' JsonEscape(model) '","max_tokens":' maxTokens ',"messages":['
    if (systemPrompt != "")
        body .= '{"role":"system","content":"' JsonEscape(systemPrompt) '"},'
    body .= '{"role":"user","content":"' JsonEscape(userText) '"}]}'

    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("POST", "https://openrouter.ai/api/v1/chat/completions", true)   ; true = async
        req.SetTimeouts(10000, 10000, 30000, 120000)   ; resolve/connect/send/receive ms
        req.SetRequestHeader("Authorization", "Bearer " key)
        req.SetRequestHeader("Content-Type", "application/json")
        req.SetRequestHeader("X-Title", "VoiceKit")
        req.Send(body)
    } catch as e {
        err := "Couldn't reach OpenRouter — check your internet connection. (" e.Message ")"
        return ""
    }
    ; Poll instead of blocking, so this AHK thread stays interruptible.
    ; Verified semantics: WaitForResponse(0) returns false while pending,
    ; true when done, and THROWS the request's error (connect/receive
    ; timeout per SetTimeouts) on terminal failure — so a throw here means
    ; failed, not still-waiting.
    done := false
    deadline := A_TickCount + 125000
    while (A_TickCount < deadline) {
        try done := req.WaitForResponse(0)
        catch as e {
            err := "Couldn't reach OpenRouter — check your internet connection. (" e.Message ")"
            return ""
        }
        if done
            break
        Sleep(100)
    }
    if !done {
        err := "OpenRouter didn't answer in time. Try again, or set a faster model in AI Settings."
        return ""
    }

    status := 0
    try status := req.Status
    ; ResponseText mis-decodes UTF-8 as ANSI when the server sends no
    ; charset (OpenRouter sends bare application/json), turning every
    ; non-ASCII character into mojibake — decode the raw bytes ourselves.
    respText := AIDecodeUtf8Body(req)
    if (respText = "")
        try respText := req.ResponseText
    parsed := ""
    try parsed := JsonParse(respText)

    if (parsed is Map && parsed.Has("error")) {
        apiMsg := ""
        try apiMsg := parsed["error"]["message"]
        err := "OpenRouter error" (status ? " (HTTP " status ")" : "") ": " (apiMsg != "" ? apiMsg : "no details given.")
        if (status = 401)
            err .= "`n`nYour API key looks invalid — open AI Settings and paste a fresh one."
        return ""
    }
    if (status != 200) {
        err := "OpenRouter returned HTTP " status "."
        return ""
    }
    content := ""
    try content := parsed["choices"][1]["message"]["content"]
    if !(content is String) || (content = "") {
        err := "OpenRouter's response had no text in it (model: " model "). Try again, or set a different model in AI Settings."
        return ""
    }
    return content
}

; The response body's raw bytes decoded as UTF-8 ("" on any failure).
AIDecodeUtf8Body(req) {
    try {
        st := ComObject("ADODB.Stream")
        st.Type := 1                    ; binary
        st.Open()
        st.Write(req.ResponseBody)
        st.Position := 0
        st.Type := 2                    ; text
        st.Charset := "utf-8"
        s := st.ReadText()
        st.Close()
        return s
    }
    return ""
}

; The window an AI feature may type into / copy from: `hwnd` if usable,
; else 0. Rejects our own process, other VoiceKit GUIs, and the shell /
; input hosts (same family Workflow Studio's ClassifyWindow blacklists) —
; otherwise launching a feature from the Start menu or the Home window
; makes THAT the "previous app" and the answer lands in the wrong place.
AIUsableTargetWin(hwnd) {
    if !hwnd
        return 0
    try {
        if (WinGetPID(hwnd) = DllCall("GetCurrentProcessId"))
            return 0
        cls := WinGetClass(hwnd)
        if (cls ~= "^(Shell_TrayWnd|Progman|WorkerW|NotifyIconOverflowWindow|Windows\.UI\.Core\.CoreWindow|XamlExplorerHostIslandWindow|AutoHotkeyGUI)$")
            return 0
        if (WinGetProcessName(hwnd) ~= "i)^(VoiceAccess|TextInputHost|SearchHost|StartMenuExperienceHost|ShellExperienceHost)\.exe$")
            return 0
    } catch
        return 0
    return hwnd
}

; ---- selection / clipboard input for AI text actions --------

; The text the user means: their selection if there is one, else whatever
; text is on the clipboard. The user's clipboard is preserved either way.
AIGrabInput(&fromSelection := false) {
    fromSelection := false
    saved := ClipboardAll()
    A_Clipboard := ""
    Send("^c")
    sel := ClipWait(0.6) ? A_Clipboard : ""
    A_Clipboard := saved
    if (sel != "") {
        fromSelection := true
        return sel
    }
    Sleep(150)          ; let the restore settle before reading it back
    return A_Clipboard  ; text form of the original clipboard ("" if none)
}

; ---- settings dialog -----------------------------------------

; Ensure a key exists, showing the settings dialog if not. Returns true
; when configured. `owner` is the calling Gui (or 0).
AIEnsureConfigured(owner := 0) {
    if AIConfigured()
        return true
    AISettingsDialog(owner)
    return AIConfigured()
}

; Themed settings window for the key + model. Modal over `owner` if given.
; Returns true if a key is saved when it closes.
AISettingsDialog(owner := 0) {
    d := Gui("+AlwaysOnTop" (owner ? " +Owner" owner.Hwnd : ""), "AI Settings")
    d.SetFont("s10", "Segoe UI")
    d.MarginX := 18, d.MarginY := 16
    d.SetFont("s12 bold")
    d.AddText("xm", "AI Settings")
    d.SetFont("s10 norm")
    intro := d.AddText("xm y+4 w460", "VoiceKit's AI features run through OpenRouter — one key, any model. Nothing is sent anywhere until a key is saved here.")
    d.AddLink("xm y+8", 'Get a key: <a href="https://openrouter.ai/keys">openrouter.ai/keys</a>')

    d.AddText("xm y+16", "API key:")
    edKey := d.AddEdit("xm y+4 w460 Password")
    keyHint := d.AddText("xm y+4 w460", AIConfigured()
        ? "A key is already saved (encrypted). Leave blank to keep it."
        : "Paste your key here (starts with sk-or-).")

    d.AddText("xm y+14", "Model:")
    edModel := d.AddEdit("xm y+4 w460", AIModel())
    modelHint := d.AddText("xm y+4 w460", "openrouter/auto picks a good model for each request — fine to leave as is.")

    btnSave := d.AddButton("xm y+18 w130 h34 Default", "Save")
    btnTest := d.AddButton("x+8 w130 h34", "Test Key")
    btnRemove := d.AddButton("x+8 w130 h34", "Remove Key")
    btnCancel := d.AddButton("x+8 w110 h34", "Cancel")
    status := d.AddText("xm y+12 w520 h28", "")

    SaveFields(*) {
        if (Trim(edKey.Value) != "")
            AISetKey(Trim(edKey.Value))
        AISetModel(Trim(edModel.Value))
    }
    OnSave(*) {
        if (Trim(edKey.Value) = "" && !AIConfigured()) {
            status.Text := "Paste an API key first (or Cancel)."
            return
        }
        SaveFields()
        d.Destroy()
    }
    OnTest(*) {
        ; Test what's typed WITHOUT persisting it — Cancel after a test
        ; must leave the previously saved key untouched.
        k := Trim(edKey.Value)
        if (k = "")
            k := AIGetKey()
        if (k = "") {
            status.Text := "Paste an API key first."
            return
        }
        btnTest.Enabled := false
        status.Text := "Testing… (a tiny request is on its way)"
        err := ""
        ans := AIComplete("You are a connectivity test.", "Reply with exactly: OK", &err, 16, k, Trim(edModel.Value))
        status.Text := (ans != "") ? "✓ Working — the key and model both answer. Click Save to keep them." : err
        btnTest.Enabled := true
    }
    OnRemove(*) {
        AISetKey("")
        edKey.Value := ""
        keyHint.Text := "Paste your key here (starts with sk-or-)."
        status.Text := "Key removed — AI features are off until a new one is saved."
    }

    btnSave.OnEvent("Click", OnSave)
    btnTest.OnEvent("Click", OnTest)
    btnRemove.OnEvent("Click", OnRemove)
    btnCancel.OnEvent("Click", (*) => d.Destroy())
    d.OnEvent("Close", (*) => d.Destroy())
    d.OnEvent("Escape", (*) => d.Destroy())

    ThemeApply(d, status)
    ThemeDim(intro)
    ThemeDim(keyHint)
    ThemeDim(modelHint)
    d.Show()
    if owner
        owner.Opt("+Disabled")
    WinWaitClose("ahk_id " d.Hwnd)
    if owner {
        owner.Opt("-Disabled")
        WinActivate("ahk_id " owner.Hwnd)
    }
    return AIConfigured()
}

; ---- DPAPI + base64 plumbing ---------------------------------

; UTF-8 string -> DPAPI-encrypted blob -> base64 text.
AIProtect(plain) {
    if (plain = "")
        return ""
    n := StrPut(plain, "UTF-8") - 1        ; bytes without the terminator
    raw := Buffer(n + 1)
    StrPut(plain, raw, "UTF-8")
    inBlob := Buffer(16, 0)
    NumPut("uint", n, inBlob, 0)
    NumPut("ptr", raw.Ptr, inBlob, 8)
    outBlob := Buffer(16, 0)
    if !DllCall("crypt32\CryptProtectData", "ptr", inBlob, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr", outBlob)
        return ""
    cb := NumGet(outBlob, 0, "uint")
    pb := NumGet(outBlob, 8, "ptr")
    b64 := AIBase64Encode(pb, cb)
    DllCall("LocalFree", "ptr", pb)
    return b64
}

; base64 text -> DPAPI-decrypted UTF-8 string ("" on any failure).
AIUnprotect(b64) {
    if (b64 = "")
        return ""
    size := 0
    if !DllCall("crypt32\CryptStringToBinary", "str", b64, "uint", 0, "uint", 1, "ptr", 0, "uint*", &size, "ptr", 0, "ptr", 0)
        return ""
    raw := Buffer(size)
    if !DllCall("crypt32\CryptStringToBinary", "str", b64, "uint", 0, "uint", 1, "ptr", raw, "uint*", &size, "ptr", 0, "ptr", 0)
        return ""
    inBlob := Buffer(16, 0)
    NumPut("uint", size, inBlob, 0)
    NumPut("ptr", raw.Ptr, inBlob, 8)
    outBlob := Buffer(16, 0)
    if !DllCall("crypt32\CryptUnprotectData", "ptr", inBlob, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr", outBlob)
        return ""
    cb := NumGet(outBlob, 0, "uint")
    pb := NumGet(outBlob, 8, "ptr")
    s := StrGet(pb, cb, "UTF-8")
    DllCall("LocalFree", "ptr", pb)
    return s
}

; binary -> single-line base64 (CRYPT_STRING_BASE64 | NOCRLF).
AIBase64Encode(ptr, size) {
    len := 0
    DllCall("crypt32\CryptBinaryToString", "ptr", ptr, "uint", size, "uint", 0x40000001, "ptr", 0, "uint*", &len)
    out := Buffer(len * 2)
    if !DllCall("crypt32\CryptBinaryToString", "ptr", ptr, "uint", size, "uint", 0x40000001, "ptr", out, "uint*", &len)
        return ""
    return StrGet(out, "UTF-16")
}
