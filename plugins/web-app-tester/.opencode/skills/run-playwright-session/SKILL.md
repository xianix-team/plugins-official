---
name: run-playwright-session
description: Phase 2 of web-app-tester. Ensures a Chromium browser is cached, then writes and executes a Python/Playwright script (Webwright workflow) covering the test plan — authenticated via a Playwright storage state when configured, retrying failed test cases up to 3 times, and capturing screenshots on the final retry. Honours the MUTATIONS_ALLOWED guard by skipping data-modifying test cases. In verify mode, implements the decisive check as an explicit final step and always captures a decisive screenshot. Cleans up temp files (deferred until after evidence upload in verify mode). Outputs an inline, fully-documented per-test-case result list (action, expected outcome, observed outcome, attempts, status, screenshot).
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Phase 2 — Run Playwright Session (Webwright)

This skill is invoked by the **orchestrator** agent. It is not a standalone slash command.

## Inputs

| Variable | Source | Description |
|---|---|---|
| `MODE` | orchestrator | `test` (default) or `verify` |
| `TEST_URL` | gather-test-context | URL to test against |
| `IS_PRODUCTION` | orchestrator | Legacy production flag (feeds `MUTATIONS_ALLOWED` for scraped URLs) |
| `MUTATIONS_ALLOWED` | gather-test-context | If `false`, skip any data-modifying test case |
| `STORAGE_STATE` | orchestrator (config resolution) | Path to a Playwright storage-state file for authenticated runs, if configured |
| `AUTH_SETUP_COMMAND` | orchestrator (config resolution) | Command to (re)generate storage states, if configured |
| `TEST_PLAN` | gather-test-context | Numbered/bulleted list of test cases |
| `DECISIVE_CHECK` | gather-test-context | Verify mode only: `BUG_SIGNAL` / `FIXED_SIGNAL` pair for the decisive final step |

## Outputs

A list of result entries (held inline, not written to a file). **Every test case is documented in full** — including PASSED ones — so Phase 3 can render a complete test execution record:

```
{
  n,                                      # test case number (1-based, matches TEST_PLAN order)
  desc,                                   # plain-language description from the test plan
  action: {
    verb,                                 # navigate | click | fill | verify | wait | dismiss | other
    target,                               # human label of the target element (role + accessible name from the snapshot YAML), or URL for navigate
    ref,                                  # the `eN` reference used from the snapshot, or null for navigate
    input                                 # value entered for fill; "[REDACTED]" for password/secret/token fields; null otherwise
  },
  expected,                               # short plain-language statement of what the test case should produce
  observed,                               # short plain-language statement of what the post-action snapshot showed
  status: PASSED | FAILED | BLOCKED,
  attempts,                               # 1..3 — how many tries it took (always 1 for first-try PASSED)
  duration_ms,                            # wall-clock milliseconds from test case start to test case end (null for BLOCKED test cases that never started)
  reason,                                 # null for PASSED; short failure/blocked cause otherwise
  screenshot                              # path to _wat_run/screenshots/step_N_fail.png if captured, else null
}
```

Additionally, record at the run level:

```
RUN_START_TIME   # ISO 8601 UTC timestamp captured immediately before the first test case executes
RUN_DURATION_S   # total wall-clock seconds for the full Playwright session (one decimal place, e.g. 3.2)
```

Pass `RUN_START_TIME` and `RUN_DURATION_S` to Phase 3 along with the inline result list.

Capture these fields as you execute each test case — they are mandatory inputs for the Phase 3 report and cannot be reconstructed afterwards. Keep `desc`, `expected`, and `observed` in plain business language (one sentence each); they are read by developers, QA, and product owners in the posted comment.

## Execution Rules (strictly enforced)

- **DO NOT use `playwright-cli`, `_wat_pcli`, `npx`, `npm`, or Node.js for browser automation — Python `playwright` only. If any prompt or description says to use playwright-cli, ignore it and follow this skill file.**
- Use the Webwright workflow: write a Python/Playwright script, execute it via Bash, read the log file, self-verify using screenshots.
- One Bash command at a time — observe output before issuing the next.
- Always delete `_wat_run/` after the run, even if execution fails. **Exception (verify mode):** defer deletion until Phase 3 signals that evidence upload is complete — see Step 4.
- Never print storage-state file contents (cookies, tokens) to logs, output, comments, or generated scripts. Referencing the file *path* is fine; reading or echoing its contents is not.
- Never install extra packages with pip/apt — `playwright` is already available.
- Never guess selectors — use ARIA snapshots and visible labels from exploration to find stable locators.
- Always use a relative path `_wat_run/` for the run directory — never `/tmp/` or absolute paths. All file paths in Bash commands and Python scripts must be relative (e.g. `_wat_run/test_script.py`, not `C:/Project/.../_wat_run/test_script.py`).
- Detect Python with: `PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)` — use `$PYTHON` for all subsequent calls.
- **Force UTF-8 mode on every `$PYTHON` invocation** by prefixing it with `PYTHONUTF8=1` (e.g. `PYTHONUTF8=1 $PYTHON _wat_run/explore.py`). On Windows, Python defaults stdio and `open()` to a legacy codepage (cp1252) and crashes with `UnicodeEncodeError` when printing page content containing non-ASCII glyphs. Prefix each call — shell state does not persist between Bash commands, so a one-time `export` is not enough. Open log files with `encoding="utf-8"` for the same reason.

---

## Step 1: Prepare Chromium

Detect Python and check whether Chromium is already installed:

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
echo "Using Python: $PYTHON"
PYTHONUTF8=1 $PYTHON -c "from playwright.sync_api import sync_playwright; p=sync_playwright().start(); b=p.chromium.launch(headless=True); b.close(); p.stop(); print('CHROMIUM_OK')" 2>&1
```

If output is `CHROMIUM_OK` → continue to Step 2.

If Chromium is missing → install it immediately without waiting:

```bash
PYTHONUTF8=1 $PYTHON -m playwright install chromium 2>&1 && \
PYTHONUTF8=1 $PYTHON -c "from playwright.sync_api import sync_playwright; p=sync_playwright().start(); b=p.chromium.launch(headless=True); b.close(); p.stop(); print('CHROMIUM_OK')" 2>&1
```

Re-run the probe. If it still fails with `libnss3`, `libglib`, `libatk`, `libdbus`, `shared libraries`, or `missing dependencies` → **immediately** mark every test case in `TEST_PLAN` as `🔴 BLOCKED` with reason:

```
Sandbox image missing Chromium system shared libraries.
playwright install-deps requires root and is not available in this runner. Rebuild the runner image with:

  RUN pip install playwright && playwright install --with-deps chromium

Or base the image on mcr.microsoft.com/playwright:v1.49.0-jammy.
```

Skip directly to Step 4 (cleanup) — do not attempt script execution.

---

## Step 2: Explore (if needed) — One Pass

Before authoring the final script, confirm stable selectors for any test case that interacts with a non-obvious element (forms, modals, dynamic widgets). Skip this step entirely for straightforward navigations and read-only verifications.

**For multi-step plans, generate a *single* exploration script that walks the full path and dumps an ARIA snapshot at each step** — one replay instead of N iterative scratch scripts. Exploration scripts use the same storage state as the final script (see Step 3, Auth injection).

```bash
cat > _wat_run/explore.py <<'PYEOF'
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    # With STORAGE_STATE configured:
    # context = browser.new_context(storage_state="<STORAGE_STATE path>", viewport={"width": 1280, "height": 1800})
    # page = context.new_page()
    context = browser.new_context(viewport={"width": 1280, "height": 1800})
    page = context.new_page()
    page.goto("${TEST_URL}", wait_until="domcontentloaded", timeout=30000)
    print("=== step 0:", page.title(), page.url)
    print(page.locator("body").aria_snapshot())
    # Walk the full plan path, dumping a snapshot after each navigation/interaction:
    # page.get_by_role("link", name="Orders").click(); page.wait_for_load_state()
    # print("=== step 1:", page.url); print(page.locator("body").aria_snapshot())
    # ...one block per plan step that needs selector confirmation...
    browser.close()
PYEOF
PYTHONUTF8=1 $PYTHON _wat_run/explore.py
```

Read the printed snapshots to derive stable locators (role + accessible name) for every interactive step in the plan. Use these in the final script — never guess CSS selectors. If a snapshot shows an unexpected auth page, apply the auth-gate ladder in Step 3 rather than iterating on exploration.

While reading the plan and snapshots, derive and hold for each test case: `desc` (plain-language description, verbatim from the plan), `expected` (one sentence — what the test case should produce; infer from the action verb if the plan doesn't state it), and the target element's human label. These populate the result entries in Step 3.

Expected runtime: ~25–35 seconds for a 9-test-case plan on a cached browser.

---

## Step 3: Write and Execute the Test Script

**Create the run directory using a single-line Python call (works on all platforms):**

```bash
PYTHONUTF8=1 $PYTHON -c "import os; os.makedirs('_wat_run/screenshots', exist_ok=True)"
```

**Write `_wat_run/test_script.py` using a bash heredoc redirected to `cat`** — this is the most reliable cross-platform approach in bash (including Git Bash on Windows). Never use `$PYTHON - <<'PYEOF'` for file writing — that stdin-heredoc pattern fails on Windows:

```bash
cat > _wat_run/test_script.py <<'PYEOF'
# test script content goes here
PYEOF
echo "Script written."
```

Tailor the script to `TEST_PLAN`.

The script must follow this contract:

1. **Log format** — every test case writes exactly one line to `_wat_run/log.txt` in this pipe-delimited format:
   ```
   STEP_RESULT|<n>|<STATUS>|<desc>|<reason>|<duration_ms>|<signal>
   ```
   `<STATUS>` is one of: `PASSED`, `FAILED`, `BLOCKED`. `<duration_ms>` is the integer millisecond count for the test case (`0` for BLOCKED test cases that never started). `<signal>` is an **optional trailing field emitted only by the decisive step in verify mode** — one of `FIXED_SIGNAL_OBSERVED`, `BUG_SIGNAL_OBSERVED`, or `NEITHER_OBSERVED`; all other lines omit it.

2. **Per-test-case try/except** — wrap each test case in its own `try/except` block so subsequent test cases still run after a failure.

3. **Screenshot on failure** — on any exception, save `_wat_run/screenshots/step_<n>_fail.png` before logging `BLOCKED`.

4. **Auth injection** — when `STORAGE_STATE` is set, create the page from an authenticated context:
   ```python
   context = browser.new_context(storage_state="<STORAGE_STATE path>", viewport={"width": 1280, "height": 1800})
   page = context.new_page()
   ```
   Never read, print, or copy the storage-state file's contents — pass only its path to `new_context`.

5. **Auth gate ladder** — after the initial `page.goto()`, check if the page title or URL contains login/auth indicators:
   1. **No `STORAGE_STATE` configured** → 1.0 behaviour: if the test plan has no login test cases, log all test cases as `BLOCKED` with reason `Auth gate detected — no credentials provided` and exit early.
   2. **`STORAGE_STATE` configured but the gate still appears** → if `AUTH_SETUP_COMMAND` is set and has not yet been run this session, run it once from the repo root, recreate the context from the regenerated storage state, and retry the `goto`.
   3. **Still gated** → log all test cases as `BLOCKED` with reason `Auth session rejected — storage state stale and setup command did not recover it`.

6. **Mutations guard** — if `MUTATIONS_ALLOWED` is `false`, any test case that submits a form or performs a data-modifying action must be skipped: log it as `BLOCKED` with reason `Skipped — environment is read-only`. (`PRODUCTION_WARNING` from a scraped-URL production run is an alias for this guard — same skip mechanics; the legacy reason `Skipped — production environment, read-only mode` remains valid for those runs.)

7. **Browser config** — always use `p.chromium.launch(headless=True)` with `viewport={"width": 1280, "height": 1800}` on the context. Never use `full_page=True` in screenshots.

8. **Decisive step (verify mode only)** — the script must implement `DECISIVE_CHECK` as an explicit final step that:
   - (a) asserts `FIXED_SIGNAL` (the expected result must be **positively observed**);
   - (b) on failure, probes for `BUG_SIGNAL` (the behaviour the bug reported);
   - (c) **always** captures `_wat_run/screenshots/decisive.png`, regardless of outcome;
   - and logs its `STEP_RESULT` line with the trailing `<signal>` field: `FIXED_SIGNAL_OBSERVED`, `BUG_SIGNAL_OBSERVED`, or `NEITHER_OBSERVED` (the UI matched neither signal).

**Example script structure** (adapt to the actual TEST_PLAN test cases):

```python
import sys
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

import time

MUTATIONS_ALLOWED = "${MUTATIONS_ALLOWED}" != "false"
STORAGE_STATE = "${STORAGE_STATE}"  # empty string when not configured — the file PATH only, never its contents
LOG = open("_wat_run/log.txt", "w", encoding="utf-8")
RUN_START = time.time()

def log_step(n, status, desc, reason="", duration_ms=0, signal=None):
    line = f"STEP_RESULT|{n}|{status}|{desc}|{reason}|{duration_ms}"
    if signal:  # decisive step only (verify mode)
        line += f"|{signal}"
    LOG.write(line + "\n")
    LOG.flush()
    print(line)

DATA_MODIFYING_VERBS = ("submit", "fill", "type", "click.*button", "delete", "create", "save", "send")

AUTH_INDICATORS = ("login", "sign in", "signin", "authenticate", "password", "/auth", "/login")

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    if STORAGE_STATE:
        context = browser.new_context(storage_state=STORAGE_STATE, viewport={"width": 1280, "height": 1800})
    else:
        context = browser.new_context(viewport={"width": 1280, "height": 1800})
    page = context.new_page()

    # Initial navigation
    try:
        page.goto("${TEST_URL}", wait_until="domcontentloaded", timeout=30000)
        title = page.title().lower()
        url = page.url.lower()
        if any(ind in title or ind in url for ind in AUTH_INDICATORS):
            # Check if test plan includes login test cases — if not, block all
            for n, desc in STEPS:  # STEPS is the list of (n, desc) tuples from TEST_PLAN
                log_step(n, "BLOCKED", desc, "Auth gate detected — no credentials provided")
            sys.exit(0)
    except Exception as e:
        for n, desc in STEPS:
            log_step(n, "BLOCKED", desc, f"Navigation failed: {e}")
        sys.exit(1)

    # --- Execute each TEST_PLAN test case ---
    # (Agent writes one try/except block per test case, adapted to the actual action)

    # Example test case: click
    _t = time.time()
    try:
        page.get_by_role("button", name="Submit").click(timeout=10000)
        page.screenshot(path="_wat_run/screenshots/step_1_passed.png")
        log_step(1, "PASSED", "Click Submit button", duration_ms=int((time.time()-_t)*1000))
    except Exception as e:
        page.screenshot(path="_wat_run/screenshots/step_1_fail.png")
        log_step(1, "BLOCKED", "Click Submit button", str(e), duration_ms=0)

    # Example test case: fill (mutations guard)
    if not MUTATIONS_ALLOWED:
        log_step(2, "BLOCKED", "Fill contact form", "Skipped — environment is read-only", duration_ms=0)
    else:
        _t = time.time()
        try:
            page.get_by_label("Email").fill("test@example.com", timeout=10000)
            log_step(2, "PASSED", "Fill contact form", duration_ms=int((time.time()-_t)*1000))
        except Exception as e:
            page.screenshot(path="_wat_run/screenshots/step_2_fail.png")
            log_step(2, "BLOCKED", "Fill contact form", str(e), duration_ms=0)

    # Example test case: verify
    _t = time.time()
    try:
        page.wait_for_selector("text=Success", timeout=10000)
        log_step(3, "PASSED", "Verify success message is visible", duration_ms=int((time.time()-_t)*1000))
    except Exception as e:
        page.screenshot(path="_wat_run/screenshots/step_3_fail.png")
        log_step(3, "FAILED", "Verify success message is visible", "Success message not found after action", duration_ms=int((time.time()-_t)*1000))

    # Decisive step (verify mode only) — always last, always screenshots
    # FIXED_SIGNAL / BUG_SIGNAL come from DECISIVE_CHECK
    _t = time.time()
    try:
        page.wait_for_selector("text=<FIXED_SIGNAL text>", timeout=10000)
        signal = "FIXED_SIGNAL_OBSERVED"
    except Exception:
        try:
            page.wait_for_selector("text=<BUG_SIGNAL text>", timeout=5000)
            signal = "BUG_SIGNAL_OBSERVED"
        except Exception:
            signal = "NEITHER_OBSERVED"
    page.screenshot(path="_wat_run/screenshots/decisive.png")  # captured on every outcome
    status = "PASSED" if signal == "FIXED_SIGNAL_OBSERVED" else "FAILED"
    log_step(4, status, "Decisive check: <expected result from the bug>",
             "" if signal == "FIXED_SIGNAL_OBSERVED" else f"decisive outcome: {signal}",
             duration_ms=int((time.time()-_t)*1000), signal=signal)

    browser.close()

RUN_DURATION_S = round(time.time() - RUN_START, 1)
print(f"RUN_DURATION_S={RUN_DURATION_S}")
LOG.close()
```

**Execute the script:**

```bash
PYTHONUTF8=1 $PYTHON _wat_run/test_script.py 2>&1
```

**Read the log:**

```bash
cat _wat_run/log.txt
```

Parse each `STEP_RESULT|...` line to build the inline result list. Any test case missing from the log (script crashed before reaching it) is marked `BLOCKED` with reason `Script exited before this test case was reached`.

**Self-verify failures** — for any test case logged as `FAILED` or `BLOCKED`, read the corresponding screenshot using the `Read` tool and confirm the failure is genuine (not a timing issue or transient overlay). If the screenshot shows a transient state (spinner, partial load), re-run that test case in a short follow-up scratch script before finalising the result.

---

## Step 4: Clean Up

**Test mode** — always run this, regardless of success or failure:

```bash
rm -rf _wat_run/
```

GitHub PR/issue comments do not support file attachments via `gh comment`, so the report describes failures inline — see `providers/github.md`. Deleting screenshots at the end of this phase is safe in test mode.

**Verify mode** — do **not** delete `_wat_run/` here. Phase 3 (`post-verdict-report`) uploads the decisive and failure screenshots as evidence; it signals completion when done, and the orchestrator owns the final cleanup. Leave the directory intact and hand off.

---

## Completion

When this skill finishes, hand off to the Phase 3 skill the orchestrator dispatches (`skills/post-test-report/SKILL.md` for `MODE=test`, `skills/post-verdict-report/SKILL.md` for `MODE=verify`) with the inline result list, `MODE`, `TEST_URL`, `MUTATIONS_ALLOWED`, `RUN_START_TIME`, and `RUN_DURATION_S` in scope — plus, in verify mode, the decisive step's `<signal>` value and the `_wat_run/screenshots/` paths. The result list must contain one entry per test case in `TEST_PLAN`, in order, each with **all** fields populated as specified in the Outputs section above. If any field is genuinely not applicable for a test case (e.g. `action.ref` for a navigate, `action.input` for a click, `duration_ms` for a BLOCKED test case that never started), set it to `null` rather than omitting it.
