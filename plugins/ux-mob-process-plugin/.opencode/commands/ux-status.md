---
description: Summarize the current project status, including active phase, saved artifacts, and pending approvals.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Command: ux-status

**Purpose:** Summarize the current project status.

## Instructions
- Read `project-state.json` in the active project directory.
- Provide a clear summary to the user including:
  - Project Name
  - Main Category
  - Brownfield AI Readiness Status
  - Brownfield Work Type
  - Active Process File
  - Current Phase
  - Completed Phases
  - Open Questions
  - Needs Human Input
