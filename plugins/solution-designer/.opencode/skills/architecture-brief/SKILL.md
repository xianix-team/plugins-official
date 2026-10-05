---
name: architecture-brief
description: "Summarise the accepted architecture that applies to a backlog item — binding constraints and ADRs, the components and paths it touches, patterns to reuse, and tensions — without producing a design. Local output only. Usage: /architecture-brief [issue-number | work-item-id]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Produce an architecture brief for item $ARGUMENTS. Do not post anything, create branches, or change labels.

1. Detect the platform from `git remote get-url origin` and fetch the item title and description (see `providers/<platform>.md`). For plain text, use the text given.
2. Run the **architecture-analyst** agent with the requirement and the repository root.
3. Output the brief as returned.

Useful before grooming finishes, or to check whether the repo has ratified constraints at all (baseline `inferred` means run `arch-fitness --docs-only` first).
