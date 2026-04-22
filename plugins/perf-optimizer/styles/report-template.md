# Performance Analysis Report Template

This template defines the structure for the compiled performance analysis report. The orchestrator agent must follow this format exactly when compiling findings from the four analyzer sub-agents.

The report is **embedded in the body of the pull request** opened by the `perf-pr-author` agent — there is no separate analysis comment. Reviewers see the applied optimizations and the underlying analysis in one place.

On local runs where no PR is opened (no Quick-win applied cleanly, or `/analyze-performance` invoked directly), the report is also written verbatim to `performance-report.md` in the repository root.

---

## Performance Analysis Report

**Trigger:** [Issue #`<n>`: `<title>`] or [Work Item #`<id>`: `<title>`]
**Repository:** `<owner/repo>` or `<org/project/repo>`
**Default branch:** `<branch>` @ `<short-sha>`
**Language / Framework:** [detected stack]
**Scope:** [value of Scope hint / --scope, or "full codebase"]
**Target runtime:** [value of Target hint / --target, or "none"]
**Files analyzed:** [count]

---

### Summary

[2–4 sentence qualitative assessment: which category dominates (latency / CPU / memory / I/O), where in the codebase the hottest issues cluster, how much of the backlog is auto-applicable as Quick-wins vs. Deeper follow-up, and any cross-cutting risk worth calling out before merge.]

---

### Top bottlenecks

> Up to ~5 findings, ranked by `impact × confidence`, with hot-path and runtime-target tie-breakers applied.

| # | Location | Category | Impact | Confidence | One-line reason |
|---|---|---|---|---|---|
| 1 | `src/api/checkout.<ext>:42-68` | Latency | High | High | 3 serial external calls on every checkout |
| 2 | `src/services/search.<ext>:88-114` | CPU | High | High | O(n²) linear search inside hot loop |
| 3 | `src/api/orders.<ext>:45-72` | I/O | High | High | N+1 query on the order-list handler |
| 4 | `src/cache/user-cache.<ext>:20-45` | Memory | High | High | Unbounded in-memory cache with no eviction |

---

### Latency risk areas

[Summary from `latency-analyzer`: which request paths are at risk, why, and what rewrites are suggested. Include each finding in the exact shape below.]

- `path/to/file.<ext>:<lines>` — [short title]
  **Impact:** High / Medium / Low
  **Confidence:** High / Medium / Low
  **Boundary:** quick-win | deeper-follow-up
  **Why it matters:** [user-visible effect — added request latency, P99 risk, cold-start cost, etc.]
  **Current:**
  ```[language]
  [problematic snippet]
  ```
  **Suggested optimization:**
  ```[language]
  [scoped rewrite]
  ```
  **Validation hint:** [measurement or benchmark to confirm the win]

*(If none: "No latency concerns identified in the scoped code.")*

---

### CPU & memory hotspots

[Combined summary from `cpu-analyzer` and `memory-analyzer`. Include findings in the same shape as above, grouped by category.]

#### CPU

- `path/to/file.<ext>:<lines>` — [short title]
  **Impact / Confidence / Boundary:** ...
  **Why it matters / Current / Suggested optimization / Validation hint:** ...

#### Memory

- `path/to/file.<ext>:<lines>` — [short title]
  **Impact / Confidence / Boundary:** ...
  **Why it matters / Current / Suggested optimization / Validation hint:** ...

*(If none in a category: "No [CPU | memory] concerns identified in the scoped code.")*

---

### I/O & query inefficiencies

[Summary from `io-query-analyzer`. Include each finding in the same shape as above.]

- `path/to/file.<ext>:<lines>` — [short title]
  **Category:** I/O (N+1 / blocking I/O / chatty call / missing batch / missing cache / query shape / timeout hygiene)
  **Impact / Confidence / Boundary:** ...
  **Why it matters / Current / Suggested optimization / Validation hint:** ...

*(If none: "No I/O or query inefficiencies identified in the scoped code.")*

---

### Optimization backlog

> All findings in one place, split into two tiers. Only **Quick wins** are eligible for automatic application in this PR.

#### Quick wins (safe, localized, low-risk) — auto-applied in this PR

- [x] `path/to/file.<ext>:<lines>` — [short title] — **Impact:** Medium — *applied as commit `<short-sha>`*
- [ ] `path/to/file.<ext>:<lines>` — [short title] — **Impact:** Low — *skipped: <reason>*

*(If none: "No quick-win optimizations available — see Deeper follow-up below.")*

#### Deeper follow-up (architectural, cross-cutting, needs measurement first)

- [ ] `path/to/file.<ext>:<lines>` — [short title] — **Impact:** High — **Boundary:** cross-module — *not applied automatically; track separately*
- [ ] ...

*(If none: "No deeper follow-up items identified.")*

---

### Files assessed

| File | Runtime criticality | Notes |
|------|---------------------|-------|
| `src/api/checkout.<ext>` | 🔴 Request-path | Serial outbound calls |
| `src/utils/format.<ext>` | 🟢 Cold | No runtime-critical impact |

*(Large repositories: list only the files that contributed findings or that the analyzer classified as hot. Tests, docs, and build manifests are excluded from this index by design.)*

---

### Analyzer verdicts

| Analyzer | Verdict | Findings |
|---|---|---|
| Latency | PASS \| REVIEW NEEDED \| LATENCY CONCERN | `<n>` |
| CPU | PASS \| REVIEW NEEDED \| CPU CONCERN | `<n>` |
| Memory | PASS \| REVIEW NEEDED \| MEMORY CONCERN | `<n>` |
| I/O & Query | PASS \| REVIEW NEEDED \| I/O CONCERN | `<n>` |

---

_Generated by the Performance Optimizer._
