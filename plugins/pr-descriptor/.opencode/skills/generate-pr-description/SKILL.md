---
name: generate-pr-description
description: "Generate or completely regenerate a pull request's description by analyzing its full diff, commit history, and codebase. Replaces the PR's title and description in place. Usage: /generate-pr-description [pr-number or branch-name]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Generate (or completely regenerate) the description for the pull request $ARGUMENTS.

Use the **orchestrator** agent to run the full pipeline. The orchestrator will:

1. Detect the hosting platform from `git remote get-url origin`
2. Resolve the PR and read its current title/description (to preserve "Related Work" references before they're overwritten)
3. Gather the full, cumulative diff and commit history versus the base branch
4. Index the codebase structure (skipped for small PRs — the diff alone is enough)
5. In parallel, load or bootstrap the repository's knowledge profile (**knowledge-curator**) and analyze the change (**change-analyst**)
6. Synthesize the description per `styles/pr-description-template.md` and `styles/description-style.md`
7. **Completely replace** the PR's title and description — never append, never comment, never open a thread
8. Refine the cached knowledge profile with what was learned this run (Knowledge Creation & Updates — see `agents/knowledge-curator.md`)

If a branch name is provided (e.g. `/generate-pr-description feature/my-feature`), compare that branch against `main`.

If no argument is given, describe the **current branch** against `main`.

This is the exact pipeline run automatically by webhook triggers on PR opened/synchronize/push events — see `commands/pr-describe.md`. Manual and webhook-driven invocations are identical: every run is a full regeneration from the PR's current, cumulative diff.
