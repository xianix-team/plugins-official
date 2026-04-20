# Provider: Generic / Unknown Platform

Use this provider when the git remote does not match GitHub or Azure DevOps — or as a fallback when API posting is not possible.

## Behaviour

In generic mode the plugin cannot fetch review threads from a remote API. Instead, it outputs a local report file documenting what would have been resolved, so a human or CI system can act on it.

---

## Writing the Resolution Report

Write the full resolution report to the repository root:

```
pr-comment-resolution.md
```

**File format:**

```markdown
# PR Comment Resolution Report

Generated: <ISO 8601 timestamp>
Branch: <current branch>
Commit: <HEAD SHA>

---

<full disposition summary from styles/report-template.md>
```

Write the report file even if no threads were found — it serves as the audit artifact.

---

## Applying Code Changes

Code changes are still applied locally even in generic mode:

1. Edit files using `Write`
2. Commit using `git commit`
3. Push using `git push origin HEAD` (if a remote is available)

If no remote push is possible, commit locally and note it in the report.

---

## No Thread Fetching

Generic mode cannot fetch unresolved threads from a remote platform. In this case:

1. Read any review comments from local files if they were captured elsewhere (e.g., a JSON file passed as input)
2. If no thread data is available, write a report noting that platform API access was not available and listing what the plugin would need to run fully

---

## Output

On completion:

```
Resolution complete: <N> applied, <N> discussed, <N> declined — report written to pr-comment-resolution.md
```

---

## When to Use

This provider is the correct fallback for:

- Bitbucket (API posting not yet implemented — use generic)
- Self-hosted GitLab instances
- Any on-premises git server
- Local or offline runs where no remote API is available
- CI environments where only the report file output is needed
