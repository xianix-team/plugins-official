# Test Strategist Plugin

> Risk-based impact analysis and **manual-tester-focused** test strategy generation.

Given a PR number, Azure DevOps work item ID, or GitHub issue number, this plugin resolves all linked context — requirements, code changes, child items, comments, and documentation — then produces a **self-contained HTML report** (`impact-analysis-report.html`) that tells a manual tester two things:

1. **Where the highest business risk is** in this change.
2. **How to actually test it** — including ready-to-use, copy-pasteable test data.

Every test case is written in plain language. Each one carries a **"Why this matters"** business statement, a specific **user persona**, a **test data table** with realistic sample values (and boundary / negative / PII-flagged variations), step-by-step actions, the **expected business outcome**, and exactly where to verify it.

Reports are written for **manual QA testers, product owners, and non-technical stakeholders**. They never describe which line of code changed.

---

## Quick Start

```
/test-strategy pr 87
/test-strategy wi 4521
/test-strategy issue 203
/test-strategy              # infers PR from current branch
```

### Flags

| Flag | Purpose |
|---|---|
| `--no-perf` | Skip performance test case generation |
| `--no-a11y` | Skip accessibility & usability test case generation |

```
/test-strategy pr 87 --no-perf --no-a11y
```

---

## How It Works

```mermaid
flowchart TD
    A["/test-strategy"] --> B{Entry Point?}
    B -->|pr N| C[Fetch PR]
    B -->|wi ID| D[Fetch Work Item]
    B -->|issue N| E[Fetch Issue]
    B -->|no arg| F[Infer PR from branch]
    F --> C

    C --> G[Discover linked work item / issue]
    D --> H[Discover linked PRs + child items]
    E --> I[Discover linked PRs]

    G --> J[Gather code changes from all PRs]
    H --> J
    I --> J

    J --> K[Enrich with repo documentation]
    K --> L[Synthesize scope]

    L --> M["Phase 1 (parallel)"]
    M --> N[requirement-collector]
    M --> O[change-analyst]
    M --> P[risk-assessor]

    N --> Q["Phase 2"]
    O --> Q
    P --> Q
    Q --> R[test-guide-writer]

    R --> S["impact-analysis-report.html"]
    S --> T{Platform?}
    T -->|GitHub| U["Markdown summary comment + local HTML"]
    T -->|Azure DevOps| V["HTML attached to work item + comment"]
    T -->|Generic| W["Local HTML file only"]
```

---

## Entry Points

The command accepts three entry points. Only one is needed — the orchestrator resolves the rest automatically via bidirectional discovery.

| Entry Point | Example | What the agent does |
|---|---|---|
| **PR number** | `/test-strategy pr 87` | Fetches the PR diff, then discovers the linked work item or issue to read requirements |
| **Azure DevOps Bug or PBI ID** | `/test-strategy wi 4521` | Fetches the work item fields and comments, then discovers all linked and child PRs |
| **GitHub Issue number** | `/test-strategy issue 203` | Fetches the issue body and comments, then discovers all linked pull requests |
| **No argument** | `/test-strategy` | Infers the PR from the active branch |

---

## Agent Pipeline

### Phase 1 — Context Gathering (parallel)

| Agent | Focus |
|---|---|
| **requirement-collector** | Consolidates requirements: acceptance criteria (PBI/Feature), repro steps + root cause (Bug), child items, comments, referenced documentation |
| **change-analyst** | Translates each code change into user-visible behaviour ("what does the user notice?"); cross-references against requirements; flags "Developer Changes Requiring Clarification" with an actionable question for the developer |
| **risk-assessor** | Business-level risk summary plus a ranked **Top Focus Areas** list that drives the report's "Where Testers Should Focus First" section |

### Phase 2 — Report Generation

| Agent | Focus |
|---|---|
| **test-guide-writer** | Produces the final HTML report with 13 sections, business-oriented test cases across 7 categories with full test data tables, coverage map, and QA sign-off checklist |

---

## Report Sections

The HTML report contains **13 sections**, ordered so a manual tester sees risk and focus areas before any test cases:

| # | Section | Purpose |
|---|---|---|
| 1 | **Summary** | Work item metadata, overall risk, test case count, linked PRs, and a one-sentence headline business risk |
| 2 | **Where Testers Should Focus First** | Top 3–5 highest-risk business areas with the test case IDs that cover them — the "first hour of testing" guide |
| 3 | **Business Risk Assessment** | What could go wrong, who is affected, how severe — business language only |
| 4 | **Impacted Areas** | Direct and indirect impact on user workflows, integrations, and data |
| 5 | **Context Gathered** | Linked PRs, child work items, changesets, referenced documentation |
| 6 | **Code Changes Overview** | Per-PR cards translating file changes into user-visible behaviour — no raw diffs |
| 7 | **Requirements Coverage** | Each requirement mapped to the code changes that address it, with user-visible evidence |
| 8 | **Developer Changes Requiring Clarification** | Code changes not explained by any stated requirement — flagged with an actionable question for the developer |
| 9 | **Missing Requirement Coverage** | Requirements with no corresponding code change found |
| 10 | **Test Cases** | Self-contained tester instructions across seven categories — see "Test Case Anatomy" below |
| 11 | **Coverage Map** | Matrix: requirements → test cases, business risks → test cases, explicitly out of scope |
| 12 | **Environment & Assignment** | Area path, iteration, developer, tester, environment/data/account needs |
| 13 | **QA Sign-off** | Interactive checklist for the tester to confirm completion |

---

## Test Case Anatomy

Every test case is a self-contained set of instructions a manual tester can run without reading the code. Each one includes:

| Field | Purpose |
|---|---|
| **ID + title** | Sequential `TC-NNN` and a plain-language scenario starting with a verb the user performs |
| **Why this matters** | One or two sentences. Business outcome verified if it passes; business loss if it fails; affected users |
| **Linked to** | The requirement (AC/RS) **and** the business risk (Risk-N) this case covers — no orphan test cases |
| **User role / persona** | The specific kind of user running the scenario |
| **Preconditions** | System state, environment, feature flags, existing data |
| **Test data** | A table of concrete copy-pasteable sample values, with boundary / PII / PCI / invalid flags |
| **Steps** | Numbered observable user actions — no code references |
| **Expected business outcome** | What the user sees and what the business gains |
| **How to verify** | Where the tester looks: UI cues, emails, records (technical hints permitted only here) |
| **If this fails** | What evidence to capture, which risk it confirms, who to escalate to |

---

## Test Data Generation

The plugin generates concrete, synthetic test data for every test case — the tester can copy and paste it. Generation covers:

- **Identifiers** — `*.test@example.com` / `Test-NNNN` patterns
- **Money / quantity** — currency-correct values around any thresholds (just below / at / just above)
- **Dates / times** — relative to "today", with edge dates (DST, leap day, far past / future) where relevant
- **Free-text** — short, long, with apostrophes ("O'Brien"), with non-ASCII (José, 王芳)
- **Geographic data** — postal codes, phone numbers in the system's actual format
- **Payment data** — known test cards (`4242 4242 4242 4242` for success, `4000 0000 0000 9995` for declined) — never real card numbers
- **Boundary values** — minimum, just below, maximum, just above, empty, whitespace, special characters, format-invalid
- **Negative test data** — expired coupons, blocked customers, oversized uploads, SQL/script-like strings, role-escalation attempts
- **PII / PCI / PHI tags** — every sensitive field is flagged in the test data table

Performance, accessibility, resilience, and compatibility test cases include category-specific extras (load profile, assistive technology, failure simulation, target browsers / OS / API versions).

---

## Test Case Categories

| Emoji | Category | When generated |
|---|---|---|
| 🟢 | **Functional** | Always |
| 🔵 | **Performance** | Change touches a service, query, or data pipeline (skipped with `--no-perf`) |
| 🔴 | **Security** | Change touches authentication, data input, API surfaces, or permissions |
| 🟡 | **Privacy & PII** | Change handles personal, financial, or health data |
| 🟣 | **Accessibility & Usability** | Change touches any user interface (skipped with `--no-a11y`) |
| ⚪ | **Resilience** | Change touches a service call, queue, or external dependency |
| 🟤 | **Compatibility** | Change touches a UI, public API, integration point, or shared contract |

Categories with no realistic surface are skipped automatically.

---

## Platform Support

The plugin auto-detects the hosting platform from the git remote URL:

| Remote URL contains | Platform | Fetch | Deliver |
|---|---|---|---|
| `github.com` | GitHub | `gh` CLI | Markdown summary comment on the issue/PR + local `impact-analysis-report.html` |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API | HTML report **attached to the work item** + notification comment (+ PR thread if triggered from PR) |
| Anything else | Generic | Git + user input | Local `impact-analysis-report.html` only |

---

## Rule Examples

### GitHub — PR

```
When using test-strategist on a GitHub repository and a PR number is provided,
you should /test-strategy pr 87

This will:
1. Fetch the PR diff and metadata via gh CLI
2. Discover linked issues from closingIssuesReferences and PR body
3. Fetch each linked issue's body, labels, and comments
4. Run the 4-agent pipeline
5. Post a markdown summary comment on the PR
6. Write impact-analysis-report.html locally
```

### GitHub — Issue

```
When using test-strategist on a GitHub repository and an issue number is provided,
you should /test-strategy issue 203

This will:
1. Fetch the issue body, labels, and comments via gh CLI
2. Discover linked PRs via timeline API and body search
3. Fetch diffs from each linked PR
4. Run the 4-agent pipeline
5. Post a markdown summary comment on the issue
6. Write impact-analysis-report.html locally
```

### Azure DevOps — PR

```
When using test-strategist on an Azure DevOps repository and a PR number is provided,
you should /test-strategy pr 42

This will:
1. Fetch the PR metadata and iterations via REST API
2. Discover linked work items from the PR
3. Fetch each work item with all fields, comments, and relations
4. Fetch child work items and changesets
5. Run the 4-agent pipeline
6. Attach impact-analysis-report.html to the work item
7. Post a notification comment on the work item and a thread on the PR
```

### Azure DevOps — Work Item

```
When using test-strategist on an Azure DevOps repository and a work item ID is provided,
you should /test-strategy wi 4521

This will:
1. Fetch the work item with all fields, comments, and relations via REST API
2. Auto-detect Bug vs PBI/Feature and read appropriate fields
3. Discover all linked PRs and child work items
4. Fetch changesets attached to the work item
5. Run the 4-agent pipeline
6. Attach impact-analysis-report.html to the work item
7. Post a notification comment on the work item
```

---

## Environment Variables

| Variable | Required | Platform | Purpose |
|---|---|---|---|
| `GITHUB_TOKEN` | If not using `gh auth login` | GitHub | GitHub API authentication |
| `AZURE_DEVOPS_TOKEN` | Yes | Azure DevOps | Personal Access Token for REST API |
| `AZURE_ORG` | No | Azure DevOps | Override org parsed from remote URL |
| `AZURE_PROJECT` | No | Azure DevOps | Override project parsed from remote URL |
| `AZURE_REPO` | No | Azure DevOps | Override repo parsed from remote URL |

### Token Permissions

**GitHub:**

| Permission | Access |
|---|---|
| Contents | Read |
| Metadata | Read |
| Issues | Read |
| Pull requests | Read & Write |

**Azure DevOps:**

| Permission | Access |
|---|---|
| Work Items | Read & Write |
| Code | Read |
| Pull Requests | Read |

---

## Prerequisites

- Must be run inside a git repository
- **GitHub**: `gh` CLI installed and authenticated (`gh auth login` or `GITHUB_TOKEN`)
- **Azure DevOps**: `AZURE_DEVOPS_TOKEN` environment variable set

Verify prerequisites:

```bash
git --version    # required
gh auth status   # GitHub only
echo $AZURE_DEVOPS_TOKEN  # Azure DevOps only
```

---

## Plugin Structure

```
test-strategist/
├── .claude-plugin/
│   ├── plugin.json           # Plugin manifest
│   ├── .lsp.json             # Language server configs
│   └── settings.json         # Default agent setting
├── agents/
│   ├── orchestrator.md       # Main orchestrator — coordinates all agents
│   ├── requirement-collector.md  # Consolidates testable requirements
│   ├── change-analyst.md     # Analyzes code changes vs requirements
│   ├── risk-assessor.md      # Business-level risk assessment
│   └── test-guide-writer.md  # Produces the 12-section HTML report
├── commands/
│   └── test-strategy.md      # /test-strategy command definition
├── docs/
│   └── platform-config.md    # Platform setup and token permissions
├── hooks/
│   ├── hooks.json            # Hook configuration
│   └── validate-prerequisites.sh  # Pre-run validation
├── providers/
│   ├── azure-devops.md       # Azure DevOps API instructions
│   ├── generic.md            # Generic/fallback platform
│   └── github.md             # GitHub CLI instructions
├── skills/
│   ├── analyze-changes/SKILL.md
│   ├── assess-risk/SKILL.md
│   ├── collect-requirements/SKILL.md
│   ├── generate-test-strategy/SKILL.md
│   ├── post-strategy/SKILL.md
│   └── write-test-guide/SKILL.md
└── styles/
    ├── report-template.md    # 12-section HTML template
    └── strategy.md           # Output style conventions
```
