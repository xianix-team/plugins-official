#!/usr/bin/env bash
# gh-start-comment.sh — post GitHub "review in progress" comment.
#
# Usage:
#   PR_NUMBER=123 bash "${CLAUDE_PLUGIN_ROOT}/scripts/gh-start-comment.sh"
#
# Inputs:
#   PR_NUMBER             — required (or resolvable via gh for current branch)
#   gh CLI authenticated
#
# Outputs:
#   /tmp/pr_progress_comment.env — PROGRESS_PR, PROGRESS_COMMENT_ID (read by report-failure.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  echo "WARN: no PR number — skipping review-in-progress comment" >&2
  exit 0
fi

PLUGIN_VERSION=$(grep -hom1 '"version"[^,}]*' \
  "${SCRIPT_DIR}/../.claude-plugin/plugin.json" \
  ~/.claude/plugins/pr-reviewer/.claude-plugin/plugin.json \
  "$HOME/Library/Application Support/Claude/plugins/pr-reviewer/.claude-plugin/plugin.json" 2>/dev/null \
  | cut -d'"' -f4 || true)
PLUGIN_VERSION=${PLUGIN_VERSION:-unknown}

# A new run starts here: drop the previous run's progress comment and failure guard.
rm -f /tmp/pr_progress_comment.env /tmp/pr_failure_reported

if COMMENT_URL=$(gh pr comment "$PR_NUMBER" --body "$(cat <<EOF
🔍 PR Review in Progress

Claude Code is analyzing this pull request. The review will be posted here shortly.

PR Reviewer (${PLUGIN_VERSION})
EOF
)"); then
  echo "Review-in-progress comment posted on PR #${PR_NUMBER}"
  # Remember the comment so report-failure.sh can edit it instead of leaving it stuck.
  COMMENT_ID="${COMMENT_URL##*#issuecomment-}"
  if [ "$COMMENT_ID" != "$COMMENT_URL" ]; then
    {
      echo "export PROGRESS_PR=$(printf %q "$PR_NUMBER")"
      echo "export PROGRESS_COMMENT_ID=$(printf %q "$COMMENT_ID")"
    } > /tmp/pr_progress_comment.env
  fi
else
  echo "WARN: review-in-progress comment failed — continuing" >&2
fi
