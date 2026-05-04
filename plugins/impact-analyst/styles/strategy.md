# Output Style: Impact Analysis & Test Strategy

This style guide defines the conventions used when generating the impact analysis and test strategy report. It applies to the `report-writer` agent and to any markdown summary posted on the platform.

---

## Audience

The primary readers are **QA engineers**, **product owners**, and **non-technical stakeholders**. All output must be written in **business language**:

- Describe _what_ a user would experience, not which line of code changed.
- Describe _who_ is affected and _how_, not the internal mechanism.
- Use domain terms from the work item, not implementation terms.

---

## Test Case Categories

Seven categories, each with a color-coded badge. Categories with no realistic surface in the current change must be **skipped entirely** — never generate empty sections.

| Emoji | Badge Class | Category | When to include |
|---|---|---|---|
| 🟢 | `tc-functional` | **Functional** | Always — every change must have functional test coverage |
| 🔵 | `tc-performance` | **Performance** | Change touches a service, query, or data pipeline with realistic performance exposure |
| 🔴 | `tc-security` | **Security** | Change touches authentication, data input, API surfaces, or permission logic |
| 🟡 | `tc-privacy` | **Privacy & PII** | Change handles personal, financial, or health data |
| 🟣 | `tc-accessibility` | **Accessibility & Usability** | Change touches any user interface |
| ⚪ | `tc-resilience` | **Resilience** | Change touches a service call, queue, or external dependency |
| 🟤 | `tc-compatibility` | **Compatibility** | Change touches a UI, public API, integration point, or contract shared with other systems |

### Category Suppression Flags

| Flag | Effect |
|---|---|
| `--no-perf` | Skip 🔵 Performance test cases entirely |
| `--no-a11y` | Skip 🟣 Accessibility & Usability test cases entirely |

When a flag is active, omit the category from the report, the coverage map, and the QA sign-off checklist.

---

## Test Case Format

Each test case must include:

| Field | Content |
|---|---|
| **ID** | Sequential: `TC-001`, `TC-002`, etc. Numbering is global across all categories. |
| **Title** | Business-readable description of what is being tested |
| **Category badge** | One of the 7 badges above |
| **Priority** | Uses the risk badge: `risk-critical`, `risk-high`, `risk-medium`, `risk-low` |
| **Linked Requirement** | Which acceptance criterion, repro step, or risk this test covers (e.g. AC1, RS2, Risk-3) |
| **Preconditions** | System state, test data, user role required before the test begins |
| **Steps** | Numbered, specific, actionable steps. Use business language. |
| **Test Data** | Specific values, records, or inputs to use |
| **Expected Result** | Observable, verifiable outcome from a user's perspective |

---

## Developer Changes Requiring Clarification

These are code changes that could not be mapped to any stated requirement. They are flagged, not tested — the tester must discuss with the developer before testing.

### Category Tags

| Emoji | Category | Meaning |
|---|---|---|
| 🔧 | **Refactoring** | Structural change with no new behaviour |
| 📊 | **Observability** | Logging, metrics, or monitoring additions |
| 🧹 | **Housekeeping** | Dependency updates, linting, config changes |
| 🔄 | **Tech-Debt** | Known technical debt remediation |
| ➕ | **Undocumented Feature** | New behaviour not mentioned in requirements |
| 🔀 | **Scope Creep** | Change that appears outside the scope of this work item |

### Clarification Card Format

```
[Category emoji] [Category] — [Change title]
  Change: [What the code does differently]
  Location: [File and functional area]
  Hypothesis: [Best guess of intent — if possible]
  Status: Needs Clarification
```

---

## Coverage Map

The coverage map provides explicit traceability and makes gaps visible.

### Requirements → Test Cases

Map every requirement (AC, RS) to the test cases that cover it. Requirements with **no test case** must show a "Gap" status.

### Risks → Test Cases

Map every identified risk to the test cases that mitigate it.

### Explicitly Out of Scope

List items deliberately excluded from testing, with a reason (deferred, not applicable, separate work item).

---

## Blast Radius Language

When describing blast radius in the report, use these terms consistently:

| Category | File count | Plain-language description |
|---|---|---|
| **Isolated** | < 5 files | "Limited — changes are self-contained" |
| **Moderate** | 5–20 files | "Moderate — changes ripple into several modules" |
| **Wide** | > 20 files | "Wide — changes affect a large portion of the codebase" |

---

## Business Risk Assessment

Risk descriptions must use business language:

- ❌ "The null check on line 45 might fail"
- ✅ "Users who haven't completed profile setup will see an error when accessing the dashboard"

Risk levels:

| Level | CSS Class | Meaning |
|---|---|---|
| **Critical** | `risk-critical` | Production outage or data loss likely |
| **High** | `risk-high` | Major feature broken or security exposure |
| **Medium** | `risk-medium` | Partial feature degradation or edge-case failures |
| **Low** | `risk-low` | Cosmetic issues or unlikely edge cases |

---

## Report Filename

The report must always be written to:

```
impact-analysis-{YYYY-MM-DD}-{entry-id}.html
```

---

## Markdown Summary (for platform comments)

When posting a comment on a PR or issue, use this condensed format:

```markdown
## 🧪 Impact Analysis & Test Strategy

**Entry:** [type] #[id] — [title]
**Overall Risk:** [RISK LEVEL]
**Test Cases:** [total] (🟢 [n] Functional | 🔵 [n] Performance | 🔴 [n] Security | 🟡 [n] Privacy | 🟣 [n] Accessibility | ⚪ [n] Resilience | 🟤 [n] Compatibility)
**Blast Radius:** [isolated / moderate / wide] — [N] files in blast radius

### Summary
[2-3 sentences]

### Key Risk Areas
[bullet list]

### Affected Features
[bullet list]

### Developer Changes Requiring Clarification
[count] items flagged — review before testing begins.

### Test Priorities
- **P0 (Must verify before release):** [list]
- **P1 (Verify in QA cycle):** [list]
- **P2 (Good to verify):** [list]

### Coverage Gaps
[bullet list]

> Full report: `impact-analysis-{YYYY-MM-DD}-{id}.html` — open in any browser for the complete test strategy with all [N] test cases, blast radius map, coverage map, and QA sign-off checklist.
```

---

## General Rules

1. Never invent requirements — only test against what was stated in the work item and what was discovered in the code
2. Never guess what an unclear change does — flag it in "Developer Changes Requiring Clarification"
3. Coverage map must be honest — show gaps, not just coverage
4. Every test case must link to at least one requirement or risk
5. Categories with no surface are omitted, not listed as empty
6. Use `--no-perf` and `--no-a11y` flags to suppress categories
7. Blast radius data must be sourced from dependency-tracer — never inferred
