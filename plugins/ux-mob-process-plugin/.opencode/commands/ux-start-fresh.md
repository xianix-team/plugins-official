---
description: Start a fresh UX Mob process, clearing any prior project state and initializing a new project folder.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Command: /ux-start-fresh

**Description:**
Start a new UX Mob process with strict context isolation. Use this command to guarantee that previous mob runs, old projects, and prior conversation memory do not leak into the new project.

**Agent Instructions:**
When the user types `/ux-start-fresh`, you must:
1. Load and read `.agents/workflows/start-fresh-ux-mob-process.md`.
2. Follow its instructions exactly.
3. Explicitly enforce the `Context Isolation Rule` across all phases.
