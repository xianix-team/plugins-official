# Provider: GitHub

Use this provider when `git remote get-url origin` contains `github.com`.

## How this fits with the rest of the plugin

- **Reading / analysis** — uses **git** against the repository's default branch. No `gh` is needed to fetch files; the analyzer operates on the full working tree.
- **GitHub-specific** — `gh` is used to (a) read the trigger issue body, (b) post a "review in progress" comment on the issue, (c) open the pull request, and (d) post a link-back comment on the issue after the PR is open.

## Prerequisites

- **GitHub CLI** (`gh`) installed: https://cli.github.com
- Authenticated: `gh auth login`, or non-interactive `GH_TOKEN` / `GITHUB_TOKEN`

**Token scopes / permissions:**

| Permission | Access | Purpose |
|---|---|---|
| **Contents** | Read & Write | Read repository code, push the new `perf/issue-*` branch |
| **Metadata** | Read | Resolve repository metadata (default branch, etc.) |
| **Issues** | Read & Write | Read the trigger issue body / scope hints and post a link-back comment |
| **Pull requests** | Read & Write | Open the optimization PR and update it with the report |

For classic tokens: `repo` (private repos) or `public_repo` (public only); `read:org` if the repository is under an organization.

The plugin does **not** use the GitHub MCP server.

---

## Resolving `owner` and `repo`

```bash
REMOTE=$(git remote get-url origin)
# https://github.com/org/repo.git  →  owner=org  repo=repo
# git@github.com:org/repo.git      →  owner=org  repo=repo
OWNER=$(echo "$REMOTE" | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f1)
REPO=$(echo  "$REMOTE" | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f2 | sed 's|\.git$||')
```

---

## Reading the trigger issue body (for scope / target hints)

The orchestrator receives the issue body via the rule payload. If you need to re-read it (for example when running the command locally after the webhook fired), use:

```bash
gh issue view "${ISSUE_NUMBER}" --json title,body,labels \
  --jq '{title, body, labels: [.labels[].name]}'
```

Parse lines matching `^\s*Scope:` and `^\s*Target:` (case-insensitive) from the issue body.

---

## Posting the "review in progress" comment

The starting comment must be **transparent about what was parsed** from the issue. The reporter should be able to read this single comment and know, before the review finishes, exactly which scope the agent decided to run under. This closes the loop on silent scope / target drift.

Populate these fields from the orchestrator's resolved run plan (not from the raw issue body — use the values the orchestrator actually committed to):

- `SCOPE_RESOLVED`   — literal scope string or `full codebase` if no hint was given
- `TARGET_RESOLVED`  — literal target runtime (`api` / `worker` / `frontend` / `data`) or `none`
- `DEFAULT_BRANCH`   — e.g. `main`
- `BASELINE_SHA`     — short SHA of `origin/${DEFAULT_BRANCH}` at review start
- `FILE_COUNT`       — number of files that survived scope filtering

```bash
gh issue comment "${ISSUE_NUMBER}" --body "$(cat <<EOF
Performance review in progress

Running a whole-codebase performance review covering latency, CPU, memory, and I/O patterns. A pull request with focused, low-risk optimizations and the embedded report will be linked here when complete — this may take a few minutes.

**Run plan**
- Default branch: \`${DEFAULT_BRANCH}\` @ \`${BASELINE_SHA}\`
- Scope: ${SCOPE_RESOLVED}
- Target runtime: ${TARGET_RESOLVED}
- Files in scope: ${FILE_COUNT}
EOF
)"
```

If posting fails, output one warning line and continue — but do **not** attempt to proceed without resolving `SCOPE_RESOLVED` / `TARGET_RESOLVED` / `BASELINE_SHA` first. Those values are reused in the PR body and must be consistent between the starting comment and the final report.

---

## Opening the pull request

Enter this section **only** after the `perf-pr-author` agent has committed Quick-win findings and pushed the `perf/issue-*` branch.

### 1. Push the optimization branch

Performed by `perf-pr-author`:

```bash
git push -u origin "${NEW_BRANCH}"
```

### 2. Create the PR

```bash
gh pr create \
  --base  "${DEFAULT_BRANCH}" \
  --head  "${NEW_BRANCH}" \
  --title "perf: ${ISSUE_TITLE}" \
  --body  "$(cat <<EOF
## Summary

Automated response to issue #${ISSUE_NUMBER} from the Performance Optimizer. Contains focused, low-risk performance optimizations applied across the codebase based on a whole-repository analysis of the default branch.

Closes #${ISSUE_NUMBER}

## Applied optimizations

${APPLIED_TABLE}

## Not applied

${NOT_APPLIED_LIST:-"_None — all selected Quick-wins applied cleanly._"}

## Verification checklist

- [ ] Unit tests pass locally / in CI
- [ ] Integration tests pass locally / in CI
- [ ] Manual smoke test on the affected hot paths
- [ ] Before/after measurement captured for at least one High-impact item
- [ ] No behavior change intended — API contracts unchanged

## Performance Report

${REPORT_BODY}

---

_Generated by the Performance Optimizer._
EOF
)"
```

The `${REPORT_BODY}` substitution is the full, already-compiled report body produced by the orchestrator per `styles/report-template.md`.

### 3. Link the PR back to the issue

```bash
NEW_PR_URL=$(gh pr view "${NEW_BRANCH}" --json url --jq .url)

gh issue comment "${ISSUE_NUMBER}" --body "Performance PR opened with focused, low-risk optimizations: ${NEW_PR_URL}"
```

### 4. Output

```
Performance PR opened: ${NEW_PR_URL} — targets ${DEFAULT_BRANCH}, closes issue #${ISSUE_NUMBER}
```

If `gh pr create` fails (branch protection, missing scope, pre-existing PR on the branch), emit one error line and stop. Do **not** force-push, do **not** rewrite the default branch.
