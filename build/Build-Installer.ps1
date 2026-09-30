#Requires -Version 5
<#
    Build-Installer.ps1 — regenerate the VoiceKit distribution package.

    Output (into the gitignored dist\ folder):
      dist\VoiceKit-Setup.zip  — a self-contained installer. It bundles a
        portable AutoHotkey64.exe (so the recipient needs NOTHING preinstalled)
        plus every VoiceKit file and Install-VoiceKit.cmd, which copies it to
        %LOCALAPPDATA%\Programs\VoiceKit and launches it via the bundled exe.

    With -Exe it also wraps that zip into:
      dist\VoiceKit-Setup.exe  — a one-double-click self-extractor, built with
        Windows' built-in IExpress. IExpress needs an INTERACTIVE desktop, so run
        -Exe from Explorer/Terminal (it silently no-ops in headless sessions; the
        ZIP is always the reliable artifact).

    Requires AutoHotkey v2 installed locally (to source the bundled interpreter).
    Run it after making changes:  double-click Build-Installer.cmd, or
      powershell -ExecutionPolicy Bypass -File build\Build-Installer.ps1 [-Exe]
#>
[CmdletBinding()]
param([switch]$Exe)

$ErrorActionPreference = 'Stop'
$build = $PSScriptRoot
$root  = Split-Path $build -Parent
$dist  = Join-Path $root 'dist'
$ahk   = Join-Path ${env:ProgramFiles} 'AutoHotkey\v2\AutoHotkey64.exe'

if (-not (Test-Path -LiteralPath $ahk)) {
    throw "AutoHotkey v2 not found at`n  $ahk`nInstall it first:  winget install AutoHotkey.AutoHotkey"
}

# --- stage the payload: git-TRACKED files (+ your uncommitted edits to them) ---
# Staging from git (not the raw working tree) guarantees untracked personal
# automations never leak into a package sent to someone else. Commit NEW files
# (e.g. a new lib script) so they're included; the sanity check below catches
# anything missing before a broken/incomplete package ships.
$stage = Join-Path ${env:TEMP} ('vk_pkg_' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Write-Host 'Staging VoiceKit files (git-tracked)...'
& git -C $root rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { throw "This build stages git-tracked files, but '$root' is not a git repo." }
# A snapshot of tracked files including uncommitted edits (stash create); untracked
# files are excluded. Returns nothing (null) when the tree is clean => use HEAD.
$snap = & git -C $root stash create
if ($snap) { $snap = ([string]$snap).Trim() } else { $snap = 'HEAD' }
$arch = Join-Path ${env:TEMP} ('vk_arch_' + [IO.Path]::GetRandomFileName() + '.zip')
& git -C $root archive --format=zip -o $arch $snap
if ($LASTEXITCODE -ne 0) { throw "git archive failed while staging the payload." }
Expand-Archive -LiteralPath $arch -DestinationPath $stage -Force
Remove-Item -LiteralPath $arch -Force
# Only what the INDEX tracks. `git stash create` snapshots the working tree of
# every path HEAD knows, so a file just untracked with `git rm --cached` (the
# per-user files, the samples moved to templates\examples) still rode along
# until the next commit -- measured on 2026-09-30. The index is the truth.
# core.quotepath=off: by default git prints a non-ASCII path as a quoted octal
# escape ("\303\251..."), which matches no staged file -- so every such file
# was silently dropped from the package. Read git's output as UTF-8 too (the
# console's OEM code page would mangle the same names).
$indexed = @{}
$prevEnc = [Console]::OutputEncoding
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }  # no console: keep going
$tracked = & git -C $root -c core.quotepath=off ls-files
$lsExit = $LASTEXITCODE
try { [Console]::OutputEncoding = $prevEnc } catch { }
if ($lsExit -ne 0) { throw "git ls-files failed while staging the payload." }
foreach ($f in $tracked) { $indexed[($f -replace '/', '\').ToLowerInvariant()] = $true }
$stageFull = (Get-Item -LiteralPath $stage).FullName
Get-ChildItem -LiteralPath $stageFull -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($stageFull.Length + 1).ToLowerInvariant()
    if (-not $indexed.ContainsKey($rel)) { Remove-Item -LiteralPath $_.FullName -Force }
}
# Drop tracked-but-dev-only files that shouldn't ship to a tester (Setup.bat is
# excluded because it does a fragile in-place install; the zip uses Install-VoiceKit.cmd).
foreach ($devOnly in 'build', 'CLAUDE.md', 'Setup.bat', '.gitignore', '.gitattributes', 'docs', 'tests') {
    $p = Join-Path $stage $devOnly
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
# The live per-user files (hotkeys\_index.ahk, bridge-map.txt,
# hotkeys\Snippets.ahk) are gitignored user data, so git archive never stages
# them -- only their committed *.default.* versions ship, and VoiceKit makes
# the live copies on first start (SeedUserFiles). Belt and braces: never ship
# one even if a future change re-tracks it.
foreach ($live in 'hotkeys\_index.ahk', 'bridge-map.txt', 'hotkeys\Snippets.ahk') {
    $p = Join-Path $stage $live
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
# logs\ is per-machine state and gitignored: settings.ini (the DPAPI-wrapped
# OpenRouter key), and the MCP privacy key + token map (logs\privacy.key,
# logs\privacy-tokens.json -- the map names client files). Same belt: never
# ship the folder even if something in it were ever force-tracked.
$stagedLogs = Join-Path $stage 'logs'
if (Test-Path -LiteralPath $stagedLogs) { Remove-Item -LiteralPath $stagedLogs -Recurse -Force }

# --- stamp the version into the staged copy ---
# An installed copy has no .git, so the MCP server (health / server_info /
# serverInfo) reads VERSION: the repo's base version plus the commit and the
# build date, e.g. 1.2.0-dev+500eb6c.20260930 (".dirty" when uncommitted
# edits were staged). Written here, after the index filter, so it ships even
# before VERSION itself is committed.
$verFile = Join-Path $root 'VERSION'
$baseVer = ''
if (Test-Path -LiteralPath $verFile) { $baseVer = ([string](Get-Content -LiteralPath $verFile -TotalCount 1)).Trim() }
if (-not $baseVer) { $baseVer = '0.0.0-unknown' }
$baseVer = ($baseVer -split '\+')[0]
$hash = ([string](& git -C $root rev-parse --short HEAD)).Trim()
if (-not $hash) { $hash = 'nogit' }
if ($snap -ne 'HEAD') { $hash += '.dirty' }
$stampVer = '{0}+{1}.{2}' -f $baseVer, $hash, (Get-Date -Format 'yyyyMMdd')
[IO.File]::WriteAllText((Join-Path $stage 'VERSION'), $stampVer + "`n", (New-Object System.Text.UTF8Encoding $false))
Write-Host "  Version  $stampVer"

# bundle the interpreter; add the installer normalized to CRLF (Set-Content default)
Copy-Item -LiteralPath $ahk -Destination (Join-Path $stage 'AutoHotkey64.exe')
Get-Content -LiteralPath (Join-Path $build 'Install-VoiceKit.cmd') |
    Set-Content -LiteralPath (Join-Path $stage 'Install-VoiceKit.cmd')

# fail loudly if the package is missing something the installer depends on
foreach ($must in 'VoiceKit.ahk', 'VoiceKitLauncher.ahk', 'AutoHotkey64.exe',
                  'lib\_Common.ahk', 'lib\Watchdog.ahk', 'lib\Acc.ahk', 'lib\UIA.ahk',
                  'lib\Clip.ahk', 'lib\ExplorerSel.ahk', 'lib\Workflow.ahk', 'lib\Browser.ahk',
                  'lib\LoopRunner.ahk', 'lib\WorkflowLoop.ahk',
                  'lib\AI.ahk', 'lib\Json.ahk', 'lib\Theme.ahk',
                  'macros\VoiceKitHome.ahk', 'macros\AskAI.ahk', 'macros\NewAutomation.ahk',
                  'macros\WorkflowStudio.ahk', 'macros\RecordMySteps.ahk', 'macros\SplitPages.ahk',
                  'hotkeys\_index.default.ahk', 'bridge-map.default.txt', 'hotkeys\Snippets.default.ahk',
                  'hotkeys\RecordMySteps.hotkey.ahk',
                  'templates\ai-template.ahk', 'Install-VoiceKit.cmd', 'VERSION',
                  'mcp\server.py', 'mcp\voicekit_writer.py', 'mcp\privacy.py') {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $must))) {
        Remove-Item -LiteralPath $stage -Recurse -Force
        throw "Staged package is missing '$must'. Aborting so a broken installer isn't shipped."
    }
}

# --- load-check the staged master, exactly as a fresh install will start it ---
# File presence isn't enough: a build from a tree whose manifest listed modules
# the package doesn't contain shipped a master that never started (the audit's
# "5 dangling #Includes"). Seed the live files from the staged defaults the way
# SeedUserFiles will on first start, /validate VoiceKit.ahk, then remove the
# seeded copies so they never ship. Through a cmd.exe FILE redirect, bounded:
# AutoHotkey is a GUI-subsystem exe (a pipe gives empty output), and a #Warn
# warning pops a dialog even under /validate.
$seeded = @()
foreach ($pair in @(@('hotkeys\_index.ahk', 'hotkeys\_index.default.ahk'),
                    @('bridge-map.txt', 'bridge-map.default.txt'),
                    @('hotkeys\Snippets.ahk', 'hotkeys\Snippets.default.ahk'))) {
    $live = Join-Path $stage $pair[0]
    Copy-Item -LiteralPath (Join-Path $stage $pair[1]) -Destination $live -Force
    $seeded += $live
}
$valOut = Join-Path ${env:TEMP} ('vk_val_' + [IO.Path]::GetRandomFileName() + '.txt')
$master = Join-Path $stage 'VoiceKit.ahk'
$cmdLine = '/c ""' + $ahk + '" /ErrorStdOut=UTF-8 /validate "' + $master + '" > "' + $valOut + '" 2>&1"'
$vp = Start-Process -FilePath (Join-Path ${env:WinDir} 'System32\cmd.exe') -ArgumentList $cmdLine `
      -PassThru -WindowStyle Hidden
$null = $vp.Handle
$valText = ''
$valOk = $false
if (-not $vp.WaitForExit(30000)) {
    & (Join-Path ${env:WinDir} 'System32\taskkill.exe') /T /F /PID $vp.Id 2>&1 | Out-Null
    $valText = 'the load check timed out after 30 s (a #Warn dialog, most likely)'
} else {
    if (Test-Path -LiteralPath $valOut) { $valText = ((Get-Content -LiteralPath $valOut -Encoding UTF8) -join "`n").Trim() }
    $valOk = ($vp.ExitCode -eq 0)
}
Remove-Item -LiteralPath $valOut -ErrorAction SilentlyContinue
foreach ($f in $seeded) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
if (-not $valOk) {
    Remove-Item -LiteralPath $stage -Recurse -Force
    throw "The staged VoiceKit.ahk does not load, so the package would install a master that never starts. Aborting.`n$valText"
}
Write-Host '  Staged VoiceKit.ahk loads.'

# --- zip ---
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist 'VoiceKit-Setup.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Get-ChildItem -LiteralPath $stage).FullName -DestinationPath $zip -CompressionLevel Optimal
Write-Host ('  Built  {0}  ({1:N0} KB)' -f $zip, ((Get-Item -LiteralPath $zip).Length / 1KB))

# --- optional: wrap the zip into a single self-extracting .exe via IExpress ---
if ($Exe) {
    $exeOut = Join-Path $dist 'VoiceKit-Setup.exe'
    if (Test-Path -LiteralPath $exeOut) { Remove-Item -LiteralPath $exeOut -Force }
    $pkg = Join-Path ${env:TEMP} ('vk_exe_' + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $pkg | Out-Null
    Copy-Item -LiteralPath $zip -Destination (Join-Path $pkg 'VoiceKit-Setup.zip')
    Get-Content -LiteralPath (Join-Path $build 'bootstrap.cmd') |
        Set-Content -LiteralPath (Join-Path $pkg 'bootstrap.cmd')
    $sed = @(
        '[Version]', 'Class=IEXPRESS', 'SEDVersion=3',
        '[Options]', 'PackagePurpose=InstallApp', 'ShowInstallProgramWindow=1', 'HideExtractAnimation=0',
        'UseLongFileName=1', 'InsideCompressed=0', 'CAB_FixedSize=0', 'CAB_ResvCodeSigning=0', 'RebootMode=N',
        'InstallPrompt=%InstallPrompt%', 'DisplayLicense=%DisplayLicense%', 'FinishMessage=%FinishMessage%',
        'TargetName=%TargetName%', 'FriendlyName=%FriendlyName%', 'AppLaunched=%AppLaunched%',
        'PostInstallCmd=%PostInstallCmd%', 'AdminQuietInstCmd=%AdminQuietInstCmd%', 'UserQuietInstCmd=%UserQuietInstCmd%',
        'SourceFiles=SourceFiles',
        '[Strings]', 'InstallPrompt=', 'DisplayLicense=',
        'FinishMessage=VoiceKit is installed and starting. Turn on Voice Access, then say: open voice kit',
        "TargetName=$exeOut", 'FriendlyName=VoiceKit Setup', 'AppLaunched=cmd /c bootstrap.cmd',
        'PostInstallCmd=<None>', 'AdminQuietInstCmd=', 'UserQuietInstCmd=',
        'FILE0="bootstrap.cmd"', 'FILE1="VoiceKit-Setup.zip"',
        '[SourceFiles]', "SourceFiles0=$pkg",
        '[SourceFiles0]', '%FILE0%=', '%FILE1%='
    )
    $sedFile = Join-Path $pkg 'voicekit.sed'
    Set-Content -LiteralPath $sedFile -Value $sed -Encoding Ascii
    & (Join-Path ${env:WinDir} 'System32\iexpress.exe') /N /Q $sedFile | Out-Null
    Start-Sleep -Milliseconds 800
    if (Test-Path -LiteralPath $exeOut) {
        Write-Host ('  Built  {0}  ({1:N2} MB)' -f $exeOut, ((Get-Item -LiteralPath $exeOut).Length / 1MB))
    } else {
        Write-Warning 'IExpress did not produce the .exe. It needs an interactive desktop (run from Explorer/Terminal). The ZIP is complete and ready to send on its own.'
    }
    Remove-Item -LiteralPath $pkg -Recurse -Force
}

Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host ''
Write-Host 'Send the file(s) above. See build\README.md for how the recipient installs.'
exit 0   # don't leak robocopy's "files copied" exit code as a failure
