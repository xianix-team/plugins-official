---
name: test-strategy
description: Generate a risk-based test strategy and impact analysis. Accepts three entry points — a PR number, an Azure DevOps work item ID, or a GitHub issue number — then resolves all linked context and produces a business-readable HTML report. Usage: /test-strategy [pr|wi|issue] [id] [--no-perf] [--no-a11y]
argument-hint: [pr <n> | wi <id> | issue <n>] [--no-perf] [--no-a11y]
---

Generate a risk-based test strategy and impact analysis for $ARGUMENTS.

## What This Does

Invokes the **orchestrator** agent to gather everything needed to understand what was built — work item requirements, code changes across linked pull requests, comments, child items, and referenced documentation — then produces a business-readable HTML report that serves as the testing guide for QA engineers doing risk-based testing.

Reports are written for **QA engineers, product owners, and non-technical stakeholders**. Test cases describe _what_ to verify and _why it matters_ — not which line of code changed.

## Entry Points

The command accepts three entry points. Only one is needed — the orchestrator resolves the rest automatically.

| Entry Point | Example | What the agent does |
|---|---|---|
| **PR number** | `/test-strategy pr 87` | Fetches the PR diff, then discovers the linked work item or issue to read requirements |
| **Azure DevOps Bug or PBI ID** | `/test-strategy wi 4521` | Fetches the work item fields and comments, then discovers all linked and child PRs |
| **GitHub Issue number** | `/test-strategy issue 203` | Fetches the issue body and comments, then discovers all linked pull requests |
| **No argument** | `/test-strategy` | Infers the PR from the active branch |

## Flags

| Flag | Purpose |
|---|---|
| `--no-perf` | Skip performance test case generation |
| `--no-a11y` | Skip accessibility & usability test case generation |

## Pipeline

**Phase 1 — Context gathering (parallel):**

| Agent | Focus |
|---|---|
| `requirement-collector` | Consolidates requirements from the work item / issue, child items, comments, acceptance criteria (PBI/Feature), repro steps and root cause (Bug), and referenced documentation into a traceable requirements map |
| `change-analyst` | Analyzes all code changes across linked pull requests — maps diffs to functional areas, identifies integration points and regression surface, and flags changes that cannot be explained by the stated requirements |
| `risk-assessor` | Produces a business-level risk summary — what could break, who is affected, and how severe the impact would be |

**Phase 2 — Report generation:**

| Agent | Focus |
|---|---|
| `test-guide-writer` | Produces the final HTML impact-analysis report with test cases across seven categories, a coverage map, and a QA sign-off checklist |

## Test Case Categories

| Category | When generated |
|---|---|
| 🟢 **Functional** | Always |
| 🔵 **Performance** | When the change touches a service, query, or data pipeline with realistic performance exposure (skipped with `--no-perf`) |
| 🔴 **Security** | When the change touches authentication, data input, API surfaces, or permission logic |
| 🟡 **Privacy & PII** | When the change handles personal, financial, or health data |
| 🟣 **Accessibility & Usability** | When the change touches any user interface (skipped with `--no-a11y`) |
| ⚪ **Resilience** | When the change touches a service call, queue, or external dependency |
| 🟤 **Compatibility** | When the change touches a UI, a public API, an integration point, or a contract shared with other systems |

Categories with no realistic surface are skipped automatically.

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | Fetch | Deliver |
|---|---|---|---|
| `github.com` | GitHub | `gh` CLI | Markdown summary comment on the issue/PR + local `impact-analysis-report.html` |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API | HTML report attached to the work item + comment on work item (and PR if triggered from PR) |
| Anything else | Generic | Git + user input | Local `impact-analysis-report.html` only |

## Prerequisites

- Must be run inside a git repository
- **GitHub**: `gh` CLI installed and authenticated (see `docs/platform-config.md`)
- **Azure DevOps**: `AZURE-DEVOPS-TOKEN` environment variable set (see `docs/platform-config.md`)

---

Starting impact analysis and test strategy generation now...
