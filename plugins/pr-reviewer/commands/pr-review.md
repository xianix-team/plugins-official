---
name: pr-review
description: Run a full PR review. Analyzes code quality, security, tests, and performance. Works with GitHub, Azure DevOps, Bitbucket, and any git repository. Usage: /pr-review [PR number, branch name, or leave blank for current branch]
argument-hint: [pr-number | branch-name]
---

Run a comprehensive pull request review for $ARGUMENTS.

## Hand-off Rules (read first)

When invoking the `orchestrator` sub-agent, **do not assume a hosting platform**. Pass only the raw PR identifier (number, branch name, or empty) and let the orchestrator detect the platform from `git remote get-url origin`.

- ❌ Bad: *"Perform a review for PR #12 in the **GitHub** repository foo/bar"* — this primes the orchestrator with the wrong platform when the remote is actually Azure DevOps or Bitbucket, leading to wasted `gh` calls and leaked tokens in logs.
- ✅ Good: *"Perform a review for PR #12 in repository `foo/bar` on branch `feature/x`. Detect the hosting platform from the git remote before doing anything else."*

The orchestrator's first action is always `git remote get-url origin`; do not pre-empt it.

## What This Does

This command invokes the **orchestrator** agent which coordinates four specialized reviewers in parallel:

| Reviewer | Focus |
|----------|-------|
| `code-reviewer` | Readability, naming, duplication, error handling, design patterns |
| `security-reviewer` | OWASP Top 10, secrets, injection, auth/authz vulnerabilities |
| `test-reviewer` | Coverage gaps, test quality, edge cases, missing regression tests |
| `performance-reviewer` | N+1 queries, O(n²) loops, memory leaks, blocking I/O |

## How to Use

```
/pr-review              # Review current branch vs main
/pr-review 123          # Review PR #123 (GitHub) or PR ID 123 (Azure DevOps)
/pr-review feature/foo  # Review branch feature/foo vs main
/pr-review 123 --fix    # Review and auto-apply fixes
```

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How review is posted |
|---|---|---|
| `github.com` | GitHub | GitHub CLI (`gh`) |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`) |
| Anything else | Generic | Written to `pr-review-report.md` |

## Output

The review produces a structured report with verdict (`APPROVE`, `REQUEST CHANGES`, or `NEEDS DISCUSSION`), critical issues, warnings, suggestions, and per-category summaries. See `styles/report-template.md` for the full format.

## Prerequisites

- Must be run inside a git repository
- The current branch must have at least one commit ahead of the base branch
- **GitHub**: `gh` CLI installed and authenticated (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE-DEVOPS-TOKEN` environment variable set (see `docs/platform-setup.md`)
- **Fix mode**: `GITHUB-TOKEN` (GitHub) or `AZURE-DEVOPS-TOKEN` (Azure DevOps) must be set for `git push`

---

Starting review now...
