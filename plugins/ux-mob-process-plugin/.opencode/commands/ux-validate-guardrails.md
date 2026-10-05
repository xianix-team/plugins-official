---
description: Check the current project against all UX Mob governance guardrails and report any violations.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Command: ux-validate-guardrails

**Purpose:** Check the current project against the governance guardrails.

## Instructions
- Run the workflow defined in `.agents/workflows/validate-guardrails.md`.
- Review all required files: `project-state.json`, approved artifacts, source-of-truth chain, phase dependencies, artifact paths, scope statuses, removed/rejected items, assumptions, inferred items, needs-human-input items, evidence labels, `units.md` quality, and `do-not-invent-list.md`.
- Output the `Guardrail Validation Report` in chat first.
- Only after explicit save approval, save the report to `projects/[project-folder]/decisions/guardrail-validation-report.md`.
