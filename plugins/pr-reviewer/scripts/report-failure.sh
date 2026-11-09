#!/usr/bin/env bash
# report-failure.sh — post a "PR Review failed" comment when the review stops on an error.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/report-failure.sh" "<what failed>"
#
# Inputs:
#   PR_NUMBER / PR_ID  — or read from /tmp/pr_state.env
#   gh CLI (GitHub) · AZURE_DEVOPS_TOKEN + curl (Azure DevOps)
#
# Always exits 0 so it never hides the original error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Strip credentials from URLs before the message goes on the PR.
ERROR_MSG=$(printf '%s' "${1:-unknown error}" | sed -E 's#(https?://)[^/@[:space:]]+@#\1***@#g')

CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"
# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env
PR="${CALLER_PR:-${PR_NUMBER:-}}"
[ -n "$PR" ] || { echo "WARN: no PR number — cannot post failure comment" >&2; exit 0; }

BODY="❌ PR Review failed

${ERROR_MSG}

Please re-trigger the review. If it keeps failing, contact your Xianix admin."

echo "ERROR: [pr-review] ${ERROR_MSG}" >&2

case "$(git remote get-url origin 2>/dev/null)" in
  *github.com*)
    gh pr comment "$PR" --body "$BODY" >/dev/null \
      && echo "Failure comment posted on PR #${PR}" \
      || echo "WARN: could not post failure comment" >&2
    ;;
  *dev.azure.com*|*visualstudio.com*)
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib-azure-remote.sh"
    if [ -z "${AZURE_DEVOPS_TOKEN:-}" ] || ! parse_azure_remote >/dev/null 2>&1; then
      echo "WARN: cannot post failure comment (no token or Azure remote)" >&2
      exit 0
    fi
    PAYLOAD=$(BODY="$BODY" python3 -c 'import json,os; print(json.dumps({"comments":[{"content":os.environ["BODY"],"commentType":1}],"status":"active"}))')
    curl -sSf -o /dev/null -H "Content-Type: application/json" -u ":${AZURE_DEVOPS_TOKEN}" \
      -X POST --data "$PAYLOAD" \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR}/threads?api-version=7.1" \
      && echo "Failure comment posted on PR #${PR}" \
      || echo "WARN: could not post failure comment" >&2
    ;;
  *)
    echo "WARN: unknown platform — cannot post failure comment" >&2
    ;;
esac
exit 0
