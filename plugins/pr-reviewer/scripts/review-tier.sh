#!/usr/bin/env bash
# review-tier.sh — decide haiku finders vs specialist reviewers from the diff.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-tier.sh"
#
# Inputs:
#   /tmp/pr_changed_files.txt
#   /tmp/pr_full_diff.patch
#   /tmp/pr_state.env (optional)
#
# Outputs:
#   Prints REVIEW_TIER=haiku|specialists
#   Appends REVIEW_TIER to /tmp/pr_state.env

set -euo pipefail

# shellcheck disable=SC1091
[ -f ${PR_STATE_DIR:-/tmp}/pr_state.env ] && source ${PR_STATE_DIR:-/tmp}/pr_state.env

if [ ! -f ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt ] || [ ! -f ${PR_STATE_DIR:-/tmp}/pr_full_diff.patch ]; then
  echo "ERROR: need ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt and ${PR_STATE_DIR:-/tmp}/pr_full_diff.patch (run pr-setup.sh first)" >&2
  exit 1
fi

RISK_PATH_RE='(auth|login|signin|session|password|passwd|secret|token|jwt|oauth|crypto|encrypt|decrypt|payment|billing|charge|invoice|checkout|migration|schema|\.sql$|webhook|/api/|/controllers?/|/routes?/|/handlers?/|iam|rbac|permission)'
RISK_CONTENT_RE='(password|secret|api[_-]?key|private[_-]?key|authorize|authenticate|hashpw|bcrypt|jwt|sql|exec\(|eval\(|subprocess|os\.system|pickle\.loads)'

REVIEW_TIER="haiku"
# 1. High-risk by file path — docs/images can never be a high-risk surface
if grep -ivE '\.(md|markdown|rst|txt|png|jpg|jpeg|gif|svg)$' ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt \
   | grep -qiE "$RISK_PATH_RE"; then
  REVIEW_TIER="specialists"
# 2. High-risk by changed content. '^\+[^+]' matches added lines ONLY
elif grep -E '^\+[^+]' ${PR_STATE_DIR:-/tmp}/pr_full_diff.patch | grep -qiE "$RISK_CONTENT_RE"; then
  REVIEW_TIER="specialists"
fi

if [ "$REVIEW_TIER" = "specialists" ]; then
  echo "High-risk surface detected — escalating to specialist reviewers."
else
  echo "No high-risk surface — using low-cost Haiku finder path."
fi
echo "REVIEW_TIER=$REVIEW_TIER"
{
  echo "export REVIEW_TIER=$(printf %q "$REVIEW_TIER")"
} >> ${PR_STATE_DIR:-/tmp}/pr_state.env
export REVIEW_TIER
