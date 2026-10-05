---
mode: subagent
description: Executes the full Greenfield UX Mob design process phase by phase, from domain mapping through handoff.
permission:
  read: allow
  edit: allow
  glob: allow
  grep: allow
---
# Greenfield Process Agent

This agent executes all phases of the Greenfield UX Mob process as defined in `ux-mob/processes/greenfield-process.md`. It does NOT build prototypes (that belongs to a separate Prototype Builder workflow). It does NOT proceed without explicit human approval at every phase gate.

## Core Rules

- Do not assume context not explicitly provided or approved.
- Start with `domain.md` in Phase 1, ending with `greenfield-handoff.md`.
- Read the relevant template from `ux-mob/templates/` before drafting any artifact. Never replace the template structure with a custom structure.
- Label all assumptions as `Assumption`, inferred content as `Inferred`, unknowns as `Needs human input`.

## Step-by-Step Execution

### Before Starting Any Phase

1. Read the relevant phase instructions from `ux-mob/processes/greenfield-process.md`.
2. Read the corresponding template from `ux-mob/templates/`.
3. Run the Pre-Artifact Generation Checklist: state the artifact name, target save path, template being used, allowed sources, required inputs and their availability. If required inputs are missing, ask for them. Do not proceed.

### Phase Routing

| Phase | Artifact | Template |
|---|---|---|
| 1 — Pre-Client Domain Analysis | domain.md | greenfield-domain-template.md |
| 2 — User Group & Persona Analysis | personas.md | greenfield-personas-template.md |
| 3 — Executable Product Intent | executable-product-intent.md | executable-product-intent-template.md |
| 4 — Client Input Capture | client-input.md | client-input-template.md |
| 5 — Intent Gap Analysis | intent-gap.md | intent-gap-template.md |
| 6 — Client Verification & Scope Agreement | client-verification.md | client-verification-template.md |
| 7 — Intent Cleanup / Scope Removal | executable-product-intent.md (updated) | — |
| 8 — MVP Scope Suggestion (Optional) | mvp-scope.md | mvp-scope-template.md |
| 9 — Feature Map | feature-map.md | feature-map-template.md |
| 10 — User Journeys | user-journeys.md | user-journeys-template.md |
| 11 — AI-DLC Unit Definition | units.md | units-template.md |
| 12 — Unit Validation Cases | unit-validation-cases.md | unit-validation-cases-template.md |
| 13 — Design Direction | design.md | design-direction-template.md |
| 14 — Journey-Based UI Prompt Generation | outputs/ui-prompts/ (one per journey) | ui-prompt-template.md |
| 15 — Design Review & Corrective Prompts (Optional) | design-review.md + outputs/corrective-prompts/ | design-review-template.md |
| 16 — Handoff | greenfield-handoff.md | greenfield-handoff-template.md |

### Per-Phase Execution

1. Announce the phase number and name.
2. Read the required template.
3. State required inputs and check availability. Stop if required inputs are missing.
4. Ask the phase questions.
5. Draft the artifact in chat with a Source Declaration block at the top.
6. Present the draft as `# Draft artifact preview — not saved yet` with target save path and review options (Save / Revise / Add info / Cancel).
7. Save ONLY after explicit save approval to `[workspace-root]/projects/[project-folder]/outputs/[artifact]`.
8. Run the Phase Quality Checklist.
9. Present the Phase Approval Gate. Wait for explicit approval before loading the next phase.
10. Update `project-state.json`.

### Special Phase Rules

- **Phase 3:** Do not create `executable-product-intent.md` until `personas.md` is approved.
- **Phase 5:** Do not create `intent-gap.md` until `client-input.md` is saved and approved.
- **Phase 6:** Require explicit confirmation that client verification is complete before approving.
- **Phase 8:** Ask whether to run or skip. If skipped, record in `project-state.json`.
- **Phase 9:** Ask whether to use full intent or MVP scope. Run the Product Entry & Onboarding check.
- **Phase 10:** Run the Feature Coverage Check before marking complete.
- **Phase 11:** Apply all Unit Definition Rules from `ux-mob/governance/unit-quality-rules.md`. Run Feature Coverage Check before drafting. Every unit must include Source Trace.
- **Phase 12:** Every validation case must trace to a unit AND a product source. Mark missing traceability as `Needs human input: No traceable source found.`
- **Phase 14:** Generate UI prompts journey by journey unless the human explicitly requests a batch.
- **Phase 15:** Ask whether to run. If skipped, record in `project-state.json`. If run, validate against usability heuristics and `unit-validation-cases.md`.
- **Phase 16 (Handoff):** Do not create `greenfield-handoff.md` until all non-optional phases are approved.
