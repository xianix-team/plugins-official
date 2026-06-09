---
name: post-test-report
description: Phase 3 of web-app-tester. Computes the overall verdict (PASSED / FAILED / BLOCKED) from the inline step results and composes a fully detailed test execution report — header, summary table, and per-step log documenting the action, expected outcome, observed outcome, attempts, status, and screenshot for every step. Posts via the correct provider (GitHub or Azure DevOps). For wi entry points on Azure DevOps, also posts a notification comment on the work item. The report is strictly bounded — factual execution record only, no recommendations or root-cause analysis.
disable-model-invocation: true
---

# Phase 3 — Post Test Execution Report

This skill is invoked by the **orchestrator** agent. It is not a standalone slash command.

## Inputs

| Variable | Source | Description |
|---|---|---|
| Inline result list | run-playwright-session | One entry per step: `{ n, desc, action: { verb, target, ref, input }, expected, observed, status, attempts, reason, screenshot }`. All fields populated for every step — see the Outputs section of `skills/run-playwright-session/SKILL.md`. |
| `TEST_URL` | gather-test-context | URL that was tested |
| `PRODUCTION_WARNING` | gather-test-context | Whether read-only mode was applied |
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
|---|---|
| All steps passed | **PASSED** |
| One or more steps failed (all steps were attempted) | **FAILED** |
| One or more steps could not execute (element not found, page error, timeout, auth gate, production-mode skip) | **BLOCKED** |

A run with both FAILED and BLOCKED steps uses **BLOCKED** as the overall result.

Store as `OVERALL_RESULT`, `PASSED` (count), `FAILED` (count), `BLOCKED` (count), `TOTAL` (count).

---

## Step 2: Compose the Report Body

Build the comment body using the **exact** structure defined in `styles/report-template.md`. The report comment must contain **only** the sections defined in that template (Header, Summary table, Detailed Step Log, optional Failed/Blocked roll-up). Do not add suggested fixes, recommendations, next steps, root cause analysis, explanations, or any content not defined in the template.

The skeleton is:

```
🤖 web-app-tester — Test Execution Report
URL tested: {TEST_URL}
{PRODUCTION_WARNING ? "⚠️ URL appears to be production. Executed read-only steps only." : ""}
Total: N | ✅ Passed: X | ❌ Failed: Y | 🔴 Blocked: Z
Overall: PASSED / FAILED / BLOCKED

## Summary

| # | Step | Status | Attempts |
|---|------|--------|----------|
| 1 | {desc} | ✅ PASSED | 1 |
| 2 | {desc} | ❌ FAILED | 3 |

## Detailed Step Log

### Step 1 — {desc}
- **Action:** {plain-language description of action.verb on action.target}
- **Target:** {action.target}                       ← omit if not applicable
- **Input:** {action.input}                         ← omit if null; show "[REDACTED]" for secrets
- **Expected:** {expected}
- **Observed:** {observed}
- **Status:** ✅ PASSED
- **Attempts:** 1

### Step 2 — {desc}
- **Action:** {plain-language description}
- **Target:** {action.target}
- **Input:** {action.input or [REDACTED]}
- **Expected:** {expected}
- **Observed:** {observed}
- **Status:** ❌ FAILED
- **Attempts:** 3
- **Screenshot:** captured at point of failure (`_wat_screenshot_2.png`)
- **Reason:** {reason}

[If any FAILED or BLOCKED steps exist, append the roll-up:]

---

### Failed / Blocked Steps

**Step N — {desc}**
Reason: {reason}
Screenshot: {captured at point of failure / not available}
```

**Composition rules:**

1. **Emit a Detailed Step Log entry for every step** in the result list — including PASSED steps. This is the test execution record; completeness is the whole point of the section.
2. Translate each result entry's structured fields into the bullet lines verbatim. Do not paraphrase, embellish, or merge across steps.
3. Step descriptions must be in **business language** — describe the user action and observed outcome, not the Playwright command. See `Step Description Format` in `styles/report-template.md` for examples.
4. **Omit** the `Target`, `Input`, `Screenshot`, and `Reason` lines when they are not applicable for the step (e.g. no `Input` line on a click; no `Screenshot` or `Reason` lines on a PASSED step). Do not emit empty placeholders.
5. **Screenshots are described inline**, not embedded — neither GitHub nor Azure DevOps PR comments support direct file attachments via the CLI/REST flows used here, so the PNG files are not uploaded.
6. **Never include secrets.** If `action.input` is `[REDACTED]`, keep it `[REDACTED]` in the report. If you spot a credential-like value that was not redacted upstream, redact it here before posting.

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

```
web-app-tester complete for {ENTRY_TYPE} #{ENTRY_ID}: {OVERALL_RESULT} — {PASSED}/{TOTAL} steps passed
```

If posting fails, output a single error line describing what failed and stop.
