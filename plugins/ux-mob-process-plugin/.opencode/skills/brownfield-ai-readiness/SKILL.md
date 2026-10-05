---
name: brownfield-ai-readiness
description: Skill for running the Brownfield AI Readiness process.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Brownfield AI Readiness Skill

Use this skill when the project type is Brownfield. It guides the session through the mandatory 11-phase AI Readiness assessment before any brownfield work begins.

## When to Use This Skill

- The user selects Brownfield as the project type via `/ux-start`
- The user runs `/ux-run-ai-readiness` directly
- The facilitator agent needs to route to the Brownfield AI Readiness process

## Steps

1. Confirm the project is Brownfield.
2. Load `ux-mob/processes/brownfield/ai-readiness-process.md`.
3. Read all governance files from `ux-mob/governance/`.
4. Check whether an `outputs/ai-readiness/` folder already exists under the active project folder.
5. Run Phase 1 (Existing Artifact Check) — scan for pre-existing artifacts. For each artifact found, offer the human: Use existing / Review / Revise / Recreate / Skip.
6. Continue phase by phase through all 11 phases, following per-phase rules:
   - Chat-first preview for every artifact draft
   - Explicit save approval before writing to disk
   - Phase approval gate at the end of each phase (separate from save approval)
7. At Phase 11, present the AI Readiness approval decision.
8. After explicit human approval, unlock brownfield work type selection:
   - 1. Add New Feature
   - 2. Complete Revamp
   - 3. Improve Existing Feature
9. Record the selection in `project-state.json`. Return control to the facilitator.

## Governance Rules Always Apply

- Never overwrite an existing artifact without explicit human approval.
- All outputs must go to `[workspace-root]/projects/[project-folder]/outputs/ai-readiness/`.
- Do not unlock brownfield work types until Phase 11 is approved by the human.
- Label all inferred content as `Inferred`, evidence-backed content as `Evidence-backed` or `Confirmed`, and uncertain content as `Candidate / Needs validation`.
- If evidence is insufficient to reconstruct an artifact, ask the human rather than inventing.
