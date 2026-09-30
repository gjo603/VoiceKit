# build\ — package VoiceKit for someone else

This folder regenerates the installer you send to another person. The build
outputs land in the gitignored `dist\` folder (never committed); everything
*here* is committed so the build is reproducible.

## Build it

Make your changes in the repo, then:

- **Double-click `Build-Installer.cmd`** → produces **`dist\VoiceKit-Setup.zip`**.
- Or, for a single double-clickable file, **double-click `Build-Exe.cmd`** →
  also produces **`dist\VoiceKit-Setup.exe`** (needs an interactive desktop;
  if IExpress can't run, the ZIP is complete on its own).

Command line equivalent:

```powershell
powershell -ExecutionPolicy Bypass -File build\Build-Installer.ps1 [-Exe]
```

Requires **AutoHotkey v2** installed locally — the build bundles its
`AutoHotkey64.exe` so the recipient needs nothing preinstalled.

## What the recipient does

**ZIP:** send `VoiceKit-Setup.zip` → they right-click → *Extract All* →
double-click `Install-VoiceKit.cmd`.

**EXE:** send `VoiceKit-Setup.exe` → they double-click it. Because it's
unsigned, Windows SmartScreen shows a one-time *More info → Run anyway*.

Either way it installs to `%LOCALAPPDATA%\Programs\VoiceKit`, runs from the
bundled interpreter, and starts VoiceKit (a welcome screen walks them through
Voice Access and auto-start). Then they say *open voice kit*.

## Files

| File | Role |
|---|---|
| `Build-Installer.ps1` | the build script (stage → bundle AHK → zip → optional exe) |
| `Build-Installer.cmd` / `Build-Exe.cmd` | double-click wrappers |
| `Install-VoiceKit.cmd` | the installer that ships **inside** the zip |
| `bootstrap.cmd` | the `.exe`'s post-extract step; delegates to `Install-VoiceKit.cmd` |

The build packages **git-tracked files plus your uncommitted edits to them**, then
drops dev-only files (`build\`, `CLAUDE.md`, `docs\`, `tests\`, `.gitignore`,
`.gitattributes`) and the legacy `Setup.bat` (it does a fragile in-place install;
the package uses `Install-VoiceKit.cmd`). The per-user files (`bridge-map.txt`,
`hotkeys\_index.ahk`, `hotkeys\Snippets.ahk`) are gitignored and never ship —
only their committed `*.default` versions do, and VoiceKit makes the live copies on
first start (and adds newly shipped hotkeys to them on an upgrade). Before zipping,
the build seeds a throwaway copy of those files in the stage and load-checks the
staged `VoiceKit.ahk`; a master that wouldn't start aborts the build. Staging from git means **untracked personal automations
never leak into a package you send** — so **commit new files** (e.g. a new `lib`
script) before building, or the sanity check will stop the build. `dist\`,
`logs\`, the MCP `.venv` and `__pycache__` are gitignored and never included.
