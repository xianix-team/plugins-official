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

Called from Step 3 of `commands/pr-review.md` to decide initial vs. re-review mode. It reads the plugin's **own** previous comments (identified by the `<!-- pr-reviewer:v1.2 ... -->` marker) and writes a normalised prior-findings file the reconciliation step consumes. The same GraphQL fetch also writes **all open inline threads** (humans, bots, and this plugin) to `/tmp/pr_open_threads.jsonl` for external-thread awareness, dedup, and reply-only validation.

GitHub's REST review-comments endpoint returns comment bodies and ids but **not** the review-thread node id needed to resolve a thread. GraphQL returns both — **use the plugin script**, do not invent a REST-only shortcut.

**Prefer the plugin script (one Bash call):**

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
GH_DETECT="${CLAUDE_PLUGIN_ROOT}/scripts/gh-detect-prior.sh"
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$GH_DETECT" ] || {
  echo "ERROR: scripts/gh-detect-prior.sh not found — source /tmp/pr_plugin.env from step 0; refuse to invent a GraphQL dump" >&2
  exit 1
}
# Pass --pr discovered from the invocation (or from /tmp/pr_state.env)
bash "$GH_DETECT" --pr "${PR_ARG:-${PR_NUMBER:-}}"
# shellcheck disable=SC1091
source /tmp/pr_prior.env   # PRIOR_SUMMARY_SHA
```

**Outputs:** `/tmp/pr_prior_findings.jsonl`, `/tmp/pr_open_threads.jsonl`, `/tmp/pr_review_threads.json`, `/tmp/pr_prior.env` (`PRIOR_SUMMARY_SHA`). The summary marker is read from `pulls/.../reviews` (where `gh pr review` posts), not issue comments.

If `/tmp/pr_prior_findings.jsonl` is empty, the run is an **initial** review. The `file`/`line` fields are intentionally omitted from prior findings — plugin reconciliation matches on `fid` alone. `/tmp/pr_open_threads.jsonl` may still be non-empty when other reviewers left open inline comments (used for dedup and external-thread replies even on the first plugin run).

---

## Posting the "review in progress" comment

**Prefer the plugin script (one Bash call):**

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
GH_START="${CLAUDE_PLUGIN_ROOT}/scripts/gh-start-comment.sh"
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$GH_START" ] || {
  echo "ERROR: scripts/gh-start-comment.sh not found — source /tmp/pr_plugin.env from step 0" >&2
  exit 1
}
# Pass --pr discovered from the invocation
bash "$GH_START" --pr "${PR_ARG:-${PR_NUMBER:-}}"
```

If posting fails, output one warning line and continue.

---

## Posting the final review

### Prefer the plugin script (one Bash call)

**Do not reinvent this flow.** Agents that invent shortened `gh api` / `gh pr review` snippets skip markers, self-review handling, sub-steps R/E, or the inline loop.

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
GH_POST="${CLAUDE_PLUGIN_ROOT}/scripts/gh-post-review.sh"
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$GH_POST" ] || {
  echo "ERROR: scripts/gh-post-review.sh not found — source /tmp/pr_plugin.env from step 0; refuse to invent a posting script" >&2
  exit 1
}

# Pass verdict / mode / pr as flags (shell state does not persist across Bash calls)
# VERDICT: APPROVE | APPROVE WITH SUGGESTIONS | REQUEST CHANGES | NEEDS DISCUSSION
bash "$GH_POST" \
  --verdict "REQUEST CHANGES" \
  --mode "${REVIEW_MODE:-initial}" \
  --pr "${PR_ARG:-${PR_NUMBER:-}}"
```

That script: detects self-review, maps verdict + `PR_REVIEWER_BLOCK_ON_CRITICAL` to the `gh pr review` flag, posts the summary with the marker (falls back to `gh pr comment`), reconciles re-review/external threads (sub-steps R and E), and loops inline findings with suggestion-range args. **Inputs:** `/tmp/pr_thread_body.md`, `/tmp/pr_inline_findings.jsonl` (fields: `file`, `line`, `body`, `fid`, optional `suggestion_start_line` / `suggestion_end_line`).

### Verdict → `gh pr review` flag (reference)

| Plugin verdict | Default flag | With `PR_REVIEWER_BLOCK_ON_CRITICAL=true` |
|---|---|---|
| `APPROVE` / `APPROVE WITH SUGGESTIONS` | `--approve` | `--approve` |
| `REQUEST CHANGES` | `--comment` (non-blocking) | `--request-changes` |
| `NEEDS DISCUSSION` | `--comment` | `--comment` |

Self-review (author == authenticated user) always forces `--comment`. The verdict label in the report body is identical in all modes.

### Serialize findings to JSONL before posting

After compiling the report, write **one JSON object per finding** to `/tmp/pr_inline_findings.jsonl`. In **re-review mode** serialize only the **New** bucket. Each object: `file`, `line`, `body`, `fid` (required); `severity`, `suggestion_start_line`, `suggestion_end_line` (optional). Copy `body` **verbatim** (including `` ```suggestion `` blocks).

### Diagnosing inline failures

If `INLINE_OK` is `0` while `INLINE_TOTAL` is `0`, serialization was skipped. If POSTs fail, read `/tmp/pr_inline_failures.log`:

| HTTP | Cause | Fix |
|---|---|---|
| `422` (`line must be part of the diff`) | Line not on the diff's right side | Re-resolve to post-change file line |
| `422` (`commit_id` mismatch) | `commit_id` is not the PR head | Use `git rev-parse HEAD` |
| `404` | Wrong `OWNER`/`REPO`/`PR_NUMBER`, or token lacks `repo` | Re-parse remote; confirm scopes |
| `403` | Self-review approve/request-changes, or rate-limited | Script already forces `--comment` on self-review |


## Output

On completion, use the counters from the inline loop (`$INLINE_OK` / `$INLINE_TOTAL`) — do **not** print a hard-coded number:

```
# initial mode
Review posted on PR #<number>: <verdict> — ${INLINE_OK}/${INLINE_TOTAL} inline comments — ${EXTERNAL_REPLY_OK} external replies — https://github.com/<owner>/<repo>/pull/<number>

# re-review mode (add reconciliation counters)
Re-review posted on PR #<number>: <verdict> — ${INLINE_OK}/${INLINE_TOTAL} new — ${RESOLVED_OK} resolved — ${EXTERNAL_REPLY_OK} external replies — https://github.com/<owner>/<repo>/pull/<number>
```

If `INLINE_OK == 0` but the report had findings with file:line references, treat the run as a partial failure and surface the first few lines of `/tmp/pr_inline_failures.log` so the user knows the inline step did not deliver.
