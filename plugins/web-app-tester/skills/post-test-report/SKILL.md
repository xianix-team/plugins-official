---
name: post-test-report
description: Phase 3 of web-app-tester. Computes the overall verdict (PASSED / FAILED / BLOCKED) from the inline step results, composes a report that conforms exactly to the report template, and posts it via the correct provider (GitHub or Azure DevOps). For wi entry points on Azure DevOps, also posts a notification comment on the work item. The report is strictly bounded — no recommendations, no root-cause analysis, no commentary outside the defined sections.
disable-model-invocation: true
---

# Phase 3 — Post Test Execution Report

This skill is invoked by the **orchestrator** agent. It is not a standalone slash command.

## Inputs

| Variable | Source | Description |
| --- | --- | --- |
| Inline result list | run-playwright-session | One entry per step: `{ n, desc, status, actual, expected, duration, retries, retry_1, retry_2, retry_3, screenshot }` |
| `RUN_META` | run-playwright-session | Parsed from log: `{ timestamp, duration, browser }` |
| `RUN_START_ISO` | orchestrator | Fallback timestamp if script exited before writing `RUN_META` |
| `TEST_URL` | gather-test-context | URL that was tested |
| `IS_PRODUCTION` | orchestrator | Whether read-only mode was applied |
| `ENTRY_TYPE` | orchestrator | `pr`, `issue`, or `wi` |
| `ENTRY_ID` | orchestrator | PR number, issue number, or work item ID |
| `PLATFORM` | orchestrator | `GitHub` or `AzureDevOps` |
| `LINKED_PR_ID` | gather-test-context | Azure DevOps `wi` entry only: the PR linked to the work item |

## Outputs

A single report comment posted on the PR or issue, plus (for `wi` entry) a notification on the work item, plus a one-line confirmation written to stdout.

---

## Step 1: Compute Overall Verdict

Determine the overall result from the per-step statuses:

| Condition | Overall Result |
| --- | --- |
| All steps passed | **PASSED** |
| One or more steps failed (all steps were attempted) | **FAILED** |
| One or more steps could not execute (element not found, page error, timeout, auth gate, production-mode skip) | **BLOCKED** |

A run with both FAILED and BLOCKED steps uses **BLOCKED** as the overall result.

Store as `OVERALL_RESULT`, `PASSED` (count), `FAILED` (count), `BLOCKED` (count), `TOTAL` (count).

---

## Step 2: Compose the Report Body

Build the comment body using the **exact** structure defined in `styles/report-template.md`. The report comment must contain **only** the sections defined in that template. Do not add suggested fixes, recommendations, next steps, root cause analysis, explanations, or any content not defined in the template.

### 2a — Resolve metadata

Extract `TIMESTAMP`, `DURATION`, and `BROWSER` from the `RUN_META` values. If `RUN_META` was not produced (script crashed before writing it), fall back to `RUN_START_ISO` for `TIMESTAMP`, `unknown` for `DURATION`, and `Chromium (headless)` for `BROWSER`.

Build the metadata line:

```text
Tested: {TIMESTAMP} · Browser: {BROWSER} · Duration: {DURATION}
```

### 2b — Build the header block

```markdown
🤖 web-app-tester (Webwright) — Test Execution Report
URL tested: {TEST_URL}
{IS_PRODUCTION ? "⚠️ Running in production environment. Executed read-only steps only." : ""}
Tested: {TIMESTAMP} · Browser: {BROWSER} · Duration: {DURATION}
Total: {TOTAL} | ✅ Passed: {PASSED} | ❌ Failed: {FAILED} | 🔴 Blocked: {BLOCKED}
Overall: **{OVERALL_RESULT}**

| # | Test Case | Status |
|---|-----------|--------|
| 1 | {test case description} | ✅ PASSED |
| 2 | {test case description} | ❌ FAILED |

[For each FAILED or BLOCKED test case:]
**Test Case N — {description}**
Reason: {what went wrong after 3 retries}
[Screenshot attached if available]
```

### 2c — Build the Passed Steps section

Only include if `PASSED > 0`.

For each step with `status == PASSED`, add a table row using the step's `actual` field as "What was verified":

```markdown
<details open>
<summary>✅ Passed Test Cases ({PASSED})</summary>

| # | Test Case | What was verified |
| --- | --- | --- |
| {n} | {desc} | {actual} |
| {n} | {desc} | {actual} |

</details>
```

### 2d — Build the Failed / Blocked Steps section

Only include if `FAILED + BLOCKED > 0`.

For each step with `status == FAILED` or `status == BLOCKED`, add an entry block. Order: failed steps first, then blocked steps, preserving step number order within each group.

**FAILED test case entry:**

```markdown
**Test Case {n} — {desc}**
Status: ❌ FAILED
Expected: {expected}
Actual: {actual}
Duration: {duration}
```

**BLOCKED test case entry (with retries):**

```markdown
**Test Case {n} — {desc}**
Status: 🔴 BLOCKED
Reason: {actual}
Attempts:
- Attempt 1: {retry_1}
- Attempt 2: {retry_2}
- Attempt 3: {retry_3}
Duration: {duration}
Screenshot: {screenshot == "captured" ? "captured at point of failure" : "not available"}
```

**BLOCKED test case entry (no retries — auth gate, production skip, or pre-step crash):**

```markdown
**Test Case {n} — {desc}**
Status: 🔴 BLOCKED
Reason: {actual}
```

Omit the `Attempts:` block when `retries == 0`. Omit the `Screenshot:` line for production-skip and auth-gate blocked steps (no screenshot is taken for those).

Wrap all entries in a `<details open>` block:

```markdown
<details open>
<summary>❌ Failed / 🔴 Blocked Test Cases ({FAILED + BLOCKED})</summary>

{entries}

</details>
```

### 2e — Assemble REPORT_BODY

Concatenate: header block + horizontal rule (`---`) + passed section (if any) + failed/blocked section (if any).

Store as `REPORT_BODY`.

---

## Step 3: Post the Report

Read the correct provider file and post using the appropriate command:

### GitHub

Read and follow `providers/github.md`.

- `ENTRY_TYPE == pr` → `gh pr comment ${ENTRY_ID}` with `REPORT_BODY`
- `ENTRY_TYPE == issue` → `gh issue comment ${ENTRY_ID}` with `REPORT_BODY`

Post a **single comment**. Never split the report across multiple comments.

### Azure DevOps

Read and follow `providers/azure-devops.md`.

- `ENTRY_TYPE == pr` → post the full report as a PR thread comment on PR `${ENTRY_ID}`
- `ENTRY_TYPE == wi` and `LINKED_PR_ID` is set → two posts:
  1. Post the full report as a PR thread comment on `LINKED_PR_ID`
  2. Post a notification comment on the work item `${ENTRY_ID}` (brief summary only — `OVERALL_RESULT`, step counts, `TEST_URL`, reference to the PR)
- `ENTRY_TYPE == wi` and `LINKED_PR_ID` is empty → post the full report directly on the work item `${ENTRY_ID}`

See `providers/azure-devops.md` for the exact `curl` commands for each case.

---

## Step 4: Final Output

After posting, write a single confirmation line to stdout:

```text
web-app-tester complete for {ENTRY_TYPE} #{ENTRY_ID}: {OVERALL_RESULT} — {PASSED}/{TOTAL} test cases passed
```

If posting fails, output a single error line describing what failed and stop.
