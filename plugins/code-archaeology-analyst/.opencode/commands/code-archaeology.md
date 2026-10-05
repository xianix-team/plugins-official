---
description: "Autonomous codebase archaeology analysis triggered by a GitHub Issue or Azure DevOps Work Item tagged 'code-archaeology'. Fetches the item, runs five autonomous phases across all segments, and delivers the complete report as ordered comments on the originating issue — plus writing the full report to ai-dlc/reports/code-archaeology-analysis.md. Usage: /code-archaeology [issue <n> | wi <id>]"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run the full autonomous code archaeology analysis for $ARGUMENTS.

## What This Does

Invokes the **orchestrator** agent. It detects the platform, fetches the triggering issue, posts an "Analysis in Progress" comment immediately, runs five autonomous phases, and delivers the complete structured report as ordered comments on the originating issue.

**Developers do not guide the agent during execution.** They create the issue with an optional configuration block, run this command, and consume the report.

## Creating the Triggering Issue

Create a GitHub Issue (or Azure DevOps Work Item) with the `code-archaeology` label. The body may contain an optional configuration block:

```
ARCHAEOLOGY AGENT — START

Repository: src/               (optional — defaults to repo root)
Focus areas: src/auth, src/payments   (optional — paths to prioritize)
Skip areas:  src/legacy        (optional — paths to exclude)
Max segments: 5                (optional — integer cap; default: auto)
```

If omitted, the agent uses autonomous defaults: recently modified files and business-critical module names (auth, payments, orders, core, api) are prioritized automatically.

## Pipeline

```
/code-archaeology issue 42
    └── orchestrator
          │
          ├── Step 0: Detect platform (GitHub / Azure DevOps / Generic)
          ├── Step 1: Fetch issue #42 — parse Repository, Focus areas, Skip areas, Max segments
          ├── Step 2: Post "Analysis in Progress" comment  ← immediate
          ├── Step 3: Initial codebase survey (structure, languages, frameworks, recent commits)
          │
          ├── Phase 1:
          │     └── segmentation-analyst  — divides codebase into 15–25 file segments autonomously
          │
          ├── Phases 2–4 (parallel across all segments):
          │     ├── architecture-mapper   — Module/Purpose/Owns/Calls/Exposes, service boundaries, data flows
          │     ├── pattern-extractor     — 8 pattern types, Consistent / Inconsistent / Split verdicts
          │     └── due-diligence-auditor — Logic defects, Design violations, Security gaps,
          │                                 Fragile patterns, Test blind spots, Consistency breaks
          │
          ├── Phase 5:
          │     └── debt-classifier       — Enhancement / Remediation / Migration at P1–P5
          │
          ├── report-writer  →  ai-dlc/reports/code-archaeology-analysis.md
          │
          └── Post 5 ordered comments + apply 'archaeology-complete' label
```

## Entry Points

| Argument | Example | What the agent resolves |
|---|---|---|
| `issue <n>` | `/code-archaeology issue 42` | GitHub issue #42 — reads body for configuration |
| `wi <id>` | `/code-archaeology wi 1023` | Azure DevOps work item — reads description for configuration |

## Comment Thread

| # | Heading | Content |
|---|---------|---------|
| 0 | Analysis in Progress (immediate) | Before any work starts |
| 1 | `🗺️ Architecture & Segment Map` | Segment plan + module descriptions + service boundaries |
| 2 | `🔍 Coding Conventions` | 8 pattern types — Confirmed / Inconsistency / Split |
| 3 | `🔎 Due Diligence Findings` | Critical → High → Medium → Low findings |
| 4 | `📋 Work Backlog` | Prioritized Enhancement / Remediation / Migration items at P1–P5 |
| 5 | `✅ Analysis Complete` | Confidence, next steps, blast radius controls |

Comments with no meaningful findings are skipped.

## Platform Support

| Remote URL | Platform | Delivery |
|---|---|---|
| `github.com` | GitHub | 5 ordered comments via `gh` CLI + `archaeology-complete` label |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | 5 ordered comments via REST API + `archaeology-complete` tag |
| Anything else | Generic | Report written to `ai-dlc/reports/code-archaeology-analysis.md` only |

## Individual Skills

Run individual phases without the full pipeline:

| Skill | Phase | Usage |
|---|---|---|
| `/segment-codebase` | 1 | Segment a path without full analysis |
| `/map-architecture` | 2 | Map one segment's architecture |
| `/extract-patterns` | 3 | Extract patterns from one segment |
| `/audit-codebase` | 4 | Audit one segment for defects |
| `/classify-debt` | 5 | Classify findings into a work backlog |
| `/post-report` | — | Post an existing report to an issue |

## Prerequisites

- Must be run inside a git repository
- **GitHub:** `gh` CLI installed and authenticated (`gh auth login`)
- **Azure DevOps:** `AZURE-DEVOPS-TOKEN` environment variable set
- **Generic / plain text:** nothing required

---

Starting code archaeology analysis now...
