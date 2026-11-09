#!/usr/bin/env bash
# report-failure.sh — tell the PR author that the review stopped, and why.
#
# Why this exists as a script: when a step fails, the agent used to print one
# error line and stop, leaving the "🔍 PR Review in Progress" comment on the PR
# forever. Calling this script from the failure path makes the PR comment
# deterministic instead of relying on the agent remembering to post one.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/report-failure.sh" <stage> [reason]
#
#   <stage>   short id of the step that failed (e.g. pr-not-open, checkout).
#             Unknown stages get a generic "review failed" message.
#   [reason]  one-line technical reason. Secrets are redacted before posting.
#
# Inputs:
#   PR_NUMBER / PR_ID             — or resolved from /tmp/pr_state.env, /tmp/pr_azure.env
#   PLATFORM                      — or detected from origin
#   /tmp/pr_progress_comment.env  — written by gh-start-comment.sh / ado-start-comment.sh;
#                                   when it matches this PR, that comment is edited in place
#   GITHUB: gh CLI · AZURE: AZURE_DEVOPS_TOKEN + curl
#
# Outputs:
#   One log line on stderr: "ERROR: [pr-review] <stage>: <reason>" (WARN for skips)
#   One PR comment per run (edits the progress comment, else posts a new one)
#   /tmp/pr_failure_reported      — once-per-run guard (holds the PR number)
#
# Always exits 0: reporting a failure must never mask the original failure.

set -uo pipefail  # not -e: every error path below must fall through to exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="${1:-unknown}"
REASON="${2:-}"
GUARD=/tmp/pr_failure_reported
BODY_FILE=/tmp/pr_failure_body.md

CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"

# --- 1. Redact secrets from the reason (tokens, credentialed URLs) ---
redact() {
  REDACT_TEXT="$1" python3 - <<'PY'
import os, re
text = os.environ.get("REDACT_TEXT", "")
for name in ("GITHUB_TOKEN", "GH_TOKEN", "AZURE_DEVOPS_TOKEN", "ANTHROPIC_API_KEY"):
    val = os.environ.get(name, "")
    if len(val) >= 8:
        text = text.replace(val, "***")
text = re.sub(r"(https?://)[^/@\s]+@", r"\1***@", text)
text = re.sub(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}", "***", text)
text = re.sub(r"\bgithub_pat_[A-Za-z0-9_]{20,}", "***", text)
text = re.sub(r"\bsk-ant-[A-Za-z0-9_-]{10,}", "***", text)
text = re.sub(r"(?i)\b(authorization:\s*(?:basic|bearer)\s+)\S+", r"\1***", text)
text = re.sub(r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{12,}", r"\1***", text)
text = " ".join(text.split())  # one line: no stack traces in the PR
print(text[:500] + ("…" if len(text) > 500 else ""))
PY
}
REASON=$(redact "$REASON")

# --- 2. Pick the message for this stage ---
SEVERITY=ERROR
case "$STAGE" in
  pr-not-open)
    SEVERITY=WARN
    TITLE="⏭️ PR Review skipped"
    MESSAGE="This pull request is no longer open, so the review was not run."
    ;;
  checkout)
    TITLE="❌ PR Review failed"
    MESSAGE="Couldn't check out the latest commit of this pull request. If new commits were pushed while the review was starting, please re-trigger the review."
    ;;
  base)
    TITLE="❌ PR Review failed"
    MESSAGE="Couldn't compare this pull request with its base branch. Check that the base branch still exists and shares history with this branch, then re-trigger the review."
    ;;
  *)
    TITLE="❌ PR Review failed"
    MESSAGE="The review stopped during the **${STAGE}** step. Please re-trigger the review. If it keeps failing, contact your Xianix admin."
    ;;
esac

echo "${SEVERITY}: [pr-review] ${STAGE}: ${REASON:-no reason given}" >&2

# --- 3. Resolve platform and PR number ---
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
case "$REMOTE_URL" in
  *github.com*) PLATFORM=github ;;
  *dev.azure.com*|*visualstudio.com*) PLATFORM=azure ;;
  *) PLATFORM=generic ;;
esac

# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env
# shellcheck disable=SC1091
[ "$PLATFORM" = azure ] && [ -f /tmp/pr_azure.env ] && source /tmp/pr_azure.env
PR="${CALLER_PR:-${PR_NUMBER:-${PR_ID:-}}}"

if [ "$PLATFORM" = generic ]; then
  echo "WARN: generic platform — no PR API to post the failure comment" >&2
  exit 0
fi
if [ -z "$PR" ]; then
  echo "WARN: no PR number — cannot post the failure comment" >&2
  exit 0
fi

# --- 4. Once per run ---
if [ -f "$GUARD" ] && [ "$(cat "$GUARD" 2>/dev/null)" = "$PR" ]; then
  echo "Failure already reported on PR #${PR} this run — not posting again" >&2
  exit 0
fi

# --- 5. Build the comment body ---
PLUGIN_VERSION=$(grep -hom1 '"version"[^,}]*' \
  "${SCRIPT_DIR}/../.claude-plugin/plugin.json" 2>/dev/null | cut -d'"' -f4 || true)
PLUGIN_VERSION=${PLUGIN_VERSION:-unknown}

{
  echo "$TITLE"
  echo
  echo "$MESSAGE"
  echo
  echo "**Stage:** \`${STAGE}\`"
  [ -n "$REASON" ] && echo "**Reason:** ${REASON}"
  echo
  echo "PR Reviewer (${PLUGIN_VERSION})"
} > "$BODY_FILE"

# Edit the progress comment only when it belongs to this PR.
PROGRESS_PR=""; PROGRESS_COMMENT_ID=""; PROGRESS_THREAD_ID=""
# shellcheck disable=SC1091
[ -f /tmp/pr_progress_comment.env ] && source /tmp/pr_progress_comment.env
if [ "$PROGRESS_PR" != "$PR" ]; then
  PROGRESS_COMMENT_ID=""; PROGRESS_THREAD_ID=""
fi

# --- 6. Post ---
POSTED=0
case "$PLATFORM" in
  github)
    if ! command -v gh >/dev/null 2>&1; then
      echo "WARN: gh CLI not found — cannot post the failure comment" >&2
      exit 0
    fi
    if [ -n "$PROGRESS_COMMENT_ID" ] && \
       gh api -X PATCH "repos/{owner}/{repo}/issues/comments/${PROGRESS_COMMENT_ID}" \
         -F "body=@${BODY_FILE}" >/dev/null 2>&1; then
      POSTED=1
      echo "Updated progress comment on PR #${PR} with the failure"
    elif gh pr comment "$PR" --body-file "$BODY_FILE" >/dev/null 2>&1; then
      POSTED=1
      echo "Posted failure comment on PR #${PR}"
    fi
    ;;
  azure)
    if [ -z "${AZURE_DEVOPS_TOKEN:-}" ]; then
      echo "WARN: AZURE_DEVOPS_TOKEN unset — cannot post the failure comment" >&2
      exit 0
    fi
    if [ -z "${API_BASE:-}" ] || [ -z "${AZURE_REPO:-}" ]; then
      # shellcheck disable=SC1091
      source "${SCRIPT_DIR}/lib-azure-remote.sh"
      parse_azure_remote >/dev/null 2>&1 || true
    fi
    if [ -z "${API_BASE:-}" ] || [ -z "${AZURE_REPO:-}" ]; then
      echo "WARN: could not parse Azure remote — cannot post the failure comment" >&2
      exit 0
    fi
    THREADS="${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR}/threads"
    ado_send() {  # ado_send <method> <url> <payload> -> 0 on HTTP 2xx
      local code
      code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
        -u ":${AZURE_DEVOPS_TOKEN}" -X "$1" --data "$3" "$2" 2>/dev/null || echo "000")
      echo "$code" | grep -qE '^2'
    }
    if [ -n "$PROGRESS_THREAD_ID" ] && [ -n "$PROGRESS_COMMENT_ID" ] && \
       ado_send PATCH "${THREADS}/${PROGRESS_THREAD_ID}/comments/${PROGRESS_COMMENT_ID}?api-version=7.1" \
         "$(python3 -c "import json,sys; print(json.dumps({'content': open(sys.argv[1]).read()}))" "$BODY_FILE")"; then
      POSTED=1
      echo "Updated progress comment on PR #${PR} with the failure"
    elif ado_send POST "${THREADS}?api-version=7.1" \
         "$(python3 -c "
import json, sys
print(json.dumps({
    'comments': [{'content': open(sys.argv[1]).read(), 'commentType': 1}],
    'status': 'active',
    'properties': {'Microsoft.TeamFoundation.Discussion.SupportsMarkdown': {'\$type': 'System.Int32', '\$value': 1}},
}))" "$BODY_FILE")"; then
      POSTED=1
      echo "Posted failure comment on PR #${PR}"
    fi
    ;;
esac

if [ "$POSTED" -eq 1 ]; then
  echo "$PR" > "$GUARD"
else
  echo "WARN: could not post the failure comment on PR #${PR} — see the log line above" >&2
fi
exit 0
