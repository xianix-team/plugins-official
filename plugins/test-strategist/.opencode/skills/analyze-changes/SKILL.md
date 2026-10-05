---
name: analyze-changes
description: "Analyze code changes across linked pull requests — map diffs to functional areas, identify integration points, and assess test coverage gaps. Usage: /analyze-changes [issue-number or work-item-id]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Analyze all code changes linked to $ARGUMENTS.

Use the **change-analyst** agent. It will:
- Classify every changed file by functional area and risk level
- Map code changes to behavioral changes in business terms
- Identify integration points (APIs, databases, external services, events)
- Assess regression surface from shared/modified code
- Evaluate existing test coverage and identify gaps

The output is a structured change analysis with testable impact statements.
