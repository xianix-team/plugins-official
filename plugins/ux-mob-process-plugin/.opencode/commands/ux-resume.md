---
description: Resume a paused UX Mob process from the last approved phase.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Command: ux-resume

**Purpose:** Resume a paused UX Mob Process.

## Instructions
- Read the `project-state.json` file in the specific project folder, e.g. `[workspace-root]/projects/[project-folder]/project-state.json`.
- Identify the current phase and the active process file.
- Resume the process exactly from the `current_phase` without skipping any approval gates.
- **Artifact Generation**: Follow the **Strict No-Silent-File-Write Rule** and **Long-Artifact Preview Rule** detailed in `CLAUDE.md`. Always use a strict chat-first flow. Generate drafts in chat, label them "Draft artifact preview — not saved yet", ask for save approval, and only save after human approval.


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


## Context Isolation Rule
For every new mob run, the agent must treat the current project as isolated.
The agent must not use:
- previous mob run outputs
- archived project artifacts
- old Cabin Connect outputs
- previous conversation memory
- inferred prior project decisions
- old drafts
- old phase artifacts
- old generated files outside the active project folder
unless the human explicitly provides or approves them as current inputs.

The only allowed sources are:
1. The selected process file
2. The relevant current template file
3. The active project-state.json
4. Approved upstream artifacts inside [workspace-root]/projects/[project-folder]/
5. Inputs explicitly provided by the human during the current run

## Template Enforcement Rule
Before generating any artifact, the agent must:
1. Open and read the relevant template from ux-mob/templates/
2. Use the template headings exactly
3. Preserve the template structure
4. Fill only what can be supported by approved inputs or current human input
5. Mark missing content as `Needs human input`
6. Mark assumptions as `Assumption`
7. Mark inferred content as `Inferred`

The agent must not replace the template structure with its own structure.

## Source Declaration Rule
Every draft artifact preview must start with:

### Source Declaration
Allowed sources used:
- [source file or human input]

Not used:
- previous mob runs
- archived artifacts
- prior conversation memory
- unapproved drafts

## No Prior Context Rule
If the agent recognizes information from a previous run, it must not reuse it unless the human explicitly says:
"Use previous run context"
or provides the specific file as an approved input.

## Required Phase Input Gate
Before generating a phase artifact, the agent must state:
1. Required inputs for this phase
2. Which required inputs are available
3. Which required inputs are missing
4. Whether the phase can proceed

If required inputs are missing, the agent must ask for them or mark them as `Needs human input`.

## Draft Generation Rule
The agent must not pre-fill templates with confident content unless the source is available and declared.

If content is based on domain reasoning, label it: Evidence: Domain Analysis
If content is inferred, label it: Inferred
If content is uncertain, label it: Needs validation
