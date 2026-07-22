#!/usr/bin/env bash
# ado-start-comment.sh — post Azure DevOps "review in progress" comment.
#
# Why this exists as a real script (not just markdown): agents invent shortened
# curl flows that skip writing /tmp/pr_azure.env. Run this file instead.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ado-start-comment.sh" --pr 123
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ado-start-comment.sh" --branch feat/foo
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ado-start-comment.sh" --optional   # soft-skip if no PR
#
# Inputs (flags preferred; env names kept as fallback):
#   --pr N / --branch NAME / --optional
#   AZURE_DEVOPS_TOKEN (or dashed AZURE-DEVOPS-TOKEN) — required (soft-fail if unset)
#
# Outputs:
#   /tmp/pr_azure.env       — API_BASE, AZURE_REPO, PR_ID, …

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-token.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-azure-remote.sh"

parse_pr_args "$@" || exit 1

# --- 0. Token ---
if ! resolve_token azure; then
  echo "WARN: AZURE_DEVOPS_TOKEN unset — skipping review-in-progress comment" >&2
  exit 0
fi
echo "AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}"

# --- 1. Parse remote → API_BASE / AZURE_REPO ---
if ! parse_azure_remote; then
  echo "WARN: not an Azure DevOps git URL — skipping review-in-progress comment" >&2
  exit 0
fi

# Caller may pass the id as --pr / PR_NUMBER (GitHub-style) or PR_ID (Azure-style).
# Capture it before write_azure_env clears PR_ID.
CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"
PR_ID=""
write_azure_env

# --- 2. Resolve PR_ID (argument first, else active PR for current branch) ---
PR_ID="${CALLER_PR:-}"
if [ -z "$PR_ID" ]; then
  BRANCH="${BRANCH_ARG:-}"
  if [ -z "$BRANCH" ] && [ "$(git rev-parse --abbrev-ref HEAD)" = "HEAD" ]; then
    BRANCH=$(git branch --contains "$(git rev-parse HEAD)" \
      | sed 's|^[* ] *||' | grep -v '^(' | head -1 || true)
  elif [ -z "$BRANCH" ]; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
  fi
  BRANCH="${BRANCH#refs/heads/}"
  if [ -z "${BRANCH:-}" ] || [ "$BRANCH" = "HEAD" ]; then
    if [ "${START_COMMENT_OPTIONAL:-false}" = "true" ]; then
      echo "WARN: no PR number and could not resolve branch — skipping review-in-progress comment" >&2
      exit 0
    fi
    echo "ERROR: PR id unknown — re-run with --pr <number> (detached HEAD / no branch; executor checkouts need an explicit PR id)" >&2
    exit 1
  fi
  PR_ID=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH}&searchCriteria.status=active&api-version=7.1" \
    | python3 -c "import sys,json; prs=json.load(sys.stdin).get('value',[]); print(prs[0]['pullRequestId'] if prs else '')" 2>/dev/null || true)
fi
if [ -z "$PR_ID" ]; then
  if [ "${START_COMMENT_OPTIONAL:-false}" = "true" ]; then
    echo "WARN: no open PR found — skipping review-in-progress comment" >&2
    exit 0
  fi
  echo "ERROR: PR id unknown — re-run with --pr <number> (no open PR found for the current branch)" >&2
  exit 1
fi
write_azure_env
echo "PR=#${PR_ID}"

# --- 3. Post the progress thread ---
PLUGIN_VERSION=$(grep -hom1 '"version"[^,}]*' \
  "${SCRIPT_DIR}/../.claude-plugin/plugin.json" \
  ~/.claude/plugins/pr-reviewer/.claude-plugin/plugin.json \
  "$HOME/Library/Application Support/Claude/plugins/pr-reviewer/.claude-plugin/plugin.json" 2>/dev/null \
  | cut -d'"' -f4 || true)
PLUGIN_VERSION=${PLUGIN_VERSION:-unknown}

cat > /tmp/pr_progress_body.md <<BODY
🔍 PR Review in Progress

Claude Code is analyzing this pull request. The review will be posted here shortly.

PR Reviewer (${PLUGIN_VERSION})
BODY

python3 - <<'PY' > /tmp/pr_thread_payload.json
import json
body = open('/tmp/pr_progress_body.md').read()
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {
        "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": {"$type": "System.Int32", "$value": 1},
    },
}))
PY

RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
  -H "Content-Type: application/json" \
  -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST --data @/tmp/pr_thread_payload.json \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1" \
  || true)
STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
if echo "${STATUS:-}" | grep -qE '^2'; then
  echo "Review-in-progress comment posted on PR #${PR_ID} (HTTP $STATUS)"
else
  echo "WARN: review-in-progress comment failed HTTP ${STATUS:-curl-error} — body: $(echo "$RESP" | sed '$d')" >&2
fi
