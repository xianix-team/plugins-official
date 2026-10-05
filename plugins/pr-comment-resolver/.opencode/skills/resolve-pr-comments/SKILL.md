---
name: resolve-pr-comments
description: "Resolve all unresolved review threads on a pull request. Classifies each comment as apply, discuss, or decline. Usage: /resolve-pr-comments [pr-number]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Resolve all unresolved review threads on pull request $ARGUMENTS.

This skill is a thin alias for the `/resolve-comments` command. **Act now — do not describe the process.** Invoke the **orchestrator** agent via the `Agent`/`Task` tool (`subagent_type: orchestrator`), synchronously, and wait for its result; ending the turn before the disposition summary is posted (or a hard error reported) is a failure. It runs the full comment resolution flow — `agents/orchestrator.md` is the authoritative step-by-step procedure. In outline, it will index the codebase, detect the hosting platform, resolve the PR number and state, fetch every unresolved review thread, classify each as **apply** / **discuss** / **decline**, apply the actionable changes, verify them against the repository's test suite (reverting any apply that introduces new failures), push a single commit, mark applied threads resolved, reply to the rest, and post the disposition summary.

If the PR is already merged, the orchestrator applies changes on a new branch and opens a follow-up PR linked to the original.

If no argument is given, resolve comments on the open PR for the **current branch**.
