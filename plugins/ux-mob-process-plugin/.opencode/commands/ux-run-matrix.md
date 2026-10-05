---
description: Run only the UX Matrix module to generate a prioritized feature-persona matrix from approved artifacts.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Command: ux-run-matrix

**Purpose:** Run only the UX Matrix module.

## Instructions
- Load `ux-mob/processes/brownfield/modules/ux-matrix-process.md`.
- Ask for user group/persona, journey ID, flow steps, channels, data, issues, etc.
- Generate the User Experience Matrix and all required issues and findings.
- **Artifact Generation**: Follow the **Strict No-Silent-File-Write Rule** and **Long-Artifact Preview Rule** detailed in `CLAUDE.md`. Always use a strict chat-first flow. Generate drafts in chat, label them "Draft artifact preview — not saved yet", ask for save approval, and only save after human approval.
- Enforce an approval gate before saving.
- Save the matrix to `projects/[project-folder]/phase-artifacts/ux-matrix-[journey-id].md`.


## Mandatory Governance Rules

Before running or resuming any UX Mob process, read the governance files:

- ux-mob/governance/guardrails.md
- ux-mob/governance/phase-dependencies.md
- ux-mob/governance/source-of-truth-map.md
- ux-mob/governance/evidence-labels.md
- ux-mob/governance/scope-control-rules.md
- ux-mob/governance/unit-quality-rules.md
- ux-mob/governance/unit-validation-rules.md
- ux-mob/governance/do-not-invent-rules.md

Required enforcement:
- Check phase dependencies before each phase.
- Check source-of-truth inputs before generating artifacts.
- Use evidence labels for claims.
- Respect scope statuses.
- Prevent removed items from reappearing.
- Apply unit quality rules when creating units.md.
- Apply do-not-invent rules everywhere.
- Stop and ask for human input when a required guardrail cannot be satisfied.
