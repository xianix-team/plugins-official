---
name: assess-risk
description: "Evaluate risk areas for testing — rate changes by impact, complexity, coverage, and data sensitivity. Identify edge cases, regression hotspots, and produce a risk-prioritized testing recommendation. Usage: /assess-risk [issue-number or work-item-id]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Assess testing risks for $ARGUMENTS.

Use the **risk-assessor** agent. It will:
- Risk-rate each functional area across impact, complexity, coverage, integration density, and data sensitivity
- Identify critical and high-risk scenarios with business impact
- Surface edge cases and boundary conditions
- Evaluate regression risks from code changes
- Assess data integrity concerns
- Produce a prioritized testing order: must-test → should-test → could-test → smoke-only
