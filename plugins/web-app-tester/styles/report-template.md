# Output Style: Web App Test Execution Report

This style guide defines the exact format of the test execution report posted as a GitHub comment by the `orchestrator` agent.

---

## Audience

Reports are read by **developers, QA engineers, and product owners** reviewing a PR or issue. Write step descriptions in plain language — describe what was tested, not which Playwright API was called.

---

## Report Structure

The report is posted as a single comment. It has three mandatory sections — **Header**, **Summary table**, and **Detailed Step Log** — followed by an optional **Failed / Blocked Steps** roll-up.

### 1. Header

```markdown
🤖 web-app-tester — Test Execution Report
URL tested: {TEST_URL}
{IF PRODUCTION_WARNING}⚠️ URL appears to be production. Executed read-only steps only.{END IF}
Total: {N} | ✅ Passed: {X} | ❌ Failed: {Y} | 🔴 Blocked: {Z}
Overall: {PASSED | FAILED | BLOCKED}
```

### 2. Summary table

A one-row-per-step at-a-glance view. The `Attempts` column shows how many tries the step needed (1–3).

```markdown
## Summary

| # | Step | Status | Attempts |
|---|------|--------|----------|
| 1 | {step description} | ✅ PASSED | 1 |
| 2 | {step description} | ❌ FAILED | 3 |
| 3 | {step description} | 🔴 BLOCKED | 3 |
```

### 3. Detailed Step Log (mandatory — every step, including passing ones)

For **each** step in the result list, in order, emit one sub-section with the following exact fields. Steps that passed on the first try still get a full entry — this is the test execution record and must be complete.

```markdown
## Detailed Step Log

### Step {N} — {step description}
- **Action:** {plain-language description of what was attempted, e.g. "Click the Sign In button"}
- **Target:** {role + accessible name of the element, or the URL for navigate; omit line if not applicable}
- **Input:** {value entered, or `[REDACTED]` for secrets; omit line if the step had no input}
- **Expected:** {one sentence — the outcome the step was supposed to produce}
- **Observed:** {one sentence — what the post-action snapshot actually showed}
- **Status:** ✅ PASSED | ❌ FAILED | 🔴 BLOCKED
- **Attempts:** {1..3}
- **Screenshot:** {captured at point of failure (`_wat_screenshot_{N}.png`) | not applicable}
- **Reason:** {only present when Status is FAILED or BLOCKED — short cause}
```

**Field rules:**

- `Target`, `Input`, `Screenshot`, and `Reason` lines are **conditional** — omit them when not applicable rather than emitting empty values like `Target: —`.
- `Action`, `Expected`, `Observed`, `Status`, and `Attempts` are **always** present, even for PASSED steps.
- Plain business language only. Do not describe Playwright commands, `eN` refs, CSS selectors, or YAML snapshots.

### 4. Failed / Blocked Steps (only when applicable)

When the run contains at least one FAILED or BLOCKED step, append a compact roll-up so reviewers can jump straight to problems without scrolling the full log:

```markdown
---

### Failed / Blocked Steps

**Step {N} — {step description}**
Reason: {short cause, same as in the detailed log}
Screenshot: {captured at point of failure / not available}
```

This section repeats information already in the Detailed Step Log on purpose — it's a quick-jump index, not the source of truth.

---

## Overall Result Logic

| Condition | Overall Result |
|---|---|
| All steps passed | **PASSED** |
| One or more steps failed (all steps were attempted) | **FAILED** |
| One or more steps could not execute (element not found, page error, timeout) | **BLOCKED** |

A run with both FAILED and BLOCKED steps uses **BLOCKED** as the overall result.

---

## Step Description Format

Write step descriptions in business language — describe the **user action and observed outcome**, not the technical mechanism.

| ❌ Avoid | ✅ Prefer |
|---|---|
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

A step that was **skipped due to production URL read-only mode** is marked `🔴 BLOCKED` with reason: `Skipped — production URL, read-only mode`.

---

## Retry Log (optional)

For BLOCKED steps, if retry attempts produced informative output (e.g. element selector, error message), include a brief retry summary:

```markdown
**Step 3 — Verify order confirmation message**
Reason: Element `.order-confirmation` not found after 3 retries (5s between each)
Attempts: 1 — timeout after 5s; 2 — timeout after 5s; 3 — timeout after 5s
Screenshot: captured at point of failure
```

---

## Production Warning

If the tested URL appears to be a production domain, the report must include this warning immediately after the URL line:

```
⚠️ URL appears to be production. Executed read-only steps only.
```

Steps that were skipped due to this restriction are listed in the table as `🔴 BLOCKED` with reason `Skipped — production URL, read-only mode`.

---

## Safety Rules (always enforced)

1. Never include authentication tokens, API keys, passwords, or secrets in any comment
2. Never describe credential values — redact them as `[REDACTED]` if they appear in test data
3. Screenshots are attached only for FAILED and BLOCKED steps
4. The report comment is always a single comment — never split across multiple comments

---

## Report Boundaries (strictly enforced)

**The report is strictly bounded to the sections defined above** — Header, Summary table, Detailed Step Log, and the optional Failed / Blocked roll-up. Nothing else.

✅ **Allowed and required** in the Detailed Step Log:
- Factual description of the action attempted (plain language)
- Factual description of the observed outcome from the post-action snapshot
- The expected outcome as stated or implied by the test plan
- Attempts count, screenshot reference, and short failure cause

❌ **Prohibited** anywhere in the report:
- Suggested fixes, workarounds, or "you should try…" statements
- Recommendations, advice, or test-improvement ideas
- Root cause analysis (why the bug exists, where in the code it might live)
- Next steps or action items for the developer
- Code snippets, diffs, stack traces, selectors, or YAML snapshot dumps
- Subjective commentary ("the UI feels slow", "this seems intentional")

The distinction: documenting **what was tried and what happened** is the test execution record and belongs in the report. Reasoning about **why** it happened or **what to do next** is debugging and belongs in a separate human review — not in this comment.
