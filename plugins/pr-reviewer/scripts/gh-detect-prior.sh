#!/usr/bin/env bash
# gh-detect-prior.sh — list GitHub PR review threads for re-review awareness.
#
# Why this exists as a real script (not just markdown): agents invent shortened
# REST comment dumps that miss GraphQL thread ids needed to resolve threads.
# Run this file instead of retyping.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/gh-detect-prior.sh" --pr 123
#
# Inputs (flags preferred; env names kept as fallback):
#   --pr N (or from /tmp/pr_state.env)
#   gh CLI authenticated (GH_TOKEN / GITHUB_TOKEN via resolve_token)
#
# Outputs:
#   /tmp/pr_review_threads.json
#   /tmp/pr_prior_findings.jsonl
#   /tmp/pr_open_threads.jsonl
#   /tmp/pr_prior.env          — PRIOR_SUMMARY_SHA=… (source this; shell state does not persist)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-token.sh"

parse_pr_args "$@" || exit 1
resolve_token github || true

# Caller --pr must win over a stale /tmp/pr_state.env.
CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"
# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env

PR_NUMBER="${CALLER_PR:-${PR_NUMBER:-${PR_ID:-}}}"
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PR id unknown — re-run with --pr <number>" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found — required for GitHub prior-review detection" >&2
  exit 1
fi

REMOTE=$(git remote get-url origin)
# Strip embedded credentials (https://user:token@host/...) before parsing — never log secrets.
REMOTE_CLEAN=$(echo "$REMOTE" | sed -E 's|https?://[^@]+@|https://|')
OWNER=$(echo "$REMOTE_CLEAN" | sed 's|https://github.com/||;s|git@github.com:||;s|ssh://git@github.com/||' | cut -d'/' -f1)
REPO=$(echo "$REMOTE_CLEAN"  | sed 's|https://github.com/||;s|git@github.com:||;s|ssh://git@github.com/||' | cut -d'/' -f2 | sed 's|\.git$||')
[ -n "$OWNER" ] && [ -n "$REPO" ] || {
  echo "ERROR: could not parse owner/repo from origin (credentials stripped)" >&2
  exit 1
}

echo "Detecting prior review on ${OWNER}/${REPO}#${PR_NUMBER}"

# --paginate + --slurp follows endCursor and emits a JSON array of pages.
if ! gh api graphql --paginate --slurp -f query='
  query($owner:String!, $repo:String!, $pr:Int!, $endCursor:String) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100, after:$endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            path
            line
            comments(first:1) {
              nodes {
                databaseId
                body
                author { login }
              }
            }
          }
        }
      }
    }
  }' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER" > /tmp/pr_review_threads.json; then
  echo "ERROR: GraphQL reviewThreads query failed" >&2
  exit 1
fi

if ! python3 -c "import json,sys; json.load(open('/tmp/pr_review_threads.json'))" 2>/dev/null; then
  SNIP=$(head -c 400 /tmp/pr_review_threads.json | tr '\n' ' ')
  echo "ERROR: gh graphql returned non-JSON" >&2
  [ -n "$SNIP" ] && echo "Body snippet: ${SNIP}" >&2
  exit 1
fi

python3 - <<'PY'
import json, re, sys
pages = json.load(open("/tmp/pr_review_threads.json"))
if isinstance(pages, dict):  # older gh without --slurp support returns one page
    pages = [pages]
threads = []
for page in pages:
    try:
        nodes = page["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
    except (KeyError, TypeError) as e:
        print(f"ERROR: unexpected GraphQL shape: {e}", file=sys.stderr)
        errs = (page or {}).get("errors") if isinstance(page, dict) else None
        if errs:
            print(f"GraphQL errors: {errs}", file=sys.stderr)
        sys.exit(1)
    threads += nodes or []

pat = re.compile(r"<!--\s*pr-reviewer:v1\.2\s+kind=finding\s+fid=(\S+)\s+sha=(\S+)\s*-->")
prior = open("/tmp/pr_prior_findings.jsonl", "w")
open_threads = open("/tmp/pr_open_threads.jsonl", "w")
for t in threads:
    c = (t["comments"]["nodes"] or [None])[0]
    if not c:
        continue
    body = c["body"] or ""
    m = pat.search(body)
    is_plugin = bool(m)
    if m:
        prior.write(json.dumps({
            "fid": m.group(1),
            "file": t.get("path") or "",
            "line": t.get("line"),
            "status": "resolved" if t["isResolved"] else "open",
            "thread_ref": t["id"],
            "comment_ref": c["databaseId"],
        }) + "\n")
    if t.get("isResolved") or not t.get("path"):
        continue
    author = ((c.get("author") or {}) or {}).get("login") or ""
    open_threads.write(json.dumps({
        "file": t.get("path") or "",
        "line": t.get("line"),
        "body": body,
        "author": author,
        "is_plugin": is_plugin,
        "thread_ref": t["id"],
        "comment_ref": c["databaseId"],
    }) + "\n")
prior.close()
open_threads.close()
print(f"Loaded {len(threads)} review thread(s)")
PY

# Summary marker lives on pull reviews, not issue comments.
PRIOR_SUMMARY_SHA=$(gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate \
  --jq '.[].body' 2>/dev/null \
  | grep -oE 'pr-reviewer:v1\.2 kind=summary[^>]*sha=[0-9a-f]+' \
  | tail -1 | grep -oE 'sha=[0-9a-f]+' | cut -d= -f2 || true)

{
  printf 'PRIOR_SUMMARY_SHA=%q\n' "${PRIOR_SUMMARY_SHA}"
} > /tmp/pr_prior.env

PRIOR_COUNT=$(wc -l < /tmp/pr_prior_findings.jsonl | tr -d ' ')
OPEN_COUNT=$(wc -l < /tmp/pr_open_threads.jsonl | tr -d ' ')
echo "Prior plugin findings: ${PRIOR_COUNT}  |  open inline threads: ${OPEN_COUNT}  |  PRIOR_SUMMARY_SHA=${PRIOR_SUMMARY_SHA:-none}"
echo "Wrote /tmp/pr_prior_findings.jsonl /tmp/pr_open_threads.jsonl /tmp/pr_prior.env"
