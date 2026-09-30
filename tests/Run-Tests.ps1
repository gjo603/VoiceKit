# ============================================================
#  VoiceKit test suite runner.  Run:  powershell -File tests\Run-Tests.ps1
#
#  Load-checks the core scripts (tracked macros, the master, launcher,
#  loop runner, watchdog, UIA probe, complete templates), runs every AHK
#  self-test in this folder (*-selftest.ahk, skipping *-target.ahk helpers
#  and the shared _harness.ahk / _target.ahk includes) plus the Python MCP
#  conformance test, and exits nonzero if anything failed.
#
#  Contract with the AHK self-tests (no framework, on purpose):
#   - each <name>-selftest.ahk writes PASS/FAIL lines to <name>.result
#     beside itself, ending with "ALL PASSED" or "N FAILURE(S)"
#   - the RESULT FILE is the verdict, never the process exit code: a bad
#     vtable offset can HANG rather than crash, and a blocked MsgBox never
#     exits at all -- both must show up as failures, not as a wedged runner.
#
#  ASCII only in this file: PowerShell 5.1 reads a BOM-less UTF-8 script as
#  ANSI, so an em-dash inside a string mojibakes and can break parsing.
#
#  Safe to run while VoiceKit is up: tests drive their own throwaway
#  windows (and their own target processes), never the resident master.
# ============================================================
$ErrorActionPreference = 'Stop'
$tests = Split-Path -Parent $MyInvocation.MyCommand.Path
$root  = Split-Path -Parent $tests
$ahk   = Join-Path ${env:ProgramFiles} 'AutoHotkey\v2\AutoHotkey64.exe'
if (-not (Test-Path -LiteralPath $ahk)) { throw "AutoHotkey v2 not found at $ahk" }

$failedSuites = @()

# Scratch files the tests write beside themselves. Deleted by EXACT extension
# match on an explicit list -- an earlier version used
#   Get-ChildItem -LiteralPath $tests -Include '*.result','*.state','*.stop' -Recurse
# and PS 5.1 quietly ignored -Include in that shape, returned EVERY file, and
# the cleanup deleted the whole test suite. Never reintroduce -Include here.
function Remove-TestScratch {
    Get-ChildItem -LiteralPath $tests -File |
        Where-Object { $_.Extension -eq '.result' -or $_.Extension -eq '.state' -or $_.Extension -eq '.stop' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
}

# /validate one script, BOUNDED. Returns $null when it loads, else the
# reason. Start-Process + a file redirect, never a pipe: AutoHotkey is a
# GUI-subsystem exe and /ErrorStdOut needs a real stdout handle. Bounded
# because /validate is not always dialog-free -- a #Warn warning still pops
# a MsgBox during a load check, which would wedge the runner forever. On
# timeout the whole tree is killed. ($p.Handle is touched right away: PS 5.1
# loses ExitCode for a -PassThru process whose handle was never opened.)
function Test-AhkLoads([string]$file, [int]$timeoutS = 30) {
    $val = Join-Path ${env:TEMP} ("vk-test-validate-" + [guid]::NewGuid().ToString('N') + ".txt")
    try {
        $p = Start-Process $ahk -ArgumentList '/ErrorStdOut','/validate',"`"$file`"" `
             -PassThru -NoNewWindow -RedirectStandardOutput $val
        $null = $p.Handle
        if (-not $p.WaitForExit($timeoutS * 1000)) {
            & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $p.Id 2>&1 | Out-Null
            return "load check timed out after $timeoutS s (a #Warn dialog, most likely)"
        }
        if ($p.ExitCode -eq 0) { return $null }
        $txt = ''
        if (Test-Path -LiteralPath $val) { $txt = (Get-Content -LiteralPath $val -Encoding UTF8) -join "`n" }
        if ($txt -eq '') { $txt = "exit code $($p.ExitCode)" }
        return $txt
    } finally {
        Remove-Item -LiteralPath $val -ErrorAction SilentlyContinue
    }
}

function Invoke-AhkSelfTest([string]$script) {
    $name   = [IO.Path]::GetFileNameWithoutExtension($script)
    $result = Join-Path $tests "$name.result"

    # Load-check first: a test that doesn't parse would otherwise read as a
    # silent timeout.
    $why = Test-AhkLoads $script
    if ($null -ne $why) {
        Write-Host "FAIL  $name  (does not load)" -ForegroundColor Red
        $why -split "`n" | ForEach-Object { "      $_" } | Write-Host
        return $false
    }

    Remove-Item -LiteralPath $result -ErrorAction SilentlyContinue
    $proc = Start-Process $ahk -ArgumentList "`"$script`"" -PassThru
    $deadline = (Get-Date).AddSeconds(120)
    $verdict = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $result) {
            # Poll WITHOUT denying the test write access. Get-Content holds the
            # file denying writers for the duration of the read, and the tests
            # append a line per check with a plain FileAppend -- a collision
            # makes that FileAppend THROW, which pops an AHK error dialog and
            # turns into a phantom 120 s timeout blamed on an innocent test.
            # Measured: 11.7k of 20k appends failed against a Get-Content poll
            # loop. FileShare.ReadWrite is the whole fix.
            $c = ''
            try {
                $fs = [IO.File]::Open($result, [IO.FileMode]::Open,
                    [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                    $c = $sr.ReadToEnd()
                } finally { $fs.Close() }
            } catch { $c = '' }
            if ($c -match 'ALL PASSED|FAILURE\(S\)') { $verdict = $c; break }
        }
    }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    # A test may have spawned a *-target helper; never leave one behind.
    Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" |
        Where-Object { $_.CommandLine -like "*-target.ahk*" -and $_.CommandLine -like "*$tests*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    if ($null -eq $verdict) {
        Write-Host "FAIL  $name  (TIMED OUT - hang, crash, or a blocking dialog; partial log below)" -ForegroundColor Red
        if (Test-Path -LiteralPath $result) { Get-Content -LiteralPath $result | ForEach-Object { "      $_" } | Write-Host }
        return $false
    }
    $pass = ([regex]::Matches($verdict, 'PASS ')).Count
    $fail = ([regex]::Matches($verdict, 'FAIL ')).Count
    if ($verdict -match 'ALL PASSED' -and $fail -eq 0) {
        Write-Host ("ok    {0}  ({1} checks)" -f $name, $pass)
        return $true
    }
    Write-Host ("FAIL  {0}  ({1} pass, {2} fail)" -f $name, $pass, $fail) -ForegroundColor Red
    ($verdict -split "`n") | Where-Object { $_ -match 'FAIL ' } | ForEach-Object { "      $_" } | Write-Host
    return $false
}

# ---- Load checks: every shipped entry point still parses ------------------
# Every macro and body #Includes lib\_Common.ahk, so a new function there
# reserves its name in all of them -- and nothing else would notice a clash
# until someone spoke the phrase. Only TRACKED macros (git ls-files): an
# untracked macro is the user's own and never a test input. VoiceKit.ahk is
# checked in a temp copy whose hotkeys\_index.ahk is empty, so the verdict is
# about the master's own code, not whichever user modules happen to be wired.
Write-Host "=== Load checks (core scripts) ==="
$loadTargets = @()
$tracked = @()
$gitOk = $false
try {
    $tracked = @(& git -C $root ls-files -- 'macros/*.ahk')
    $gitOk = ($LASTEXITCODE -eq 0)
} catch { $gitOk = $false }
if (-not $gitOk -or $tracked.Count -eq 0) {
    Write-Host "      (git unavailable: tracked macros\*.ahk not checked)" -ForegroundColor Yellow
    $tracked = @()
}
foreach ($rel in $tracked) { $loadTargets += Join-Path $root ($rel -replace '/', '\') }
foreach ($rel in @('VoiceKitLauncher.ahk', 'lib\LoopRunner.ahk', 'lib\Watchdog.ahk',
                   'mcp\uia_probe.ahk', 'templates\ai-template.ahk', 'templates\launch-template.ahk')) {
    $loadTargets += Join-Path $root $rel
}
$masterCopy = Join-Path ${env:TEMP} ('vk-test-master-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $masterCopy 'lib'), (Join-Path $masterCopy 'hotkeys') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'VoiceKit.ahk') -Destination $masterCopy
Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.ahk' |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $masterCopy 'lib') }
[IO.File]::WriteAllText((Join-Path $masterCopy 'hotkeys\_index.ahk'), "#Requires AutoHotkey v2.0`n")
$loadTargets += Join-Path $masterCopy 'VoiceKit.ahk'

$loadFails = 0
foreach ($f in $loadTargets) {
    $shown = if ($f.StartsWith($masterCopy)) { 'VoiceKit.ahk (empty module index)' } else { $f.Substring($root.Length + 1) }
    if (-not (Test-Path -LiteralPath $f)) { continue }       # tracked but deleted locally
    $why = Test-AhkLoads $f
    if ($null -eq $why) { continue }
    $loadFails++
    Write-Host "FAIL  $shown  (does not load)" -ForegroundColor Red
    $why -split "`n" | ForEach-Object { "      $_" } | Write-Host
}
Remove-Item -LiteralPath $masterCopy -Recurse -Force -ErrorAction SilentlyContinue
if ($loadFails) { $failedSuites += 'load checks' }
else { Write-Host ("ok    {0} scripts load" -f @($loadTargets).Count) }

Write-Host "=== AHK self-tests ==="
Get-ChildItem -LiteralPath $tests -Filter '*-selftest.ahk' |
    Where-Object { $_.Name -notlike '*-target.ahk' } |
    Sort-Object Name | ForEach-Object {
        if (-not (Invoke-AhkSelfTest $_.FullName)) { $script:failedSuites += $_.Name }
    }

Write-Host "=== MCP conformance (Python) ==="
# The MCP's own venv when it exists: it has fastmcp, so the wire-level tests
# (cancellation, schema parity) run instead of skipping themselves.
$py = Join-Path $root 'mcp\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $py)) { $py = 'python' }
Push-Location (Join-Path $root 'mcp')
try {
    & $py test_conformance.py
    if ($LASTEXITCODE -ne 0) { $failedSuites += 'test_conformance.py' }
} finally { Pop-Location }

Remove-TestScratch

Write-Host ""
if ($failedSuites.Count) {
    Write-Host ("SUITE FAILED: " + ($failedSuites -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host "SUITE PASSED"
exit 0
