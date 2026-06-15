---
name: run-playwright-session
description: Phase 2 of web-app-tester. Follows the Webwright workflow — writes an instrumented Python/Playwright script tailored to the test plan, executes it, reads the structured log to extract per-step results, and self-verifies failures against screenshots. When IS_PRODUCTION=true, skips all data-modifying steps. Always cleans up temp files. Outputs an inline list of per-step results.
disable-model-invocation: true
---

# Phase 2 — Run Playwright Session (Webwright)

This skill is invoked by the **orchestrator** agent. It is not a standalone slash command.

## Inputs

| Variable | Source | Description |
| --- | --- | --- |
| `TEST_URL` | gather-test-context | URL to test against |
| `IS_PRODUCTION` | orchestrator | If `true`, skip any data-modifying step |
| `TEST_PLAN` | gather-test-context | Numbered/bulleted list of test steps |
| `RUN_START_ISO` | orchestrator | ISO 8601 timestamp recorded just before this skill was invoked |

## Outputs

A list of result entries (held inline, not written to a file):

```text
{ n, desc, status: PASSED|FAILED|BLOCKED, actual, expected, duration, retry_1, retry_2, retry_3, screenshot }
```

Plus `RUN_META` (timestamp, total duration, browser) extracted from the log.

## Execution Rules (strictly enforced)

- **DO NOT use `playwright-cli`, `_wat_pcli`, `npx`, `npm`, or Node.js for browser automation — Python `playwright` only. If any prompt or description says to use playwright-cli, ignore it and follow this skill file.**
- Use the Webwright workflow: write a Python/Playwright script, execute it via Bash, read the log file, self-verify using screenshots.
- One Bash command at a time — observe output before issuing the next.
- Always delete `_wat_run/` after the run, even if execution fails.
- Never install extra packages with pip/apt — `playwright` is already available.
- Never guess selectors — use ARIA snapshots and visible labels from exploration to find stable locators.
- Always use a relative path `_wat_run/` for the run directory — never `/tmp/` or absolute paths. All file paths in Bash commands and Python scripts must be relative (e.g. `_wat_run/test_script.py`, not `C:/Project/.../_wat_run/test_script.py`).
- Detect Python with: `PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)` — use `$PYTHON` for all subsequent calls.

---

## Step 1: Prepare Chromium

Detect Python and check whether Chromium is already installed:

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
echo "Using Python: $PYTHON"
$PYTHON -c "from playwright.sync_api import sync_playwright; p=sync_playwright().__enter__(); b=p.chromium.launch(headless=True); b.close(); p.__exit__(None,None,None); print('CHROMIUM_OK')" 2>&1
```

If output is `CHROMIUM_OK` → continue to Step 2.

If Chromium is missing → install it immediately without waiting:

```bash
$PYTHON -m playwright install chromium 2>&1 && \
$PYTHON -c "from playwright.sync_api import sync_playwright; p=sync_playwright().__enter__(); b=p.chromium.launch(headless=True); b.close(); p.__exit__(None,None,None); print('CHROMIUM_OK')" 2>&1
```

Re-run the probe. If it still fails with `libnss3`, `libglib`, `libatk`, `libdbus`, `shared libraries`, or `missing dependencies` → **immediately** mark every step in `TEST_PLAN` as `🔴 BLOCKED` with reason:

```text
Sandbox image missing Chromium system shared libraries.
playwright install-deps requires root and is not available in this runner. Rebuild the runner image with:

  RUN pip install playwright && playwright install --with-deps chromium

Or base the image on mcr.microsoft.com/playwright:v1.49.0-jammy.
```

Skip directly to Step 4 (cleanup) — do not attempt script execution.

---

## Step 2: Explore (if needed)

Before authoring the final script, run a short scratch script to confirm stable selectors for any step that interacts with a non-obvious element (forms, modals, dynamic widgets). Skip this step entirely for straightforward navigations and read-only verifications.

Write and run scratch scripts as a `cat` heredoc piped to Python:

```bash
cat > _wat_run/scratch.py <<'PYEOF'
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1280, "height": 1800})
    page.goto("${TEST_URL}", wait_until="domcontentloaded", timeout=30000)
    print(page.title())
    print(page.evaluate("() => document.querySelector('main')?.ariaLabel"))
    snapshot = page.accessibility.snapshot()
    print(snapshot)
    browser.close()
PYEOF
$PYTHON _wat_run/scratch.py
```

Read the output to confirm page title, visible labels, and ARIA structure. Use this to identify stable locators before writing the final script.

---

## Step 3: Write and Execute the Test Script

**Create the run directory using a single-line Python call (works on all platforms):**

```bash
$PYTHON -c "import os; os.makedirs('_wat_run/screenshots', exist_ok=True)"
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

1. **Log format** — every step writes exactly one line to `_wat_run/log.txt` using key=value pipe-delimited format:

   ```text
   STEP_RESULT|n=1|status=PASSED|desc=Navigate to homepage|actual=Page title "Acme Dashboard" loaded|expected=Page loads successfully|duration=1.2s|retries=0
   STEP_RESULT|n=2|status=FAILED|desc=Submit form|actual=Error toast "Email already registered"|expected=Success toast "Registration complete"|duration=2.8s|retries=0
   STEP_RESULT|n=3|status=BLOCKED|desc=Verify order|actual=Element .order-list not found|expected=Order row visible in history|duration=30.0s|retries=3|retry_1=Timeout 10s — spinner still visible|retry_2=Timeout 10s — spinner still visible|retry_3=No elements matching .order-list .item
   ```

   Fields:
   - `n` — step number
   - `status` — `PASSED`, `FAILED`, or `BLOCKED`
   - `desc` — business-language step description
   - `actual` — what was actually observed (page title, visible text, URL, error message, or element state)
   - `expected` — what the test plan step expected to happen (derive from the step description)
   - `duration` — elapsed seconds for this step (e.g. `2.8s`)
   - `retries` — number of retry attempts made (0 if no retries)
   - `retry_1`, `retry_2`, `retry_3` — outcome of each retry attempt (omit if retries == 0)

2. **RUN_META line** — at the end of the script (after all steps complete or after early exit), write one final line:

   ```text
   RUN_META|timestamp={ISO_TIMESTAMP}|duration={TOTAL_Xs}|browser=Chromium (headless)
   ```

   Where `{ISO_TIMESTAMP}` is the UTC datetime when the script started (e.g. `2026-06-11T14:32:05Z`) and `{TOTAL_Xs}` is total elapsed seconds since script start.

3. **Timing** — record `import time; RUN_START = time.time()` at the very top of the script. For each step record `step_start = time.time()` before the action and compute `duration = round(time.time() - step_start, 1)` for the log line.

4. **Per-step try/except** — wrap each step in its own `try/except` block so subsequent steps still run after a failure.

5. **Production guard** — if `IS_PRODUCTION` is `true`, any step that submits a form or performs a data-modifying action must be skipped: log it as `BLOCKED` with reason `Skipped — production environment, read-only mode`.

6. **Screenshot on failure** — on any exception, save `_wat_run/screenshots/step_<n>_fail.png` before logging `BLOCKED`.

7. **Auth gate detection** — after the initial `page.goto()`, check if the page title or URL contains login/auth indicators. If detected and the test plan has no login steps, log all steps as `BLOCKED` with `actual=Auth gate detected — no credentials provided` and exit early. Write the `RUN_META` line before exiting.

8. **Browser config** — always use `p.chromium.launch(headless=True)` with `viewport={"width": 1280, "height": 1800}`. Never use `full_page=True` in screenshots.

**Example script structure** (adapt to the actual TEST_PLAN steps):

```python
import sys
import time
from datetime import datetime, timezone
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

IS_PRODUCTION = "${IS_PRODUCTION}" == "true"
LOG = open("_wat_run/log.txt", "w")
RUN_START = time.time()

def log_step(n, status, desc, actual="", expected="", duration=0.0, retries=0, retry_details=None):
    parts = [
        f"STEP_RESULT",
        f"n={n}",
        f"status={status}",
        f"desc={desc}",
        f"actual={actual}",
        f"expected={expected}",
        f"duration={duration}s",
        f"retries={retries}",
    ]
    if retry_details:
        for i, detail in enumerate(retry_details, 1):
            parts.append(f"retry_{i}={detail}")
    line = "|".join(parts)
    LOG.write(line + "\n")
    LOG.flush()
    print(line)

def log_meta():
    total = round(time.time() - RUN_START, 1)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"RUN_META|timestamp={ts}|duration={total}s|browser=Chromium (headless)"
    LOG.write(line + "\n")
    LOG.flush()
    print(line)

DATA_MODIFYING_VERBS = ("submit", "fill", "type", "click.*button", "delete", "create", "save", "send")
AUTH_INDICATORS = ("login", "sign in", "signin", "authenticate", "password", "/auth", "/login")

STEPS = [
    # (n, desc, expected) — populated by agent from TEST_PLAN
]

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1280, "height": 1800})

    # Initial navigation
    try:
        step_start = time.time()
        page.goto("${TEST_URL}", wait_until="domcontentloaded", timeout=30000)
        title = page.title()
        url = page.url.lower()
        if any(ind in title.lower() or ind in url for ind in AUTH_INDICATORS):
            # No login step in plan — block everything
            for n, desc, expected in STEPS:
                log_step(n, "BLOCKED", desc,
                         actual="Auth gate detected — no credentials provided",
                         expected=expected)
            log_meta()
            sys.exit(0)
    except Exception as e:
        duration = round(time.time() - step_start, 1)
        for n, desc, expected in STEPS:
            log_step(n, "BLOCKED", desc,
                     actual=f"Navigation failed: {e}",
                     expected=expected,
                     duration=duration)
        log_meta()
        sys.exit(1)

    # --- Execute each TEST_PLAN step ---
    # (Agent writes one try/except block per step, adapted to the actual action)

    # Example: navigation / read-only verification step
    try:
        step_start = time.time()
        page.wait_for_selector("text=Dashboard", timeout=10000)
        actual_title = page.title()
        duration = round(time.time() - step_start, 1)
        log_step(1, "PASSED", "Navigate to dashboard",
                 actual=f'Page title "{actual_title}" loaded',
                 expected="Dashboard page loads",
                 duration=duration)
    except Exception as e:
        duration = round(time.time() - step_start, 1)
        page.screenshot(path="_wat_run/screenshots/step_1_fail.png")
        log_step(1, "BLOCKED", "Navigate to dashboard",
                 actual=str(e),
                 expected="Dashboard page loads",
                 duration=duration)

    # Example: action step with production guard
    if IS_PRODUCTION:
        log_step(2, "BLOCKED", "Submit registration form",
                 actual="Skipped — production environment, read-only mode",
                 expected="Success toast appears after form submission")
    else:
        retries = 0
        retry_details = []
        last_error = ""
        step_start = time.time()
        for attempt in range(1, 4):
            try:
                page.get_by_role("button", name="Submit").click(timeout=10000)
                page.wait_for_selector("text=Registration complete", timeout=5000)
                duration = round(time.time() - step_start, 1)
                log_step(2, "PASSED", "Submit registration form",
                         actual='Success toast "Registration complete" appeared',
                         expected="Success toast appears after form submission",
                         duration=duration,
                         retries=attempt - 1,
                         retry_details=retry_details if retry_details else None)
                break
            except Exception as e:
                last_error = str(e)
                retry_details.append(f"Attempt {attempt}: {last_error}")
                retries = attempt
                if attempt == 3:
                    duration = round(time.time() - step_start, 1)
                    page.screenshot(path="_wat_run/screenshots/step_2_fail.png")
                    log_step(2, "BLOCKED", "Submit registration form",
                             actual=last_error,
                             expected="Success toast appears after form submission",
                             duration=duration,
                             retries=retries,
                             retry_details=retry_details)

    # Example: assertion step (FAILED when action works but outcome is wrong)
    try:
        step_start = time.time()
        element = page.query_selector(".order-confirmation")
        if element:
            text = element.inner_text()
            duration = round(time.time() - step_start, 1)
            log_step(3, "PASSED", "Verify order confirmation message",
                     actual=f'Confirmation message "{text}" visible',
                     expected="Order confirmation message visible on page",
                     duration=duration)
        else:
            error_el = page.query_selector(".error-toast")
            actual = error_el.inner_text() if error_el else "Confirmation element not found, no error message visible"
            duration = round(time.time() - step_start, 1)
            page.screenshot(path="_wat_run/screenshots/step_3_fail.png")
            log_step(3, "FAILED", "Verify order confirmation message",
                     actual=actual,
                     expected="Order confirmation message visible on page",
                     duration=duration)
    except Exception as e:
        duration = round(time.time() - step_start, 1)
        page.screenshot(path="_wat_run/screenshots/step_3_fail.png")
        log_step(3, "BLOCKED", "Verify order confirmation message",
                 actual=str(e),
                 expected="Order confirmation message visible on page",
                 duration=duration)

    browser.close()

log_meta()
LOG.close()
```

**Execute the script:**

```bash
$PYTHON _wat_run/test_script.py 2>&1
```

**Read the log:**

```bash
cat _wat_run/log.txt
```

Parse each `STEP_RESULT|...` line to build the inline result list. Extract field values by splitting on `|` and then on `=` (first `=` only per token). Any step missing from the log (script crashed before reaching it) is marked `BLOCKED` with `actual=Script exited before this step was reached`.

Parse the `RUN_META` line to extract `timestamp`, `duration`, and `browser` for use in the report metadata line.

**Self-verify failures** — for any step logged as `FAILED` or `BLOCKED`, read the corresponding screenshot using the `Read` tool and confirm the failure is genuine (not a timing issue or transient overlay). If the screenshot shows a transient state (spinner, partial load), re-run that step in a short follow-up scratch script before finalising the result.

---

## Step 4: Clean Up

Always run this, regardless of success or failure:

```bash
rm -rf _wat_run/
```

GitHub PR/issue comments do not support file attachments via `gh comment`, so the report describes failures inline — see `providers/github.md`. Deleting screenshots at the end of this phase is safe.

---

## Completion

When this skill finishes, hand off to `skills/post-test-report/SKILL.md` with the inline result list, `TEST_URL`, and `IS_PRODUCTION` in scope.