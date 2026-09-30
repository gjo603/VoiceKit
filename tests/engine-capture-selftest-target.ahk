#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
; ============================================================
;  The program engine-capture-selftest's `capture` steps run.
;  A command-line child, not a window: it writes to stdout and
;  stderr (FileAppend to "*" / "**" -- through the cmd redirect,
;  which is what gives a GUI-subsystem exe a real stdout) and
;  exits with a chosen code. ASCII only; non-ASCII is built
;  with Chr().
;
;      <this> echo <text>         text on stdout
;      <this> args <a> <b> ...    "<count>|a|b|..." on stdout
;      <this> cwd                 the working directory it was started in
;      <this> mixed               "VALUE" on stdout, noise on stderr
;      <this> unicode             accented text + an em-dash, UTF-8
;      <this> trail               "  lead" then blank lines/spaces
;      <this> empty               nothing at all, exit 0
;      <this> big                 just over 1 MB
;      <this> fail <code>         15 numbered stderr lines, exit <code>
;      <this> mark <file>         create <file> (proves it ran)
;      <this> sleep <pidfile>     write its PID, then wait forever
; ============================================================
mode := A_Args.Length ? A_Args[1] : ""
Out(t) => FileAppend(t, "*", "UTF-8")
Err(t) => FileAppend(t, "**", "UTF-8")

switch mode {
    case "echo":
        Out(A_Args.Length >= 2 ? A_Args[2] : "")
    case "args":
        s := A_Args.Length - 1
        loop A_Args.Length - 1
            s .= "|" A_Args[A_Index + 1]
        Out(s)
    case "cwd":
        Out(A_InitialWorkingDir)    ; A_WorkingDir is reset to the script's own folder
    case "mixed":
        Err("warning: something noisy`n")
        Out("VALUE`n")
        Err("more noise`n")
    case "unicode":
        Out("caf" Chr(0xE9) " " Chr(0x2014) " na" Chr(0xEF) "ve`r`n")
    case "trail":
        Out("  lead`r`n`r`n   `r`n")
    case "empty":
    case "big":
        chunk := ""
        loop 1024
            chunk .= "x"
        s := ""
        loop 1025
            s .= chunk
        Out(s)
    case "fail":
        loop 15
            Err("err line " A_Index "`n")
        ExitApp(A_Args.Length >= 2 ? Integer(A_Args[2]) : 1)
    case "mark":
        FileAppend("ran", A_Args[2], "UTF-8")
    case "sleep":
        FileAppend(DllCall("GetCurrentProcessId", "uint"), A_Args[2], "UTF-8")
        Sleep(120000)               ; never outlive the test run
}
ExitApp(0)
