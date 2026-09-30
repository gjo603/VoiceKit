# Extraction roadmap (from the 2026-09-29 audit)

Copied from the audit report (a temporary file) so the plan survives it. The
open items in `docs\backlog.md` point here by WP number. Line numbers and
"Fix-now item N" references are as of 2026-09-29; cleanup batches A–E
(2026-09-30) have since fixed the Fix-now list and WP0 in full, so read those
references as history and verify pointers against the current code.

Decisions already taken by the user (2026-09-29/30), overriding the defaults
listed at the bottom where they differ:
- **No VK_ prefix rename** — namespace clashes get explained and listed (WP1).
- **PII masking on by default** for MCP tool results, with per-call opt-out (WP9).
- Per-user files split into committed `*.default` + gitignored live files
  (done in batch E); samples moved to `templates\examples\` (done);
  decisions 11, 16 and 17 below, plus Fix-now item 7, applied as recommended
  (batches B–D1).

## Roadmap (ordered)

The order follows your priority (#1 namespace, then #2 selected files and capture), with two exceptions the code argues for. WP0 is a short safety pass, because any release today would ship a master that doesn't start. WP2 comes before WP3, because a `{{selected_files}}` built on today's Explorer code would pick up a file selected in a background Explorer tab, which could be the wrong client's file.

**WP0: Stabilize and land** (small, about a day)
- **What:** Fix-now items 1–5, 19 and 20 (the ComSpec fallback). Stage the three per-user files from `HEAD` in the build. Commit the pending work, push, and open a PR to master.
- **Files:** `_Common.ahk`, `Watchdog.ahk`, `LoopRunner.ahk`, `voicekit_writer.py`, `Build-Installer.ps1`, `.gitignore`.
- **Tests:** a preflight-selftest "cannot be opened" fixture, a watchdog "time gap ⇒ hold" case, a conformance check that deleting `Snippets` is refused, and a CamelCase delete in the sandbox.
- **Lockstep:** the preflight rule is mirrored in Python.

**WP1: Namespace, feedback #1** (small) — **DONE 2026-09-30** (items 16/17 were already done by the cleanup)
- **What:**
  - Add `_explain_ahk_error()`. Apply it at the user-facing raise sites (`820, 850, 1077, 1206, 1292, 1523, 1556`) and the snippet error path, not inside `validate_ahk`, because `master_preflight` truncates that text to 400 characters. It appends a line such as "'Log' is an AutoHotkey built-in / defined in lib\_Common.ahk line N; rename it or put the code in a function." Build the name index from definitions only (`^Name(...) {`), so top-level calls like `OnError(...)` aren't counted.
  - Pass an `instructions=` block to `FastMCP(...)` (server.py:74) listing the names that are taken (Log, Out, Notify, EnsureDir, JoinList, RunAhk, and the `Uia*`/`Browser*`/`Body*`/`Hotkey*`/`Bridge*`/`Master*` prefixes) and the v2 quote rule (`` `" ``, not `""`).
  - Add a clause to `create_launch_macro`/`update_macro` saying `_Common.ahk` is pre-included, and fix the docstrings listed above.
  - Validate the body in `create_hotkey_module` (item 17), and detect parked in-process modules (item 16).
  - Strip `USERPROFILE` and the temp directory from snippet errors and output.
- **Files:** `voicekit_writer.py`, `server.py`, `test_conformance.py`, CLAUDE.md.
- **Tests:** `test_load_error_explains_name_clash`, covering a built-in `LOG`, `Notify` from `_Common`, `Out` from the prelude, a function-local variable that still loads, and a `""` quote. A test that the names in the instructions exist in the libraries. Snippet errors contain no `USERPROFILE`.
- **Lockstep:** none.

**WP2: Tab-correct Explorer selection** (small to medium; raw vtable call) — **BUILT 2026-09-30** (tabs verified live by `tests\explorer-selftest.ahk`)
- **What:** a new `lib\ExplorerSel.ahk` with `ExplorerSelectedFiles(hwnd := 0)`. It finds the active tab via `ShellTabWindowClass1` compared with `IServiceProvider` → `IShellBrowser::GetWindow` (slot 3), keeps file-system items only, and returns `[]` rather than throwing. It replaces the two existing copies; the Studio's `ExplorerSelection` becomes a one-line delegate. Included from `Workflow.ahk` via `%A_LineFile%`, and optionally from the snippet prelude.
- **Tests:** `/validate` checks, the failure paths returning `[]`, and a manual checklist (two tabs each with a selection, multi-select, an item inside a zip, no tabs). The tabs can't be tested automatically without driving your own Explorer windows.
- **Lockstep:** none. Add the file to the build's must-ship list.

**WP3: `{{selected_file}}` / `{{selected_files}}`** (small; depends on WP2) — **BUILT 2026-09-30**
- **What:** add the names to `WfBuiltinVar` as fallbacks, read from a `wfSelection` snapshot taken once at run start, before the ask dialogs. The singular form is an error unless exactly one item is selected. The plural form is every path in double quotes, space-joined. On a pre-run error, record outcome `error` and write nothing. Loops snapshot once, and Studio Test resets the snapshot.
- **Files:** `Workflow.ahk`, `WorkflowLoop.ahk`, the Studio hint, `DraftSystemPrompt`, `server.py` and writer docs, README.
- **Tests:** add to `engine-vars-selftest` using a seeded `wfSelection` (no Explorer involved).
- **Lockstep:** only the docs that list the built-ins.

**WP4: `capture|<name>|<command>|<seconds>` step** (medium) — **BUILT 2026-09-30** (default timeout 30 s; the stderr tail goes to the local popup only; the selection names arrive quoted in command lines; the command runs in a nested cmd fed through an env var so `chcp 65001` takes effect; Draft With AI refuses the step and the paramC catch-all became an explicit `paramCless` list)
- **What:**
  - Runs the command through `cmd /c` with stdout and stderr redirected to separate uniquely named temp files, deleted in `finally`. Sets `chcp 65001` and `PYTHONIOENCODING=utf-8`.
  - The working directory is pinned to the repo root.
  - A timer kills the process tree (`taskkill /T`) on timeout or abort.
  - Output is decoded as UTF-8, falling back to CP0, and capped at 1 MB.
  - The value is run-local, like `set`.
  - Failure reasons never contain the resolved command.
  - With WP3, Extract Invoice becomes about five steps.
- **Files:** all five lockstep places, plus a new `tests\engine-capture-selftest.ahk` with a target helper.
- **Tests:** plain, UTF-8 and stderr-separation cases; exit code; tree kill on timeout (the child process is gone afterwards); abort ends as `stopped`; the working directory is correct; conformance round trip and guards.
- **Lockstep: all five places change.**
  - `NewAutomation.ahk`'s catch-all at `:589-590` blanks paramC for other step types. `capture` needs its own branch there or AI drafts lose the timeout.
  - Document that workflows can now run commands, so share them like scripts.

**WP5: `run_automation(args=[...])` and matching working directory, feedback #5** (small) — **BUILT 2026-09-30** (argv-as-selection is tested with `run` steps, and since WP4 with an args → capture → later-step round trip)
- **What:**
  - Python passes arguments as an argv list. `cwd` is set to `macros\` for macros and `REPO_ROOT` for loops, the same as a voice launch.
  - Arguments are refused for the Studio and for loop phrases. For a workflow target, every argument must be an existing file or folder.
  - `RunWorkflow` (the stub entry point only) uses `A_Args` as `wfSelection`, so a test file stands in for the Explorer selection. The stub text doesn't change.
  - Document the raw-script convention `files := A_Args.Length ? A_Args : ExplorerSelectedFiles()`, plus an optional `/dry` switch that each script implements itself. There is no generic `dry_run` flag.
- **Tests:** a conformance test that arguments and cwd arrive intact, including a path with spaces and `&`; the refusals; a set/capture-only workflow run on a fixture file.
- **Lockstep:** none. Also fix SplitPages' claim that a `nopreview` test exists.

**WP6: Read side for browsers** (small) — **BUILT 2026-09-30** (`WfFieldValue` for `collect`, trimmed needles, browser-class pacing in `WfFindElement`/`WfFieldValue` — ~580 ms → ~45 ms against a pretend Chrome window; `UiaValueOnly(&has)`, the `UiaTextPresent` scan fix and `WfElementPresent`'s one-look-per-round had already landed. Case-insensitive `CreatePropertyConditionEx` NOT built — still untested in `uia-selftest`. `WfTextVisible` still gives MSAA its 350 ms turn in a browser — a candidate for the same pacing)
- **What:**
  - Give `collect` from a named box the same interleaved Acc→UIA lookup: short Acc passes, then `UiaFindEdit`, then `UiaValueOnly`. Found-but-empty stays legitimate.
  - `UiaValueOnly(&has)` (shared with item 12).
  - The `UiaTextPresent` scan-budget fix (item 13).
  - Name matching: trim the needle (free). Consider case-insensitive matching via `CreatePropertyConditionEx` (slot 24) only once it is tested in `uia-selftest`.
  - One pass per tree per round in `WfFindElement` and `WfElementPresent`, to remove the ~0.5 s MSAA delay.
- **Tests:** `engine-hybrid-selftest` against its separate target process (a UIA-only box, a label that shares the box's name, a miss that stays inside its budget), and `uia-selftest` for `&has`.
- **Lockstep:** none (no format change).

**WP7: Batch from any CSV or Excel range, feedback #3** (medium, Python only) — **BUILT 2026-09-30** (see `docs\architecture\mcp.md`, "Batch from any CSV or Excel range"; `files=[...]` shorthand not built — needs a per-pass selection in the engine)
- **What:** `run_workflow_batch(source=, sheet=, cell_range=, header=, columns={label: header|"col:C"}, require=[], skip_if_filled=[], dry_run=False)`.
  - Python does all row skipping, so pass N always matches source row N.
  - A CSV is read as utf-8-sig, falling back to cp1252, with a `;` delimiter rule.
  - xlsx is read with a lazily imported openpyxl (`data_only=True`). A cell holding an Excel error (`#N/A` and the like) is refused, with its row number.
  - The response returns `source_rows`, `skipped`, `source_modified`, the resolved columns, and `next_cell_range` for resuming. It never echoes cell values except in the `dry_run` preview.
  - Passing the workflow's own sheet goes straight through, so write-back still works.
  - Includes item 9: refuse to launch while a loop runs, plus the per-pass journal.
- **Files:** `voicekit_writer.py`, `server.py`, `requirements.txt`, `test_conformance.py`, optional `mcp\_conformance\batchrows.ahk`.
- **Tests:** the 10 cases in the design, including a round trip through the real `WfLoopCsvRows`.
- **Lockstep:** none. `mcp-batch.csv` keeps its exact dialect.

**WP8: `fill|<window>|<label>|<value>` step, feedback #4** (large) — **BUILT 2026-09-30** (generic `#N` occurrence suffix and `##` for a literal `#`, decided without a real form dump — tune from one; UIA input kinds Edit/ComboBox/Spinner, MSAA fallback via `AccInputNodes`; `UiaIsPassword` slot 35 and `UiaSameElement` verified in `uia-selftest`; a `{{Name}}` in a fill value that nothing defines is a workflow INPUT, so batches reach fills; the SetValue no-rect rescue is untested)
- **What:**
  - `WfFill`: find the input by label (Edit type preferred, 3 s budget, abort-aware), check it is enabled, click it for real (a ValuePattern set only as a rescue when there is no rectangle), then a **focus gate** before any keystroke.
  - Then `^a`, `SendText`, no `{Esc}`. Values containing a newline are refused.
  - Read the value back through ValuePattern, or the clipboard if there's no pattern. Password boxes are skipped via `UiaIsPassword` (vtable slot 35, which is not yet verified).
  - `WfFillMatches` tolerates added separators and numeric formatting and never accepts a different digit sequence. Failure reasons never contain the value.
  - It is the first step whose paramC is substituted.
  - The Studio's Pick button gets a UIA name fallback, which also fixes picking and recording on Chrome.
- **Files:** `Workflow.ahk`, `UIA.ahk`, Studio, NewAutomation, writer, server, conformance, new `engine-fill-selftest` with a target helper, `uia-selftest`, `engine-vars-selftest`.
- **Lockstep: all five places change**, plus the NewAutomation paramC catch-all and CLAUDE.md's "paramC is never substituted" sentence.
- **Prerequisite:** run `dump_uia_tree` on a real web form screen before choosing how to handle duplicate labels.

**WP9: Privacy** (small part in WP1; the rest medium) — **phase 1 (path normalization) DONE 2026-09-30; phase 2 (`mcp\privacy.py` masking) BUILT 2026-09-30** — with the user's later decisions overriding two lines below: every name under the profile is masked (not only named client folders), and tokens passed back as input are EXPANDED locally rather than refused (they are refused only in saved code/steps), with an audited `reveal` tool and `run_ahk_snippet(unmask=True)` as the per-call opt-out. Details: `docs\architecture\mcp.md` "Privacy masking".
- **What:** always-on replacement of profile and temp prefixes in every response, handled once in `_guard`. Then `mcp/privacy.py` with `[Privacy] Mode=off|paths|strict` and `MaskRoots`:
  - stable HMAC tokens that keep the file extension, with the token map stored locally;
  - SSN and EIN patterns in strict mode;
  - exemptions for authored source reads;
  - a guard that refuses a token passed back as input;
  - no way to lower the mode from a tool call.
  Be explicit in the docs that this stops incidental leakage, not deliberate `Out()` of document text.
- **Lockstep:** none.

**WP10: MCP polish, the small feedback items** (small) — **DONE 2026-09-30**
- **What:**
  - Unify the reload notes (`_reload_note`). Tools that never reload get the note "Live now… nothing needs reloading".
  - Report a version from a build-stamped `VERSION` file through `FastMCP(version=)`.
  - Add a `server_stale` flag to `health()` when `server.py` or `voicekit_writer.py` changed after the server started, with a "reconnect /mcp" note.
  - Add a `server_info()` tool listing live server processes. A user may have two registrations (e.g. `~/.claude.json` and the Desktop config). That is the likely cause of "two sets of tool names".
  - Add the README tool table and its coverage test.
- **Lockstep:** none.

---

---

## Decisions (recommended default in bold)

1. **`{{selected_file}}` with several files selected:** **make it an error**, rather than acting on the first file.
2. **Capture failures:** **the run record says "exited with code N" only; the stderr tail appears in the local popup only** (a traceback can contain client paths).
3. **Draft With AI emitting `capture` steps:** **not at first.** Add it later, with a no-destructive-commands rule in the prompt.
4. **Read-only `preview_workflow`:** **skip it for now.** Testing on a fixture file through `run_automation(args=...)` covers the need.
5. **openpyxl as a declared MCP dependency:** **yes, lazily imported** (CSV keeps working without it).
6. **Date cells from xlsx:** **ISO `yyyy-mm-dd` by default, plus a `date_format` parameter.** Use `%m/%d/%Y` for a US-format web form.
7. **Duplicate labels for `fill`:** ~~decide after dumping a real web form screen~~ **DECIDED 2026-09-30: a generic `#N` occurrence suffix now** (`##` = literal `#`, no `#N` = the first match plus a log note); tune from a real dump.
8. **Privacy:** **profile/temp path normalization always on for everyone; default mode `paths` on this install.** You need to name the MaskRoots (the client folders).
9. **Wrapping `run_ahk_snippet` code in a function** (which makes clashes impossible but changes scoping): **no. Ship the error explanation first, and revisit if clashes keep happening.**
10. **Renaming `_Common`'s `Log` so the math built-in works again:** **no.**
11. **Split Pages status:** **protected from delete but still editable through update/edit_macro** (a separate delete-protected set).
12. **Tracked samples** (ToggleTimer, MeetingNotes, MorningTabs, WorkLayout, CleanScreenshots, OpenPublicUserFolder): **drop ToggleTimer; move the rest to `templates\examples\` or conformance fixtures.**
13. **Splitting the per-user files into committed defaults plus gitignored live files:** **yes.** It also fixes the upgrade bug.
14. **`reloaded` on tools that never reload:** **remove it and add a note** (no test depends on it).
15. **Version source:** **a build-stamped `VERSION` file.**
16. **Saving a Studio workflow under an existing name:** **ask to confirm replacing it**, and always refuse built-in tool names.
17. **Escaping formulas in collected CSV values:** **on, for non-numeric values only**, so negative amounts survive.
18. **Merge timing:** **finish WP0, run the suite, then merge to master and cut a release before starting WP1.**
