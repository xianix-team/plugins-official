---
description: Record explicit phase approval and advance the UX Mob process to the next phase.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Command: ux-approve-phase

**Purpose:** Record phase approval and move to the next phase.

## Instructions
- Ensure all required artifacts for the current phase have been saved and reviewed.
- Remember: Saving an artifact does not automatically approve the phase.
- Record the current phase as approved only if the user has explicitly given phase approval.
- Update `project-state.json` to move to the next phase.
- Load the next phase requirements from the active process file and ask the next set of questions.


# Phase Quality Checklist

At the end of each phase, before asking for phase approval, the agent must run this checklist in chat:

1. Were the required source artifacts approved?
2. Did the artifact use the correct source of truth?
3. Were assumptions clearly marked?
4. Were inferred items clearly marked?
5. Were missing inputs clearly marked?
6. Were evidence labels used where needed?
7. Were out-of-scope or removed items excluded?
8. Was the artifact previewed in chat before saving?
9. Was explicit save approval received?
10. Was the artifact saved under projects/[project-folder]/?
11. Were decisions, assumptions, or drift items logged if needed?
12. Is the phase ready for approval?

Then ask the phase approval gate.
