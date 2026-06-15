# Output Style: Web App Test Execution Report

This style guide defines the exact format of the test execution report posted as a comment by the `orchestrator` agent.

---

## Audience

Reports are read by **developers, QA engineers, and product owners** reviewing a PR or issue. Write step descriptions and observations in plain language — describe what was tested and what was seen, not which Playwright API was called.

---

## Report Structure

The report is posted as a single comment. Use this exact structure:

```markdown
🤖 web-app-tester (Webwright) — Test Execution Report
URL tested: {TEST_URL}
{IF IS_PRODUCTION}⚠️ Running in production environment. Executed read-only steps only.{END IF}
Tested: {TIMESTAMP} · Browser: Chromium (headless) · Duration: {DURATION}
Total: {N} | ✅ Passed: {X} | ❌ Failed: {Y} | 🔴 Blocked: {Z}
Overall: **{PASSED | FAILED | BLOCKED}**

---

{IF X > 0}
<details open>
<summary>✅ Passed Test Cases ({X})</summary>

| # | Test Case | What was verified |
| --- | --- | --- |
| 1 | {test case description} | {what was observed — page title, element found, text matched, URL reached} |
| 2 | {test case description} | {what was observed} |

</details>
{END IF}

{IF Y + Z > 0}
<details open>
<summary>❌ Failed / 🔴 Blocked Test Cases ({Y + Z})</summary>

**Test Case {N} — {test case description}**
Status: ❌ FAILED
Expected: {expected outcome from the test plan}
Actual: {what was actually observed — error message, wrong text, incorrect URL, missing element}
Duration: {X.Xs}

**Test Case {N} — {test case description}**
Status: 🔴 BLOCKED
Reason: {element not found / timeout / page error / auth gate / production skip}
Attempts:
- Attempt 1: {what happened — timeout duration, exception message, element state}
- Attempt 2: {what happened}
- Attempt 3: {what happened}
Duration: {X.Xs}
Screenshot: {captured at point of failure | not available}

</details>
{END IF}
```

---

## Metadata Line

Always include the metadata line immediately after the production warning (if any) and before the step counts:

```text
Tested: {TIMESTAMP} · Browser: Chromium (headless) · Duration: {DURATION}
```

- `{TIMESTAMP}` — ISO 8601 date-time of when the test run started (e.g. `2026-06-11T14:32:05Z`)
- `{DURATION}` — total elapsed time from script start to script exit (e.g. `42.3s`)
- Browser is always `Chromium (headless)` for this plugin

---

## Passed Test Cases Section

Use a `<details open>` block so the section renders expanded by default. The table has three columns: test case number, test case description, and **"What was verified"** — a one-line description of the actual observed outcome confirming the test case passed.

| Column | Content |
| --- | --- |
| `#` | Test case number |
| `Test Case` | Business-language test case description (same as test plan) |
| `What was verified` | What was actually observed to confirm the test case passed |

**"What was verified" examples:**

| ❌ Avoid | ✅ Prefer |
| --- | --- |
| `PASSED` | `Page title "Dashboard" loaded within 1.2s` |
| `Element found` | `Login button visible with label "Sign In"` |
| `Text matched` | `Success toast "Order placed" appeared after form submission` |
| `No errors` | `Navigated to /checkout, cart summary displayed with 2 items` |

Omit this section entirely if X == 0 (no passed test cases).

---

## Failed / Blocked Test Cases Section

Use a `<details open>` block. Each failed or blocked test case gets its own entry.

### For FAILED test cases

A test case is FAILED when the action completed but the expected outcome was not observed.

```markdown
**Test Case {N} — {test case description}**
Status: ❌ FAILED
Expected: {what the test plan said should happen}
Actual: {what was actually observed — be specific: error text, page state, URL, element found instead}
Duration: {X.Xs}
```

The `Expected:` field comes from the test plan's intent. The `Actual:` field comes from what the script captured: page title, visible text, URL, error message, or element state at the time of the assertion.

### For BLOCKED test cases

A test case is BLOCKED when it could not execute — the action itself could not be performed.

```markdown
**Test Case {N} — {test case description}**
Status: 🔴 BLOCKED
Reason: {why the test case could not execute}
Attempts:
- Attempt 1: {outcome — timeout duration, exception message, element state}
- Attempt 2: {outcome}
- Attempt 3: {outcome}
Duration: {X.Xs}
Screenshot: {captured at point of failure | not available}
```

If the test case was blocked for a non-retry reason (auth gate, production skip, script crash before reaching it), omit the `Attempts:` list and use only the `Reason:` field:

```markdown
**Test Case {N} — {test case description}**
Status: 🔴 BLOCKED
Reason: Auth gate detected — no credentials provided
```

```markdown
**Test Case {N} — {test case description}**
Status: 🔴 BLOCKED
Reason: Skipped — production URL, read-only mode
```

Omit the Failed / Blocked section entirely if Y + Z == 0 (all test cases passed).

---

## Overall Result Logic

| Condition | Overall Result |
| --- | --- |
| All steps passed | **PASSED** |
| One or more steps failed (all steps were attempted) | **FAILED** |
| One or more steps could not execute | **BLOCKED** |

A run with both FAILED and BLOCKED steps uses **BLOCKED** as the overall result.

---

## Step Description Format

Write step descriptions in business language — describe the **user action and observed outcome**, not the technical mechanism.

| ❌ Avoid | ✅ Prefer |
| --- | --- |
| `mcp__playwright__browser_click called on #submit-btn` | `Click the Submit button on the registration form` |
| `browser_fill input[name=email]` | `Fill in the email address field with a valid address` |
| `assert .toast-message contains text` | `Verify success toast appears after form submission` |

---

## Step Status Rules

| Status | When to use |
|---|---|
| ✅ PASSED | Action completed AND expected outcome was observed |
| ❌ FAILED | Action completed BUT expected outcome was NOT observed (wrong text, element absent, wrong page) |
| 🔴 BLOCKED | Action could not be executed after 3 retries (element not found, navigation error, timeout, crash) |

A step that was **skipped due to production environment read-only mode** is marked `🔴 BLOCKED` with reason: `Skipped — production environment, read-only mode`.

---

## Retry Log (optional)

For BLOCKED steps, if retry attempts produced informative output (e.g. element selector, error message), include a brief retry summary:

```markdown
**Test Case 3 — Verify order confirmation message**
Reason: Element `.order-confirmation` not found after 3 retries (5s between each)
Attempts: 1 — timeout after 5s; 2 — timeout after 5s; 3 — timeout after 5s
Screenshot: captured at point of failure
```

---

## Production Notice

If `IS_PRODUCTION=true`, the report must include this notice immediately after the URL line:

```
⚠️ Running in production environment. Executed read-only steps only.
```

Test cases that were skipped due to this restriction are listed in the table as `🔴 BLOCKED` with reason `Skipped — production environment, read-only mode`.

---

## Safety Rules (always enforced)

1. Never include authentication tokens, API keys, passwords, or secrets in any comment
2. Never describe credential values — redact them as `[REDACTED]` if they appear in test data
3. Screenshots are referenced only for FAILED and BLOCKED steps
4. The report comment is always a single comment — never split across multiple comments

---

## Report Boundaries (strictly enforced)

**The report is strictly bounded to the sections defined above.** Never add content outside this structure. Prohibited additions include:

- Suggested fixes or workarounds
- Recommendations or advice
- Root cause analysis
- Next steps or action items
- Code snippets or diffs
- Explanatory commentary or observations

The report is a test execution record, not a debugging guide. Any insight beyond pass/fail/blocked belongs in a separate human review — not in this comment.
