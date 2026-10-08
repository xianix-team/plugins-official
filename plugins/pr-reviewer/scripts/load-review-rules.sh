#!/usr/bin/env bash
# load-review-rules.sh — load REVIEW_RULES.md from the base branch.
#
# Output:
#   /tmp/pr_review_rules.md  — the rules (only if found)
#   REVIEW_RULES_FOUND / REVIEW_RULES_TRUNCATED / REVIEW_RULES_CHANGED_IN_PR
#   added to /tmp/pr_state.env

set -euo pipefail

RULES_FILE="REVIEW_RULES.md"
OUT=/tmp/pr_review_rules.md
MAX_LINES="${PR_REVIEWER_RULES_MAX_LINES:-300}"

# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env
REF="${BASE_TIP:-${BASE_SHA:-}}"
[ -n "$REF" ] || { echo "ERROR: run pr-setup.sh first" >&2; exit 1; }

rm -f "$OUT"
FOUND=false
TRUNCATED=false
if git cat-file -e "${REF}:${RULES_FILE}" 2>/dev/null; then
  git show "${REF}:${RULES_FILE}" > "$OUT"
  if [ "$(wc -l < "$OUT")" -gt "$MAX_LINES" ]; then
    head -n "$MAX_LINES" "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    TRUNCATED=true
    echo "WARN: ${RULES_FILE} is too long — only the first ${MAX_LINES} lines are used" >&2
  fi
  FOUND=true
  echo "Loaded ${RULES_FILE} from base branch"
else
  echo "No ${RULES_FILE} found — normal review"
fi

CHANGED=false
if grep -qx "$RULES_FILE" /tmp/pr_changed_files.txt 2>/dev/null; then
  CHANGED=true
  echo "NOTE: this PR edits ${RULES_FILE} — using the base branch version"
fi

{
  echo "REVIEW_RULES_FOUND=$FOUND"
  echo "REVIEW_RULES_TRUNCATED=$TRUNCATED"
  echo "REVIEW_RULES_CHANGED_IN_PR=$CHANGED"
} >> /tmp/pr_state.env
