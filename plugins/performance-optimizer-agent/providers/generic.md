# Provider: Generic / Unknown Platform

Use this provider when the git remote does **not** match GitHub or Azure DevOps — including Bitbucket, self-hosted GitLab, and any on-premises git server — or as a fallback when API posting is not possible.

## Behaviour

In generic mode the analysis report is **not posted to a remote platform**. Instead, the compiled report is written to a local file so it can be consumed by an external process, CI system, or human operator. The optimization branch (in fix-PR mode) is still created and pushed, but the PR itself must be opened manually on the host.

---

## Writing the Analysis Report File

Write the full compiled analysis report to the repository root:

```
performance-report.md
```

The file must be written even if no bottlenecks are found — the file serves as the audit artifact.

**File format:**

```markdown
# Performance Analysis Report

Generated: <ISO 8601 timestamp>
Branch: <current branch>
Base: <base branch>
Commit: <HEAD SHA>
Scope: <value of --scope or "full change set">
Target runtime: <value of --target or "none">

---

<full compiled analysis report body per styles/report-template.md>
```

On completion:

```
Performance analysis complete: <N> bottlenecks ranked — report written to performance-report.md
```

---

## Fix-PR Mode on Generic Hosts

The fix-PR author agent can still apply Quick-win findings and push a new branch — pushing is platform-agnostic. What it cannot do is call a platform API to open the PR. In generic mode:

1. The agent creates the branch `perf/optimize-<source-pr-number>-<short-sha>` from the source PR's head branch, applies Quick-win findings, and commits with `perf:` prefixed messages.
2. The agent pushes the branch with `git push -u origin <branch>`.
3. Instead of opening a PR via API, the agent writes the PR body to:

   ```
   performance-fix-pr.md
   ```

   in the repository root. The file contains everything the maintainer needs to open the PR manually:

   - target base branch
   - head branch (already pushed)
   - suggested PR title (`perf: optimizations for PR #<source-pr-number>`)
   - summary, links, applied-optimizations table, not-applied list, verification checklist, expected impact notes

4. The agent appends a post-fix summary to `performance-report.md` so the analysis artifact reflects what was applied.

On completion:

```
Optimization branch pushed: perf/optimize-<source-pr-number>-<short-sha> — fix-PR body written to performance-fix-pr.md; open the PR manually against <base-branch>
```

If no Quick-win finding could be applied cleanly, no branch is pushed, no file is written beyond `performance-report.md`, and the agent outputs:

```
No fix PR created — no Quick-win finding could be applied cleanly.
```

---

## When to Use

This provider is the correct fallback for:

- **Bitbucket** (API posting not yet implemented — use generic)
- Self-hosted GitLab instances
- Any on-premises git server
- Local or offline runs where no remote API is available
- CI environments where only file output is needed downstream

---

## Credentials

- `git push` for the optimization branch still requires credentials. `GIT_TOKEN` is injected into git credentials by the PreToolUse hook for generic HTTPS remotes (see `hooks/validate-prerequisites.sh`).
- For SSH remotes, rely on the existing agent / key configuration — the plugin does **not** touch `~/.ssh` or `~/.gitconfig`.
