# Provider: GitHub

Use this provider when `git remote get-url origin` contains `github.com`.

Do **not** use this provider when origin is Azure DevOps (`dev.azure.com` / `visualstudio.com`), even if the mention prompt says "pull request" or env `PLATFORM` is unset. The executor’s Azure value is `azuredevops` — that maps to `providers/azure-devops.md`, not here.

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

## Detecting a prior review (re-review awareness)

Called from Step 3 of `commands/pr-review.md` to decide initial vs. re-review mode. It reads the plugin's **own** previous comments (identified by the `<!-- pr-reviewer:v1 ... -->` marker) and writes a normalised prior-findings file the reconciliation step consumes. The same GraphQL fetch also writes **all open inline threads** (humans, bots, and this plugin) to `/tmp/pr_open_threads.jsonl` for external-thread awareness, dedup, and reply-only validation.

GitHub's REST review-comments endpoint returns comment bodies and ids but **not** the review-thread node id needed to resolve a thread. GraphQL returns both — **use the plugin script**, do not invent a REST-only shortcut.

**Prefer the plugin script (one Bash call):**

```bash
GH_DETECT="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/gh-detect-prior.sh}"
if [ -z "${GH_DETECT:-}" ] || [ ! -f "$GH_DETECT" ]; then
  GH_DETECT=$(find "${CLAUDE_PLUGIN_ROOT:-.}" ~/.claude/plugins -path '*/pr-reviewer/scripts/gh-detect-prior.sh' 2>/dev/null | head -1)
fi
[ -n "${GH_DETECT:-}" ] && [ -f "$GH_DETECT" ] || {
  echo "ERROR: scripts/gh-detect-prior.sh not found — refuse to invent a GraphQL dump" >&2
  exit 1
}
# PR_NUMBER from /tmp/pr_state.env or the invocation argument
bash "$GH_DETECT"
# shellcheck disable=SC1091
source /tmp/pr_prior.env   # PRIOR_SUMMARY_SHA
```

**Outputs:** `/tmp/pr_prior_findings.jsonl`, `/tmp/pr_open_threads.jsonl`, `/tmp/pr_review_threads.json`, `/tmp/pr_prior.env` (`PRIOR_SUMMARY_SHA`). The summary marker is read from `pulls/.../reviews` (where `gh pr review` posts), not issue comments.

If `/tmp/pr_prior_findings.jsonl` is empty, the run is an **initial** review. The `file`/`line` fields are intentionally omitted from prior findings — plugin reconciliation matches on `fid` alone. `/tmp/pr_open_threads.jsonl` may still be non-empty when other reviewers left open inline comments (used for dedup and external-thread replies even on the first plugin run).

---

## Posting the "review in progress" comment

```bash
# Best-effort version stamp — cosmetic only, never spend more than one command on it.
PLUGIN_VERSION=$(grep -hom1 '"version"[^,}]*' ~/.claude/plugins/pr-reviewer/.claude-plugin/plugin.json \
  "$HOME/Library/Application Support/Claude/plugins/pr-reviewer/.claude-plugin/plugin.json" 2>/dev/null \
  | cut -d'"' -f4)
PLUGIN_VERSION=${PLUGIN_VERSION:-unknown}

gh pr comment <pr-number> --body "$(cat <<EOF
🔍 PR Review in Progress

Claude Code is analyzing this pull request. The review will be posted here shortly.

PR Reviewer (${PLUGIN_VERSION})
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
# Detect self-review (author == authenticated user) — GitHub blocks --approve on own PRs
PR_AUTHOR=$(gh pr view "$PR_NUMBER" --json author --jq '.author.login')
CURRENT_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
SELF_REVIEW=false
if [ -n "$CURRENT_USER" ] && [ "$PR_AUTHOR" = "$CURRENT_USER" ]; then
  SELF_REVIEW=true
  echo "INFO: self-review detected (author=$PR_AUTHOR) — will post as --comment, not --approve/--request-changes"
fi

# Map verdict + PR_REVIEWER_BLOCK_ON_CRITICAL to the gh flag
case "${PR_REVIEWER_BLOCK_ON_CRITICAL:-false}" in
  true|True|TRUE|1|yes|Yes|YES) BLOCK_ON_CRITICAL=true ;;
  *)                              BLOCK_ON_CRITICAL=false ;;
esac

case "${VERDICT}" in
  "APPROVE"|"APPROVE WITH SUGGESTIONS")
    if [ "$SELF_REVIEW" = "true" ]; then
      REVIEW_FLAG="--comment"
      echo "INFO: self-review — posting APPROVE verdict as non-blocking comment review"
    else
      REVIEW_FLAG="--approve"
    fi
    ;;
  "REQUEST CHANGES")
    if [ "$SELF_REVIEW" = "true" ]; then
      REVIEW_FLAG="--comment"
      echo "INFO: self-review — posting REQUEST CHANGES verdict as non-blocking comment review"
    elif [ "$BLOCK_ON_CRITICAL" = "true" ]; then
      REVIEW_FLAG="--request-changes"
    else
      REVIEW_FLAG="--comment"
      echo "INFO: advisory mode (PR_REVIEWER_BLOCK_ON_CRITICAL not set to true) — posting REQUEST CHANGES as non-blocking comment"
    fi
    ;;
  "NEEDS DISCUSSION"|*)
    REVIEW_FLAG="--comment" ;;
esac

source /tmp/pr_state.env 2>/dev/null || HEAD_SHA=$(git rev-parse HEAD)
printf '\n\n<!-- pr-reviewer:v2 kind=summary sha=%s -->\n' "$HEAD_SHA" >> /tmp/pr_review_body.md

if ! gh pr review "$PR_NUMBER" $REVIEW_FLAG --body "$(cat /tmp/pr_review_body.md)" 2>/tmp/pr_review_err.txt; then
  echo "WARN: gh pr review failed: $(cat /tmp/pr_review_err.txt)"
  echo "WARN: falling back to gh pr comment for the summary body"
  gh pr comment "$PR_NUMBER" --body "$(cat /tmp/pr_review_body.md)" || {
    echo "ERROR: could not post review summary — see /tmp/pr_review_err.txt"
    exit 1
  }
fi
```

> **Stamp the summary marker.** The posting script above appends `<!-- pr-reviewer:v2 kind=summary sha=<HEAD_SHA> -->` to `/tmp/pr_review_body.md` before calling `gh pr review`, using `HEAD_SHA` from `/tmp/pr_state.env`. Each re-review posts a *new* review event (idiomatic on GitHub — reviews are timestamped), with the re-review delta block already at the top of the body from step 7. There is no need to edit the previous review.

### Inline comments (one thread per finding) — MANDATORY

This step is mandatory whenever the report contains at least one Critical Issue, Warning, or Suggestion with a `path/to/file.ext:NN` reference. Skipping it collapses every finding into the summary review and defeats the purpose of running the specialized reviewers.

Do **not** post inline comments with ad-hoc one-off `gh api` calls you "remember." Serialize the findings to a file and run a single posting loop with HTTP status checks — that is the only way the run stays auditable when there are 5–20 findings, and it produces the `INLINE_OK` / `INLINE_FAIL` counters the post-posting self-check in `commands/pr-review.md` expects.

> **Line numbers must be post-change file lines.** GitHub anchors the comment with `--field line=NN --field side=RIGHT`, where `NN` is the line in the **new** version of the file (resolved per the "Resolve every finding to a post-change file line" step in `commands/pr-review.md`), not the diff position. A line that is not part of the PR diff is rejected with `422`.

#### a. Serialize findings to JSONL

After compiling the report, write **one JSON object per finding** to `/tmp/pr_inline_findings.jsonl`. In **re-review mode** serialize only the **New** bucket (`/tmp/pr_reconcile.json` → `new[]`); carried-over findings are not re-posted. Each object must have:

| Field | Type | Required | Notes |
|---|---|---|---|
| `file` | string | yes | Repo-relative path (matches an entry in `/tmp/pr_changed_files.txt`). |
| `line` | int | yes | Post-change (right-side) file line number. |
| `body` | string | yes | Markdown body. Include the severity tag, e.g. `**[CRITICAL]** ...`. |
| `fid` | string | yes | Stable finding id from step 7 (`compute_fid`). Goes into the marker. |
| `severity` | string | no | `critical` / `warning` / `suggestion` — used only for the summary log. |
| `suggestion_start_line` | int | no | First line of the multi-line suggestion region. Omit for single-line fixes. Parsed from the `<!-- suggestion: lines NN-MM -->` comment in the body. |
| `suggestion_end_line` | int | no | Last line of the multi-line suggestion region. Omit for single-line fixes. |

The `body` field must be copied **verbatim** from the sub-agent finding output. Sub-agents write ` ```suggestion ` blocks directly into their output — do not strip or transform the body. GitHub renders the ` ```suggestion ` block as the "Commit suggestion" / "Apply suggestion" button automatically.

```bash
python3 - <<'PY' > /tmp/pr_inline_findings.jsonl
import json
findings = [
    # Finding with a suggestion block — body contains ```suggestion verbatim from the sub-agent
    # GitHub renders the "Commit suggestion" button from the ```suggestion block in the body.
    {"file": "src/auth/login.ts", "line": 42, "severity": "critical", "fid": "a1b2c3d4e5f6",
     "body": "**[CRITICAL] SQL injection**\n\nUser input is concatenated into the query...\n\n**Fix:** Use a parameterized query.\n\n<!-- suggestion: line 42 -->\n```suggestion\n  const result = await db.query('SELECT * FROM users WHERE id = ?', [userId]);\n```"},
    # Multi-line suggestion — also include suggestion_start_line / suggestion_end_line for the API call
    {"file": "src/auth/login.ts", "line": 55, "severity": "critical", "fid": "c3d4e5f6a1b2",
     "suggestion_start_line": 53, "suggestion_end_line": 55,
     "body": "**[CRITICAL] ...**\n\n<!-- suggestion: lines 53-55 -->\n```suggestion\n  line one\n  line two\n  line three\n```"},
    # Finding without a suggestion block (architectural issue — no drop-in fix)
    {"file": "src/services/auth.ts", "line": 87, "severity": "warning", "fid": "b2c3d4e5f6a1",
     "body": "**[WARNING] Missing rate limiting**\n\nLogin endpoint has no rate limit..."},
    # ... one entry per finding to post (initial: all; re-review: New bucket only) ...
]
for f in findings:
    print(json.dumps(f))
PY
```

> **Stamp the finding marker.** The posting loop below appends `<!-- pr-reviewer:v2 kind=finding fid=<fid> sha=<HEAD_SHA> -->` to each comment body. This is what lets the *next* re-review recognise the comment and reconcile it — a comment posted without it is invisible to reconciliation and will be duplicated next run.

#### b. Loop and POST, one comment per finding, with HTTP status checks

```bash
COMMIT_ID=$(git rev-parse HEAD)
INLINE_TOTAL=0
INLINE_OK=0
INLINE_FAIL=0
: > /tmp/pr_inline_failures.log

# In re-review mode, load the set of carried-over FIDs to skip (read from canonical /tmp/pr_reconcile.json)
CARRIED_OVER_FIDS=""
if [ -f /tmp/pr_reconcile.json ]; then
  CARRIED_OVER_FIDS=$(python3 -c "import json; s=json.load(open('/tmp/pr_reconcile.json')); print(' '.join(s.get('carried_over_fids',[])))" 2>/dev/null || echo "")
fi

while IFS= read -r line; do
  [ -z "$line" ] && continue

  # One python call extracts every field AND writes the body file (5 separate
  # per-finding python invocations is pure process overhead). Body is copied
  # verbatim — sub-agents write ```suggestion blocks directly, GitHub renders the button.
  # printf '%s' (not echo) — echo interprets \n escapes in some shells and corrupts the JSON.
  eval "$(printf '%s' "$line" | python3 -c "
import sys, json, shlex
d = json.load(sys.stdin)
open('/tmp/pr_inline_body.md', 'w').write(d['body'])
print('F_PATH=' + shlex.quote(str(d['file'])))
print('F_LINE=' + shlex.quote(str(d['line'])))
print('F_FID=' + shlex.quote(str(d.get('fid', ''))))
print('F_SUGGEST_START=' + shlex.quote(str(d.get('suggestion_start_line', ''))))
")"

  # Skip if this finding is in the carried-over set (already open from prior review)
  if [ -n "$F_FID" ] && [ -n "$CARRIED_OVER_FIDS" ] && echo " $CARRIED_OVER_FIDS " | grep -q " $F_FID "; then
    echo "Skipping carried-over finding: fid=$F_FID"
    continue
  fi

  INLINE_TOTAL=$((INLINE_TOTAL + 1))

  # Append the hidden finding marker so the next re-review can reconcile this comment.
  printf '\n\n<!-- pr-reviewer:v2 kind=finding fid=%s sha=%s -->\n' "$F_FID" "$COMMIT_ID" >> /tmp/pr_inline_body.md

  # For multi-line suggestions, pass start_line + start_side so GitHub anchors the block correctly.
  SUGGESTION_ARGS=""
  if [ -n "$F_SUGGEST_START" ] && [ "$F_SUGGEST_START" != "$F_LINE" ]; then
    SUGGESTION_ARGS="--field start_line=${F_SUGGEST_START} --field start_side=RIGHT"
  fi

  RESP=$(gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments" \
    --method POST \
    --field path="$F_PATH" \
    --field line="$F_LINE" \
    --field side="RIGHT" \
    --field commit_id="$COMMIT_ID" \
    $SUGGESTION_ARGS \
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
| `403` | Acting as the PR author attempting `--approve`/`--request-changes` on your own PR, or rate-limited. | Detect self-review before posting (see above) and use `--comment`. Inline review *comments* via `gh api .../pulls/comments` are still allowed on your own PR. If rate-limited, retry the failed entries from the log. |

---

## Reconciling prior findings (re-review mode only — sub-step R)

Runs only when `REVIEW_MODE=rereview`. Acts on `/tmp/pr_reconcile.json` (built in step 7 of `commands/pr-review.md`). Carried-over findings need **no** action. The **Fixed** and **Reopened** buckets are processed here: reply on each thread, then resolve (fixed) or reactivate (reopened).

```bash
HEAD_SHA=$(git rev-parse HEAD)
: > /tmp/pr_resolved.log
: > /tmp/pr_reopened.log

# fixed[] entries carry: fid, comment_ref (REST databaseId), thread_ref (GraphQL node id)
python3 -c "import json,sys; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_reconcile.json')).get('fixed',[])]" \
| while IFS= read -r f; do
  COMMENT_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin)['comment_ref'])")
  THREAD_ID=$(echo  "$f" | python3 -c "import sys,json; print(json.load(sys.stdin)['thread_ref'])")

  # 1. Reply on the existing review thread (in_reply_to the original comment)
  gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments/${COMMENT_ID}/replies" \
    --method POST \
    --field body="✅ Resolved as of \`${HEAD_SHA}\`. This finding no longer reproduces against the current head.

<!-- pr-reviewer:v2 kind=resolve sha=${HEAD_SHA} -->" \
    >/dev/null 2>/tmp/pr_resolve_err.txt || true

  # 2. Resolve the review thread (GraphQL — REST has no resolve endpoint)
  if gh api graphql -f query='
      mutation($id:ID!) { resolveReviewThread(input:{threadId:$id}) { thread { isResolved } } }' \
      -F id="$THREAD_ID" >/dev/null 2>>/tmp/pr_resolve_err.txt; then
    echo ok >> /tmp/pr_resolved.log
  else
    echo "fail $THREAD_ID" >> /tmp/pr_resolved.log
  fi
done

# reopened[] entries: prior finding marked resolved, but still reproduces
python3 -c "import json,sys; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_reconcile.json')).get('reopened',[])]" \
| while IFS= read -r f; do
  COMMENT_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin)['comment_ref'])")
  THREAD_ID=$(echo  "$f" | python3 -c "import sys,json; print(json.load(sys.stdin)['thread_ref'])")

  # 1. Reply on the existing review thread
  gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments/${COMMENT_ID}/replies" \
    --method POST \
    --field body="⚠️ This finding still reproduces as of \`${HEAD_SHA}\` despite being marked resolved. Reactivating thread.

<!-- pr-reviewer:v2 kind=reopen sha=${HEAD_SHA} -->" \
    >/dev/null 2>/tmp/pr_reopen_err.txt || true

  # 2. Unresolve the review thread (GraphQL)
  if gh api graphql -f query='
      mutation($id:ID!) { unresolveReviewThread(input:{threadId:$id}) { thread { isResolved } } }' \
      -F id="$THREAD_ID" >/dev/null 2>>/tmp/pr_reopen_err.txt; then
    echo ok >> /tmp/pr_reopened.log
  else
    echo "fail $THREAD_ID" >> /tmp/pr_reopened.log
  fi
done

# Counters are read from the log file because the while loop ran in a pipeline subshell.
RESOLVED_OK=$(grep -c '^ok' /tmp/pr_resolved.log 2>/dev/null || echo 0)
RESOLVED_FAIL=$(grep -c '^fail' /tmp/pr_resolved.log 2>/dev/null || echo 0)
REOPENED_OK=$(grep -c '^ok' /tmp/pr_reopened.log 2>/dev/null || echo 0)
REOPENED_FAIL=$(grep -c '^fail' /tmp/pr_reopened.log 2>/dev/null || echo 0)
export RESOLVED_OK RESOLVED_FAIL REOPENED_OK REOPENED_FAIL
echo "Reconciled: ${RESOLVED_OK} prior finding(s) resolved (${RESOLVED_FAIL} failed); ${REOPENED_OK} reopened (${REOPENED_FAIL} failed)"
```

If `resolveReviewThread` returns a permissions error, the token lacks write access to the PR or thread resolution is restricted — log it and continue; the reply still lands and the verdict still updates.

---

## Replying on addressed external threads (sub-step E)

Runs when `/tmp/pr_external_reconcile.json` exists and `addressed` is non-empty (initial **or** re-review). Reply only — **never** call `resolveReviewThread` on these threads. Resolution stays with the original author.

```bash
HEAD_SHA=$(git rev-parse HEAD)
: > /tmp/pr_external_replies.log
EXTERNAL_REPLY_OK=0
EXTERNAL_REPLY_FAIL=0

if [ -f /tmp/pr_external_reconcile.json ]; then
  python3 -c "import json,sys; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_external_reconcile.json')).get('addressed',[])]" \
  | while IFS= read -r f; do
    [ -z "$f" ] && continue
    COMMENT_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('comment_ref') or '')")
    [ -n "$COMMENT_ID" ] || { echo "fail missing comment_ref" >> /tmp/pr_external_replies.log; continue; }

    gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments/${COMMENT_ID}/replies" \
      --method POST \
      --field body="Looks addressed as of \`${HEAD_SHA}\` — leaving this thread open for the original author to resolve.

<!-- pr-reviewer:v1 kind=external-ack sha=${HEAD_SHA} -->" \
      >/dev/null 2>/tmp/pr_external_reply_err.txt \
      && echo ok >> /tmp/pr_external_replies.log \
      || echo "fail $COMMENT_ID" >> /tmp/pr_external_replies.log
  done
  EXTERNAL_REPLY_OK=$(grep -c '^ok' /tmp/pr_external_replies.log 2>/dev/null || echo 0)
  EXTERNAL_REPLY_FAIL=$(grep -c '^fail' /tmp/pr_external_replies.log 2>/dev/null || echo 0)
fi
export EXTERNAL_REPLY_OK EXTERNAL_REPLY_FAIL
echo "External replies: ${EXTERNAL_REPLY_OK} addressed thread(s) acknowledged (${EXTERNAL_REPLY_FAIL} failed) — threads left open"
```

---

## Output

On completion, use the counters from the inline loop (`$INLINE_OK` / `$INLINE_TOTAL`) — do **not** print a hard-coded number:

```
# initial mode
Review posted on PR #<number>: <verdict> — ${INLINE_OK}/${INLINE_TOTAL} inline comments — ${EXTERNAL_REPLY_OK} external replies — https://github.com/<owner>/<repo>/pull/<number>

# re-review mode (add reconciliation counters)
Re-review posted on PR #<number>: <verdict> — ${INLINE_OK}/${INLINE_TOTAL} new — ${RESOLVED_OK} resolved — ${EXTERNAL_REPLY_OK} external replies — https://github.com/<owner>/<repo>/pull/<number>
```

If `INLINE_OK == 0` but the report had findings with file:line references, treat the run as a partial failure and surface the first few lines of `/tmp/pr_inline_failures.log` so the user knows the inline step did not deliver.
