#!/usr/bin/env bash
# verify-pr.sh — confirm the PR exists and is still open (post-review / pre-post).
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-pr.sh" --pr 123
#
# Inputs (flags preferred; env names kept as fallback):
#   --pr N
#   PLATFORM (or detect from origin)
#   /tmp/pr_azure.env — Azure (from ado-start-comment / check-permissions)
#   AZURE_DEVOPS_TOKEN (via resolve_token) / gh CLI
#
# Outputs:
#   /tmp/pr_verify.env — PR_STATE, PR_TITLE, PR_HEAD_BRANCH, …
#   Exit 0 if open/active; exit 1 if missing, merged, completed, or abandoned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-token.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-azure-remote.sh"

parse_pr_args "$@" || exit 1
resolve_token azure || true
resolve_token github || true

PR_NUMBER="${PR_NUMBER:-${PR_ID:-}}"
[ -n "$PR_NUMBER" ] || { echo "ERROR: PR id unknown — re-run with --pr <number>" >&2; exit 1; }

REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
[ -n "$REMOTE_URL" ] || { echo "ERROR: no git remote origin" >&2; exit 1; }

case "$REMOTE_URL" in
  *github.com*) PLATFORM=github ;;
  *dev.azure.com*|*visualstudio.com*) PLATFORM=azure ;;
  *) PLATFORM=generic ;;
esac

fail_closed() {
  echo "ERROR: $1" >&2
  exit 1
}

case "$PLATFORM" in
  github)
    if ! command -v gh >/dev/null 2>&1; then
      fail_closed "gh CLI not installed"
    fi
    META=$(gh pr view "$PR_NUMBER" --json state,title,headRefName,url 2>/dev/null) \
      || fail_closed "PR #${PR_NUMBER} not found"
    STATE=$(echo "$META" | jq -r '.state')
    PR_TITLE=$(echo "$META" | jq -r '.title')
    PR_HEAD_BRANCH=$(echo "$META" | jq -r '.headRefName')
    PR_URL=$(echo "$META" | jq -r '.url')
    case "$STATE" in
      OPEN|open) ;;
      *) fail_closed "PR #${PR_NUMBER} is ${STATE} — not open; refusing to post" ;;
    esac
    echo "OK: PR #${PR_NUMBER} open: ${PR_TITLE}"
    ;;
  azure)
    if [ -f /tmp/pr_azure.env ]; then
      # shellcheck disable=SC1091
      source /tmp/pr_azure.env
    fi
    if [ -z "${API_BASE:-}" ] || [ -z "${AZURE_REPO:-}" ]; then
      parse_azure_remote || fail_closed "could not parse Azure remote"
      write_azure_env
    fi
    PR_ID="${PR_ID:-$PR_NUMBER}"
    [ -n "${AZURE_DEVOPS_TOKEN:-}" ] || fail_closed "AZURE_DEVOPS_TOKEN unset"
    BODY=$(mktemp)
    HTTP=$(curl -sS -o "$BODY" -w "%{http_code}" -u ":${AZURE_DEVOPS_TOKEN}" \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1" \
      || echo "000")
    [ "$HTTP" = "200" ] || { rm -f "$BODY"; fail_closed "PR #${PR_ID} not found (HTTP ${HTTP})"; }
    STATE=$(python3 -c "import json; print(json.load(open('$BODY')).get('status',''))")
    PR_TITLE=$(python3 -c "import json; print(json.load(open('$BODY')).get('title',''))")
    PR_HEAD_BRANCH=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('sourceRefName','').replace('refs/heads/',''))" "$BODY")
    PR_URL="${API_BASE}/_git/${AZURE_REPO}/pullrequest/${PR_ID}"
    rm -f "$BODY"
    case "$STATE" in
      active|Active) ;;
      *) fail_closed "PR #${PR_ID} is ${STATE} — not active; refusing to post" ;;
    esac
    echo "OK: PR #${PR_ID} active: ${PR_TITLE}"
    ;;
  *)
    echo "WARN: generic platform — no PR API to verify; continuing"
    STATE=generic
    PR_TITLE=""
    PR_HEAD_BRANCH=""
    PR_URL=""
    ;;
esac

{
  echo "export PLATFORM=$(printf %q "$PLATFORM")"
  echo "export PR_NUMBER=$(printf %q "$PR_NUMBER")"
  echo "export PR_STATE=$(printf %q "${STATE:-}")"
  echo "export PR_TITLE=$(printf %q "${PR_TITLE:-}")"
  echo "export PR_HEAD_BRANCH=$(printf %q "${PR_HEAD_BRANCH:-}")"
  echo "export PR_URL=$(printf %q "${PR_URL:-}")"
} > /tmp/pr_verify.env
echo "Wrote /tmp/pr_verify.env"
exit 0
