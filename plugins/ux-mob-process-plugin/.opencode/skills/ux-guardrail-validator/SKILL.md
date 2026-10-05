---
name: ux-guardrail-validator
description: Skill for validating UX Mob guardrails.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# UX Guardrail Validator Skill

Use this skill to run a full guardrail compliance check on the active UX Mob project. It verifies that the current session and all saved artifacts comply with the UX Mob governance rules.

## When to Use This Skill

- The user runs `/ux-validate-guardrails`
- Before requesting phase approval on a long or complex phase
- After resuming a paused session to verify no drift occurred during the pause

## Steps

1. Read `project-state.json` in the active project folder to identify the current phase and all completed phases.
2. Read `ux-mob/governance/guardrails.md` to load the full rule set.
3. Read `ux-mob/governance/phase-dependencies.md` to verify phase sequencing.
4. Read `ux-mob/governance/source-of-truth-map.md` to check artifact source chains.
5. Read `ux-mob/governance/scope-control-rules.md` to check for scope violations.
6. Read `ux-mob/governance/do-not-invent-rules.md` and the project's `decisions/do-not-invent-list.md`.
7. For each completed phase, check:
   - Required artifacts exist and are saved under `[workspace-root]/projects/[project-folder]/`
   - Artifacts use the correct source of truth
   - Assumptions are clearly marked
   - Inferred items are clearly marked
   - Missing inputs are clearly marked
   - Evidence labels are applied where needed
   - Removed or out-of-scope items are excluded
   - Artifact save approval was separate from phase approval
   - Do-not-invent list was respected
   - Unit quality rules were applied if `units.md` is present
8. Compile the Guardrail Validation Report in chat, listing each rule checked with status: Pass / Violation / Cannot determine. Describe each violation and recommend corrective actions.
9. Show the full report in chat before asking about saving.
10. After explicit save approval from the human, save to `[workspace-root]/projects/[project-folder]/decisions/guardrail-validation-report.md`.

## Governance Rule Always Applies

Do not save the report without explicit human save approval.
