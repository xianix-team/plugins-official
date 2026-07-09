#!/usr/bin/env bash
# lib/github.sh — GitHub (gh CLI) helpers.
#
# Sourced by gather-context.sh, post-start-comment.sh, and post-review.sh.
# providers/github.md documents *why* — this file is the actual implementation.
#
# All functions run to completion within ONE process, so OWNER/REPO/PR_NUMBER are always
# freshly resolved in the same invocation that uses them.

# gh_parse_remote — sets OWNER, REPO from `git remote get-url origin`.
gh_parse_remote() {
  local remote
  remote=$(git remote get-url origin 2>/dev/null || echo "")
  if [ -z "$remote" ]; then
    echo "ERROR: could not resolve git remote 'origin'." >&2
    return 1
  fi
  _gh_parse_remote_url "$remote"
}

# _gh_parse_remote_url <url> — pure function, no git dependency, directly testable.
_gh_parse_remote_url() {
  local remote="$1"
  OWNER=$(echo "$remote" | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f1)
  REPO=$(echo "$remote"  | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f2 | sed 's|\.git$||')
  if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
    echo "ERROR: could not parse owner/repo from remote: $remote" >&2
    return 1
  fi
  export OWNER REPO
}

# _gh_extract_pr_number_from_arg <arg> — pure function, no git/gh dependency, directly
# testable. Prints a PR number if `arg` is a GitHub PR URL, prints nothing otherwise.
# Handles both `.../pull/123` and `.../pull/123/files` (or any trailing path/query/fragment).
_gh_extract_pr_number_from_arg() {
  echo "$1" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | head -1
}

# gh_resolve_pr_number [explicit-pr-number|pr-url|branch-name] — sets PR_NUMBER and
# TRIGGER_SOURCE (one of: chat-url | chat-number | explicit-branch | current-branch — recorded
# so the state file can show *how* the PR was identified, not just which one).
#
# Precedence:
#   1. A PR URL (Agent Studio chat re-review trigger) — extract the number regardless of
#      which owner/repo the URL names; OWNER/REPO for API calls always come from this
#      workspace's own `origin` remote, never from the pasted URL.
#   2. A bare PR number (Agent Studio chat, or explicit invocation).
#   3. A branch name — per this command's own `argument-hint: [pr-number | branch-name]`.
#      Looked up via `gh pr list --head`. This used to be silently ignored and fall through
#      to the current-checked-out-branch lookup below, which meant an explicit branch-name
#      argument was never actually honored.
#   4. Nothing — comment-triggered runs, where the executor has already checked out the
#      right branch and we just need to find its PR.
gh_resolve_pr_number() {
  local explicit="${1:-}"
  local from_url

  from_url=$(_gh_extract_pr_number_from_arg "$explicit")
  if [ -n "$from_url" ]; then
    PR_NUMBER="$from_url"
    TRIGGER_SOURCE="chat-url"
    export PR_NUMBER TRIGGER_SOURCE
    return 0
  fi

  if [ -n "$explicit" ] && echo "$explicit" | grep -qE '^[0-9]+$'; then
    PR_NUMBER="$explicit"
    TRIGGER_SOURCE="chat-number"
    export PR_NUMBER TRIGGER_SOURCE
    return 0
  fi

  if [ -n "$explicit" ]; then
    PR_NUMBER=$(gh pr list --head "$explicit" --json number --jq '.[0].number' 2>/dev/null)
    if [ -z "$PR_NUMBER" ]; then
      echo "ERROR: could not resolve a PR number from argument '$explicit' (not a PR URL, PR number, or a branch name with an open PR)." >&2
      return 1
    fi
    TRIGGER_SOURCE="explicit-branch"
    export PR_NUMBER TRIGGER_SOURCE
    return 0
  fi

  PR_NUMBER=$(gh pr list --head "$(git rev-parse --abbrev-ref HEAD)" --json number --jq '.[0].number' 2>/dev/null)
  if [ -z "$PR_NUMBER" ]; then
    PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null)
  fi
  if [ -z "$PR_NUMBER" ]; then
    echo "ERROR: could not resolve a PR number for the current branch." >&2
    return 1
  fi
  TRIGGER_SOURCE="current-branch"
  export PR_NUMBER TRIGGER_SOURCE
}

# gh_ensure_correct_branch — comment-triggered runs (and Agent Studio chat runs that only
# pass a PR URL/number, no ref) may execute in a workspace still checked out to whatever
# branch a previous run left it on, not the PR's actual head branch. Detect and fix before
# diffing — mirrors ado_ensure_correct_branch, needed here for the exact same reason: without
# it, a review can silently run against the wrong branch's diff even though PR_NUMBER itself
# was resolved correctly. Only acts when GIT_REF is unset (initial/push-update runs already
# have the right ref checked out by the executor).
gh_ensure_correct_branch() {
  if [ -n "${GIT_REF:-}" ]; then
    return 0
  fi
  if [ -z "${PR_SOURCE:-}" ]; then
    echo "WARN: no PR source branch resolved — continuing on current branch." >&2
    return 0
  fi

  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  if [ "$current_branch" = "$PR_SOURCE" ]; then
    return 0
  fi

  echo "Comment/chat-triggered run: checking out PR head branch '${PR_SOURCE}' (was on '${current_branch}')" >&2
  git fetch origin "refs/heads/${PR_SOURCE}:${PR_SOURCE}" 2>/dev/null \
    || git fetch origin "refs/heads/${PR_SOURCE}" 2>/dev/null
  git checkout "$PR_SOURCE" 2>/dev/null || git checkout -b "$PR_SOURCE" FETCH_HEAD 2>/dev/null \
    || echo "WARN: could not check out '${PR_SOURCE}' — diff will be computed against current HEAD." >&2
}

# gh_fetch_pr_metadata — sets PR_TITLE, PR_DESC, PR_SOURCE, PR_TARGET, PR_AUTHOR.
gh_fetch_pr_metadata() {
  local json
  json=$(gh pr view "$PR_NUMBER" --json title,body,headRefName,baseRefName,author 2>/dev/null)
  if [ -z "$json" ]; then
    echo "WARN: PR metadata fetch failed — title/description will be blank." >&2
    PR_TITLE=""; PR_DESC=""; PR_SOURCE=""; PR_TARGET=""; PR_AUTHOR=""
  else
    eval "$(echo "$json" | python3 -c "
import sys, json, shlex
d = json.load(sys.stdin)
def esc(v): return shlex.quote(str(v))
print('PR_TITLE=' + esc(d.get('title','')))
print('PR_DESC=' + esc(d.get('body','') or ''))
print('PR_SOURCE=' + esc(d.get('headRefName','')))
print('PR_TARGET=' + esc(d.get('baseRefName','')))
print('PR_AUTHOR=' + esc((d.get('author') or {}).get('login','')))
")"
  fi
  export PR_TITLE PR_DESC PR_SOURCE PR_TARGET PR_AUTHOR
}

# gh_detect_prior_review — writes /tmp/pr_prior_findings.jsonl and sets PRIOR_SUMMARY_SHA
# + DETECTION_STATUS (ok|failed). Same call-in-one-process guarantee as ado_detect_prior_review.
gh_detect_prior_review() {
  gh api graphql -f query='
    query($owner:String!, $repo:String!, $pr:Int!) {
      repository(owner:$owner, name:$repo) {
        pullRequest(number:$pr) {
          reviewThreads(first:100) {
            nodes {
              id
              isResolved
              path
              comments(first:1) { nodes { databaseId body } }
            }
          }
        }
      }
    }' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER" > /tmp/pr_review_threads.json 2>/tmp/pr_review_threads.err

  if [ ! -s /tmp/pr_review_threads.json ] || ! python3 -c "
import json
d = json.load(open('/tmp/pr_review_threads.json'))
assert d.get('data', {}).get('repository', {}).get('pullRequest') is not None
" 2>/dev/null; then
    echo "WARN: prior-review detection query failed or returned no pullRequest — treating as detection failure, not 'no prior review'. Raw response:" >&2
    cat /tmp/pr_review_threads.json >&2 2>/dev/null
    cat /tmp/pr_review_threads.err >&2 2>/dev/null
    DETECTION_STATUS="failed"
    : > /tmp/pr_prior_findings.jsonl
    PRIOR_SUMMARY_SHA=""
    export DETECTION_STATUS PRIOR_SUMMARY_SHA
    return 0
  fi

  python3 - <<'PY' > /tmp/pr_prior_findings.jsonl
import json, re
data = json.load(open('/tmp/pr_review_threads.json'))
threads = data['data']['repository']['pullRequest']['reviewThreads']['nodes']
pat = re.compile(
    r'<!--\s*pr-reviewer:v1\s+kind=finding\s+fid=(\S+)\s+sha=(\S+)'
    r'(?:\s+sev=(\S+))?(?:\s+cat=(\S+))?\s*-->'
)
for t in threads:
    c = (t['comments']['nodes'] or [None])[0]
    if not c:
        continue
    m = pat.search(c['body'] or '')
    if not m:
        continue
    print(json.dumps({
        "fid": m.group(1),
        "status": "resolved" if t['isResolved'] else "open",
        "thread_ref": t['id'],
        "comment_ref": c['databaseId'],
        "file": t.get('path') or '',
        "severity": m.group(3) or "",
        "category": m.group(4) or "",
    }))
PY

  # Most-recent summary marker sha — check both PR comments and PR reviews.
  PRIOR_SUMMARY_SHA=$(
    {
      gh api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" --paginate \
        --jq '.[].body' 2>/dev/null
      gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate \
        --jq '.[].body' 2>/dev/null
    } | grep -oE 'pr-reviewer:v1 kind=summary[^>]*sha=[0-9a-f]+' \
      | tail -1 | grep -oE 'sha=[0-9a-f]+' | cut -d= -f2
  )
  DETECTION_STATUS="ok"
  export DETECTION_STATUS PRIOR_SUMMARY_SHA
}

# gh_post_pr_comment <body-file> — plain issue-style PR comment (used for the "in progress" note).
gh_post_pr_comment() {
  local body_file="$1"
  gh pr comment "$PR_NUMBER" --body "$(cat "$body_file")"
}

# gh_post_review <flag> <body-file> — posts the PR-level review (summary + verdict), e.g.
# flag one of --approve / --request-changes / --comment.
gh_post_review() {
  local flag="$1" body_file="$2"
  gh pr review "$PR_NUMBER" "$flag" --body "$(cat "$body_file")"
}

# gh_post_inline_finding <body-file> <fid> <repo-relative-file> <line> <head-sha> [severity] [category]
# severity/category are persisted in the marker (when given) so a future re-review can
# recompute the verdict correctly for a carried-over finding the finder fails to re-surface,
# and can narrow which category to try when re-verifying the finding's fid against HEAD.
gh_post_inline_finding() {
  local body_file="$1" fid="$2" file_path="$3" line="$4" head_sha="$5" severity="${6:-}" category="${7:-}"
  local marker="<!-- pr-reviewer:v1 kind=finding fid=${fid} sha=${head_sha}"
  [ -n "$severity" ] && marker="${marker} sev=${severity}"
  [ -n "$category" ] && marker="${marker} cat=${category}"
  marker="${marker} -->"
  printf '\n\n%s\n' "$marker" >> "$body_file"
  gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments" \
    --method POST \
    --field path="$file_path" \
    --field line="$line" \
    --field side="RIGHT" \
    --field commit_id="$head_sha" \
    --field body="$(cat "$body_file")"
}

# gh_reply_to_comment <comment-id> <body-file>
gh_reply_to_comment() {
  local comment_id="$1" body_file="$2"
  gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments/${comment_id}/replies" \
    --method POST --field body="$(cat "$body_file")"
}

# gh_resolve_thread <thread-node-id> — GraphQL resolveReviewThread (REST has no equivalent).
gh_resolve_thread() {
  local thread_id="$1"
  gh api graphql -f query='
      mutation($id:ID!) { resolveReviewThread(input:{threadId:$id}) { thread { isResolved } } }' \
      -F id="$thread_id" >/dev/null
}
