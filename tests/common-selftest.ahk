#Requires AutoHotkey v2.0
#SingleInstance Off
; Self-test for the GUI-side helpers New Automation, the home window and
; Workflow Studio share (lib\_Common.ahk + lib\Theme.ahk): the snippet parser,
; validator and check-and-restore write; AhkStrLit and the write-then-load-
; check helpers; the companion-hotkey replace (an old key must survive a
; replacement that won't load); module unwiring and delete; the tool lists;
; the workflow-stub marker; the snippet codec (SnipEncode/SnipDecode), the
; JSON parser, the bridge-key allocator, the naming helpers, the workflow
; and macro deletes; the per-user file seed + shipped-line merge
; (SeedUserFiles); and ThemeShowModal's dialog-lifetime contract.
;
; Every file lives in a %TEMP% sandbox standing in for the VoiceKit root —
; never the real hotkeys\, bridge-map.txt or Start Menu: VoiceMacrosDir()
; is pointed at a sandbox folder before anything runs (and checked), so the
; shortcut helpers create and delete .lnk files there, never in the user's
; real "Voice Macros" folder. Nothing here reloads the master: no delete
; below retires a companion hotkey, the one thing that would trigger it
; (the one delete that has a companion -- a tool's -- must keep it).
; The dialog checks drive two throwaway windows of this script's own.
; Writes PASS/FAIL to common-selftest.result, ending ALL PASSED / N FAILURE(S).
#Include "%A_ScriptDir%\..\lib\_Common.ahk"
#Include "%A_ScriptDir%\..\lib\Theme.ahk"
#Include "%A_ScriptDir%\..\lib\Json.ahk"

#Include "%A_ScriptDir%\_harness.ahk"
TestBegin("common-selftest")

Put(path, text) {
    try FileDelete(path)
    FileAppend(text, path, "UTF-8")
}
Has(path, needle) => FileExist(path) && InStr(FileRead(path, "UTF-8"), needle, true) > 0
Count(path, needle) {
    n := 0
    if FileExist(path)
        Loop Parse FileRead(path, "UTF-8"), "`n", "`r"
            if InStr(A_LoopField, needle)
                n += 1
    return n
}

box := A_Temp "\vk-common-selftest"
try DirDelete(box, true)
DirCreate(box "\hotkeys\bodies")
DirCreate(box "\logs\module-backups")
DirCreate(box "\macros")
DirCreate(sm := box "\startmenu")
; Before ANY helper runs: every shortcut the helpers touch now lives here.
; If the redirect ever stops working, stop -- the deletes below would
; otherwise reach the real Start Menu.
if (VoiceMacrosDir(sm) != sm || VoiceMacrosDir() != sm) {
    Check("VoiceMacrosDir can be pointed at a sandbox", false, VoiceMacrosDir())
    TestEnd()
}

; ---------- 1. the snippet line parser -----------------------------------
s := SnippetParseLine(":*:/sig::Best``nMe")
Check("parses opts / abbrev / on-disk text", IsObject(s) && s.opts = "*" && s.abbrev = "/sig"
    && s.text = "Best``nMe", IsObject(s) ? s.opts "|" s.abbrev "|" s.text : "no match")
s := SnippetParseLine("::btw::by the way")
Check("an options-less hotstring parses too", IsObject(s) && s.opts = "" && s.abbrev = "btw")
Check("a comment line is not a snippet", SnippetParseLine("; :*:/x::y") = "")
s := SnippetParseLine(":*:/date:: {")
Check("a code-block snippet's text is its brace", IsObject(s) && Trim(s.text) = "{")

; ---------- 2. the snippet rules ------------------------------------------
Check("empty abbreviation refused", SnippetValidate("", "x") != "")
Check("colon refused", SnippetValidate("a:b", "x") != "")
Check("backtick refused (Invalid hotkey otherwise)", SnippetValidate("ab``", "x") != "")
Check("blank text refused", SnippetValidate("/x", " `r`n ") != "")
Check("lone brace refused", SnippetValidate("/x", " { ") != "")
Check("a normal snippet passes", SnippetValidate("/x", "hello `; world") = "")

; ---------- 3. snippet file edits, load-checked with a byte-exact restore -
snip := box "\hotkeys\Snippets.ahk"
Put(snip, "#Requires AutoHotkey v2.0`n; my snippets`n:*:/one::First`n::two::Second`n")
Check("SnippetExists is caseless", SnippetExists(snip, "/ONE") && SnippetExists(snip, "TWO"))
Check("SnippetExists misses what isn't there", !SnippetExists(snip, "/nope"))
ok := SnippetFileChange(snip, () => ReplaceSnippetLine(snip, "/one", "/uno", "Primero"), &err)
Check("a good edit stands", ok && err = "", err)
Check("...rewritten in place, options and comment kept", Has(snip, ":*:/uno::Primero")
    && !Has(snip, "/one") && Has(snip, "::two::Second") && Has(snip, "; my snippets"))
before := FileRead(snip, "RAW")
beforeText := FileRead(snip, "UTF-8")
ok := SnippetFileChange(snip, () => (FileAppend("`n:*:ab``::hello", snip, "UTF-8"), true), &err)
after := FileRead(snip, "RAW")
Check("a change that breaks the file is refused", !ok && err != "", SubStr(err, 1, 80))
Check("...and the file is put back byte for byte", after.Size = before.Size
    && FileRead(snip, "UTF-8") == beforeText, before.Size " -> " after.Size)
Check("...so it still loads", AhkValidate(snip).ok)
ok := SnippetFileChange(snip, () => RemoveSnippetLine(snip, "/missing"), &err)
Check("nothing to change reports not-found, not an error", !ok && err = "")
Check("RemoveSnippetLine matches caselessly", RemoveSnippetLine(snip, "TWO") && !Has(snip, "::two::"))

; ---------- 4. AhkStrLit + write-then-load-check --------------------------
Check("AhkStrLit escapes a space-semicolon", AhkStrLit("a `;b") = '"a ``;b"', AhkStrLit("a `;b"))
Check("AhkStrLit escapes quote, backtick, newline", AhkStrLit('say "hi" ``x' "`r`n" "y")
    = '"say ``"hi``" ````x``ny"', AhkStrLit('say "hi" ``x' "`r`ny"))
typed := HotkeyInProcessContent("Typed Probe", "Q", "SendText(" AhkStrLit("SELECT 1 `; SELECT 2") ")",
    "Types the saved text")
ok := HotkeyWriteChecked(box, "hotkeys\TypedProbe.ahk", typed, &err)
Check("a no-code module typing a space-semicolon now loads", ok, err)
ok := AhkWriteChecked(box "\macros\Broken.ahk", "#Requires AutoHotkey v2.0`nx := `"never closed`n", &err)
Check("a file that won't load is refused", !ok && InStr(err, "load check"), SubStr(err, 1, 80))
Check("...and deleted again", !FileExist(box "\macros\Broken.ahk"))

; ---------- 5. companion hotkeys: create, replace, and a failed replace ---
root := box
Put(root "\hotkeys\_index.ahk", "#Requires AutoHotkey v2.0`n")
Put(root "\bridge-map.txt", "; bridge map`n")
comp := HotkeyCompanionFile(root, "Demo")
Check("companion created", HotkeyCompanionCreate(root, "Demo", "open demo", "Q") = ""
    && HotkeyCompanionKey(root, "Demo") = "Q" && Has(comp, "^!+Q::"))
err := HotkeyCompanionCreate(root, "Demo", "open demo", '"')   ; a quote breaks the literals: can't load
Check("a replacement that won't load is refused", err != "", SubStr(err, 1, 60))
Check("...and the OLD key is untouched (module, map, index)", HotkeyCompanionKey(root, "Demo") = "Q"
    && Has(comp, "^!+Q::") && Count(root "\hotkeys\_index.ahk", "Demo.hotkey.ahk") = 1)
Check("a good replacement swaps the key", HotkeyCompanionCreate(root, "Demo", "open demo", "W") = ""
    && HotkeyCompanionKey(root, "Demo") = "W" && Has(comp, "^!+W::"))
Check("...leaving one map line and one index line", Count(root "\bridge-map.txt", "Demo.hotkey.ahk") = 1
    && Count(root "\hotkeys\_index.ahk", "Demo.hotkey.ahk") = 1)
Check("remove retires it", HotkeyCompanionRemove(root, "Demo") && !FileExist(comp)
    && !Count(root "\bridge-map.txt", "Demo.hotkey") && !Count(root "\hotkeys\_index.ahk", "Demo.hotkey"))
Check("removing again is a no-op", !HotkeyCompanionRemove(root, "Demo"))

; ---------- 6. deleting a hotkey module takes everything with it ----------
Put(root "\hotkeys\Mod.ahk", "modProbe := 1`n")
Put(root "\hotkeys\ModExtra.ahk", "modExtra := 1`n")
Put(HotkeyBodyFile(root, "Mod"), "x := 1`n")
Put(ModuleBackupFile(root, "Mod"), "old := 1`n")
BodyStatus("Mod", "3 / 766", root)
Put(BodyStopFile("Mod", root), "")
BridgeRegisterModule(root, "K", "mod", "hotkeys\Mod.ahk")
BridgeRegisterModule(root, "L", "mod extra", "hotkeys\ModExtra.ahk")
Check("DeleteHotkeyModuleArtifacts reports it deleted", DeleteHotkeyModuleArtifacts(root, "mod"))
Check("...the module, body, backup, status and stop flag are gone", !FileExist(root "\hotkeys\Mod.ahk")
    && !FileExist(HotkeyBodyFile(root, "Mod")) && !FileExist(ModuleBackupFile(root, "Mod"))
    && !IsObject(BodyStatusRead("Mod", root)) && !FileExist(BodyStopFile("Mod", root)))
Check("...its lines went (caselessly), a longer name's stayed",
    !Count(root "\hotkeys\_index.ahk", "\Mod.ahk") && !Count(root "\bridge-map.txt", "|hotkeys\Mod.ahk|")
    && Count(root "\hotkeys\_index.ahk", "ModExtra.ahk") = 1 && Count(root "\bridge-map.txt", "ModExtra.ahk") = 1)
Check("Snippets.ahk is never deleted as a module", !DeleteHotkeyModuleArtifacts(root, "snippets")
    && FileExist(snip))

; ---------- 7. tool lists, stub marker, entry names -----------------------
Check("builtin tools are caseless", VkBuiltinTools().Has("askai") && VkBuiltinTools().Has("WORKFLOWSTUDIO"))
Check("Split Pages is delete-protected but not a builtin", VkDeleteProtected("splitpages")
    && !VkBuiltinTools().Has("SplitPages") && !VkDeleteProtected("MorningTabs"))
Put(root "\macros\SplitPages.ahk", "; a tool`n")
Check("DeleteMacroArtifacts refuses a protected tool", !DeleteMacroArtifacts(root, "SplitPages", "Split Pages")
    && FileExist(root "\macros\SplitPages.ahk"))
Put(root "\macros\Stub.ahk", ";  Generated by Workflow Studio — don't edit steps here.`n")
Put(root "\macros\Mentions.ahk", "; opens Workflow Studio for you`n")
Check("a generated stub is recognized", IsWorkflowStub(root "\macros\Stub.ahk"))
Check("merely mentioning the Studio is not a stub", !IsWorkflowStub(root "\macros\Mentions.ahk"))
Check("a missing file is not a stub", !IsWorkflowStub(root "\macros\Nope.ahk"))
Check("the home window's entry is 'Voice Kit'", VoiceShortcutName("VoiceKitHome") = "Voice Kit"
    && VoiceShortcutName("MorningTabs") = "Morning Tabs")

; ---------- 8. the snippet codec: SnipEncode / SnipDecode ------------------
; SnipEncode puts any text on ONE line of Snippets.ahk; a bad line there
; stops every snippet loading, so the round trip AND the load both matter.
; (Byte parity with voicekit_writer.snip_encode: test_generators_match_ahk.)
CrlfOnly(t) => StrReplace(StrReplace(StrReplace(t, "`r`n", "`n"), "`r", "`n"), "`n", "`r`n")
nasty := ["a;b", "``", "line1`r`nline2`rline3`nline4", "tab`there `; semi", " `; comment-like",
    "caf" Chr(0xE9) " " Chr(0x2014) " " Chr(0x2713), "``n stays literal", "trailing``",
    "```;", "say `"hi`" {Enter}", "100% | done"]
snipLines := "#Requires AutoHotkey v2.0`n"
oneLine := true, noBareSemi := true, roundTrip := true, rtDetail := ""
for t in nasty {
    enc := SnipEncode(t)
    if InStr(enc, "`n") || InStr(enc, "`r")
        oneLine := false
    if RegExMatch(enc, "(?<!``);")
        noBareSemi := false
    if !(SnipDecode(enc) == CrlfOnly(t))
        roundTrip := false, rtDetail .= "[" t "] -> [" enc "] -> [" SnipDecode(enc) "] "
    snipLines .= ":*:/zz" A_Index "::" enc "`n"
}
Check("SnipEncode keeps every text on one line", oneLine)
Check("...with every semicolon escaped", noBareSemi)
Check("SnipDecode(SnipEncode(t)) gives t back (newlines as CRLF)", roundTrip, rtDetail)
Put(box "\hotkeys\SnipCodec.ahk", snipLines)
v := AhkValidate(box "\hotkeys\SnipCodec.ahk")
Check("...and a Snippets file of every encoded line loads", v.ok, SubStr(v.text, 1, 120))
Check("SnipDecode reads a hand-written ``t as a tab", SnipDecode("a``tb") == "a`tb")
Check("SnipDecode drops a stray ``r", SnipDecode("a``rb") == "ab")
Check("SnipDecode reads an unknown escape as its character", SnipDecode("``x``;``{") == "x;{")
Check("SnipDecode keeps a lone trailing backtick", SnipDecode("ab``") == "ab``")
Check("empty text encodes and decodes to empty", SnipEncode("") == "" && SnipDecode("") == "")

; ---------- 9. JsonParse / JsonEscape -------------------------------------
; The parser behind every AI reply and New Automation's AI draft: strict on
; purpose, so the malformed cases must THROW rather than half-parse.
JsonThrows(s) {
    try JsonParse(s)
    catch
        return true
    return false
}
j := ""
try j := JsonParse('{"a": [1, -2.5, 3e2, true, false, null], "b": {"c": "d"}, "": "empty key"}')
Check("a nested document parses into Map / Array", Type(j) = "Map" && Type(j["a"]) = "Array"
    && Type(j["b"]) = "Map", Type(j))
if (Type(j) = "Map") {
    a := j["a"]
    Check("numbers: int, negative float, exponent", a[1] = 1 && a[2] = -2.5 && a[3] = 300,
        a[1] " " a[2] " " a[3])
    Check("true / false / null -> 1 / 0 / empty", a[4] == 1 && a[5] == 0 && a[6] == "")
    Check("a nested object's value", j["b"]["c"] == "d")
    Check("an empty key is a key", j.Has("") && j[""] == "empty key")
}
k := JsonParse('{"K": 1, "k": 2}')
Check("keys are case-sensitive, like JSON", k.Count = 2 && k["K"] = 1 && k["k"] = 2)
Check("string escapes decode", JsonParse('"q\"b\\s\/n\nt\tué"')
    == 'q"b\s/n' "`n" "t`t" "u" Chr(0xE9))
Check("a \uXXXX escape decodes", JsonParse('"café A"') == "caf" Chr(0xE9) " A")
Check("an escaped surrogate pair is one character", JsonParse('"😀"') == Chr(0x1F600))
Check("a literal supplementary character passes through", JsonParse('"😀"') == Chr(0x1F600))
Check("whitespace anywhere between tokens", JsonParse(" `r`n`t[ 1 ,`n 2 ]`n ").Length = 2)
Check("empty containers", JsonParse("{}").Count = 0 && JsonParse("[]").Length = 0
    && Type(JsonParse("[]")) = "Array" && Type(JsonParse("{}")) = "Map")
Check("a top-level scalar", JsonParse('"x"') == "x" && JsonParse("42") = 42 && IsInteger(JsonParse("0")))
bad := ["", "   ", "[1,]", '{"a":1,}', "{a:1}", "{'a':1}", "[1 2]", '"unterminated', "tru", "True",
    "01", "1.", "-", '"bad \x"', '"\u12"', "[1]x", "NaN", '{"a" 1}']
notThrown := ""
for s in bad
    if !JsonThrows(s)
        notThrown .= "[" s "] "
Check("malformed input throws, every time", notThrown = "", "parsed: " notThrown)
raw := 'q"b\s' "`n`r`t`b`f" Chr(1) Chr(0x1F) Chr(0xE9) "/"
Check("JsonEscape round-trips through JsonParse", JsonParse('"' JsonEscape(raw) '"') == raw)
Check("JsonEscape writes control characters as \u escapes", InStr(JsonEscape(Chr(1)), "\u0001"))

; ---------- 10. BridgeFreeKeys: the AHK key allocator ---------------------
; (Rule parity with voicekit_writer._used_bridge_keys: test_used_bridge_keys_match_ahk.)
mapf := box "\free-keys-map.txt"
Put(mapf, "; header: pressing Ctrl+Alt+Shift+G is mentioned, not registered`n"
    . "Ctrl+Alt+Shift+B|bee|hotkeys\B.ahk|2026-01-01`n"
    . "; Ctrl+Alt+Shift+D|parked|hotkeys\D.ahk|2026-01-01`n"
    . "  Ctrl+Alt+Shift+f | padded | hotkeys\F.ahk | 2026-01-01`n"
    . "Ctrl+Alt+Shift+[|bracket|hotkeys\Br.ahk|2026-01-01`n")
free := JoinList(BridgeFreeKeys(mapf), "")
Check("used keys (plain, commented-out, padded + lowercase, punctuation) are skipped, pool order kept",
    free == "AGJKLMOPQSTUVWYZ0123456789];',./-=\", free)
Check("a missing map leaves the whole pool free", JoinList(BridgeFreeKeys(box "\no-such-map.txt"), "")
    == BridgeKeyPool())
Check("the reserved keys are never in the pool", !RegExMatch(BridgeKeyPool(), "[ENRXHIC]"))

; ---------- 11. naming helpers ----------------------------------------------
; (Byte parity with voicekit_writer: test_generators_match_ahk.)
Check("CleanPhrase title-cases", CleanPhrase("meeting notes") == "Meeting Notes"
    && CleanPhrase("MEETING NOTES") == "Meeting Notes")
Check("CleanPhrase: no capital after a digit (StrTitle)", CleanPhrase("open2tabs") == "Open2tabs")
Check("CleanPhrase deletes punctuation, not spaces it", CleanPhrase("meeting-notes!!") == "Meetingnotes")
Check("CleanPhrase collapses and trims whitespace", CleanPhrase("  a   b`t c  ") == "A B C",
    "[" CleanPhrase("  a   b`t c  ") "]")
Check("CleanPhrase trims AFTER stripping (no leading space left)", CleanPhrase("! foo !") == "Foo"
    && CleanPhrase(" `n foo `n ") == "Foo", "[" CleanPhrase("! foo !") "]")
Check("CleanPhrase of nothing is nothing", CleanPhrase("") == "" && CleanPhrase("!!!") == "")
Check("SpaceOut splits camel case and digits", SpaceOut("OpenPublicUserFolder") == "Open Public User Folder"
    && SpaceOut("Plan9Tabs") == "Plan9 Tabs")
Check("SpaceOut leaves capitals-only runs alone", SpaceOut("ABCDef") == "ABCDef")
Check("Abbrev cuts long text only", Abbrev("abcdef", 3) == "abc..." && Abbrev("ab", 3) == "ab")
Check("AhkStrEsc escapes backtick then quote", AhkStrEsc('a"b``c') == 'a``"b````c')
Check("JoinList", JoinList(["a", "b", "c"]) == "a|b|c" && JoinList([], ",") == "")
Check("reserved device names are caught, caselessly", IsReservedName("con") && IsReservedName("COM1")
    && IsReservedName("lpt9") && !IsReservedName("Con1") && !IsReservedName("Notes"))
Check("a companion's parent is recovered from its file", HotkeyCompanionParent(HotkeyCompanionRel("MorningTabs"))
    == "MorningTabs" && HotkeyCompanionParent("hotkeys\MorningTabs.ahk") == "")
Check("the body layout", HotkeyBodyRel("Scrape") == "hotkeys\bodies\Scrape.body.ahk")

; ---------- 12. deleting a workflow takes all its artifacts ----------------
DirCreate(box "\workflows")
DirCreate(box "\logs\loop-journal")
DirCreate(box "\prompts")
stubText := ";  Generated by Workflow Studio — don't edit steps here.`n"
for f in ["workflows\ZzFlow.steps.txt", "workflows\ZzFlow.inputs.csv", "workflows\ZzFlow.results.csv",
        "workflows\ZzFlowLonger.steps.txt", "logs\loop-journal\ZzFlow.20260101010101-1.jnl",
        "logs\loop-journal\ZzFlow.notajournal.jnl", "logs\loop-journal\ZzFlowLonger.20260101010101-1.jnl"]
    Put(root "\" f, "x`n")
Put(root "\macros\ZzFlow.ahk", stubText)
Put(root "\macros\ZzFlowLonger.ahk", stubText)
for f in ["Zz Flow.lnk", "loop Zz Flow.lnk", "Zz Flow Longer.lnk", "loop Zz Flow Longer.lnk"]
    Put(sm "\" f, "x")
DeleteWorkflowArtifacts(root, "ZzFlow", "Zz Flow")
Check("steps, inputs sheet and results overflow are gone", !FileExist(root "\workflows\ZzFlow.steps.txt")
    && !FileExist(root "\workflows\ZzFlow.inputs.csv") && !FileExist(root "\workflows\ZzFlow.results.csv"))
Check("its loop journal is gone, a non-journal file is kept",
    !FileExist(root "\logs\loop-journal\ZzFlow.20260101010101-1.jnl")
    && FileExist(root "\logs\loop-journal\ZzFlow.notajournal.jnl"))
Check("the generated stub and both Start Menu entries are gone", !FileExist(root "\macros\ZzFlow.ahk")
    && !FileExist(sm "\Zz Flow.lnk") && !FileExist(sm "\loop Zz Flow.lnk"))
Check("a workflow whose name merely STARTS the same is untouched",
    FileExist(root "\workflows\ZzFlowLonger.steps.txt") && FileExist(root "\macros\ZzFlowLonger.ahk")
    && FileExist(root "\logs\loop-journal\ZzFlowLonger.20260101010101-1.jnl")
    && FileExist(sm "\Zz Flow Longer.lnk") && FileExist(sm "\loop Zz Flow Longer.lnk"))
Put(root "\workflows\ZzHand.steps.txt", "x`n")
Put(root "\macros\ZzHand.ahk", "; my own hand-written macro`n")
DeleteWorkflowArtifacts(root, "ZzHand", "Zz Hand")
Check("a hand-written macro of the same name is never deleted", FileExist(root "\macros\ZzHand.ahk")
    && !FileExist(root "\workflows\ZzHand.steps.txt"))
Put(root "\macros\SplitPages.ahk", stubText)          ; even one carrying the marker
Put(sm "\Split Pages.lnk", "x")
Put(sm "\loop Split Pages.lnk", "x")
Put(root "\workflows\SplitPages.steps.txt", "x`n")
DeleteWorkflowArtifacts(root, "SplitPages", "Split Pages")
Check("a tool's name keeps the tool's script and its Start Menu entry",
    FileExist(root "\macros\SplitPages.ahk") && FileExist(sm "\Split Pages.lnk"))
Check("...but the workflow's own steps and loop entry go",
    !FileExist(root "\workflows\SplitPages.steps.txt") && !FileExist(sm "\loop Split Pages.lnk"))
; A legacy workflow saved under RecordMySteps: the tool's SHIPPED companion
; (^!+W) is keyed by the same base, and must survive the workflow's delete.
; (Were it retired, the delete would also reload -- the one path in this
; file that could; a regression shows up as a timeout, never a pass.)
Put(root "\hotkeys\RecordMySteps.hotkey.ahk", "; companion`n")
Put(root "\bridge-map.txt", "; bridge map`nCtrl+Alt+Shift+W|open record my steps|hotkeys\RecordMySteps.hotkey.ahk|2026-07-23`n")
Put(root "\workflows\RecordMySteps.steps.txt", "x`n")
DeleteWorkflowArtifacts(root, "RecordMySteps", "Record My Steps")
Check("a tool-named workflow's delete keeps the tool's companion hotkey",
    FileExist(root "\hotkeys\RecordMySteps.hotkey.ahk")
    && Count(root "\bridge-map.txt", "RecordMySteps.hotkey.ahk") = 1
    && HotkeyCompanionKey(root, "RecordMySteps") = "W"
    && !FileExist(root "\workflows\RecordMySteps.steps.txt"))

; ---------- 13. macros: shortcut, name claim, delete -----------------------
Put(root "\macros\ZzMac.ahk", "; an AI action`n")
lnk := EnsureVoiceShortcut("Zz Mac", root "\macros\ZzMac.ahk")
Check("EnsureVoiceShortcut creates the entry (in the sandbox)", lnk = sm "\Zz Mac.lnk" && FileExist(lnk))
Check("ClaimNewMacroName refuses nothing when the name is free", ClaimNewMacroName(root, "ZzFree", 0) == "Zz Free")
Put(root "\prompts\ZzMac.prompt.txt", "prompt`n")
DirCreate(box "\logs\macro-backups")
Put(MacroBackupFile(root, "ZzMac"), "old`n")
Check("DeleteMacroArtifacts reports it deleted", DeleteMacroArtifacts(root, "ZzMac", "Zz Mac", true))
Check("...the script, prompt, Start Menu entry and undo backup are gone",
    !FileExist(root "\macros\ZzMac.ahk") && !FileExist(root "\prompts\ZzMac.prompt.txt")
    && !FileExist(lnk) && !FileExist(MacroBackupFile(root, "ZzMac")))

; ---------- 13b. per-user files: seed from defaults, merge shipped lines -----
; A root of its own (box\seed) so nothing above can colour the result.
sd := box "\seed"
DirCreate(sd "\hotkeys")
incW := '#Include "%A_ScriptDir%\hotkeys\Ship.hotkey.ahk"'
incS := '#Include "%A_ScriptDir%\hotkeys\Snippets.ahk"'
Put(sd "\hotkeys\_index.default.ahk", "; manifest`n" incS "`n`n" incW "`n")
Put(sd "\bridge-map.default.txt", "; map`nCtrl+Alt+Shift+W|open ship|hotkeys\Ship.hotkey.ahk|2026-01-01`n")
Put(sd "\hotkeys\Snippets.default.ahk", "; snippets`n:*:/d::x`n")
Put(sd "\hotkeys\Ship.hotkey.ahk", "; shipped companion`n")
; (1) missing live files: all three are created, byte-identical.
r := SeedUserFiles(sd)
Check("missing live files are created from their defaults", r.created.Length = 3
    && FileRead(sd "\hotkeys\_index.ahk", "RAW").Size = FileRead(sd "\hotkeys\_index.default.ahk", "RAW").Size
    && FileRead(sd "\bridge-map.txt", "UTF-8") == FileRead(sd "\bridge-map.default.txt", "UTF-8"),
    r.created.Length)
Check("...and a fresh index counts as changed, with nothing merged", r.indexChanged && !r.merged.Length)
r := SeedUserFiles(sd)
Check("a second run does nothing", !r.created.Length && !r.merged.Length && !r.indexChanged)
; (2) an upgrade: the live files predate the shipped companion, and hold
; user lines (unterminated last line, like the tools leave it).
userInc := '#Include "%A_ScriptDir%\hotkeys\Mine.ahk"'
Put(sd "\hotkeys\_index.ahk", "; manifest`n" incS "`n" userInc)
Put(sd "\bridge-map.txt", "; map`nCtrl+Alt+Shift+A|mine|hotkeys\Mine.ahk|2026-02-02`n")
Put(sd "\hotkeys\Snippets.ahk", "; my snippets only`n")
r := SeedUserFiles(sd)
idx := FileRead(sd "\hotkeys\_index.ahk", "UTF-8"), bm := FileRead(sd "\bridge-map.txt", "UTF-8")
Check("a missing shipped include and map line are added", r.indexChanged && r.merged.Length = 2
    && Count(sd "\hotkeys\_index.ahk", "Ship.hotkey.ahk") = 1 && Count(sd "\bridge-map.txt", "Ship.hotkey.ahk") = 1, idx)
Check("user lines are kept, in order, ahead of the added one",
    InStr(idx, userInc "`n" incW) && InStr(bm, "hotkeys\Mine.ahk|2026-02-02`nCtrl+Alt+Shift+W|"), idx)
Check("Snippets.ahk is never merged into", FileRead(sd "\hotkeys\Snippets.ahk", "UTF-8") == "; my snippets only`n")
r := SeedUserFiles(sd)
Check("...and merging twice adds nothing", !r.merged.Length && Count(sd "\hotkeys\_index.ahk", "Ship.hotkey.ahk") = 1)
; (3) the user commented the shipped line out: it stays out.
Put(sd "\hotkeys\_index.ahk", "; manifest`n" incS "`n; " incW "    parked by me`n")
Put(sd "\bridge-map.txt", "; map`n; Ctrl+Alt+Shift+W|open ship|hotkeys\Ship.hotkey.ahk|2026-01-01`n")
r := SeedUserFiles(sd)
Check("a commented-out shipped line is not resurrected", !r.merged.Length
    && Count(sd "\hotkeys\_index.ahk", "Ship.hotkey.ahk") = 1 && Count(sd "\bridge-map.txt", "Ship.hotkey.ahk") = 1)
; (4) the user moved the companion to another key: present by FILE.
Put(sd "\hotkeys\_index.ahk", "; manifest`n" incS "`n" incW "`n")
Put(sd "\bridge-map.txt", "; map`nCtrl+Alt+Shift+Q|open ship|hotkeys\Ship.hotkey.ahk|2026-03-03`n")
r := SeedUserFiles(sd)
Check("a companion re-keyed by the user isn't re-added under the shipped key",
    !r.merged.Length && !InStr(FileRead(sd "\bridge-map.txt", "UTF-8"), "Shift+W"))
; (5) the shipped key is already someone else's: neither line is added.
Put(sd "\hotkeys\_index.ahk", "; manifest`n" incS "`n")
Put(sd "\bridge-map.txt", "; map`nCtrl+Alt+Shift+W|other|hotkeys\Other.ahk|2026-04-04`n")
r := SeedUserFiles(sd)
Check("a shipped hotkey whose key is taken is held back (include too)", !r.merged.Length
    && !Count(sd "\hotkeys\_index.ahk", "Ship.hotkey.ahk"))
; (6) the shipped module file is gone (the user removed the companion).
Put(sd "\bridge-map.txt", "; map`n")
FileDelete(sd "\hotkeys\Ship.hotkey.ahk")
r := SeedUserFiles(sd)
Check("a shipped hotkey whose file is gone is not wired", !r.merged.Length
    && !Count(sd "\bridge-map.txt", "Ship.hotkey.ahk"))
; (7) CRLF live file: the added line follows its style.
FileAppend("; shipped companion`n", sd "\hotkeys\Ship.hotkey.ahk", "UTF-8")
Put(sd "\hotkeys\_index.ahk", "; manifest`r`n" incS "`r`n")
Put(sd "\bridge-map.txt", "; map`r`n")
SeedUserFiles(sd)
Check("an added line matches a CRLF file's line endings",
    InStr(FileRead(sd "\hotkeys\_index.ahk", "UTF-8"), incS "`r`n" incW "`r`n"))
; (8) no defaults at all (a test fixture, a dev tree): nothing happens.
nd := box "\nodefaults"
DirCreate(nd "\hotkeys")
r := SeedUserFiles(nd)
Check("a root without defaults is left alone", !r.created.Length && !r.merged.Length
    && !FileExist(nd "\hotkeys\_index.ahk") && !FileExist(nd "\bridge-map.txt"))

; ---------- 14. ThemeShowModal --------------------------------------------
WS_DISABLED := 0x8000000
owner := Gui("+AlwaysOnTop", "vk common-selftest owner")
owner.AddText("w220", "owner")
owner.Show("NoActivate")
ownerHwnd := owner.Hwnd
state := {during: -1, hook: false, fn: false}

d := Gui("+AlwaysOnTop +Owner" ownerHwnd, "vk common-selftest dialog")
ed := d.AddEdit("w220")
lbl := d.AddText("w220", "hint")
dHwnd := d.Hwnd
Probe() {
    global state, ownerHwnd, d
    try state.during := (WinGetStyle("ahk_id " ownerHwnd) & 0x8000000) ? 1 : 0   ; WS_DISABLED
    try d.Destroy()
}
SetTimer(Probe, -400)
ThemeShowModal(d, owner, [lbl, (*) => state.fn := true], ed, (g) => (state.hook := true, g.Show()))
Check("the owner is disabled while the dialog is up", state.during = 1, state.during)
Check("...and enabled again after", !(WinGetStyle("ahk_id " ownerHwnd) & WS_DISABLED))
Check("the placement hook showed it", state.hook)
Check("a function in dims runs after theming", state.fn)
Check("the dialog is gone", !WinExist("ahk_id " dHwnd))

; The dialog-lifetime trap: destroyed the instant it appears (a fast Enter or
; a voice click). A property read after Show would throw "Gui has no window".
d2 := Gui("+AlwaysOnTop +Owner" ownerHwnd, "vk common-selftest dialog 2")
d2.AddButton("Default w120", "OK")
threw := ""
try ThemeShowModal(d2, owner, , , (g) => (g.Show(), g.Destroy()))
catch as e
    threw := e.Message
Check("a dialog destroyed as it appears doesn't throw", threw = "", threw)
Check("...and the owner is still enabled", !(WinGetStyle("ahk_id " ownerHwnd) & WS_DISABLED))
owner.Destroy()

try DirDelete(box, true)
TestEnd()
