# Provider: GitHub

Use this provider when `git remote get-url origin` contains `github.com`.

## How this fits with the rest of the plugin

- **Reading / analysis** — Use **git** against your base branch (same as Azure DevOps and other hosts): `git diff`, `git log`, etc. See Step 3 of the `/pr-review` command in `commands/pr-review.md`. No `gh` needed to fetch patches or file lists.
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

A `--request-changes` review is a first-class blocking review on GitHub. Under any branch protection rule that requires PR review approval, it blocks the merge button (`Merging is blocked`) until the review is dismissed or the reviewer re-reviews and approves. **By default this plugin runs in advisory / shadow mode**, so a `REQUEST CHANGES` verdict is posted as a non-blocking `gh pr review --comment` (the verdict text is still in the body). Set `PR_REVIEWER_BLOCK_ON_CRITICAL=true` to make CRITICAL findings post a blocking `--request-changes` review instead.

The `PR_REVIEWER_BLOCK_ON_CRITICAL` environment variable controls this:

| Value | Behavior on `REQUEST CHANGES` verdict |
|---|---|
| unset / `false` / `0` / `no` *(default)* | `gh pr review --comment` — non-blocking comment review (verdict text is still in the body) |
| `true` / `1` / `yes` | `gh pr review --request-changes` — blocking review |

The verdict label in the report body, the Critical Issues section, and the inline comments are identical in both modes — only the GitHub review *type* changes.

```bash
# Map verdict + PR_REVIEWER_BLOCK_ON_CRITICAL to the gh flag
case "${PR_REVIEWER_BLOCK_ON_CRITICAL:-false}" in
  true|True|TRUE|1|yes|Yes|YES) BLOCK_ON_CRITICAL=true ;;
  *)                              BLOCK_ON_CRITICAL=false ;;
esac

case "${VERDICT}" in
  "APPROVE"|"APPROVE WITH SUGGESTIONS")
    REVIEW_FLAG="--approve" ;;
  "REQUEST CHANGES")
    if [ "$BLOCK_ON_CRITICAL" = "true" ]; then
      REVIEW_FLAG="--request-changes"
    else
      REVIEW_FLAG="--comment"
      echo "INFO: advisory mode (PR_REVIEWER_BLOCK_ON_CRITICAL not set to true) — posting REQUEST CHANGES as non-blocking comment"
    fi
    ;;
  "NEEDS DISCUSSION"|*)
    REVIEW_FLAG="--comment" ;;
esac

gh pr review <pr-number> $REVIEW_FLAG --body "$(cat /tmp/pr_review_body.md)"
```

### Inline comments (one thread per finding) — MANDATORY

This step is mandatory whenever the report contains at least one Critical Issue, Warning, or Suggestion with a `path/to/file.ext:NN` reference. Skipping it collapses every finding into the summary review and defeats the purpose of running the specialized reviewers.

Do **not** post inline comments with ad-hoc one-off `gh api` calls you "remember." Serialize the findings to a file and run a single posting loop with HTTP status checks — that is the only way the run stays auditable when there are 5–20 findings, and it produces the `INLINE_OK` / `INLINE_FAIL` counters the post-posting self-check in `commands/pr-review.md` expects.

> **Line numbers must be post-change file lines.** GitHub anchors the comment with `--field line=NN --field side=RIGHT`, where `NN` is the line in the **new** version of the file (resolved per the "Resolve every finding to a post-change file line" step in `commands/pr-review.md`), not the diff position. A line that is not part of the PR diff is rejected with `422`.

#### a. Serialize findings to JSONL

After compiling the report, write **one JSON object per finding** to `/tmp/pr_inline_findings.jsonl`. Each object must have:

| Field | Type | Required | Notes |
|---|---|---|---|
| `file` | string | yes | Repo-relative path (matches an entry in `/tmp/pr_changed_files.txt`). |
| `line` | int | yes | Post-change (right-side) file line number. |
| `body` | string | yes | Markdown body. Include the severity tag, e.g. `**[CRITICAL]** ...`. |
| `severity` | string | no | `critical` / `warning` / `suggestion` — used only for the summary log. |

```bash
python3 - <<'PY' > /tmp/pr_inline_findings.jsonl
import json
findings = [
    {"file": "src/auth/login.ts", "line": 42, "severity": "critical",
     "body": "**[CRITICAL] SQL injection**\n\nUser input is concatenated into the query..."},
    # ... one entry per Critical / Warning / Suggestion with a precise post-change file:line ...
]
for f in findings:
    print(json.dumps(f))
PY
```

#### b. Loop and POST, one comment per finding, with HTTP status checks

```bash
COMMIT_ID=$(git rev-parse HEAD)
INLINE_TOTAL=0
INLINE_OK=0
INLINE_FAIL=0
: > /tmp/pr_inline_failures.log

while IFS= read -r line; do
  [ -z "$line" ] && continue
  INLINE_TOTAL=$((INLINE_TOTAL + 1))

  F_PATH=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['file'])")
  F_LINE=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['line'])")
  echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])" > /tmp/pr_inline_body.md

  RESP=$(gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments" \
    --method POST \
    --field path="$F_PATH" \
    --field line="$F_LINE" \
    --field side="RIGHT" \
    --field commit_id="$COMMIT_ID" \
    --field body="$(cat /tmp/pr_inline_body.md)" \
    2>/tmp/pr_inline_err.txt) && STATUS=ok || STATUS=fail

  if [ "$STATUS" = "ok" ]; then
    INLINE_OK=$((INLINE_OK + 1))
  else
    INLINE_FAIL=$((INLINE_FAIL + 1))
    {
      echo "---"
      echo "finding: $line"
      cat /tmp/pr_inline_err.txt
    } >> /tmp/pr_inline_failures.log
  fi
done < /tmp/pr_inline_findings.jsonl

echo "Inline comments: ${INLINE_OK}/${INLINE_TOTAL} posted (${INLINE_FAIL} failed)"
if [ "$INLINE_FAIL" -gt 0 ]; then
  echo "WARN: see /tmp/pr_inline_failures.log for failure details" >&2
  head -40 /tmp/pr_inline_failures.log >&2
fi

export INLINE_OK INLINE_FAIL INLINE_TOTAL
```

`OWNER`, `REPO`, and `PR_NUMBER` come from the "Resolve the PR number" section above.

#### c. Diagnosing inline failures

If `INLINE_OK` is `0` while `INLINE_TOTAL` is `0`, step (a) was skipped — the JSONL file is empty. Go back and serialize the findings.

If POSTs fail, read `/tmp/pr_inline_failures.log` and check the `gh api` error:

| HTTP | Cause | Fix |
|---|---|---|
| `422` (`line must be part of the diff`) | The line is not on the diff's right side — usually a diff-position or old-side line number leaked through. | Re-resolve the finding to its post-change file line per `commands/pr-review.md`. As a fallback, attach the comment to the nearest changed line in the same hunk. |
| `422` (`commit_id` mismatch) | `commit_id` is not the PR head. | Use `git rev-parse HEAD`; ensure the branch is the PR head, not a stale checkout. |
| `404` | Wrong `OWNER`/`REPO`/`PR_NUMBER`, or token lacks `repo` scope. | Re-parse the remote URL; confirm token scopes. |
| `403` | Acting as the PR author with a self-review restriction, or rate-limited. | Inline review *comments* are allowed on your own PR; if rate-limited, retry the failed entries from the log. |

---

## Output

On completion, use the counters from the inline loop (`$INLINE_OK` / `$INLINE_TOTAL`) — do **not** print a hard-coded number:

```
Review posted on PR #<number>: <verdict> — ${INLINE_OK}/${INLINE_TOTAL} inline comments — https://github.com/<owner>/<repo>/pull/<number>
```

If `INLINE_OK == 0` but the report had findings with file:line references, treat the run as a partial failure and surface the first few lines of `/tmp/pr_inline_failures.log` so the user knows the inline step did not deliver.
