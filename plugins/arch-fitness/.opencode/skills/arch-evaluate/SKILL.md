---
name: arch-evaluate
description: "Evaluate a changeset scope against existing architecture constraints and report the few most important improvements. Does not create or update docs. Usage: /arch-evaluate [scope] [--pr <n>] [--since <date>] [--issue <n> | --workitem <id>]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run an **evaluate-only** architecture fitness pass for $ARGUMENTS.

This is the evaluation half of `/arch-fitness`. It assumes constraint documents already exist (typically under `docs/architecture/`). It does **not** bootstrap or update docs and does **not** open a docs PR — use `/arch-docs` or the full `/arch-fitness` command for that.

## Steps

1. Detect platform from `git remote get-url origin`.
2. Capture inputs (CLI scope + optional task body config block).
3. Locate constraint-bearing docs (`docs/architecture/constraints.md` preferred). If none exist, stop with an error directing the caller to `/arch-docs`.
4. Assemble the changeset scope (PR / branch / merged window) via the matching provider.
5. Invoke the **`fitness-evaluator`** agent with `DOCS_MODE=evaluate-only` and `CONSTRAINTS_SOURCE=existing`.
6. Route the report:
   - Task mode → comment on the issue / work item (unless `Output:` overrides)
   - Chat mode → print the report
   - `Output: file <path>` / `json` → follow the instruction
   - Generic remote → write `arch-fitness-report.md`

Follow `styles/fitness-report.md` for the report shape and the platform provider for I/O.

## Output

Fitness report with verdict (`FIT` / `DRIFTING` / `AT RISK`) and up to `Max findings` improvements.
