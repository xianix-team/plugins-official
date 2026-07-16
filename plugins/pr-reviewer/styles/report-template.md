# PR Review Report Template

This template defines the structure for the compiled PR review report. The `/pr-review` command (`commands/pr-review.md`) must follow this format exactly when compiling findings from the sub-agents.

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

### Re-review delta
> Include this block **only in re-review mode** (a prior plugin review exists). Omit it entirely on the first review.

Reviewed [N] new commit(s) since the last review (`[prior sha]`..`[current sha]`).
- ✅ Fixed: [count] previously-flagged issue(s) resolved
- 🔴 Reopened: [count] previously-fixed issue(s) still reproduce — regression (omit this line when there are none)
- ⏳ Still open: [count] carried-over issue(s)
- 🆕 New: [count] issue(s) introduced since the last review

---

### Existing review threads
> Include when `/tmp/pr_open_threads.jsonl` was non-empty (initial or re-review). Omit entirely when there were no open threads to consider.

- ✅ Appears addressed: [count] open thread(s) — will reply, leave open for original author
- ⏳ Still open: [count] open thread(s) — no reply (avoid spam)
- 🔇 Duplicates avoided: [count] finding(s) not re-posted

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
> Cap this table at **20 rows** (highest-risk first). For larger PRs, aggregate the rest into one final row — e.g. `| …and 34 more files | +210/-95 | 🟢 Low | Config, tests, docs |`. A row per file on a 100-file PR bloats the posted comment without adding review value.

| File | Lines Changed | Risk | Notes |
|------|---------------|------|-------|
| `src/auth/login.<ext>` | +45/-12 | 🔴 High | Auth logic modified |
| `src/utils/format.<ext>` | +8/-3 | 🟢 Low | Utility function |
