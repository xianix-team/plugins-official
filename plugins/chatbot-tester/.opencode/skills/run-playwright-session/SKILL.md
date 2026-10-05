---
name: run-playwright-session
description: Phase 2 of chatbot-tester. Opens the target URL in headless Chromium, logs in if required, translates plain language widget hints to Playwright selectors, runs a responsiveness probe, and runs seven test categories against the chatbot (Conversation Flow only when a conversation_flow array is defined). If the bot does not complete a response to the initial probe within 60 seconds all categories are marked BLOCKED immediately and the session exits. Outputs structured category results with verbatim bot responses for all Q&A pairs.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Phase 2 — Run Playwright Session

This skill is invoked by the **orchestrator** agent. It is not a standalone slash command.

## Inputs

| Variable | Source | Description |
|---|---|---|
| `TEST_URL` | Phase 1 | The URL to open in the browser |
| `REQUIRES_LOGIN` | Phase 1 | `true` if login must be attempted before testing |
| `HAS_CONVERSATION_FLOW` | Phase 1 | `true` if the test block contains a `conversation_flow` array |
| `KNOWLEDGE` | orchestrator | Parsed contents of the `chatbot-test` block |
| `LITE_MODE` | orchestrator | `true` if no issue/work item was provided |

## Outputs

`CATEGORY_RESULTS` — a structured list with one entry per test category:

```
{
  category: string,
  status: "PASSED" | "FAILED" | "BLOCKED" | "NOT_RUN",
  detail: string,
  qa_pairs: [                          // only present for Functional Accuracy category
    { question, must_contain, actual_response, duration_ms }
  ],
  probe_results: [                     // for Fallback, Continuity, Empty Input categories
    { probe, actual_response, duration_ms }
  ],
  flow_steps: [                        // only present for Conversation Flow category
    { index, name, question, actual_response, duration_ms,
      chain_status }                   // "CONTINUE" | "STOPPED" | "NOT_RUN"
  ]
}
```

---

## Step 1: Detect Python and Check Chromium

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python)
$PYTHON -c "import playwright" 2>/dev/null || $PYTHON -m pip install playwright
$PYTHON -m playwright install chromium --with-deps 2>/dev/null || $PYTHON -m playwright install chromium
```

---

## Step 2: Translate Widget Hints

If `LITE_MODE=true` and `KNOWLEDGE` has no `widget` block, skip this step — no widget hints are available. Set `TRIGGER_SELECTORS` to `[]`, `READY_SELECTOR` and `RESPONSE_DONE_SELECTOR` to `null`.

Otherwise, run a short Playwright exploration script to capture the page's HTML structure, then use an LLM call to translate the plain language hints into CSS selectors or XPath expressions.

`KNOWLEDGE.widget.trigger_hint` accepts two forms:
- **String** — a single trigger (click once to open the widget). Wrap it in a one-element list: `TRIGGER_SELECTORS = [selector]`.
- **Array of strings** — a sequence of intermediate navigation steps clicked in order before the widget/chat input is reachable (e.g. "open a menu", "pick an instance from a list", "switch to a tab"). Translate **each** entry independently into its own selector, in the same order, producing `TRIGGER_SELECTORS = [selector_1, selector_2, ...]`. Each step is resolved and clicked only after the previous step's click completes and the resulting selector becomes visible — later steps may depend on DOM elements that don't exist until the earlier click happens, so do not pre-resolve all selectors up front from the initial page state.

- `KNOWLEDGE.widget.ready_hint` → `READY_SELECTOR`
- `KNOWLEDGE.widget.response_done_hint` → `RESPONSE_DONE_SELECTOR`

If translation fails for a hint, apply the per-variable fallback below. These are **last-resort** generic selectors — they match by common conventions and may hit unrelated elements on complex pages. Prefer a successful LLM translation over any fallback. For a failed step within a `trigger_hint` array, apply the `TRIGGER_SELECTORS` fallback to that step only — leave successfully translated steps as-is.

| Variable | Fallback selector (try in order, use first that matches) |
|---|---|
| `TRIGGER_SELECTORS` (per step) | `button[aria-label*="chat" i], button[title*="chat" i], [class*="chat-trigger"], [class*="chat-button"], [id*="chat-button"]` |
| `READY_SELECTOR` | `input[type=text]:not([disabled]), textarea:not([disabled])` |
| `RESPONSE_DONE_SELECTOR` | 1. `.typing-indicator, .chat-loading, [class*="typing"]` disappears (wait for absence); 2. `button[type=submit]:not([disabled]), button.send:not([disabled])` re-enables; 3. `input[type=text]:not([disabled]), textarea:not([disabled])` re-enables |

If a fallback selector matches multiple elements, prefer the one deepest inside a chat/widget container (e.g. `[class*="chat"], [class*="widget"], [id*="chat"]`).

---

## Step 2.5: Generate Continuity Probes

**Skip this step entirely if `HAS_CONVERSATION_FLOW=true`** — conversation flow testing supersedes the auto-generated probe. Set `CONTINUITY_PROBES={}`.

Before writing the test script, generate a topic-specific follow-up question for **each** Q&A pair so the probe can be sent immediately after the first passing pair.

**If `KNOWLEDGE` has a `knowledge` array with at least one entry**, make a single batched LLM call:

```
For each question below, generate one short follow-up question (max 12 words) that:
- Is topically related to that specific question
- Only makes sense if the chatbot remembers what it just answered
- Does not repeat the original question
- Is natural conversational English

Questions:
{for each pair: "{index}: {question}"}

Return a JSON array: [{"index": 0, "probe": "..."}, ...]
```

Store the parsed list as `CONTINUITY_PROBES` (a dict keyed by Q&A pair index).

**If no `knowledge` array exists** (lite mode or no Q&A pairs), set:
`CONTINUITY_PROBE_FALLBACK = "What else can you tell me about that topic?"`

---

## Step 3: Write and Execute Test Script

Create directory `_cbt_run/` and write `_cbt_run/test_script.py`.

The script must:
- Use **sync Playwright API** (not async)
- Open `TEST_URL` in headless Chromium
- Use a 90-second timeout for all `wait_for_selector` calls (AI chatbot responses can take 30–60 s)
- Log each result as a pipe-delimited line to `_cbt_run/log.txt`:
  `CATEGORY_RESULT|{category}|{status}|{detail}|{duration_ms}`
  `QA_RESULT|{index}|{question}|{actual_response}|{duration_ms}`
  `PROBE_RESULT|{category}|{probe_label}|{actual_response}|{duration_ms}`
- Always close the browser in a `finally` block

### Login (if REQUIRES_LOGIN=true)

Before opening the chatbot, attempt login using `username` (literal value) and the env var named in `password_env`:

```python
import os, json, pathlib

username = KNOWLEDGE["credentials"]["username"]                          # literal value from block
password_env_key = KNOWLEDGE["credentials"]["password_env"]             # e.g. "CHATBOT-TEST-PASSWORD"
password = os.environ.get(password_env_key, "")

# Fallback: read from ~/.chatbot-tester-creds.json if env var is empty
if not password:
    creds_file = pathlib.Path.home() / ".chatbot-tester-creds.json"
    if creds_file.exists():
        try:
            creds = json.loads(creds_file.read_text())
            password = creds.get(password_env_key, "")
        except Exception:
            pass

page.goto(TEST_URL)
try:
    # Step 1: fill the username/email field
    username_field = page.wait_for_selector(
        'input[type=email], input[type=text][name*=user], input[name*=email], input[id*=user], input[id*=email]',
        timeout=10000
    )
    username_field.fill(username)

    # Step 2: check if a password field is already visible (single-step form)
    #         or if we need to submit the email first (two-step form)
    password_field = page.query_selector('input[type=password]')
    if not password_field:
        # Two-step flow: submit the email, then wait for the password field to appear
        page.keyboard.press('Enter')
        password_field = page.wait_for_selector('input[type=password]', timeout=10000)

    # Step 3: fill password and submit
    password_field.fill(password)
    page.keyboard.press('Enter')

    # Step 4: wait for navigation — try networkidle first, fall back to domcontentloaded
    # (apps with WebSockets or long-polling never reach networkidle)
    try:
        page.wait_for_load_state('networkidle', timeout=15000)
    except Exception:
        page.wait_for_load_state('domcontentloaded', timeout=15000)

    log('CATEGORY_RESULT|login|PASSED|Login succeeded|' + str(duration))
except Exception as e:
    log('CATEGORY_RESULT|login|BLOCKED|Login failed: ' + str(e) + '|0')
    categories = ['ui_availability', 'functional_accuracy', 'fallback_handling',
                  'response_latency', 'conversation_continuity']
    if HAS_CONVERSATION_FLOW:
        categories.append('conversation_flow')
    categories.append('empty_input_handling')
    for category in categories:
        log(f'CATEGORY_RESULT|{category}|NOT_RUN|Login failed — category not executed|0')
    sys.exit(0)
```

### Timeout handling (applies to every category)

Wrap each category block in a `try/except`. If a `playwright.sync_api.TimeoutError` (or its alias `playwright._impl._errors.TimeoutError`) is raised, log the category as FAILED with a fixed detail string and continue to the next category — do **not** let the exception propagate and crash the script:

```python
except playwright.sync_api.TimeoutError:
    log(f'CATEGORY_RESULT|{category}|FAILED|90-second selector timeout — chatbot did not respond in time|0')
```

All remaining categories must still execute after a timeout in an earlier category.

---

### Category 1: UI Availability

```python
ui_available = False
try:
    # Login already navigated to TEST_URL — only navigate here if login was not performed
    if not REQUIRES_LOGIN:
        page.goto(TEST_URL)
        page.wait_for_load_state('networkidle')

    # 2. Walk the trigger sequence in order — each step is resolved against the
    #    page state left behind by the previous click, since later steps may
    #    depend on elements that only exist after an earlier click (e.g. a menu
    #    that must open before the next selector appears).
    for step_selector in TRIGGER_SELECTORS:
        step_element = page.wait_for_selector(step_selector, timeout=90000)
        step_element.click()

    # 3. Wait for the input field to be ready
    page.wait_for_selector(READY_SELECTOR, timeout=90000)

    log('CATEGORY_RESULT|ui_availability|PASSED|Widget opened and input field ready|0')
    ui_available = True
except playwright.sync_api.TimeoutError:
    log('CATEGORY_RESULT|ui_availability|FAILED|90-second selector timeout — chatbot did not respond in time|0')
```

### Bot Responsiveness Probe

Runs immediately after Category 1 PASSES (`ui_available = True`). Sends a single "Hello" message and waits up to **60 seconds** in two stages: 30 seconds for any bot element to appear, then 30 seconds for the response to complete (using `RESPONSE_DONE_SELECTOR`). This catches both completely silent bots and bots that show a "Thinking..." indicator but never finish. If either stage times out, all remaining categories are marked `BLOCKED` and the script exits.

Skip this probe if `ui_available = False` (widget did not open); the remaining categories will each handle their own failures independently.

```python
_PROBE_BLOCKED_REASON = 'Bot did not complete a response to initial probe within 60 seconds — all test categories skipped'

if ui_available:
    try:
        probe_input = page.wait_for_selector(READY_SELECTOR, timeout=10000)
        probe_input.fill('Hello')
        page.keyboard.press('Enter')
        # Stage 1: wait for any bot element to appear (catches completely silent bots)
        page.wait_for_selector(
            '[class*="bot-message"], [class*="assistant"], [data-role="bot"], '
            '[class*="chat"] [class*="message"]:last-child, '
            '[class*="widget"] [class*="message"]:last-child',
            timeout=30000
        )
        # Stage 2: wait for the response to complete, not just appear (catches bots stuck in "Thinking...")
        if RESPONSE_DONE_SELECTOR:
            page.wait_for_selector(RESPONSE_DONE_SELECTOR, timeout=30000)
        # Probe passed — bot responded and completed, continue to all categories
    except playwright.sync_api.TimeoutError:
        _blocked = ['functional_accuracy', 'fallback_handling', 'response_latency',
                    'conversation_continuity']
        if HAS_CONVERSATION_FLOW:
            _blocked.append('conversation_flow')
        _blocked.append('empty_input_handling')
        for _cat in _blocked:
            log(f'CATEGORY_RESULT|{_cat}|BLOCKED|{_PROBE_BLOCKED_REASON}|0')
        sys.exit(0)
```

### Category 2: Functional Accuracy

**If `LITE_MODE=true` or `KNOWLEDGE` has no `knowledge` array**, skip this category and log:
`CATEGORY_RESULT|functional_accuracy|BLOCKED|Skipped — no Q&A pairs in test case|0`

Otherwise, initialise `continuity_done = False` before the loop, then for each Q&A pair in `KNOWLEDGE.knowledge`, wrap in a per-question try/except:

```python
try:
    start = time.time()
    input_field = page.wait_for_selector(READY_SELECTOR, timeout=90000)
    input_field.fill(question)
    page.keyboard.press('Enter')

    page.wait_for_selector(RESPONSE_DONE_SELECTOR, timeout=90000)

    response_text = page.locator('[class*="bot-message"], [class*="assistant"], [data-role="bot"]').last.inner_text()

    # Fallback: if the primary locator returned nothing, widen the search to any
    # element inside a chat/widget container that appeared after the question was sent
    if not response_text.strip():
        response_text = page.locator(
            '[class*="chat"] [class*="message"]:last-child, '
            '[class*="widget"] [class*="message"]:last-child, '
            '[class*="response"]:last-child'
        ).last.inner_text()

    if not response_text.strip():
        response_text = '__RESPONSE_CAPTURE_FAILED__'

    duration_ms = int((time.time() - start) * 1000)

    log(f'QA_RESULT|{index}|{question}|{response_text}|{duration_ms}')

    # Inline continuity check — skipped when HAS_CONVERSATION_FLOW=True (flow testing
    # supersedes the auto-probe). Otherwise send the probe after the first passing pair.
    # "Passing" uses must_contain substring check if present; falls back to any non-empty
    # response when only expected_answer is declared (LLM judge is authoritative in Phase 3).
    if not HAS_CONVERSATION_FLOW and not continuity_done and response_text != '__RESPONSE_CAPTURE_FAILED__':
        must_contain = step.get('must_contain', [])
        pair_passes = all(term.lower() in response_text.lower() for term in must_contain) if must_contain else bool(response_text.strip())
        if pair_passes:
            continuity_probe = CONTINUITY_PROBES[index]
            try:
                c_start = time.time()
                c_input = page.wait_for_selector(READY_SELECTOR, timeout=90000)
                c_input.fill(continuity_probe)
                page.keyboard.press('Enter')
                page.wait_for_selector(RESPONSE_DONE_SELECTOR, timeout=90000)
                continuity_response = page.locator('[class*="bot-message"], [class*="assistant"], [data-role="bot"]').last.inner_text()
                if not continuity_response.strip():
                    continuity_response = page.locator(
                        '[class*="chat"] [class*="message"]:last-child, '
                        '[class*="widget"] [class*="message"]:last-child, '
                        '[class*="response"]:last-child'
                    ).last.inner_text()
                c_duration_ms = int((time.time() - c_start) * 1000)
                log(f'PROBE_RESULT|conversation_continuity|{continuity_probe}|{continuity_response}|{c_duration_ms}')
                log(f'CONTINUITY_ANCHOR|{index}')
            except playwright.sync_api.TimeoutError:
                log(f'PROBE_RESULT|conversation_continuity|{continuity_probe}|90-second selector timeout — chatbot did not respond in time|90000')
                log(f'CONTINUITY_ANCHOR|{index}')
            continuity_done = True
except playwright.sync_api.TimeoutError:
    log(f'QA_RESULT|{index}|{question}|90-second selector timeout — chatbot did not respond in time|90000')
```

### Category 3: Fallback / Error Handling

Send two probes:
1. `"asdfghjkl zxcvbnm qwerty"` — pure gibberish
2. `"What is the capital of Mars?"` — out-of-scope question

For each probe, capture the bot response and verify:
- Response is non-empty
- Response does not contain a raw exception, stack trace, or `500` / `error` indicators

Wrap each probe send in a try/except for `playwright.sync_api.TimeoutError` and log:
`PROBE_RESULT|fallback_handling|{probe_label}|90-second selector timeout — chatbot did not respond in time|90000`

### Category 4: Response Latency

Record `duration_ms` for each Q&A pair message send (already captured in Category 2). Compute the average. Apply this threshold table and log the average latency in `detail`:

| Average response time | Verdict |
|---|---|
| ≤ 30 s | PASSED |
| 31 – 60 s | PARTIAL — responses were slow but within the acceptable ceiling for AI chatbots |
| > 60 s | FAILED — responses exceeded the 60-second ceiling |

If all captured `duration_ms` values equal `90000` (every response timed out), do not compute or report an average. Instead log:
`CATEGORY_RESULT|response_latency|FAILED|All responses timed out — latency could not be measured|0`

If `LITE_MODE=true` and no Q&A pairs were run, measure latency on the fallback probes instead.

### Category 5: Conversation Continuity

Four cases:

**Case A — `HAS_CONVERSATION_FLOW=True`:** Conversation Flow category supersedes the auto-probe. Do not send a probe. Log:
`CATEGORY_RESULT|conversation_continuity|NOT_RUN|conversation_flow defined — continuity probe superseded by Conversation Flow category|0`

**Case B — `continuity_done = True`:** The probe already ran inline after the first passing Q&A pair. No action needed — results are already logged. Log:
`CATEGORY_RESULT|conversation_continuity|DONE_INLINE|Probe ran inline after Q&A pair {continuity_anchor_index}|0`

**Case C — Lite mode or no `knowledge` array:** No Q&A pairs were run. Send `CONTINUITY_PROBE_FALLBACK` after the fallback probes have been sent:
`PROBE_RESULT|conversation_continuity|{CONTINUITY_PROBE_FALLBACK}|{actual_response}|{duration_ms}`

Wrap in a try/except for `playwright.sync_api.TimeoutError` and log:
`PROBE_RESULT|conversation_continuity|{CONTINUITY_PROBE_FALLBACK}|90-second selector timeout — chatbot did not respond in time|90000`

**Case D — Q&A pairs were run but none passed the inline check:** No anchor pair was found. Do not send a probe. Log:
`CATEGORY_RESULT|conversation_continuity|NOT_RUN|No passing Q&A pair found — continuity probe skipped|0`

### Category 6: Conversation Flow

**Skip this category entirely if `HAS_CONVERSATION_FLOW=False`.** Log:
`CATEGORY_RESULT|conversation_flow|NOT_RUN|No conversation_flow defined in test block|0`

Otherwise, iterate through each step in `KNOWLEDGE.conversation_flow` in order. Maintain `chain_stopped = False` and `chain_stop_index = None` before the loop.

```python
conversation_flow = KNOWLEDGE.get('conversation_flow', [])
chain_stopped = False
chain_stop_index = None

for index, step in enumerate(conversation_flow):
    if chain_stopped:
        log(f'FLOW_RESULT|{index}|{step.get("name", "")}|{step["question"]}|NOT_RUN — chain stopped at step {chain_stop_index}|0|NOT_RUN')
        continue

    try:
        start = time.time()
        input_field = page.wait_for_selector(READY_SELECTOR, timeout=90000)
        input_field.fill(step['question'])
        page.keyboard.press('Enter')
        page.wait_for_selector(RESPONSE_DONE_SELECTOR, timeout=90000)

        response_text = page.locator('[class*="bot-message"], [class*="assistant"], [data-role="bot"]').last.inner_text()
        if not response_text.strip():
            response_text = page.locator(
                '[class*="chat"] [class*="message"]:last-child, '
                '[class*="widget"] [class*="message"]:last-child, '
                '[class*="response"]:last-child'
            ).last.inner_text()
        if not response_text.strip():
            response_text = '__RESPONSE_CAPTURE_FAILED__'

        duration_ms = int((time.time() - start) * 1000)

        # Chain-stop decision: must_contain substring check if present;
        # otherwise continue optimistically (LLM judge is authoritative in Phase 3).
        must_contain = step.get('must_contain', [])
        if response_text == '__RESPONSE_CAPTURE_FAILED__':
            chain_status = 'STOPPED'
            chain_stopped = True
            chain_stop_index = index
        elif must_contain:
            if all(term.lower() in response_text.lower() for term in must_contain):
                chain_status = 'CONTINUE'
            else:
                chain_status = 'STOPPED'
                chain_stopped = True
                chain_stop_index = index
        else:
            chain_status = 'CONTINUE'

        log(f'FLOW_RESULT|{index}|{step.get("name", "")}|{step["question"]}|{response_text}|{duration_ms}|{chain_status}')

    except playwright.sync_api.TimeoutError:
        log(f'FLOW_RESULT|{index}|{step.get("name", "")}|{step["question"]}|90-second selector timeout — chatbot did not respond in time|90000|STOPPED')
        chain_stopped = True
        chain_stop_index = index
```

Log lines for this category use the prefix `FLOW_RESULT` (not `CATEGORY_RESULT`) so the parser can distinguish them from category-level entries.

### Category 7: Empty Input Handling

```python
try:
    input_field = page.wait_for_selector(READY_SELECTOR, timeout=90000)
    input_field.fill('')
    page.keyboard.press('Enter')
    page.wait_for_timeout(3000)
    # Verify: no crash, no empty error screen, page is still interactive
except playwright.sync_api.TimeoutError:
    log('CATEGORY_RESULT|empty_input_handling|FAILED|90-second selector timeout — chatbot did not respond in time|0')
```

Verify the input field is still present and interactable after the empty submission.

---

## Step 4: Execute Script

```bash
$PYTHON _cbt_run/test_script.py 2>&1 | tee _cbt_run/execution.log
```

---

## Step 5: Parse Log

Read `_cbt_run/log.txt`. Parse each pipe-delimited line into the `CATEGORY_RESULTS` structure.

**If `log.txt` is missing or empty**, the Playwright script crashed before logging any results. Read the last 20 lines of `_cbt_run/execution.log` and surface them as a BLOCKED overall result:

```
CATEGORY_RESULT|script_crash|BLOCKED|Playwright script exited before writing any results. Last output: {last_20_lines_of_execution.log}|0
```

Pass this directly to `skills/post-test-report/SKILL.md` — skip Phase 3. The overall verdict is `BLOCKED`.

**If the login entry has status `BLOCKED`:** all subsequent categories will be `NOT_RUN`. Skip Phase 3 entirely — there are no responses to judge. Pass `CATEGORY_RESULTS` directly to `skills/post-test-report/SKILL.md`. The overall verdict is `BLOCKED`.

**If any Q&A pair has `actual_response` equal to `__RESPONSE_CAPTURE_FAILED__`**, replace it with the display string `(response capture failed — no matching bot message element found)` before passing to Phase 3. The judge must mark that pair FAIL.

For any FAILED or BLOCKED category, include the error detail captured from the exception or timeout in the `detail` field of `CATEGORY_RESULTS`.

---

## Step 6: Clean Up

```bash
rm -rf _cbt_run/
```

Always run this step, even if the script failed.

---

## Completion

Hand off to `skills/judge-responses/SKILL.md` with `CATEGORY_RESULTS` and `KNOWLEDGE` in scope.
