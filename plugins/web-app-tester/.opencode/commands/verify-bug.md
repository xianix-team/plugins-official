---
description: "Re-verify a reported bug against a deployed environment using the Webwright workflow (Python/Playwright, headless Chromium). Replays the bug's repro steps, runs a decisive check against the expected result, and posts a STILL REPRODUCIBLE / NOT REPRODUCIBLE / INCONCLUSIVE verdict comment on the bug itself, with screenshot evidence on Azure DevOps. Usage: /verify-bug <wi <id> | issue <n>> [--env <name>] [--url <url>] [--role <role>] [--interactive]"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run automated bug verification for $ARGUMENTS.

## What This Does

Invokes the **orchestrator** agent with `MODE=verify` to:

1. Fetch the bug (ADO work item or GitHub issue) — description, repro steps, expected/actual results, and all comments
2. Triage verifiability — backend-only, API-only, or build/tooling bugs are not browser-verifiable and stop before any browser is launched
3. Derive a verification plan from the repro steps, plus a **decisive check**: the single observation that discriminates "still broken" (`BUG_SIGNAL`) from "appears fixed" (`FIXED_SIGNAL`)
4. Execute the plan against the resolved environment (authenticated via a Playwright storage state when configured), capturing a decisive screenshot regardless of outcome
5. Post exactly one verdict comment **on the bug itself**, with the decisive screenshot attached (Azure DevOps) or the decisive observation described inline (GitHub)

## Entry Points

| Entry Point | Platform | Example | Notes |
|---|---|---|---|
| **Work item ID** | Azure DevOps only | `/verify-bug wi 1234` | The work item type must be `Bug` — any other type stops with an error |
| **Issue number** | GitHub only | `/verify-bug issue 88` | The issue is treated as the bug report |

`pr` is **not** a valid verify target — bugs are verified, not pull requests.

## Arguments

| Flag | Meaning |
|---|---|
| `--env <name>` | Use the named environment from `.web-app-tester.json` |
| `--url <url>` | Test against this URL directly (overrides `--env` and config) |
| `--role <role>` | Use this role's storage state from the environment config |
| `--interactive` | Pause at Gate A (plan confirmation) and Gate B (comment approval) — see below |

URL resolution precedence: `--url` → `--env` → `defaultEnvironment` from `.web-app-tester.json` → comment-scraping → stop with "no testable URL". See `docs/configuration.md`.

## The Three Verdicts

| Verdict | Meaning |
|---|---|
| ❌ **STILL REPRODUCIBLE** | The decisive check observed the behaviour the bug reports |
| ✅ **NOT REPRODUCIBLE — appears fixed** | All steps executed and the expected result was positively observed |
| ⚪ **INCONCLUSIVE** | Anything else — blocked step, auth/environment failure, missing precondition, or neither signal observed |

**Safety rule: a blocked run is never reported as fixed.** If any step on the path to the decisive check could not execute, the verdict is INCONCLUSIVE — the plan "not failing" is never evidence that the bug is gone. A bug's repro steps describe an unhappy path; only positively observing the expected result justifies "appears fixed", and even then the wording is always qualified ("appears fixed", never "fixed").

## Interactive vs Autonomous

- **Autonomous (default):** never pauses; INCONCLUSIVE runs post a brief neutral note so the run isn't silent; work item state is **never** changed.
- **`--interactive`:** pauses at **Gate A** (shows the verification plan, decisive check, preconditions, and mutating steps before opening a browser) and **Gate B** (shows the draft comment and decisive screenshot before posting). After posting, offers — never auto-applies — the matching work item state transition.

## Prerequisites

- Python 3.10+ with the `playwright` package (`pip install playwright && playwright install chromium`)
- **Azure DevOps:** `curl` available and `AZURE-DEVOPS-TOKEN` set to a PAT with Work Items **Read & Write**
- **GitHub:** `gh` CLI installed and authenticated
- For authenticated apps: storage states configured in `.web-app-tester.json` — see `docs/configuration.md`

---

Starting bug verification now (MODE=verify)...
