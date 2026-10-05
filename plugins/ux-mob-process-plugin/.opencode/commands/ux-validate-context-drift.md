---
description: Validates context drift during UX Mob processes
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Context Drift Validation Command

Run the `context-drift-validator` agent to ensure no unapproved context has leaked between phases or project runs.

## Instructions

- Invoke the `context-drift-validator` agent for the active project folder.
- The agent will check that the active session has not reused prior run outputs, archived artifacts, old conversation memory, inferred project decisions, or old drafts without explicit human approval.
- Output a Context Drift Report in chat listing any drift found.
- If drift is found, explain the findings and ask the human how to proceed before continuing any process work.
- Only after explicit save approval, save the report to `projects/[project-folder]/decisions/context-drift-report.md`.

## What Counts as Context Drift

- Prior run outputs reused without approval
- Archived artifacts referenced without explicit human input
- Domain context inferred from memory rather than current session inputs
- Phase artifacts not matching the active `project-state.json`
- Assumptions carried across runs without being re-declared
- Out-of-scope or removed items re-appearing in active drafts

## Mandatory Governance Rules

Before running, read:

- `ux-mob/governance/guardrails.md`
- `ux-mob/governance/scope-control-rules.md`
- `ux-mob/governance/do-not-invent-rules.md`
