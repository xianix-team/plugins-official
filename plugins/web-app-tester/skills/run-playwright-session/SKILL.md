---
name: run-playwright-session
description: Phase 2 of web-app-tester. Resolves the playwright-cli wrapper, ensures a Chromium browser is cached, opens a single headless session, and executes the test plan adaptively — taking a DOM snapshot before every interaction, retrying failed steps up to 3 times, and capturing screenshots on the final retry. Honours PRODUCTION_WARNING by skipping data-modifying steps. Always cleans up temp files. Outputs an inline, fully-documented per-step result list (action, expected outcome, observed outcome, attempts, status, screenshot).
disable-model-invocation: true
---

# Phase 2 — Run Playwright Session

This skill is invoked by the **orchestrator** agent. It is not a standalone slash command.

## Inputs

| Variable | Source | Description |
|---|---|---|
| `TEST_URL` | gather-test-context | URL to test against |
| `PRODUCTION_WARNING` | gather-test-context | If `true`, skip any data-modifying step |
| `TEST_PLAN` | gather-test-context | Numbered/bulleted list of test steps |

## Outputs

A list of result entries (held inline, not written to a file). **Every step is documented in full** — including PASSED ones — so Phase 3 can render a complete test execution record:

```
{
  n,                                      # step number (1-based, matches TEST_PLAN order)
  desc,                                   # plain-language description from the test plan
  action: {
    verb,                                 # navigate | click | fill | verify | wait | dismiss | other
    target,                               # human label of the target element (role + accessible name from the snapshot YAML), or URL for navigate
    ref,                                  # the `eN` reference used from the snapshot, or null for navigate
    input                                 # value entered for fill; "[REDACTED]" for password/secret/token fields; null otherwise
  },
  expected,                               # short plain-language statement of what the step should produce
  observed,                               # short plain-language statement of what the post-action snapshot showed
  status: PASSED | FAILED | BLOCKED,
  attempts,                               # 1..3 — how many tries it took (always 1 for first-try PASSED)
  reason,                                 # null for PASSED; short failure/blocked cause otherwise
  screenshot                              # path to _wat_screenshot_N.png if captured, else null
}
```

Capture these fields as you execute each step — they are mandatory inputs for the Phase 3 report and cannot be reconstructed afterwards. Keep `desc`, `expected`, and `observed` in plain business language (one sentence each); they are read by developers, QA, and product owners in the posted comment.

## Execution Rules (strictly enforced)

- Use `playwright-cli` for all browser testing — execute steps adaptively via the command loop, track results inline.
- Never launch multiple browser sessions for one test run — always use session `-s=wat`.
- Always delete temp files (`_wat_pcli`, `_wat_screenshot_*.png`) after the run, even if execution fails.
- Never install npm packages globally except `@playwright/cli` itself, which is required to run.

---

## Step 1: Prepare Playwright CLI and Chromium

**Resolve playwright-cli once and write a wrapper script `_wat_pcli`:**

Run this single block — it checks, installs if needed, and writes `_wat_pcli` regardless of whether the binary lands on PATH:

```bash
if command -v playwright-cli > /dev/null 2>&1; then
  printf '#!/bin/sh\nplaywright-cli "$@"\n' > _wat_pcli && chmod +x _wat_pcli && echo "CLI_READY (PATH)"
else
  npm install -g @playwright/cli@latest 2>&1
  if command -v playwright-cli > /dev/null 2>&1; then
    printf '#!/bin/sh\nplaywright-cli "$@"\n' > _wat_pcli && chmod +x _wat_pcli && echo "CLI_READY (installed)"
  else
    PCLI_JS="$(npm root -g)/@playwright/cli/playwright-cli.js"
    printf '#!/bin/sh\nnode "%s" "$@"\n' "$PCLI_JS" > _wat_pcli && chmod +x _wat_pcli && echo "CLI_READY (node path)"
  fi
fi
```

All three outcomes produce a working `_wat_pcli` wrapper. All browser commands in Step 2 use `./_wat_pcli` — the path is resolved once here and never re-evaluated per command.

**Critical:** the package is `@playwright/cli` (the playwright-cli tool), NOT `playwright` (the Node.js library). These are different packages with different behaviour. Never substitute one for the other.

**Check whether Playwright Chromium is already cached before attempting any install:**

```bash
node -e "const {chromium}=require('playwright');chromium.executablePath()" 2>/dev/null \
  && echo "BROWSER_READY" || echo "BROWSER_MISSING"
```

If output is `BROWSER_MISSING` → install the binary **and** its system shared libraries. Try `--with-deps` first (this is what gets `libnss3`, `libglib-2.0.so.0`, `libatk-1.0.so.0`, `libdbus-1.so.3`, etc. installed via `apt-get`). If that path is unavailable (no root / sandboxed runner), fall back to the binary-only install — system libs must already be baked into the environment in that case:

```bash
npx --yes playwright@1.49.0 install --with-deps chromium 2>&1 \
  || npx --yes playwright@1.49.0 install chromium 2>&1
```

**Preflight launch — catch missing system libraries before executing the test plan:**

A cached binary is not enough. Headless Chromium also needs `libnss3`, `libnspr4`, `libglib-2.0.so.0`, `libatk-1.0.so.0`, `libdbus-1.so.3`, and friends. Try a single launch+close cycle. If it fails, the test plan cannot run — **do not iterate the steps and accumulate 9× retry timeouts.**

```bash
LAUNCH_PROBE=$(node -e "const{chromium}=require('playwright');chromium.launch({headless:true}).then(b=>b.close()).then(()=>console.log('LAUNCH_OK')).catch(e=>{console.error('LAUNCH_FAIL: '+e.message);process.exit(1);})" 2>&1)
echo "$LAUNCH_PROBE"
```

If `LAUNCH_PROBE` contains `LAUNCH_OK` → continue to Step 2.

If `LAUNCH_PROBE` contains `LAUNCH_FAIL` and any of `libnss3`, `libglib`, `libatk`, `libdbus`, `shared libraries`, `Host system is missing dependencies`, `install-deps`, `playwright install` → **immediately** mark every step in `TEST_PLAN` as `🔴 BLOCKED` with reason:

```
Sandbox image missing Chromium system shared libraries (libnss3 / libglib / libatk / libdbus / etc.).
playwright install-deps requires root and is not available in this runner. Rebuild the runner image with the
system libraries baked in. Recommended Dockerfile additions:

  ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
  RUN npm install -g @anthropic-ai/claude-code @playwright/cli playwright \
      && playwright install --with-deps chromium \
      && chmod -R a+rX /ms-playwright \
      && rm -rf /var/lib/apt/lists/* /root/.npm

Or base the image on mcr.microsoft.com/playwright:v1.49.0-jammy which already includes Chromium + deps.
```

Then skip directly to Step 3 (cleanup) — do **not** attempt `open`, retries, or screenshots. The browser will not launch and every retry will fail identically.

---

## Step 2: Open Browser and Execute Steps Adaptively

**Navigate to the test URL:**

```bash
./_wat_pcli -s=wat open "${TEST_URL}"
```

Use `open` for initial navigation — not `goto`. `open` launches the browser session and loads the URL in one step. `goto` requires an existing open page and will fail with exit code 1 on session start.

**Take an initial snapshot to confirm the page loaded correctly:**

```bash
./_wat_pcli -s=wat snapshot
```

Read the YAML output. If the snapshot shows a login/auth page and the test plan does not include login steps, mark all steps `BLOCKED` with reason `Auth gate detected — no credentials provided` and skip to Step 3.

**For each step in TEST_PLAN, execute adaptively:**

1. **Restate the step before acting.** From the test-plan line, derive and hold in memory:
   - `desc` — the plain-language step description (verbatim from the plan, lightly rewritten if the plan was bullet-formatted).
   - `expected` — one sentence describing what the step should produce (e.g. "Dashboard page loads and shows the user's name in the header"). If the plan does not state an expected outcome explicitly, infer the most reasonable one from the action verb.

2. **Map the action verb** to the appropriate command:
   - Navigate / Go to (mid-flow) → `./_wat_pcli -s=wat goto <url>`
   - Click / Tap → `./_wat_pcli -s=wat click <ref>`
   - Fill / Enter / Type → `./_wat_pcli -s=wat fill <ref> "<text>"`
   - Verify / Assert / Confirm / Expect / Check → `./_wat_pcli -s=wat snapshot` then inspect YAML for expected text or element

3. **Before every click or fill**, run `./_wat_pcli -s=wat snapshot` to get live element references from the current DOM. Use the `eN` references from the YAML output to target elements — do not guess CSS selectors. Record the chosen `eN` reference and the human label (role + accessible name) of the target into the result entry's `action.target` / `action.ref` fields.

4. **If `PRODUCTION_WARNING=true`:** skip any step that submits a form or performs a data-modifying action; mark those steps `BLOCKED` with reason `Skipped — production URL, read-only mode`. Still populate `desc`, `expected`, and `action` so the detailed log shows what would have been done.

5. **Redact sensitive input.** For `fill` steps where the target is a password, secret, token, API key, or any credentials field (detected from the field's accessible name / role / autocomplete attribute), record `action.input` as `[REDACTED]` instead of the literal value. Never log credentials.

6. **After each command**, run `./_wat_pcli -s=wat snapshot` to verify the outcome. Translate what you see into a one-sentence `observed` string (plain business language — e.g. "Order confirmation banner appeared with the new order ID"), then decide the status:
   - Expected text or element present → `PASSED`
   - Unexpected blocker (modal, banner, overlay) detected → dismiss it with `./_wat_pcli -s=wat click <dismiss-ref>` and retry the step (this counts toward the attempt tally; record the dismissal in `observed`)
   - Auth redirect detected → mark all remaining steps `BLOCKED` with reason `Auth gate detected mid-run`; still write each remaining step's `desc`, `expected`, and `action` to the result list
   - Error state or element missing → retry

7. **Retry logic:** up to 3 attempts total (1 initial + 2 retries) with 2-second waits between attempts. Increment the `attempts` counter on every try.
   ```bash
   sleep 2
   ```
   On the 3rd unsuccessful attempt, capture a screenshot, set `attempts = 3`, and mark the step `BLOCKED`:
   ```bash
   ./_wat_pcli -s=wat screenshot _wat_screenshot_N.png
   ```
   Set `screenshot` to the file path. For PASSED steps, leave `screenshot = null` — screenshots are only captured for the final-retry failure case.

8. **Track results inline** as you go (no JSON file). Append a fully populated result entry per step before moving on to the next one:
   ```
   {
     n: <step number>,
     desc: "<plain-language description>",
     action: { verb: "<verb>", target: "<element label or URL>", ref: "<eN or null>", input: "<value, [REDACTED], or null>" },
     expected: "<one sentence>",
     observed: "<one sentence>",
     status: PASSED | FAILED | BLOCKED,
     attempts: <1..3>,
     reason: <null or short failure cause>,
     screenshot: <null or "_wat_screenshot_N.png">
   }
   ```
   Do not collapse, summarise, or drop fields between steps — Phase 3 reads this list verbatim to build the per-step report.

Step statuses:
- `✅ PASSED` — step executed, expected outcome observed
- `❌ FAILED` — step executed, expected outcome NOT observed
- `🔴 BLOCKED` — step could not execute after 3 retries, auth gate detected, or skipped due to production URL

**Close the browser session after all steps complete:**

```bash
./_wat_pcli -s=wat close
```

Expected runtime: ~25–35 seconds for a 9-step plan on a cached browser.

---

## Step 3: Clean Up

Always run this, regardless of success or failure:

```bash
rm -f _wat_pcli _wat_screenshot_*.png
rm -rf .playwright-cli/
```

GitHub PR/issue comments do not support file attachments via `gh comment`, so the report describes screenshots inline as "captured at point of failure" rather than embedding them — see `providers/github.md`. Deleting the PNGs at the end of this phase is safe.

---

## Completion

When this skill finishes, hand off to `skills/post-test-report/SKILL.md` with the inline result list, `TEST_URL`, and `PRODUCTION_WARNING` in scope. The result list must contain one entry per step in `TEST_PLAN`, in order, each with **all** fields populated as specified in the Outputs section above. If any field is genuinely not applicable for a step (e.g. `action.ref` for a navigate, `action.input` for a click), set it to `null` rather than omitting it.
