#!/usr/bin/env bash
# gh-start-comment.sh — post GitHub "review in progress" comment.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/gh-start-comment.sh" --pr 123
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/gh-start-comment.sh" --optional
#
# Inputs (flags preferred; env names kept as fallback):
#   --pr N / --optional
#   gh CLI authenticated

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-token.sh"

parse_pr_args "$@" || exit 1
resolve_token github || true

# A caller-provided PR number must win over a stale /tmp/pr_state.env left by a
# previous run (this script normally runs before pr-setup.sh writes that file).
CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"
# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env

if ! command -v gh >/dev/null 2>&1; then
  echo "WARN: gh CLI not found — skipping review-in-progress comment" >&2
  exit 0
fi

PR_NUMBER="${CALLER_PR:-${PR_NUMBER:-${PR_ID:-}}}"
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null || true)
fi
if [ -z "$PR_NUMBER" ]; then
  if [ "${START_COMMENT_OPTIONAL:-false}" = "true" ]; then
    echo "WARN: no PR number — skipping review-in-progress comment" >&2
    exit 0
  fi
  echo "ERROR: PR id unknown — re-run with --pr <number>" >&2
  exit 1
fi

PLUGIN_VERSION=$(grep -hom1 '"version"[^,}]*' \
  "${SCRIPT_DIR}/../.claude-plugin/plugin.json" \
  ~/.claude/plugins/pr-reviewer/.claude-plugin/plugin.json \
  "$HOME/Library/Application Support/Claude/plugins/pr-reviewer/.claude-plugin/plugin.json" 2>/dev/null \
  | cut -d'"' -f4 || true)
PLUGIN_VERSION=${PLUGIN_VERSION:-unknown}

if gh pr comment "$PR_NUMBER" --body "$(cat <<EOF
🔍 PR Review in Progress

Claude Code is analyzing this pull request. The review will be posted here shortly.

PR Reviewer (${PLUGIN_VERSION})
EOF
)"; then
  echo "Review-in-progress comment posted on PR #${PR_NUMBER}"
else
  echo "WARN: review-in-progress comment failed — continuing" >&2
fi
