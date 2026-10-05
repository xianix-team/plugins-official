---
description: Start the full UX Mob process. Prompts for project type (Greenfield or Brownfield) and initializes the project workspace.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Command: ux-start

**Purpose:** Start the full UX Mob Process.

## Instructions
- Start by asking the user: "What type of project are we working on: Greenfield or Brownfield? Please also provide a project name and project folder name."
- If Greenfield: set up the state and load `ux-mob/processes/greenfield-process.md`. Note that Greenfield starts with minimal known project context, creates `domain.md` in Phase 1, requires client input before `intent-gap.md`, involves mandatory manual client verification, and ends with `greenfield-handoff.md`. Prototype building is not part of the greenfield process (recommend the separate Prototype Builder workflow if asked).
- If Brownfield: apply the mandatory Brownfield AI Readiness rule. Do not ask for the specific brownfield work type yet. Load and run `ux-mob/processes/brownfield/ai-readiness-process.md` first.
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


## Unit Definition Rules (Phase 11)
- When generating units.md, always use ux-mob/templates/units-template.md.
- Derive units from approved feature-map.md and approved user-journeys.md.
- Do not create technical foundation units.
- Do not create units from architecture, auth, routing, database schema, access control, or infrastructure unless explicitly listed as product features.
- For every high-priority or in-scope feature in feature-map.md, either create a product unit or list it under Deferred / Not Unitized Yet with a reason.
- Every unit must include Source Trace: Feature ID, Feature name, Journey ID, Journey name, Product intent item, Persona.
- Every unit must explain: what the capability is, why it exists, what needs to be built, what is in scope, what is out of scope, UX / UI expectations, data needs, dependencies, suggested Bolt execution.
- Show draft units.md in chat before saving.
- Save only after explicit artifact save approval.
- Save only to [workspace-root]/projects/[project-folder]/outputs/units.md.
- Do not proceed to Unit Validation Cases until units.md is saved and Phase 11 is approved.


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


## Mandatory Brownfield Starter Rule

When the user selects Brownfield, do not immediately ask whether they want Add New Feature, Complete Revamp, or Improve Existing Feature.
First run Brownfield AI Readiness.
In AI Readiness Phase 1, check existing artifacts and decide what can be reused.
After AI Readiness is approved, then ask which Brownfield work type to run:
1. Add New Feature
2. Complete Revamp
3. Improve Existing Feature
