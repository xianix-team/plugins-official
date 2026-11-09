#!/usr/bin/env bash
# report-failure.sh — post a "PR Review failed" comment when the review stops on an error.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/report-failure.sh" "<what failed>"
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/report-failure.sh" --hook   # StopFailure hook (hooks/hooks.json)
#
# Inputs:
#   PR_NUMBER / PR_ID  — or read from /tmp/pr_state.env
#   --hook: StopFailure JSON on stdin (error, error_details, transcript_path).
#           Fires when the run ends on a Claude API error (e.g. billing_error when
#           credits run out), so Claude itself cannot report it. The PR number is
#           read from the "/pr-review <n>" prompt in the transcript; runs that are
#           not a PR review are ignored.
#   gh CLI (GitHub) · AZURE_DEVOPS_TOKEN + curl (Azure DevOps)
#
# Always exits 0 so it never hides the original error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"

if [ "${1:-}" = "--hook" ]; then
  # Prints "<pr number>\t<message>", or nothing when this run is not a PR review.
  HOOK_RESULT=$(python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
pr = ""
try:
    m = re.search(r"/(?:pr-review|review-pr)\s+#?(\d+)", open(d.get("transcript_path") or "").read())
    pr = m.group(1) if m else ""
except Exception:
    pass
if pr:
    msg = "Claude API error (%s)" % (d.get("error") or "unknown")
    if d.get("error_details"):
        msg += ": %s" % d["error_details"]
    print("%s\t%s" % (pr, " ".join(msg.split())))
' 2>/dev/null)
  [ -n "$HOOK_RESULT" ] || exit 0
  CALLER_PR="${HOOK_RESULT%%$'\t'*}"
  set -- "${HOOK_RESULT#*$'\t'}"
fi

# Strip credentials from URLs before the message goes on the PR.
ERROR_MSG=$(printf '%s' "${1:-unknown error}" | sed -E 's#(https?://)[^/@[:space:]]+@#\1***@#g')

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
