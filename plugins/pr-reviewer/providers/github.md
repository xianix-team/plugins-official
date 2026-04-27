# Provider: GitHub

Use this provider when `git remote get-url origin` contains `github.com`.

## How this fits with the rest of the plugin

- **Reading / analysis** — Use **git** against your base branch (same as Azure DevOps and other hosts): `git diff`, `git log`, etc. See the main orchestrator Step 3 in `agents/orchestrator.md`. No `gh` needed to fetch patches or file lists.
- **GitHub-specific** — Use **`gh`** only to resolve the PR number when it was not passed in, and to **post** comments and reviews to GitHub.

## Prerequisites for posting

- **GitHub CLI** (`gh`) installed: [https://cli.github.com](https://cli.github.com)
- Authenticated: `gh auth login`, or non-interactive `GH_TOKEN` / `GITHUB_TOKEN` (same scopes as below)

**Token scopes:** `repo` (private repos) or `public_repo` (public only); `read:org` if needed for org repos.

The plugin does **not** use the GitHub MCP server.

---

## Resolve the PR number (for posting only)

If the user passed a PR number, use it.

Otherwise, for the **current branch** (needed for `gh pr comment` / `gh pr review`):

```bash
gh pr list --head "$(git rev-parse --abbrev-ref HEAD)" --json number --jq '.[0].number'
```

Or:

```bash
gh pr view --json number --jq '.number'
```

Parse `owner` and `repo` when needed (e.g. for `gh api` inline comments):

```bash
REMOTE=$(git remote get-url origin)
# https://github.com/org/repo.git  →  owner=org  repo=repo
# git@github.com:org/repo.git      →  owner=org  repo=repo
OWNER=$(echo "$REMOTE" | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f1)
REPO=$(echo "$REMOTE"  | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f2 | sed 's|\.git$||')
```

---

## Posting the “review in progress” comment

```bash
gh pr comment <pr-number> --body "$(cat <<'EOF'
🔍 **PR review in progress**

I'm running a comprehensive review covering code quality, security, test coverage, and performance. The full results will be posted as a review comment when complete — this may take a few minutes.
EOF
)"
```

If posting fails, output one warning line and continue.

---

## Posting the final review

### Overall verdict and report body

| Plugin verdict      | `gh pr review` flags |
|---------------------|----------------------|
| `APPROVE`           | `--approve --body "<report>"` |
| `REQUEST CHANGES`   | `--request-changes --body "<report>"` *(see `PR_REVIEWER_BLOCK_ON_CRITICAL` below)* |
| `NEEDS DISCUSSION`  | `--comment --body "<report>"` |

```bash
gh pr review <pr-number> --comment --body "<full compiled report>"
# Use --approve or --request-changes instead of --comment when appropriate.
```

#### Optional: `PR_REVIEWER_BLOCK_ON_CRITICAL` (controls merge-blocking behavior)

A `--request-changes` review is a first-class blocking review on GitHub. Under any branch protection rule that requires PR review approval, it blocks the merge button (`Merging is blocked`) until the review is dismissed or the reviewer re-reviews and approves. That is usually what you want when the agent finds CRITICAL issues — but in some workflows (e.g. advisory bot on a repo with strict branch protection, or shadow-mode rollouts) you want the review *visible* but *non-blocking*.

The `PR_REVIEWER_BLOCK_ON_CRITICAL` environment variable controls this:

| Value | Behavior on `REQUEST CHANGES` verdict |
|---|---|
| unset / `true` *(default)* | `gh pr review --request-changes` — blocking review |
| `false` / `0` / `no` | `gh pr review --comment` — non-blocking comment review (verdict text is still in the body) |

The verdict label in the report body, the Critical Issues section, and the inline comments are identical in both modes — only the GitHub review *type* changes.

```bash
# Map verdict + PR_REVIEWER_BLOCK_ON_CRITICAL to the gh flag
case "${PR_REVIEWER_BLOCK_ON_CRITICAL:-true}" in
  false|False|FALSE|0|no|No|NO) BLOCK_ON_CRITICAL=false ;;
  *)                              BLOCK_ON_CRITICAL=true ;;
esac

case "${VERDICT}" in
  "APPROVE"|"APPROVE WITH SUGGESTIONS")
    REVIEW_FLAG="--approve" ;;
  "REQUEST CHANGES")
    if [ "$BLOCK_ON_CRITICAL" = "true" ]; then
      REVIEW_FLAG="--request-changes"
    else
      REVIEW_FLAG="--comment"
      echo "INFO: PR_REVIEWER_BLOCK_ON_CRITICAL=false — posting REQUEST CHANGES as non-blocking comment"
    fi
    ;;
  "NEEDS DISCUSSION"|*)
    REVIEW_FLAG="--comment" ;;
esac

gh pr review <pr-number> $REVIEW_FLAG --body "$(cat /tmp/pr_review_body.md)"
```

### Inline comments (one per finding)

```bash
gh api repos/{owner}/{repo}/pulls/<pr-number>/comments \
  --method POST \
  --field path="src/auth/login.ts" \
  --field line=42 \
  --field side="RIGHT" \
  --field body="Finding description and fix" \
  --field commit_id="$(git rev-parse HEAD)"
```

Post all inline comments without pausing between them.

---

## Output

On completion:

```
Review posted on PR #<number>: <verdict> — <N> inline comments — https://github.com/<owner>/<repo>/pull/<number>
```
