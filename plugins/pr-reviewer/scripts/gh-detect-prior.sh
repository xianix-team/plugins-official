#!/usr/bin/env bash
# gh-detect-prior.sh — list GitHub PR review threads for re-review awareness.
#
# Why this exists as a real script (not just markdown): agents invent shortened
# REST comment dumps that miss GraphQL thread ids needed to resolve threads.
# Run this file instead of retyping.
#
# Usage:
#   PR_NUMBER=123 bash "${CLAUDE_PLUGIN_ROOT}/scripts/gh-detect-prior.sh"
#
# Inputs:
#   PR_NUMBER (or from /tmp/pr_state.env)
#   gh CLI authenticated (GH_TOKEN / GITHUB_TOKEN)
#
# Outputs:
#   /tmp/pr_review_threads.json
#   /tmp/pr_prior_findings.jsonl
#   /tmp/pr_open_threads.jsonl
#   /tmp/pr_prior.env          — PRIOR_SUMMARY_SHA=… (source this; shell state does not persist)

set -euo pipefail

# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env

PR_NUMBER="${PR_NUMBER:-${PR_ID:-}}"
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PR_NUMBER unset — pass PR number before detecting prior review" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found — required for GitHub prior-review detection" >&2
  exit 1
fi

REMOTE=$(git remote get-url origin)
OWNER=$(echo "$REMOTE" | sed 's|https://github.com/||;s|git@github.com:||;s|ssh://git@github.com/||' | cut -d'/' -f1)
REPO=$(echo "$REMOTE"  | sed 's|https://github.com/||;s|git@github.com:||;s|ssh://git@github.com/||' | cut -d'/' -f2 | sed 's|\.git$||')
[ -n "$OWNER" ] && [ -n "$REPO" ] || {
  echo "ERROR: could not parse owner/repo from origin: $REMOTE" >&2
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

pat = re.compile(r"<!--\s*pr-reviewer:v2\s+kind=finding\s+fid=(\S+)\s+sha=(\S+)\s*-->")
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
# Also extract review ID for potential future updates.
PRIOR_SUMMARY_DATA=$(gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate \
  --jq '.[] | select(.body | contains("pr-reviewer:v2")) | [
    (.body | match("sha=([0-9a-f]+)").captures[0].string),
    .id,
    .submitted_at
  ] | join("\t")' 2>/dev/null | tail -1 || echo "")

PRIOR_SUMMARY_SHA=$(echo "$PRIOR_SUMMARY_DATA" | cut -f1)
PRIOR_SUMMARY_REVIEW_ID=$(echo "$PRIOR_SUMMARY_DATA" | cut -f2)
PRIOR_SUMMARY_PUBLISHED=$(echo "$PRIOR_SUMMARY_DATA" | cut -f3)

{
  printf 'PRIOR_SUMMARY_SHA=%q\n' "${PRIOR_SUMMARY_SHA}"
  printf 'PRIOR_SUMMARY_REVIEW_ID=%q\n' "${PRIOR_SUMMARY_REVIEW_ID}"
  printf 'PRIOR_SUMMARY_PUBLISHED=%q\n' "${PRIOR_SUMMARY_PUBLISHED}"
} > /tmp/pr_prior.env

PRIOR_COUNT=$(wc -l < /tmp/pr_prior_findings.jsonl | tr -d ' ')
OPEN_COUNT=$(wc -l < /tmp/pr_open_threads.jsonl | tr -d ' ')

# Log summary
if [ -n "$PRIOR_SUMMARY_SHA" ]; then
  echo "✓ Prior review detected:"
  echo "  SHA: ${PRIOR_SUMMARY_SHA}"
  echo "  Review ID: ${PRIOR_SUMMARY_REVIEW_ID}"
  echo "  Published: ${PRIOR_SUMMARY_PUBLISHED}"
  echo "  Prior findings: ${PRIOR_COUNT}"
else
  echo "✓ No prior review found (first-time review)"
fi
echo "  Open threads: ${OPEN_COUNT}"
echo ""
echo "Wrote /tmp/pr_prior_findings.jsonl /tmp/pr_open_threads.jsonl /tmp/pr_prior.env"
