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
| `TEST_PLAN` | gather-test-context | Original test plan (used to write the Test Plan Summary) |
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

Build the comment body using the **exact** structure defined in `styles/report-template.md`. The report contains five sections: header block, Test Plan Summary, Test Case Results table, Failed / Blocked Detail (if any), Overall Result, and footer.

### 2a — Resolve metadata

Extract `TIMESTAMP`, `DURATION`, and `BROWSER` from the `RUN_META` values. If `RUN_META` was not produced (script crashed before writing it), fall back to `RUN_START_ISO` for `TIMESTAMP`, `unknown` for `DURATION`, and `Chromium (headless)` for `BROWSER`.

Build the metadata line:

```text
Tested: {TIMESTAMP} · Browser: {BROWSER} · Duration: {DURATION}
```

### 2b — Build the header block

```markdown
🤖 web-app-tester (Webwright) — Test Execution Report
Verdict: **{OVERALL_RESULT}**
URL tested: {TEST_URL}
{IS_PRODUCTION ? "⚠️ Running in production environment. Executed read-only steps only." : ""}
Tested: {TIMESTAMP} · Browser: {BROWSER} · Duration: {DURATION}
Total: {TOTAL} | ✅ Passed: {PASSED} | ❌ Failed: {FAILED} | 🔴 Blocked: {BLOCKED}
```

### 2c — Build the Test Plan Summary

Write 1–3 sentences in plain language describing what the test plan covers, derived from `TEST_PLAN`. Mention the user flows, features, and scenarios exercised. Do not copy steps verbatim.

```markdown
## Test Plan Summary

{summary}
```

### 2d — Build the Test Case Results table

Include **every** test case in a single table. Order by step number.

- `Status` column: `✅ PASSED`, `❌ FAILED`, or `🔴 BLOCKED`
- `Actual` column: what was observed (visible text, URL, error message, or block reason)
- `Expected` column: what the test plan expected
- `Duration` column: elapsed time (`Xms` or `X.Xs`); use `—` for no-retry BLOCKED cases

```markdown
## Test Case Results

| # | Test Case | Status | Actual | Expected | Duration |
| --- | --- | --- | --- | --- | --- |
| {n} | {desc} | {status_emoji} {STATUS} | {actual} | {expected} | {duration} |
```

### 2e — Build the Failed / Blocked Detail section

Only include if `FAILED + BLOCKED > 0`.

For each step with `status == FAILED` or `status == BLOCKED`, add an entry. Order: failed steps first, then blocked, preserving step number order within each group.

**FAILED entry:**

```markdown
**Test Case {n} — {desc}**
Status: ❌ FAILED
Expected: {expected}
Actual: {actual}
Duration: {duration}
```

**BLOCKED entry (with retries):**

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

**BLOCKED entry (no retries — auth gate, production skip, or pre-step crash):**

```markdown
**Test Case {n} — {desc}**
Status: 🔴 BLOCKED
Reason: {actual}
```

Omit the `Attempts:` block when `retries == 0`. Omit the `Screenshot:` line for production-skip and auth-gate blocked steps.

Wrap all entries in a `<details open>` block:

```markdown
<details open>
<summary>❌ Failed / 🔴 Blocked — Detail</summary>

{entries}

</details>
```

### 2f — Build the Overall Result section

Start with the count line, then write 1–5 factual bullet points summarising what was verified in business language. For PASSED runs: state what was confirmed working. For FAILED/BLOCKED runs: state what did not complete without recommendations. Add a `**Note:**` line if a constraint affected the run (production mode, auth gate, local stack).

```markdown
## Overall Result

{PASSED} / {TOTAL} test cases PASSED — {FAILED} FAILED — {BLOCKED} BLOCKED

- {factual bullet}
- {factual bullet}

{IF note warranted}
**Note:** {one sentence}
{END IF}
```

### 2g — Footer

Always append as the final line:

```markdown
---

*Generated by Web App Tester — Python/Playwright (headless Chromium)*
```

### 2h — Assemble REPORT_BODY

Concatenate in order:
1. Header block
2. `---`
3. Test Plan Summary
4. `---`
5. Test Case Results table
6. Failed / Blocked Detail section (if any, preceded by a blank line)
7. `---`
8. Overall Result section
9. Footer

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
