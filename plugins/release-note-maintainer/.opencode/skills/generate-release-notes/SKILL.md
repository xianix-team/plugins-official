---
name: generate-release-notes
description: "Generate structured release notes for a git tag by analyzing all merged pull requests, commits, breaking changes, and work items since the previous tag. Publishes to the hosting platform. Usage: /generate-release-notes [tag]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Generate release notes for the tag $ARGUMENTS (defaults to the tag at HEAD).

Use the **orchestrator** agent to run the full pipeline. The orchestrator will:

1. Detect the hosting platform from `git remote get-url origin`
2. Identify the current tag and previous tag
3. Gather all commits in the release window
4. List merged pull requests in the release window (GitHub/Azure DevOps) or use commits alone (generic)
5. In parallel: load or bootstrap the repository's release knowledge profile (**knowledge-curator**) and categorize the release content (**release-analyst**)
6. Synthesize structured release notes per `styles/release-notes-template.md` and `styles/release-notes-style.md`
7. Publish the release notes to the platform — never appends, never posts a thread
8. Refine the cached knowledge profile with what was learned this run

This is the exact pipeline run automatically on tag-creation webhook events — see `commands/release-notes.md`. Manual and webhook-driven invocations are identical.
