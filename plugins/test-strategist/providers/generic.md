# Provider: Generic / Unknown Platform

Use this provider when the git remote does not match GitHub or Azure DevOps — or as a fallback when API posting is not possible.

## Behaviour

In generic mode the report is **not posted to a remote platform**. The HTML report is written to a local file so it can be consumed by an external process, CI system, or human operator.

---

## Writing the Report

Write the full HTML impact analysis and test strategy report to the repository root:

```
impact-analysis-report.html
```

The HTML file must be self-contained (inline CSS, no external dependencies) and printable.

The file must be written even if the overall risk is Low — it serves as the audit artifact.

---

## Source of Code Changes

In generic mode, code changes are gathered from git against the base branch:

```bash
BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
git diff origin/${BASE}...HEAD
git diff --name-only origin/${BASE}...HEAD
git log --oneline origin/${BASE}..HEAD
```

The work item content must be provided by the user (pasted text or local file path).

---

## Output

On completion:

```
Impact analysis and test strategy complete: <risk-level> — <N> test cases — report written to impact-analysis-report.html
```

---

## When to Use

This provider is the correct fallback for:

- Jira instances (API posting not yet implemented)
- Self-hosted GitLab instances
- Bitbucket (API posting not yet implemented)
- Any on-premises git server
- Local or offline runs where no remote API is available
- CI environments where only the report file output is needed
