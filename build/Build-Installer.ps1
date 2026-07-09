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
# Drop tracked-but-dev-only files that shouldn't ship to a tester (Setup.bat is
# excluded because it does a fragile in-place install; the zip uses Install-VoiceKit.cmd).
foreach ($devOnly in 'build', 'CLAUDE.md', 'Setup.bat', '.gitignore', '.gitattributes') {
    $p = Join-Path $stage $devOnly
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}

# bundle the interpreter; add the installer normalized to CRLF (Set-Content default)
Copy-Item -LiteralPath $ahk -Destination (Join-Path $stage 'AutoHotkey64.exe')
Get-Content -LiteralPath (Join-Path $build 'Install-VoiceKit.cmd') |
    Set-Content -LiteralPath (Join-Path $stage 'Install-VoiceKit.cmd')

# fail loudly if the package is missing something the installer depends on
foreach ($must in 'VoiceKit.ahk', 'AutoHotkey64.exe', 'lib\LoopRunner.ahk', 'lib\WorkflowLoop.ahk', 'Install-VoiceKit.cmd') {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $must))) {
        Remove-Item -LiteralPath $stage -Recurse -Force
        throw "Staged package is missing '$must'. Aborting so a broken installer isn't shipped."
    }
}

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
        'FinishMessage=VoiceKit is installed and starting. Turn on Voice Access, then say: open new automation',
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
