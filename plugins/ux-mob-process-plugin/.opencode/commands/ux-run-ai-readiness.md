---
description: Run the Brownfield AI Readiness assessment. Required before Add New Feature, Complete Revamp, or Improve Existing Feature.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# ux-run-ai-readiness

# Instructions
1. Follow `.agents/workflows/run-brownfield-ai-readiness.md`.
2. Ensure all outputs are saved to `[workspace-root]/projects/[project-folder]/outputs/ai-readiness/`.


## Brownfield AI Readiness Artifact Existence and Skip Rule

Before running each AI Readiness phase, the agent must check whether the target artifact already exists under:
`[workspace-root]/projects/[project-folder]/outputs/ai-readiness/`

If the artifact exists, the agent must ask:
"This artifact already exists. How should we proceed?"

Options:
1. Use existing artifact as approved
2. Review existing artifact
3. Revise existing artifact
4. Recreate artifact from scratch
5. Skip this artifact as not applicable

Rules:
- Do not overwrite an existing artifact without explicit human approval.
- If the human chooses "Use existing artifact as approved", record it in project-state.json and decision log.
- If the human chooses "Review existing artifact", show it in chat first.
- If the human chooses "Recreate artifact from scratch", archive the old artifact before replacing it.
- If the human chooses "Skip as not applicable", record the reason.


## Mandatory Brownfield Starter Rule

When the user selects Brownfield, do not immediately ask whether they want Add New Feature, Complete Revamp, or Improve Existing Feature.
First run Brownfield AI Readiness.
In AI Readiness Phase 1, check existing artifacts and decide what can be reused.
After AI Readiness is approved, then ask which Brownfield work type to run:
1. Add New Feature
2. Complete Revamp
3. Improve Existing Feature
