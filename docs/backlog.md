# VoiceKit backlog

Running list of known gaps and requested capabilities — **open items only**.
Shipped work moves to `docs\CHANGELOG.md`. Newest session at the top.
Each item: what went wrong, why it matters, and the proposed fix. File pointers are
starting points taken from CLAUDE.md — verify against current code before building.

---

## Open

### 2026-09-29 — document-extraction feedback (an agent built a PDF data extractor via the MCP)

The session ran on a second PC's **installed** copy, so everything here
reaches it only through a rebuilt installer (`build\Build-Installer.ps1`).
The sequenced plan — what each item touches, its tests and lockstep cost — is
**`docs\roadmap-extraction.md`** (WP1–WP10, copied from the 2026-09-29 audit).
Priority order is the user's; WP numbers point into the roadmap.

1. ~~**Namespace explainer (WP1).**~~ **SHIPPED 2026-09-30** — load errors
   name the owner of a clashing name, the server instructions list the taken
   names (see `docs\CHANGELOG.md`).
2. ~~**Selected files — HIGH (WP2, WP3).**~~ **BUILT 2026-09-30** —
   `{{selected_file}}` / `{{selected_files}}` from the active Explorer tab
   (`lib\ExplorerSel.ahk`, tab-correct); 0 or several files with the
   singular form refuses to start (see `docs\CHANGELOG.md`).
3. ~~**Run-and-capture step — HIGH (WP4).**~~ **BUILT 2026-09-30** —
   `capture|<name>|<command>|<seconds>` runs a command hidden and keeps its
   stdout as a run-local value; failures record only the exit code; the
   selection names arrive quoted in commands; Draft With AI refuses it (see
   `docs\CHANGELOG.md`).
4. ~~**Batch from any CSV or Excel range — MEDIUM (WP7).**~~ **BUILT
   2026-09-30** — `run_workflow_batch(source=...)` from any CSV/xlsx range
   with column mapping, row skipping by source row, a `dry_run` preview and
   `next_cell_range` for resuming; `openpyxl` added to `mcp\requirements.txt`
   (lazy) — an existing `mcp\.venv` needs `pip install openpyxl` once, and
   a second PC's installed copy gets it only through a rebuilt installer
   plus that pip step (see `docs\CHANGELOG.md`). Still open from it: rows
   hidden by an Excel filter are not detected, and
   `run_workflow_batch(files=[...])` (one pass per file as
   `{{selected_file}}`) needs a per-pass selection in the engine.
5. ~~**Fill-by-label step — MEDIUM (WP8).**~~ **BUILT 2026-09-30** —
   `fill|<window>|<label>[#N]|<value>`: find, click, focus gate, type, read
   back; `#N` for duplicate labels; fill-value `{{names}}` are workflow
   inputs so a batch reaches them (see `docs\CHANGELOG.md`). Still open:
   dump a real web form app's input screen (`dump_uia_tree`) and tune — whether
   its labels are the inputs' accessible names, how many repeat, and whether
   its boxes reformat in a way `WfFillMatches` doesn't cover.
6. ~~**`run_automation` args / dry-run — MEDIUM (WP5).**~~ **BUILT
   2026-09-30** — `args` (argv list; a workflow's args are its selection),
   voice-launch working directory, documented `/dry` convention, no generic
   flag. Phase 2 (`run_workflow_batch(files=...)`) not built — the
   selection is one snapshot per run (a whole loop shares it) and batch rows
   only seed ask labels; meanwhile a workflow can take a path as an ask
   label and batch over a CSV of paths.
7. ~~**PII masking — MEDIUM (WP9).**~~ **BUILT 2026-09-30** (both phases) —
   always-on `%USERPROFILE%` / `%TEMP%` normalization, then `mcp\privacy.py`:
   `[Privacy] Mode=paths` by default (every name under the profile → a stable
   `<dir#..>` / `<file#..>.ext` token, VoiceKit's own names readable),
   `strict` (+ one-way SSN/EIN tokens), `off`; `MaskRoots`; tokens expand back
   on input; `reveal` + `run_ahk_snippet(unmask=True)`, both audited. See
   `docs\CHANGELOG.md`. Still open, deliberately not built: a term list for
   client names that never appear inside a path (window titles, form text —
   the design's `privacy-terms.txt` idea), and a Home / AI Settings toggle
   for the mode (the user edits `logs\settings.ini`).
8. ~~**Small MCP polish (WP10).**~~ **SHIPPED 2026-09-30** — one reload-note
   wording, build-stamped `VERSION`, `server_stale`, `server_info()`.

### 2026-08-01 — session notes (MCP field use, reported by another agent)

Five issues from an agent driving VoiceKit through the MCP add-on. Items 1, 2 and
5 turned out to be one problem — a run left no evidence — and shipped together
(see `docs\CHANGELOG.md`). Item B (Chrome web content invisible to element steps) has since
shipped too, as an Acc→UIA fallback rather than the diagnostic proposed there.
Item A below is real but needs a design decision, so it stays logged rather than
guessed at.

#### A. `run <url>` and window steps can disagree about the browser — MEDIUM

**What happened.** `run|<url>` is a plain `Run()`, so the URL opens in the system
default browser (Edge on the reporter's machine). But `ClassifyWindow` records
whatever was actually on screen when recording, e.g. `ahk_exe chrome.exe`. A
workflow can therefore open the page in one browser and then wait forever for the
other — and with `waitfor` it now fails cleanly instead of hanging, which makes the
mismatch visible but doesn't fix it.

**Why it matters.** It's silent at authoring time and looks like a flaky workflow
at run time. Nothing in the Studio or the docs warns that the two halves are
resolved by different mechanisms.

**Options, roughly in order of cost.**
- Cheapest and safest: an **authoring-time warning** — if a workflow has a `run`
  step with an `http(s)` URL and any window criterion naming a *different*
  browser exe, say so on Save/Test (the same shape as the existing
  `WfUndefinedVars` warning, which warns and never blocks).
- Middle: give the `run` step an optional browser choice, so a URL can be opened
  with the exe the rest of the workflow targets.
- Most invasive: have the engine resolve a URL against the workflow's own window
  steps automatically. Rejected on first look — it makes `run` non-obvious, and
  guessing wrong is worse than the current honest mismatch.

**Where this lives.** `lib\Workflow.ahk` (`WfRunStep`'s `run` case),
`macros\WorkflowStudio.ahk` (`ClassifyWindow`, `BlockBalanceError` /
`UndefinedVarsOk` as the warning precedent), `mcp\voicekit_writer.py`
(`create_workflow` guards) if the warning becomes a shared rule.

*(Item B — "element steps against Chrome web content can silently never work" —
has SHIPPED, and not as the diagnostic proposed here. See `docs\CHANGELOG.md`, 2026-08-01.)*
