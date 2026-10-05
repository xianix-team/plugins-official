---
name: analyze-impact
description: Runs the full impact analysis and test strategy pipeline. Traces blast radius, maps affected features, cross-references requirements, and produces a 14-section HTML report with structured test cases across seven categories.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Skill: Analyze Impact

Triggers the **orchestrator** agent to run the full impact analysis and test strategy pipeline for the given entry point.

## Usage

```
/impact-analysis [pr <n> | wi <id> | issue <n>] [--no-perf] [--no-a11y]
```

## What It Does

1. Gathers git context and pre-computes codebase fingerprint
2. Resolves the entry point and discovers all linked context
3. Runs 4 specialist agents in parallel: requirement-collector, change-analyst, dependency-tracer, feature-mapper
4. Runs risk-assessor with all Phase 1 outputs
5. Produces a self-contained 14-section HTML report

## Output

- `impact-analysis-{YYYY-MM-DD}-{entry-id}.html` — full report
- Platform comment (GitHub / Azure DevOps) with markdown summary
