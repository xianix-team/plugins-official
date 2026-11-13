#!/usr/bin/env bash
# report-failure.sh — post a "PR Review failed" comment when the review stops on an error.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/report-failure.sh" "<what failed>" ["<what to do>"] ["<error code>"]
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/report-failure.sh" --hook   # StopFailure hook (hooks/hooks.json)
#
# Inputs:
#   PR_NUMBER / PR_ID  — or read from /tmp/pr_state.env
#   --hook: StopFailure JSON on stdin (error, error_details, transcript_path).
#           Fires when the run ends on a Claude API error (e.g. billing_error when
#           credits run out), so Claude itself cannot report it. The PR number is
#           read from the latest user prompt ("/pr-review <n>") in the transcript; runs that are
#           not a PR review are ignored. The comment is posted in the background
#           because Claude Code kills StopFailure hooks as it exits.
#   gh CLI (GitHub) · AZURE_DEVOPS_TOKEN + curl (Azure DevOps)
#
# Always exits 0 so it never hides the original error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"

if [ "${1:-}" = "--hook" ]; then
  # Prints "<pr number>\t<what happened>\t<what to do>\t<error code>", or nothing
  # when this run is not a PR review.
  HOOK_RESULT=$(python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# Only the latest prompt the user typed counts: tool results (file contents, diffs)
# and earlier prompts in the session may mention other PR numbers.
prompt = ""
try:
    for line in open(d.get("transcript_path") or ""):
        e = json.loads(line)
        if e.get("type") != "user" or e.get("isMeta"):
            continue
        c = (e.get("message") or {}).get("content")
        if isinstance(c, list):
            if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
                continue
            c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
        if isinstance(c, str) and c.strip():
            prompt = c
except Exception:
    pass
cmd = r"/(?:[\w-]+:)?(?:pr-review|review-pr)"
m = (re.search(cmd + r"\s+#?(\d+)\b", prompt)
     or re.search(cmd + r"</command-name>.*?<command-args>\s*#?(\d+)\b", prompt, re.S))
pr = m.group(1) if m else ""
if not pr:
    sys.exit(0)
ADMIN = "Ask your Xianix admin to %s, then re-trigger the review."
WAIT = "Wait a few minutes, then re-trigger the review."
plain = {
    "billing_error":          ("The Claude API account has run out of credits.", ADMIN % "add credits"),
    "authentication_failed":  ("The Claude API key is invalid or has expired.", ADMIN % "update the Claude API key"),
    "account_on_hold":        ("The Claude API account is on hold.", ADMIN % "check the Claude account"),
    "oauth_org_not_allowed":  ("This Claude account is not allowed to run the review.", ADMIN % "check the Claude account"),
    "cloud_credential_error": ("The cloud credentials for Claude are not working.", ADMIN % "check the cloud credentials"),
    "model_not_found":        ("The Claude model set for the review is not available.", ADMIN % "check the model setting"),
    "rate_limit":             ("Too many requests were sent to the Claude API at once.", WAIT),
    "overloaded":             ("The Claude API is busy right now.", WAIT),
    "server_error":           ("The Claude API had a temporary problem.", WAIT),
}
code = d.get("error") or "unknown"
what, todo = plain.get(code, ("The Claude API returned an error.",
                              "Please re-trigger the review. If it keeps failing, contact your Xianix admin."))
print("\t".join([pr, what, todo, code]))
' 2>/dev/null)
  [ -n "$HOOK_RESULT" ] || exit 0
  IFS=$'\t' read -r HOOK_PR HOOK_WHAT HOOK_TODO HOOK_CODE <<< "$HOOK_RESULT"
  # Claude Code exits right after StopFailure and kills its hooks before a comment
  # can be posted, so post from a background copy of this script and return now.
  PR_NUMBER="$HOOK_PR" nohup bash "${BASH_SOURCE[0]}" \
    "$HOOK_WHAT The review could not run." "$HOOK_TODO" "$HOOK_CODE" \
    </dev/null >/dev/null 2>&1 &
  exit 0
fi

# Strip credentials from URLs before the message goes on the PR.
ERROR_MSG=$(printf '%s' "${1:-unknown error}" | sed -E 's#(https?://)[^/@[:space:]]+@#\1***@#g')

# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env
PR="${CALLER_PR:-${PR_NUMBER:-}}"
[ -n "$PR" ] || { echo "WARN: no PR number — cannot post failure comment" >&2; exit 0; }

NEXT_STEP="${2:-Please re-trigger the review. If it keeps failing, contact your Xianix admin.}"
BODY="❌ PR Review failed

${ERROR_MSG}

**What to do:** ${NEXT_STEP}"
[ -n "${3:-}" ] && BODY="${BODY}

<sub>Error code: \`${3}\`</sub>"

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
