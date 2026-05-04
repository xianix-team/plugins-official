---
name: impact-analysis
description: Unified impact analysis and risk-based test strategy. Analyzes a PR, GitHub issue, or Azure DevOps work item — traces blast radius, maps affected features, cross-references requirements, and produces a self-contained HTML report with structured test cases across seven categories. Usage: /impact-analysis [pr|issue|wi] [id] [--no-perf] [--no-a11y]
argument-hint: [pr <n> | wi <id> | issue <n>] [--no-perf] [--no-a11y]
---

Run a full impact analysis and risk-based test strategy for $ARGUMENTS.

## What This Does

Invokes the **orchestrator** agent to gather everything needed — PR diffs, blast radius, feature mapping, work item requirements, comments, child items, and referenced documentation — then produces a **self-contained HTML report** with:

- Blast radius and dependency map
- Affected features and user journeys
- Requirements traceability (when a work item or issue is linked)
- Developer Changes Requiring Clarification
- Business risk assessment
- Structured test cases across seven categories
- Coverage map and QA sign-off checklist

Reports are written for **QA engineers, product owners, and non-technical stakeholders**.

## Entry Points

| Entry Point | Example | What the agent does |
|---|---|---|
| **PR number** | `/impact-analysis pr 87` | Fetches PR diff + blast radius, then discovers linked work item/issue for requirements |
| **Azure DevOps Bug or PBI ID** | `/impact-analysis wi 4521` | Fetches work item fields and comments, discovers all linked PRs |
| **GitHub Issue number** | `/impact-analysis issue 203` | Fetches issue body and comments, discovers all linked pull requests |
| **No argument** | `/impact-analysis` | Analyzes current branch vs main |

## Flags

| Flag | Purpose |
|---|---|
| `--no-perf` | Skip Performance test case generation |
| `--no-a11y` | Skip Accessibility & Usability test case generation |

## Pipeline

**Step 1–3:** Gather git context, pre-compute codebase fingerprint, resolve entry point and linked context.

**Step 4:** Trivial PR fast-path check — if all changed files are docs/tests/formatting and total lines < 50, skip dependency-tracer, feature-mapper, and requirement-collector.

**Phase 1 (parallel):**

| Agent | Focus |
|---|---|
| `requirement-collector` | Consolidates requirements from the work item/issue — acceptance criteria (PBI/Feature/Issue), repro steps and root cause (Bug), child items, comments. Skipped if PR-only with no linked work item. |
| `change-analyst` | Classifies every changed file, maps changes to behavioral impact in business language, cross-references against requirements, flags unexplained changes |
| `dependency-tracer` | Traces callers, callees, data flows, and transitive dependencies — produces the blast radius |
| `feature-mapper` | Maps changed code to routes, UI pages, user journeys, and business workflows |

**Phase 2:**

| Agent | Focus |
|---|---|
| `risk-assessor` | Rates each area on 8 dimensions (impact, complexity, change frequency, test coverage, integration density, data sensitivity, user exposure, blast radius). Tags which test surfaces exist. Sole authority on overall risk level. |

**Phase 3:**

| Agent | Focus |
|---|---|
| `report-writer` | Produces the final 14-section HTML report with test cases, coverage map, and QA sign-off checklist |

## Test Case Categories

| Category | When generated |
|---|---|
| 🟢 **Functional** | Always |
| 🔵 **Performance** | Change touches a service, query, or data pipeline (skipped with `--no-perf`) |
| 🔴 **Security** | Change touches authentication, data input, API surfaces, or permission logic |
| 🟡 **Privacy & PII** | Change handles personal, financial, or health data |
| 🟣 **Accessibility & Usability** | Change touches any user interface (skipped with `--no-a11y`) |
| ⚪ **Resilience** | Change touches a service call, queue, or external dependency |
| 🟤 **Compatibility** | Change touches a UI, public API, integration point, or shared contract |

Categories with no realistic surface are skipped automatically.

## Output

- **HTML report:** `impact-analysis-{YYYY-MM-DD}-{entry-id}.html` — self-contained, printable, opens in any browser
- **Platform comment:** Markdown summary posted to the PR/issue/work item (platform-dependent)

## Platform Support

| Remote URL | Platform | Deliver |
|---|---|---|
| `github.com` | GitHub | Markdown summary comment on PR/issue + local HTML |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | HTML attached to work item + notification comment |
| Anything else | Generic | Local HTML only |

## Prerequisites

- Must be run inside a git repository
- **GitHub:** `gh` CLI installed and authenticated (see `docs/platform-config.md`)
- **Azure DevOps:** `AZURE_DEVOPS_TOKEN` environment variable set (see `docs/platform-config.md`)

---

Starting impact analysis now...
