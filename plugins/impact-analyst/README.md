# Impact Analyst

Unified impact analysis and risk-based test strategy plugin. Combines blast radius tracing, dependency mapping, feature impact analysis, and structured test case generation into a single 14-section HTML report.

This plugin merges the best of two approaches:
- **Blast radius + dependency tracing** from `imp-analyst` — how far do the changes ripple?
- **Structured test cases + requirements traceability** from `test-strategist` — what exactly should be tested and why?

---

## Quick Start

```bash
# Analyze current branch
/impact-analysis

# Analyze a specific PR
/impact-analysis pr 87

# Analyze a GitHub issue and all linked PRs
/impact-analysis issue 203

# Analyze an Azure DevOps work item
/impact-analysis wi 4521

# Skip performance and accessibility test cases
/impact-analysis pr 87 --no-perf --no-a11y
```

---

## Pipeline

```
/impact-analysis
    └── orchestrator
          │
          ├── Step 1: Detect platform + gather git context
          ├── Step 2: Pre-compute codebase fingerprint
          ├── Step 3: Resolve entry point + discover linked context
          ├── Step 4: Trivial PR fast-path check
          │
          ├── Phase 1 (parallel):
          │     ├── requirement-collector   [skipped if PR-only]
          │     ├── change-analyst
          │     ├── dependency-tracer       [skipped if fast-path]
          │     └── feature-mapper          [skipped if fast-path]
          │
          ├── Phase 2:
          │     └── risk-assessor
          │
          └── Phase 3:
                └── report-writer  →  impact-analysis-{YYYY-MM-DD}-{id}.html
```

---

## Report Structure (14 sections)

| # | Section | Notes |
|---|---|---|
| 1 | Summary | Risk badge, test case counts, blast radius, linked PRs |
| 2 | Context Gathered | PRs, child work items, docs |
| 3 | Code Changes Overview | Per-PR file cards |
| 4 | **Blast Radius & Dependency Map** | Direct callers, data flows, transitive dependencies |
| 5 | **Affected Features & User Journeys** | Routes, UI pages, user scenarios |
| 6 | Requirements Coverage | Req → code mapping (N/A if no work item) |
| 7 | Developer Changes Requiring Clarification | Unexplained changes (N/A if no work item) |
| 8 | Missing Requirement Coverage | Gaps (N/A if no work item) |
| 9 | Business Risk Assessment | Risk matrix + scenarios |
| 10 | Test Cases | 7 categories, TC-001 format |
| 11 | Coverage Map | Req→TC, Risk→TC, out-of-scope |
| 12 | Impacted Areas | High/Medium/Low ratings |
| 13 | Environment & Assignment | Developer, tester, iteration |
| 14 | QA Sign-off | Interactive checkboxes |

Sections 4 and 5 are new additions — not present in either source plugin.

---

## Test Case Categories

| Category | When generated |
|---|---|
| 🟢 **Functional** | Always |
| 🔵 **Performance** | Service/query/pipeline changes (skipped with `--no-perf`) |
| 🔴 **Security** | Auth, input, API, permissions changes |
| 🟡 **Privacy & PII** | Personal/financial/health data handling |
| 🟣 **Accessibility & Usability** | UI changes (skipped with `--no-a11y`) |
| ⚪ **Resilience** | Service calls, queues, external dependencies |
| 🟤 **Compatibility** | Public APIs, shared schemas, contracts |

Test case priority maps from risk-assessor output: P0 → Critical, P1 → High, P2 → Medium.

---

## Entry Points

| Argument | Platform | What the agent resolves |
|---|---|---|
| `pr <n>` | GitHub or Azure DevOps | PR diff + discovers linked issue/WI |
| `issue <n>` | GitHub only | Issue body + discovers linked PRs |
| `wi <id>` | Azure DevOps only | Work item fields + discovers linked PRs |
| *(none)* | Both | Current branch vs main |

---

## Platform Support

| Remote URL | Platform | Report Delivery |
|---|---|---|
| `github.com` | GitHub | Markdown summary comment on PR/issue + local HTML |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | HTML attached to work item + notification comment |
| Anything else | Generic | Local HTML only |

---

## Prerequisites

- Git repository required
- **GitHub:** `gh` CLI installed and authenticated (`gh auth login`)
- **Azure DevOps:** `AZURE_DEVOPS_TOKEN` environment variable set

See `docs/platform-config.md` for detailed setup instructions.

---

## Flags

| Flag | Effect |
|---|---|
| `--no-perf` | Skip Performance test cases |
| `--no-a11y` | Skip Accessibility & Usability test cases |

---

## Key Design Decisions

- **Timestamped output** — `impact-analysis-{YYYY-MM-DD}-{id}.html` — repeated runs never overwrite previous reports
- **risk-assessor is sole authority** on overall risk level — orchestrator reads it, never re-derives it
- **Trivial PR fast-path** — docs/tests/formatting changes < 50 lines skip 3 of 4 Phase 1 agents
- **Budget warnings** — dependency-tracer and change-analyst emit explicit warnings if tool budget is reached
- **Phase validation** — orchestrator checks Phase 1 outputs before dispatching Phase 2, and Phase 2 before Phase 3
- **PR-only mode** — works without a work item; sections 6/7/8/13 render as N/A; test cases anchor to risks and user scenarios
