---
name: gather-test-context
description: Phase 1 of chatbot-tester. Validates the extracted test block, checks if login is required, and handles lite mode. TEST_URL and KNOWLEDGE are already set by the orchestrator before this phase runs.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Phase 1 — Gather Test Context

This skill is invoked by the **orchestrator** agent. It is not a standalone slash command.

## Inputs

| Variable | Source | Description |
|---|---|---|
| `TEST_URL` | orchestrator | URL of the app to test (from `KNOWLEDGE.url` or direct URL argument) |
| `KNOWLEDGE` | orchestrator | Parsed contents of the `chatbot-test` block (empty object for lite mode) |
| `LITE_MODE` | orchestrator | `true` if invoked with a direct URL and no issue/work item |

## Outputs

| Variable | Description |
|---|---|
| `REQUIRES_LOGIN` | `true` if credentials are declared in the knowledge block; otherwise `false` |
| `HAS_CONVERSATION_FLOW` | `true` if the test block contains a non-empty `conversation_flow` array; otherwise `false` |
| `PHASE1_BLOCK` | Set to a reason string if the run must not proceed; otherwise unset |

---

## Step 1: Validate Test Block Entries

Before any other checks, validate every entry in the `knowledge` array and the `conversation_flow` array (if present).

For each entry in `KNOWLEDGE.knowledge` (if the array exists):
- If the entry has neither `expected_answer` nor `must_contain` → set:
  `PHASE1_BLOCK="knowledge entry at index {n} has neither 'expected_answer' nor 'must_contain' — at least one is required for judgment."`
  Stop validation and do not proceed to Phase 2.

Apply the same check to every entry in `KNOWLEDGE.conversation_flow` (if the array exists):
- If the entry has neither `expected_answer` nor `must_contain` → set:
  `PHASE1_BLOCK="conversation_flow entry at index {n} has neither 'expected_answer' nor 'must_contain' — at least one is required for judgment."`
  Stop validation and do not proceed to Phase 2.

---

## Step 2: Detect Conversation Flow

If `KNOWLEDGE` contains a `conversation_flow` key with at least one entry → set `HAS_CONVERSATION_FLOW=true`.

Otherwise → set `HAS_CONVERSATION_FLOW=false`.

---

## Step 3: Check Login Requirement

If `KNOWLEDGE` contains a `credentials` block with both `username` and `password_env` fields → set `REQUIRES_LOGIN=true`.

Otherwise → set `REQUIRES_LOGIN=false`.

If `REQUIRES_LOGIN=true`, verify the env var named in `password_env` is set:

```bash
PASSWORD_ENV_KEY="${KNOWLEDGE.credentials.password_env}"
if [ -z "${!PASSWORD_ENV_KEY:-}" ]; then
  PHASE1_BLOCK="Password env var '${PASSWORD_ENV_KEY}' is not set. Store the test password in Xianix Agentri Studio Secrets under that key and re-run."
fi
```

If `PHASE1_BLOCK` is set, do not proceed to Phase 2. The orchestrator will post a BLOCKED report and stop.

---

## Step 4: Lite Mode Notice

If `LITE_MODE=true`, log the following so it is included in the final report:

```
LITE_MODE_NOTICE: Functional Accuracy was skipped — no test case provided.
To run a full test, create a GitHub issue or Azure DevOps work item with a
chatbot-test block and re-run:
  /test-chatbot https://github.com/owner/repo/issues/<n>
  /test-chatbot https://dev.azure.com/org/project/_workitems/edit/<id>
```

---

## Completion

Hand off to `skills/run-playwright-session/SKILL.md` with `TEST_URL`, `REQUIRES_LOGIN`, `HAS_CONVERSATION_FLOW`, `KNOWLEDGE`, `LITE_MODE` in scope.
