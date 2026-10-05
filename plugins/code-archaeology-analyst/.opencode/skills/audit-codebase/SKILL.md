---
name: audit-codebase
description: "Run only Phase 4 — due diligence audit for a single segment. Actively searches for logic defects, design violations, security gaps, fragile patterns, test blind spots, and consistency breaks. Assigns Critical / High / Medium / Low severity with Fix-in-place / Quarantine / Encode-as-prohibition recommendations. Usage: /audit-codebase <segment-path>"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run Phase 4 due diligence audit on the segment at `$ARGUMENTS`.

## Steps

1. Treat the argument as `SEGMENT_SCOPE`. Use the directory name as `SEGMENT_NAME`.

2. Use the **due-diligence-auditor** agent, passing it:
   - `SEGMENT_NAME` (derived from path)
   - `SEGMENT_SCOPE` (from argument)
   - `TARGET_PATH` (repository root — current directory)

3. Output the findings directly. Do not post to any platform.

This skill is useful for targeted auditing of a specific module before beginning AI-assisted development on it.
