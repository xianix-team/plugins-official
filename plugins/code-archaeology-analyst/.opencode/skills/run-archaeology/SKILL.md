---
name: run-archaeology
description: "Run the full autonomous codebase archaeology analysis on a GitHub Issue or Azure DevOps Work Item tagged 'code-archaeology'. Segments the codebase, maps architecture, extracts conventions, audits for defects, classifies all work, and posts the complete report as ordered comments on the originating issue. Usage: /code-archaeology [issue <n> | wi <id>]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run the full code archaeology analysis for item $ARGUMENTS.

Use the **orchestrator** agent to run the complete five-phase pipeline. The orchestrator will:

1. Detect the hosting platform from `git remote get-url origin` (or read `PLATFORM` / `REPO_URL` / `ISSUE_NUMBER` env vars in CI)
2. Fetch the issue or work item — parse `Repository`, `Focus areas`, `Skip areas`, and `Max segments` from the body
3. Post an "Analysis in Progress" comment immediately
4. Survey the codebase structure (languages, frameworks, directory tree, recent commits)
5. Run **Phase 1** — `segmentation-analyst` decides how to segment the codebase autonomously
6. Run **Phases 2–4 in parallel across all segments:**
   - `architecture-mapper` — module descriptions (Module/Purpose/Owns/Calls/Exposes), service boundaries, data flows
   - `pattern-extractor` — eight pattern types with Consistent / Inconsistent / Split verdicts
   - `due-diligence-auditor` — defects, security gaps, fragile patterns, test blind spots (Critical → Low)
7. Run **Phase 5** — `debt-classifier` classifies all findings into Enhancement / Remediation / Migration at P1–P5
8. Run `report-writer` — produces the full archaeology report at `ai-dlc/reports/code-archaeology-analysis.md`
9. Post five ordered comments on the issue (Architecture Map | Conventions | Findings | Backlog | Complete)
10. Apply the `archaeology-complete` label/tag

If an issue or work item ID is provided (e.g. `/code-archaeology issue 42`), fetch the item details first.

If no argument is given, list open issues tagged `code-archaeology` and prompt for selection.
