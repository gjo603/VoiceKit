# VoiceKit Feedback — Findings from the Split Pages Debugging Run

> **Repo copy.** Pasted into the implementing session on 2026-08-05. The test
> run behind it: an agent debugged Split Pages' save-race crash through the
> MCP alone, and everything that made that slow lived *outside* the
> Studio-workflow happy path — where the tooling goes dark.

## Implementation status

- [x] **1. `read_macro_source` + a guarded write path** (the #1 gap)
  - *2026-08-05 — shipped.* `read_macro_source(name, previous=False)` returns
    any `macros\` script's full source, kind, and header description;
    `update_macro` is the confirmation-shaped full replace (`/validate` +
    byte-exact rollback, previous source banked in `logs\macro-backups\`,
    retrievable via `previous=True`, removed on delete); `edit_macro` is the
    patch-shaped exact-match splice (shared `_splice_once` core with
    `edit_hotkey_module`). Builtins and generated workflow stubs are refused
    with pointers at the right tools. Pinned by
    `test_macro_source_read_update_edit_and_kinds`.
- [x] **2. Observability: `read_log` + capturing the error popup text**
  - *2026-08-05 — shipped.* `read_log(log, tail, filter)` reads `activity`
    (created.log — where Split Pages' `saved of pageCount` lines were sitting
    all along), `errors`, and `runs`; filter applies BEFORE the tail so one
    tool's last N runs survive unrelated traffic. The popup text is captured
    too: `_Common.ahk` now registers `OnError(LogUncaughtError)` during its
    include, so every macro/body/Studio process appends uncaught errors
    (script, message, file+line) to `logs\errors.log` before stock handling
    proceeds; the master's `MasterError` deduplicates, and the snippet
    prelude opts out (its errors already report through their own channel).
    Pinned by `test_read_log_tails_and_filters` + preflight-selftest §9.
- [x] **3. The taxonomy: `raw_script` kind + header-block description**
  - *2026-08-05 — shipped.* `list_automations` launch-macro entries carry an
    explicit `kind` (`opens` vs `raw_script`), and raw scripts surface their
    leading banner comment as `description` (`_macro_description`: borders
    dropped, `;` stripped, capped at 400 chars). `read_macro_source` returns
    the same kind plus a per-kind note.
- [x] **4. Near-miss-aware errors**
  - *2026-08-05 — shipped.* `_near_miss(base)` — what the name DOES exist as,
    and which tool reads it — is appended to every not-found path:
    `read_workflow`, `run_workflow_batch`, `read_workflow_sheet`,
    `read_ai_prompt`, `read_hotkey_module`, `read_module_status`,
    `edit_hotkey_module`, `run_automation` (both raise points), and the new
    macro tools. Pinned by `test_near_miss_errors_name_what_the_name_is`.
- [x] **5. `RobustMove()` in `_Common.ahk` + `RunCapture` last-line parse**
  - *2026-08-05 — shipped.* `RobustMove(src, dst, timeoutMs, overwrite)` —
    retry the rename, fall back to copy, never throw, `"moved"/"copied"/""`
    — with Split Pages' `SavePage` as a one-line delegate, so the class of
    "move a file something just touched" crashes has one fix. `SplitPdf`
    reads the page count from the last integer-only line (`LastIntLine`)
    instead of `IsInteger()` on the whole merged blob, so a pypdf warning
    can no longer fail a successful split. Pinned by preflight-selftest §8
    (real delete-denying and exclusive locks).

Suite after all five: `tests\Run-Tests.ps1` all green (8 AHK suites incl.
preflight 39 checks; 37/37 conformance).

## The feedback, verbatim

Given the "we built" in your setup notes, I'll address this to you directly.
The honest headline: the Studio-workflow happy path is genuinely well
designed — and today's problem lived entirely outside it, where the tooling
goes dark. Ranked by how much each cost me today:

1. **No read access to macro source is the #1 gap.** The debugging session
   that justified this whole integration required you to manually open a file
   and paste 250 lines into chat. `read_ai_prompt` exists for AI actions;
   there's no equivalent for `.ahk` source. Even a read-only
   `read_macro_source` would have collapsed three turns into one. And the
   loop is broken on the write side too — I produced a patch you now have to
   hand-apply. `create_workflow` already has load-check-and-discard
   machinery; a confirmation-gated `update_macro` with backup could reuse it.

2. **Observability exists but isn't exposed.** Split Pages writes a log line
   every run — `saved of pageCount | src`. That log would have shown me "died
   at page 7, then page 12, then page 4" *before I saw any code*, which is
   the varying-failure-point signature of a race. A `read_log` or
   `recent_runs` tool turns "it keeps crashing" from an interview into one
   call. Capturing AHK's error popup text (it names the failing line) would
   be even better.

3. **The taxonomy lies about raw scripts.** Split Pages is a full interactive
   application listed as a "launch macro," distinguishable only by a
   *missing* `opens` field — a signal I nearly missed. Worse: the script has
   an excellent self-describing header comment that the MCP throws away. Add
   a `raw_script` kind and surface the header block as a description in
   `list_automations`, and "what even is this thing" gets answered at the
   index level.

4. **The error message was half-great.** "Looked for SplitPages.steps.txt"
   told me the mechanism — good. But the index *knows* SplitPages exists as a
   macro; the error should have said "exists as a raw script, no steps file,
   source at <path>." Errors that know about near-miss entities save entire
   reasoning loops.

5. **From the one script I read: the shared lib needs a robust-save
   primitive.** The bug was an unguarded `FileMove` racing a viewer's file
   lock — and other file-filing macros presumably all
   do the same "move a file something just touched" dance. One `RobustMove()`
   in `_Common.ahk` (retry, copy fallback, never fatal) fixes a *class* of
   crashes. Same pattern in `RunCapture`: merging stderr then `IsInteger()`
   on the whole blob is one pypdf warning away from a false failure — parse
   the last line.

What earned trust: `list_automations` as a single grounding index with exact
voice phrases meant I never guessed a name; the tool docstrings encode the
operational model (the `wait_seconds` cap plus poll-`loop_running` guidance
is a detail most MCP authors get wrong); and the script itself was careful
code — consent-gated installs, never touching the original, a testing hook —
undone by one race the platform made invisible. Fix the visibility, and the
next bug like this is a five-minute job instead of a three-turn excavation.
