# PR Review Report Template

This template defines the structure for the compiled PR review report. The orchestrator agent must follow this format exactly when compiling findings from sub-agents.

---

## PR Review Report

**PR:** [title or branch name]
**Author:** [author]
**Files Changed:** [count] | **+[additions]** / **-[deletions]**
**Verdict:** one of — `APPROVE` | `APPROVE WITH SUGGESTIONS` | `REQUEST CHANGES` | `NEEDS DISCUSSION`

> The verdict string MUST be one of the four values above, written in uppercase, with no decoration (no ✅, no parentheses, no extras like `APPROVED WITH SUGGESTIONS`). The provider doc maps each value to a platform vote — invented strings (e.g. `APPROVED WITH SUGGESTIONS`) cause the vote step to be skipped silently.
>
> Mapping guide:
> - `APPROVE` — no critical issues, no warnings.
> - `APPROVE WITH SUGGESTIONS` — no critical issues, no warnings, only suggestions. Plugin still casts a non-blocking vote.
> - `REQUEST CHANGES` — at least one critical issue.
> - `NEEDS DISCUSSION` — at least one warning that can't be resolved without input from the author, but no hard blockers.

---

### Summary
[2-3 sentence overall assessment of the change]

---

### Critical Issues (Must Fix)
> Blocking issues that must be resolved before merge

- [ ] `path/to/file.<ext>:42` — [Issue description]
  ```
  // Current (problematic)
  [problematic code in the language of the PR]

  // Fix
  [corrected code in the language of the PR]
  ```

*(If none: "No critical issues found.")*

---

### Warnings (Should Fix)
> Non-blocking but important — strongly recommended before merge

- [ ] `path/to/file.<ext>:87` — [Issue description with suggested fix]

*(If none: "No warnings found.")*

---

### Suggestions (Consider Improving)
> Nice-to-have improvements — address in follow-up if not now

- [ ] `path/to/file.<ext>:120` — [Suggestion]

---

### Review Details

#### Code Quality
[Summary from code-reviewer: naming, structure, duplication, error handling]

#### Security
[Summary from security-reviewer: vulnerabilities found, severity, fixes]

#### Test Coverage
[Summary from test-reviewer: coverage %, missing tests, test quality issues]

#### Performance
[Summary from performance-reviewer: bottlenecks, complexity concerns]

---

### Files Reviewed
| File | Lines Changed | Risk | Notes |
|------|---------------|------|-------|
| `src/auth/login.<ext>` | +45/-12 | 🔴 High | Auth logic modified |
| `src/utils/format.<ext>` | +8/-3 | 🟢 Low | Utility function |
