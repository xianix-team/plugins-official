#!/usr/bin/env bash
# push-fixes.sh — env-scoped credential push for --fix mode.
#
# Why this exists as a real script: agents invent credential helpers that write
# tokens to disk or echo them into the transcript. This scopes the token to one
# git push via GIT_CONFIG_* and never prints the secret.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/push-fixes.sh" [--branch NAME]
#
# Inputs (flags preferred; env names kept as fallback):
#   --branch NAME           — destination branch when HEAD is detached
#   origin remote
#   GITHUB_TOKEN / AZURE_DEVOPS_TOKEN via resolve_token (platform-appropriate)
#   /tmp/pr_state.env — optional PR_HEAD_BRANCH / CURRENT_BRANCH (needed when
#                       HEAD is detached after pr-setup.sh checkout)
#
# Outputs:
#   Pushes HEAD to the PR head branch on origin. Exit non-zero on failure.
#   Never echoes token values.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-token.sh"

parse_pr_args "$@" || exit 1

# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env

REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
[ -n "$REMOTE_URL" ] || { echo "ERROR: no git remote origin" >&2; exit 1; }

REMOTE_HOST=$(echo "$REMOTE_URL" | sed -E 's|^[a-z+]+://||; s|^[^@/]+@||; s|[:/].*$||')

case "$REMOTE_URL" in
  *dev.azure.com*|*visualstudio.com*)
    if ! resolve_token azure; then
      echo "ERROR: AZURE_DEVOPS_TOKEN unset — required for fix-mode push (see docs/git-auth.md)" >&2
      exit 1
    fi
    PUSH_TOKEN="${AZURE_DEVOPS_TOKEN}"
    TOKEN_NAME=AZURE_DEVOPS_TOKEN
    ;;
  *github.com*)
    if ! resolve_token github; then
      echo "ERROR: GITHUB_TOKEN unset — required for fix-mode push (see docs/git-auth.md)" >&2
      exit 1
    fi
    PUSH_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    TOKEN_NAME=GITHUB_TOKEN
    ;;
  *)
    echo "ERROR: unknown remote host — cannot choose push token" >&2
    exit 1
    ;;
esac

echo "${TOKEN_NAME}=${PUSH_TOKEN:+yes}"
[ -n "$PUSH_TOKEN" ] || {
  echo "ERROR: ${TOKEN_NAME} unset — required for fix-mode push (see docs/git-auth.md)" >&2
  exit 1
}

# Resolve destination branch. After pr-setup.sh, HEAD is detached at the PR tip —
# `git push origin HEAD` fails with "not a full refname". Prefer --branch / PR_HEAD_BRANCH.
BRANCH="${BRANCH_ARG:-${PR_HEAD_BRANCH:-${CURRENT_BRANCH:-}}}"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  # Last resort: branch that contains HEAD (excluding detached markers)
  BRANCH=$(git branch --contains HEAD 2>/dev/null \
    | sed 's|^[* ] *||' | grep -v '^(' | head -1 || true)
fi
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "ERROR: cannot resolve PR head branch for push (pass --branch NAME or run pr-setup.sh)" >&2
  exit 1
fi
# Strip accidental refs/heads/ prefix
BRANCH="${BRANCH#refs/heads/}"

# Prefer HEAD_SHA from pr-setup.sh — on Azure /merge checkouts, git HEAD is the
# merge commit; HEAD_SHA is the real PR tip (HEAD^2) that must be pushed.
PUSH_SHA="${HEAD_SHA:-$(git rev-parse HEAD)}"
# Validate the object exists locally
git cat-file -e "${PUSH_SHA}^{commit}" 2>/dev/null || {
  echo "ERROR: push SHA ${PUSH_SHA} is not a local commit" >&2
  exit 1
}

echo "Pushing ${PUSH_SHA:0:7} → origin/refs/heads/${BRANCH} (host=${REMOTE_HOST})…"

set +e
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="url.https://x-access-token:${PUSH_TOKEN}@${REMOTE_HOST}/.insteadOf" \
GIT_CONFIG_VALUE_0="https://${REMOTE_HOST}/" \
git push origin "${PUSH_SHA}:refs/heads/${BRANCH}"
PUSH_RC=$?
set -e

if [ "$PUSH_RC" -ne 0 ]; then
  echo "ERROR: git push failed (exit ${PUSH_RC}). For Azure DevOps ensure the PAT has Code (Read & Write)." >&2
  exit "$PUSH_RC"
fi

echo "Push OK: ${PUSH_SHA:0:7} → ${BRANCH}"
exit 0
