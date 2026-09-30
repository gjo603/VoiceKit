# VoiceKit Feedback — Findings from a Real Browser-Scraping Build

> **Repo copy.** The original lives in the author's project folder (not in
> this repo); it was copied here 2026-08-02 so an hourly cloud
> routine can implement it item by item. The routine reads the checklist below,
> implements ONE unchecked item per run, ticks it off with a dated note, and
> commits to the `feedback-implementation` branch.

## Implementation status

Rules for the implementing agent: work top-to-bottom (the table mirrors the
"Suggested priority" section at the bottom of this file); before starting an
item, verify against the current code that it is genuinely not yet implemented
— some items may have shipped partially (e.g. `BodyStatus` exists; item 8 is
about *surfacing* it). Tick a box only when the item is implemented, reviewed
for functionality AND simplicity, and committed. Add the date and a one-line
note under the item. If a box cannot be completed in one run, do NOT half-tick
it — leave it unchecked and write a `(blocked: …)` note instead.

- [x] **1. `inspect_focus` / `dump_uia_tree` MCP tools** (§1.1)
  - *2026-08-02 — shipped.* Two read-only MCP tools in `mcp\server.py` backed by
    the committed out-of-process probe `mcp\uia_probe.ahk`; `lib\UIA.ahk` grew
    `UiaParent`/`UiaFirstChild`/`UiaNextSibling` (raw-view TreeWalker, offsets
    verified against the SDK header), `UiaControlTypeName` and `UiaDumpTree`.
    The optional `screenshot()` was deliberately skipped. Verified locally:
    `tests\Run-Tests.ps1` all green (uia-selftest 76 checks, conformance 24/24
    incl. an end-to-end tree dump of a live window in another process).
- [x] **2. `create_hotkey_module`: return body hash instead of full `previous_body`** (§2.1)
  - *2026-08-02 — shipped.* A replace returns `previous_body_sha256`/`length`/
    `first_lines` and banks the full text in `logs\module-backups\<Base>.prev.ahk`;
    `read_hotkey_module(name, previous=True)` is the undo path (plain
    `read_hotkey_module` reads the NEW body after a replace, so without this the
    hash-only response would have killed undo for MCP-only clients). Delete
    removes the backup. Verified locally: `tests\Run-Tests.ps1` all green
    (25/25 conformance incl. `test_hotkey_replace_returns_hash_not_body`).
- [x] **3. `edit_hotkey_module` splice operation** (§2.1)
  - *2026-08-02 — shipped.* `edit_hotkey_module(name, old_string, new_string)`
    with file-Edit-tool semantics: exactly-once match (distinct errors for
    missing vs ambiguous), CRLF→LF normalization, `/validate` + rollback on a
    breaking splice, undo = swap the strings. A body edit is live with no
    master reload (bodies run fresh per press); isolate=False edits reload.
    Verified locally: `tests\Run-Tests.ps1` all green (26/26 conformance incl.
    `test_edit_hotkey_module_splices_and_rolls_back`).
- [x] **4. `run_ahk_snippet` one-off execution** (§2.2)
  - *2026-08-03 — shipped.* `run_ahk_snippet(code, timeout_s)` runs AHK v2 once
    in a throwaway process: `lib\_Common.ahk` + `lib\UIA.ahk` pre-included,
    predefined `Out(text)` reports back through a temp file, trailing `ExitApp`
    keeps it one-shot, timeout (1–120 s) kills the process but returns the
    partial log. No bridge key, no registry lines, nothing to delete. Verified
    locally: `tests\Run-Tests.ps1` all green (27/27 conformance incl.
    `test_run_ahk_snippet_runs_and_reports`).
- [x] **5. `list_running` / `stop_module`** (§3.1)
  - *2026-08-03 — shipped.* `list_running` (pid, start time, latest BodyStatus
    line; anchored process matching) and `stop_module(name, grace_s)` —
    graceful via the new `logs\body-stop-<Base>.flag` convention
    (`BodyStopRequested()` in `_Common.ahk` consumes it; generated body headers
    document the check), force-kill fallback scoped to the module's own PIDs,
    flag cleaned up in every path. Verified locally: `tests\Run-Tests.ps1` all
    green (28/28 conformance incl. `test_list_running_and_stop_module`, which
    proves both stop paths against real processes).
- [x] **6. Investigate duplicate-instance bug** (§3.2)
  - *2026-08-03 — investigated and fixed.* Reproduced: `#SingleInstance`
    checks hidden-window titles, and the window only exists once a starting
    script finishes loading — two quick launches BOTH pass (measured: 2
    processes from no-gap launches). Hypothesis (a) refuted (replace-mid-run
    still detected — the path is the identity), (c) refuted (plain `Run()`
    detects fine), busy-instance refuted too. Fix: `BodySingleInstance(base)`
    kernel mutex in `_Common.ahk`, called by generated bodies (atomic — the
    second process always loses, exits 0 quietly). Existing bodies (e.g.
    `ScraperBody.body.ahk`) should add the one-line call after their
    `#Include`. Verified locally: `tests\Run-Tests.ps1` all green (29/29 incl.
    `test_body_single_instance_mutex` against real processes).
- [x] **7. Lib helpers: `AssertOnDomain`, `GrabPageRobust`, `TypeVerified` + docs in tool descriptions** (§4.1–4.4)
  - *2026-08-03 — shipped* as `lib\Browser.ahk`: `BrowserEnsureDomain`,
    `BrowserGrabPage` (+ `BrowserUrl`, `BrowserLooksLikeUrlOnly`),
    `BrowserTypeVerified` (prefixed names — a bare `TypeVerified` would collide
    in AHK's shared namespace). The readback verifies the ELEMENT
    (`UiaValueOnly`, new in `UIA.ahk`), not whatever has focus — the test
    caught the clipboard-only version passing while typing into the wrong
    control. Helper lists added to `create_hotkey_module`'s tool description
    (all three libs, §5.1), and `run_ahk_snippet` pre-includes `Browser.ahk`.
    §4.4's Tab-walk recipe stays documentation (site-specific). Verified
    locally: `tests\Run-Tests.ps1` all green (new `browser-selftest` 20 checks
    against a separate pretend-browser process, uia-selftest now 79).
- [x] **8. `read_module_status` + document `BodyStatus` in tool descriptions** (§1.2)
  - *2026-08-02 — doc half:* the `BodyStatus` line landed in
    `create_hotkey_module`'s tool description alongside item 2.
  - *2026-08-03 — tool shipped.* `read_module_status(name)` joins the published
    status line to the liveness check and names which of the four states you're
    in (never-ran / ran-and-stopped / running-without-a-line / running-with-one,
    where a line that stops getting newer means stuck, not done). The optional
    `BodyLog()` ring buffer was deliberately skipped — `BodyStatus` covers
    "where am I now" and a plain `FileAppend` covers keeping a log; a third
    channel with its own trimming and a second read/write seam isn't earned
    yet. Verified locally: `tests\Run-Tests.ps1` all green (30/30 conformance
    incl. `test_read_module_status_joins_line_and_liveness`, all four states
    against real processes).
- [x] **9. Worked web-scrape reference body in docs** (§5.3)
  - *2026-08-03 — shipped.* `templates\web-scrape-body.ahk`: a complete,
    load-checked scraper body (search → keyboard walk → background-tab capture
    → dedupe → resumable queue → varied pacing → Esc/`stop_module` stop),
    distilled from the session's own final body and half its length now that
    `lib\Browser.ahk` exists. Served through the MCP as
    `read_reference("web-scrape")` (an MCP-only client can't read
    `templates\`), and pointed at from `create_hotkey_module`'s description.
    Verified locally: `tests\Run-Tests.ps1` all green (31/31 conformance incl.
    `test_reference_bodies_are_readable_and_load`, which load-checks it as a
    real body).

**All nine items are implemented.** Nothing here is outstanding; the hourly
loop that worked through this checklist has ended.

---

**Date:** 2026-08-02
**Context:** This document captures friction encountered while using VoiceKit's MCP tools to build a scraper for an online listings site in a single agent session. The goal: search the site methodically across ~18 terms, open every listing, capture its details to disk, and build a CSV — driven entirely through VoiceKit hotkey modules.

The build succeeded (a few hundred listings captured), but it took **5 major rewrites** of the hotkey body and several auxiliary hacks. Nearly all friction falls into three themes: **the agent cannot sense the screen**, **iteration is token-expensive**, and **there is no process lifecycle control**. Each finding below includes evidence, impact, and a concrete proposal with suggested API shape.

---

## Theme 1 — The agent is blind (no sensing primitives)

### 1.1 No way to inspect the focused element or UIA tree

**What happened:** The scraper walks the site's search results by sending `Tab` and reading the focused element's accessible name via `UiaFocused()`/`UiaName()`. The first version matched tile captions against the pattern seen in *copied page text* (`"<title> in <City>, ST"`). Focused tiles actually expose a completely different name format (`"<title>, $price, <City>, ST, listing <id>"`). Every Tab looked like a non-tile, so each search was abandoned after ~30 seconds.

**To diagnose this, the agent had to create, register, and later delete a throwaway hotkey module** ("Tab Probe") whose only job was to Tab 40 times and log focused names to a file. That is an enormous amount of machinery for "what am I looking at?"

**Proposal — read-only inspection tools:**

```
inspect_focus()
  -> { name, control_type, bounding_rect, ancestry (2-3 levels), window_title }

dump_uia_tree(window_criteria, max_depth?, name_filter?)
  -> indented text tree of accessible names + control types,
     capped at N lines

screenshot(region?)          # optional; even a downscaled image helps
  -> image the agent can view directly
```

`inspect_focus` alone would have collapsed three debugging iterations into one call. These tools carry no desktop-mutation risk and should be safe to call freely.

### 1.2 No logging/status channel from a running body back to the agent

**What happened:** To understand mid-run behavior, the agent had to hand-roll a `Dbg()` helper appending to a log file, then poll that file with shell `tail` between turns. Separately, a **cron job had to be scheduled** just to notice when the run finished (queue empty / process gone).

**What exists but is undiscoverable:** `lib/_Common.ahk` provides `BodyStatus()`/`BodyStatusDone()` — but this is only mentioned inside the auto-generated header comments of existing module bodies. It appears **nowhere in the MCP tool descriptions**, so an agent authoring its first module doesn't know it exists.

**Proposal:**

- Document `BodyStatus()` in the `create_hotkey_module` tool description (one line is enough: "long-running bodies should report progress via BodyStatus('<Base>', msg) from _Common.ahk").
- Add `read_module_status(name)` -> last BodyStatus line + whether the body process is currently running.
- Optional but high-value: a `log` channel per module — `BodyLog()` appending to a ring buffer that `read_module_status` returns the last N lines of.

---

## Theme 2 — Iteration is token-expensive

### 2.1 `create_hotkey_module` replace echoes the entire previous body

**What happened:** The scraper body grew to ~300 lines (~10 KB). It was replaced **5 times**. Each replace response contains the full `previous_body` — so each iteration cost the new body *plus* the old body in tokens. This was the single largest token sink of the session by a wide margin.

**Proposal:**

- On replace, return only `previous_body_sha256` + `previous_body_length` (+ first 3 lines for identification). The full old body remains retrievable via the existing `read_hotkey_module` if an undo is actually needed.
- Optionally support targeted edits:

```
edit_hotkey_module(name, old_string, new_string)   # exact-match splice,
                                                   # same semantics as a file Edit tool
```

Most fixes in this session changed one function (e.g., the tile-matching predicate); a splice operation would have cost ~1% of the tokens of a full rewrite.

### 2.2 No lightweight way to run one-off AHK for diagnostics

**What happened:** The Tab Probe (see 1.1) occupied a real bridge key (`Ctrl+Alt+Shift+T`), entered the bridge registry, required Voice Access pairing notes, and needed a `delete_automation` call afterward — all for a 25-second diagnostic.

**Proposal:**

```
run_ahk_snippet(code, timeout_s?)   # runs once, unsaved, isolated process,
  -> { stdout/log file contents, exit status }
```

This covers probes, one-off checks ("what window titles exist right now?"), and experiments, without polluting the registry.

---

## Theme 3 — No process lifecycle control

### 3.1 Can't list or stop running body processes

**What happened:** Stopping the harvester required PowerShell process-hacking by command-line substring:

```powershell
Get-CimInstance Win32_Process -Filter "Name like 'AutoHotkey%'" |
  Where-Object { $_.CommandLine -match 'ScraperBody' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

That is fragile (pattern could match the wrong thing) and far outside the intended API surface.

**Proposal:**

```
list_running()          -> [{ name, pid, started_at, last_status }]
stop_module(name)       -> graceful stop (e.g. signal file the body
                           checks in its pacing sleeps), with force-kill
                           fallback
```

A documented **cooperative-stop convention** would pair well with this: bodies that poll a stop-flag file (or Esc, as this session's did) can be halted without force-killing.

### 3.2 Possible `#SingleInstance Ignore` violation — investigate

**What happened:** Late in the session, **two** `ScraperBody.body.ahk` processes were found running simultaneously (capture count jumped from 112 to 238 between checks, and a second kill pass found another PID). Both instances were created via `press_hotkey`. The body begins with `#SingleInstance Ignore`, which should prevent a second instance.

**Hypotheses to investigate:** (a) the module was *replaced* between presses, and the rewritten file counts as a different script for single-instance purposes; (b) two presses raced during a reload; (c) something in the launcher spawns the body in a way that bypasses the directive. Reproduction: press a long-running isolated module, replace it mid-run via `create_hotkey_module`, press again, count processes.

**Impact:** two scrapers walking the same grid = duplicated captures, doubled request rate against the site, and confusing state. This is the only suspected **bug** in this document; everything else is enhancement.

---

## Theme 4 — Missing browser-automation primitives (foolproofing)

Every one of these was hand-rolled and bitten by a bug in this session before landing on a working form. They are generic to any "scrape a website through the user's browser" use case and belong in a documented lib (or a recipe in the tool descriptions).

### 4.1 Keystrokes can silently land in the wrong window/tab → **domain guard**

**Incident:** Early versions sometimes typed the search query into Chrome's omnibox or a stray tab, turning it into a *Google* search (reported by the user watching the screen). Keystroke-based automation has no natural "are you sure?" — the script must verify before typing.

**Proven pattern to ship as a helper:**

```ahk
; Read the omnibox URL; if it's not the expected domain, navigate there
; first and re-check. Returns false if the site can't be reached.
AssertOnDomain(hwnd, "example.com/listings")
```

Any helper that sends keystrokes should either call this first or take a required `expected_url_fragment` parameter.

### 4.2 Clipboard page-grab is fragile → **hardened GrabPage helper**

**Incident:** First capture version grabbed the *address bar text* instead of the page, because `^l` (used to fetch the URL) strands keyboard focus in the omnibox and a following `^a^c` then copies the URL. The fix — grab page **before** URL, retry if the result looks like a bare URL — is non-obvious.

**Proven pattern to ship:**

```ahk
GrabPageRobust()   ; ^a^c, retry once after Esc if result is <400 chars
                   ; or matches ^https?://\S+$; restores clipboard
GrabUrl()          ; ^l ^c Esc, restores clipboard; documented that it
                   ; must not precede a plain page grab
```

### 4.3 Typing into web inputs needs readback verification

**Incident:** Clicking a search box by UIA rect can miss (layout shifts). Typing blind then pressing Enter is how queries leaked to Google. The robust sequence: click box → `^a` → type → **`^a^c` readback must equal the intended text** → only then Enter; otherwise fall back to navigating to a results URL directly. This is exactly the pattern an earlier form-scraping module used for the same reason — promote it from module folklore to a lib helper:

```ahk
TypeVerified(hwnd, elementName, text) -> bool
```

### 4.4 Tab-walking + UIA focus reading is *the* reliable grid-walk

**Incident:** Two other reveal strategies failed first — wheel scrolling (cursor not reliably over the scrollable pane) and Alt+Left back-navigation (keyboard focus lost on return, so the walk restarted from page top and starved). What worked: `Tab` through the grid (auto-scrolls), match `UiaFocused()` names, **`Ctrl+Enter` to open in a background tab**, capture, **`Ctrl+W` to close** — grid tab keeps scroll *and* focus, so the walk continues from the next item.

Also worth documenting: an element's **copied-text line** and its **accessible name while focused** can differ substantially (see 1.1), so any matching recipe should be validated against focused names, not clipboard text.

**Safety edge case the helper must handle:** if `Ctrl+Enter` fails to open a tab, a following blind `Ctrl+W` would close an *unrelated* user tab. The working body checks the new tab's URL matches the expected item-URL pattern before closing anything.

---

## Theme 5 — Documentation/discoverability (cheap wins)

1. **`lib/` contents are invisible to tool users.** The agent only learned that `lib/UIA.ahk` (`UiaFind`, `UiaRect`, `UiaFocused`, `UiaName`) and `lib/_Common.ahk` (`BodyStatus`) exist by reading another module's body. Add a "Available library helpers" section to the `create_hotkey_module` tool description, or a `list_lib_helpers()` tool returning signatures + one-line docs.
2. **Bridge keys are a scarce resource** — diagnostics shouldn't consume them (see 2.2).
3. Consider shipping a **worked "web scrape" reference body** (search box → walk results → capture → dedupe file → resumable queue) as a template mentioned in the tool docs; nearly every scraping request will be a variant of it. This session's final body is available as a starting point (`hotkeys/bodies/ScraperBody.body.ahk`).

---

## Suggested priority

| # | Item | Effort | Impact |
|---|------|--------|--------|
| 1 | `inspect_focus` / `dump_uia_tree` tools | Low | Very high — removes blind debugging |
| 2 | `create_hotkey_module`: return body hash instead of full `previous_body` | Trivial | Very high — biggest token saving |
| 3 | `edit_hotkey_module` splice operation | Medium | High — cheap iteration |
| 4 | `run_ahk_snippet` one-off execution | Low | High — diagnostics without registry pollution |
| 5 | `list_running` / `stop_module` | Low–Medium | High — no PowerShell process-hacking |
| 6 | Investigate duplicate-instance bug (3.2) | Medium | High — correctness/safety |
| 7 | Lib helpers: `AssertOnDomain`, `GrabPageRobust`, `TypeVerified` + docs in tool descriptions | Low | High — prevents the exact bugs hit here |
| 8 | `read_module_status` + document `BodyStatus` | Low | Medium — observability |
| 9 | Worked web-scrape reference body in docs | Low | Medium — faster first-time-right |

---

## Appendix — session evidence trail

For verification, all artifacts are on disk (on the author's machine, not in this repo):

- Final working module: `hotkeys\bodies\ScraperBody.body.ahk` (v5: Tab-walk + new-tab capture + domain guard + readback + debug log)
- Probe output showing real focused-tile name format: `tab_probe.txt` (project folder) — 40 Tab stops with accessible names
- Debug log from the healthy run: `scraper_debug.txt` — shows tile-to-tile progression, ~10 s/listing, seen/NEW decisions
- Harvest results: `listings_raw.txt` (raw captures), `sellers.csv` (the seller list), `queue.txt`, `seen.txt` (listing-ID dedupe)
- Project folder: the author's scraping project folder (not in this repo)

Bugs hit during the session, in order: (1) page-grab returned omnibox URL, (2) keystroke leak → Google searches, (3) wheel-scroll reveal starvation (14 sellers from 10 searches), (4) tile-match regex written against copied text instead of focused names (3 captures from 3 searches), (5) Alt+Left focus loss starving walks, (6) duplicate body instances, (7) blind `Ctrl+W` risk on failed tab-open (caught in design, handled by URL check).
