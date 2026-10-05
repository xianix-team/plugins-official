---
name: test-web-app
description: Runs web app behaviour verification for a GitHub PR or Issue. Resolves a testable URL (config, args, or comments), executes a structured test plan via Python Playwright (Webwright workflow, headless Chromium), and posts a step-by-step test execution report as a GitHub comment.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Skill: Test Web App

Triggers the **orchestrator** agent to run automated browser-based verification of web app behaviour for a given GitHub PR or Issue.

## Usage

```
/test-web-app [pr <n> | issue <n>]
```

## What It Does

The orchestrator runs three sequential phases, each backed by its own skill file:

1. **Gather test context** (`skills/gather-test-context/SKILL.md`)
   - Fetches PR/issue body, comments, commits, and linked issues
   - Scans content for a testable URL (preview, staging, deploy URL)
   - Checks `IS_PRODUCTION` (derived from `ENVIRONMENT=production` in `rules.json`) to determine whether to restrict execution to read-only steps
   - Finds an existing test plan or auto-generates one

2. **Run Playwright session** (`skills/run-playwright-session/SKILL.md`)
   - Ensures Chromium is available, then writes and executes a Python/Playwright script (Webwright workflow)
   - Runs authenticated via a Playwright storage state when `.web-app-tester.json` configures one
   - Executes each test step, retrying failures up to 3 times
   - Captures a screenshot on the final retry of any blocked step
   - Cleans up temp files

3. **Post test execution report** (`skills/post-test-report/SKILL.md`)
   - Computes the overall verdict
   - Composes a comment that strictly conforms to `styles/report-template.md`
   - Posts it via `providers/github.md`

## Output

- A single GitHub comment with a step-by-step results table
- Screenshots described inline (not embedded — GitHub comments do not support file attachments via `gh`)
- Overall verdict: `PASSED` / `FAILED` / `BLOCKED`
