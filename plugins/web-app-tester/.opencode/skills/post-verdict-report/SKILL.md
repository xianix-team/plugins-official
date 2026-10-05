---
name: post-verdict-report
description: Phase 3 of web-app-tester in verify mode (MODE=verify, from /verify-bug). Computes the bug-verification verdict (STILL REPRODUCIBLE / NOT REPRODUCIBLE / INCONCLUSIVE) from the decisive-step signal and the per-step results, composes the comment strictly per styles/verdict-template.md, uploads the decisive screenshot as evidence (Azure DevOps), and posts the verdict comment on the bug itself. Enforces the hard rule that a blocked run is never reported as fixed. Interactive runs hold at Gate B before posting and may offer a work item state transition afterwards.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Phase 3 (verify mode) — Post Verdict Report

This skill is invoked by the **orchestrator** agent when `MODE=verify`. It is not a standalone slash command. Test runs (`MODE=test`) use `skills/post-test-report/SKILL.md` instead.

## Inputs

| Variable | Source | Description |
|---|---|---|
| Inline result list | run-playwright-session | One entry per plan step, all fields populated, including the decisive step |
| Decisive `<signal>` | run-playwright-session | `FIXED_SIGNAL_OBSERVED`, `BUG_SIGNAL_OBSERVED`, or `NEITHER_OBSERVED` — absent if the decisive step never ran |
| `DECISIVE_CHECK` | gather-test-context | The `BUG_SIGNAL` / `FIXED_SIGNAL` pair the decisive step tested |
| `TEST_URL` / env name | orchestrator | Environment the verification ran against |
| `ROLE` | orchestrator | Storage-state role used, if any |
| `MUTATIONS_ALLOWED` | gather-test-context | Whether the environment was read-only |
| `ENTRY_TYPE` / `ENTRY_ID` / `ENTRY_TITLE` | orchestrator | The bug being verified (`wi` on ADO, `issue` on GitHub) |
| `PLATFORM` | orchestrator | `GitHub` or `AzureDevOps` |
| `INTERACTIVE` | orchestrator | Whether Gate B applies |
| `RUN_START_TIME` / `RUN_DURATION_S` | run-playwright-session | Timing for the report header |
| `_wat_run/screenshots/` | run-playwright-session | `decisive.png` plus any failure screenshots — still on disk (cleanup is deferred in verify mode) |

## Outputs

Exactly one verdict comment posted **on the bug itself** (ADO work item comment / GitHub issue comment), a one-line confirmation on stdout, and a completion signal to the orchestrator for final `_wat_run/` cleanup. No PR posting in verify mode.

---

## Step 1: Compute the Verdict

| Condition | Verdict |
|---|---|
| Decisive step ran and `BUG_SIGNAL_OBSERVED` | **STILL REPRODUCIBLE** |
| All plan steps executed AND decisive step ran AND `FIXED_SIGNAL_OBSERVED` | **NOT REPRODUCIBLE — appears fixed** |
| Anything else — any step BLOCKED before the decisive check, auth failure, environment failure, `NEITHER_OBSERVED`, precondition missing, ambiguity | **INCONCLUSIVE** |

**Hard rules (safety-critical — never override):**

- A step BLOCKED anywhere on the path to the decisive check can **never** yield "appears fixed". A bug's repro steps are an unhappy path: a run that didn't reach the decisive observation proves nothing about the bug.
- `NEITHER_OBSERVED` (the UI changed so much that neither signal exists) is **INCONCLUSIVE**, not fixed.
- `FIXED_SIGNAL` must have been **positively observed** — absence of the bug signal is never sufficient.
- Wording is always "appears fixed" / "not reproducible on {env}" — never an unqualified "fixed".

Store `VERDICT` and, for INCONCLUSIVE, a one-line `INCONCLUSIVE_REASON` (e.g. `step 3 blocked — element not found`, `auth session rejected`, `expected result not stated in bug`, `precondition missing: <which>`).

---

## Step 2: Compose the Comment

Build the comment body using the **exact** structure defined in `styles/verdict-template.md`. Read that file before composing. The comment contains **only** the sections defined there — no recommendations, no root-cause analysis, no speculation about why the bug is or isn't fixed.

- **Environment** — the environment name when the URL came from `.web-app-tester.json`, otherwise `TEST_URL`.
- **Decisive observation** — one sentence: at step N, expected "<FIXED_SIGNAL>", observed "<what was seen>".
- **Executed steps** — every plan step, one line each, in the collapsed `<details>` block.
- If `MUTATIONS_ALLOWED=false`, include the read-only warning line.
- Never include storage-state contents, cookies, tokens, or credentials; keep `[REDACTED]` values redacted.

Store as `VERDICT_BODY`.

---

## Step 3: Gate B (interactive only)

When `INTERACTIVE=true`, this entire phase sits behind **Gate B**: show the user the draft `VERDICT_BODY` and the decisive screenshot (`Read` the PNG), then wait for explicit approval before posting anything. If the user amends the draft, re-show it; post only what was approved.

Autonomous runs skip this gate entirely.

---

## Step 4: Post

Dispatch on `VERDICT`:

### STILL REPRODUCIBLE / NOT REPRODUCIBLE

Post the verdict comment **on the bug itself**:

- **Azure DevOps** (`ENTRY_TYPE=wi`) — per `providers/azure-devops.md`:
  1. Upload `_wat_run/screenshots/decisive.png` (and any failure screenshots for STILL REPRODUCIBLE) via the attachments API (§Uploading an Attachment).
  2. Embed the returned URL in `VERDICT_BODY` as `![decisive](<url>)` and post as a markdown work item comment (§Posting the Verdict Comment).
- **GitHub** (`ENTRY_TYPE=issue`) — per `providers/github.md`: post via `gh issue comment`. No attachment support via the CLI — the decisive observation sentence carries the evidence inline (1.0 convention).

### INCONCLUSIVE

- **Interactive:** report the reasons to the user only — post **nothing**.
- **Autonomous:** post a brief neutral note on the bug so the run isn't silent:
  `🤖 web-app-tester — automated verification could not run: {INCONCLUSIVE_REASON}`

---

## Step 5: Offer the State Transition (interactive only, after posting)

Never in autonomous mode. After the verdict comment is posted in an interactive run, offer — do not apply — the matching work item state transition:

- STILL REPRODUCIBLE → reactivate the bug
- NOT REPRODUCIBLE → resolve/verify per the project's process

State names differ per ADO process template — present the choice to the user (per `providers/azure-devops.md` §Updating Work Item State), and apply it **only on a second explicit yes**, via the provider's state-update command. On GitHub, the equivalent offer is closing or reopening the issue via `gh issue close` / `gh issue reopen`.

---

## Step 6: Final Output and Cleanup Signal

Write a single confirmation line to stdout:

```
verify-bug complete for {ENTRY_TYPE} #{ENTRY_ID}: {VERDICT}
```

Then signal the orchestrator that evidence upload and posting are complete — the orchestrator performs the final `rm -rf _wat_run/`. If posting fails, output a single error line describing what failed and stop; the orchestrator still cleans up.
