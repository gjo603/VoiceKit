# Example automations

Hand-written samples, kept for reference. They are **not** installed as voice
commands: nothing here has a Start Menu entry or a hotkey, and VoiceKit never
loads this folder.

| File | What it shows |
|---|---|
| `MorningTabs.ahk` | A launch macro that opens several sites/apps in one go. |
| `WorkLayout.ahk` | Opening apps and arranging their windows. |
| `CleanScreenshots.ahk` | File housekeeping — **moves every `*.png` off the Desktop** when run. Read it before using it. |
| `MeetingNotes.ahk` | A half-finished scaffold from the launch template (edit before use). |
| `OpenPublicUserFolder.ahk` + `.steps.txt` | A recorded Workflow Studio workflow: the generated stub and its steps file. The recording targets the original author's Explorer layout, so it's a format example, not something to run. |
| `ToggleTimer.ahk` | The placeholder an Always-On Hotkey starts as (it bound Ctrl+Alt+Shift+A on older installs). |

To use one: copy it into `macros\` (a launch macro) or recreate it with
**New Automation**, which also makes the voice shortcut / hotkey wiring.
A copied file's `#Include "%A_ScriptDir%\..\lib\..."` lines only resolve from
`macros\`, not from here. A workflow belongs in `workflows\<Base>.steps.txt`;
open it in Workflow Studio and save it to generate its stub and shortcuts.

Installs made before 2026-09-30 still have their own copies of these files in
`macros\` and `hotkeys\` — those are the user's now and are left alone.
