# Provider: GitHub

Use this provider when `git remote get-url origin` contains `github.com`.

## How this fits with the rest of the plugin

- **Reading / analysis** — Use **git** for diffs and logs, **`gh`** for issue and PR metadata.
- **GitHub-specific** — Use **`gh`** to fetch issues, PRs, comments, linked references, and to post the summary comment.

GitHub **does not support HTML file attachments** on issues or pull requests, so the delivery is:
1. A **markdown-formatted summary comment** posted on the issue or PR.
2. The full `impact-analysis-{YYYY-MM-DD}-{id}.html` written locally.

## Prerequisites

The `gh` CLI must be installed and authenticated. Verify with:

```bash
gh auth status
```

If not authenticated, run `gh auth login` or set the `GITHUB_TOKEN` environment variable.

### Token Permissions

| Permission | Access | Why it's needed |
|---|---|---|
| **Contents** | Read | Access repository contents, commits, and documentation files |
| **Metadata** | Read | Search repositories and access repository metadata |
| **Issues** | Read | Fetch issue body, labels, and comments |
| **Pull requests** | Read & Write | Fetch PR diffs, navigate issue ↔ PR links, and post the report comment |

---

## Entry Point: PR

### Fetching PR Details

```bash
gh pr view ${PR_NUMBER} --json number,title,body,state,headRefName,baseRefName,url,author,labels,files,additions,deletions,commits,closingIssuesReferences
```

### Discovering Linked Issues from a PR

```bash
gh pr view ${PR_NUMBER} --json closingIssuesReferences --jq '.closingIssuesReferences[].number'
```

Also scan the PR body and commit messages for `#123`, `closes #456`, `fixes #789` patterns.

For each linked issue:
```bash
gh issue view ${ISSUE_NUMBER} --json number,title,body,state,labels,assignees,milestone,comments
```

### Fetching PR Diff

```bash
gh pr diff ${PR_NUMBER}
gh pr view ${PR_NUMBER} --json files,additions,deletions,commits
```

---

## Entry Point: Issue

### Fetching Issue Details

```bash
gh issue view ${ISSUE_NUMBER} --json number,title,body,state,labels,assignees,milestone,comments,projectItems
```

### Discovering Linked PRs from an Issue

```bash
gh api "repos/{owner}/{repo}/issues/${ISSUE_NUMBER}/timeline" --paginate \
  --jq '.[] | select(.event=="cross-referenced" or .event=="closed") | .source.issue.number // empty'

gh pr list --search "${ISSUE_NUMBER} in:body" --state all --json number,title,state,headRefName,url,body --limit 20
gh pr list --state merged --search "${ISSUE_NUMBER}" --json number,title,state,headRefName,url,body --limit 20
```

For each linked PR, fetch its diff:
```bash
gh pr diff ${PR_NUMBER}
```

---

## Entry Point: Current Branch (no argument)

```bash
gh pr view --json number,title,body,state,headRefName,baseRefName,url,author,labels,files,additions,deletions,commits,closingIssuesReferences
```

Then follow the same PR flow above.

---

## Resolving Owner and Repo

```bash
REMOTE=$(git remote get-url origin)
OWNER=$(echo "$REMOTE" | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f1)
REPO=$(echo "$REMOTE"  | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f2 | sed 's|\.git$||')
```

---

## Posting the Report

Post a **markdown-formatted summary** as a comment. The full HTML report is kept locally.

### Determine where to post

| Entry point | Post comment on |
|---|---|
| `pr` | The PR itself |
| `issue` | The issue |
| Current branch | The PR (if found) |

### Post the markdown summary comment

**If entry point is a PR or inferred from current branch:**

```bash
gh pr comment ${PR_NUMBER} --body "$(cat <<'EOF'
## 🧪 Impact Analysis & Test Strategy

**Entry:** PR #${PR_NUMBER} — ${PR_TITLE}
**Overall Risk:** ${RISK_LEVEL}
**Test Cases:** ${TOTAL_COUNT} (🟢 ${FUNCTIONAL} Functional | 🔵 ${PERF} Performance | 🔴 ${SECURITY} Security | 🟡 ${PRIVACY} Privacy | 🟣 ${A11Y} Accessibility | ⚪ ${RESILIENCE} Resilience | 🟤 ${COMPAT} Compatibility)
**Blast Radius:** ${BLAST_RADIUS_SUMMARY}

### Summary
${EXECUTIVE_SUMMARY}

### Key Risk Areas
${KEY_RISKS}

### Affected Features
${AFFECTED_FEATURES}

### Developer Changes Requiring Clarification
${CLARIFICATION_COUNT} items flagged — review before testing begins.

### Test Priorities
- **P0 (Must verify before release):** ${P0_LIST}
- **P1 (Verify in QA cycle):** ${P1_LIST}
- **P2 (Good to verify):** ${P2_LIST}

### Coverage Gaps
${COVERAGE_GAPS}

> Full report: `${REPORT_FILENAME}` — open in any browser for the complete printable test strategy with all ${TOTAL_COUNT} test cases, blast radius map, coverage map, and QA sign-off checklist.
EOF
)"
```

**If entry point is an issue:**

```bash
gh issue comment ${ISSUE_NUMBER} --body "$(cat <<'EOF'
## 🧪 Impact Analysis & Test Strategy

...same content structure as above...
EOF
)"
```

If posting the summary on a PR, also post a brief notification on the linked issue (if one was found):

```bash
gh issue comment ${ISSUE_NUMBER} --body "🧪 Impact analysis generated from PR #${PR_NUMBER} — see the [PR comment](${PR_URL}) for the full summary. Report: \`${REPORT_FILENAME}\`"
```

### Apply label

```bash
gh issue edit ${ISSUE_NUMBER} --add-label "impact-analysis-generated" 2>/dev/null || true
gh pr edit ${PR_NUMBER} --add-label "impact-analysis-generated" 2>/dev/null || true
```

---

## Output

On completion:

```
Impact analysis complete for <entry-type> #<id>: <risk-level> — <N> test cases — report: <filename>
```
