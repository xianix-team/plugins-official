#!/usr/bin/env bash
# resolve-models.sh — map PR_REVIEWER_* model env vars to valid Task/Agent slugs.
#
# Valid slugs: sonnet | opus | haiku | fable | (empty = inherit / omit model field).
# Values like claude-haiku-4-5 are rejected by the SDK — this script normalises them.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-models.sh"
#
# Inputs (optional env):
#   PR_REVIEWER_MODEL           — pins every reviewer
#   PR_REVIEWER_QUALITY_MODEL   — code/test default: haiku
#   PR_REVIEWER_RISK_MODEL      — security/performance default: inherit (omit)
#
# Outputs:
#   QUALITY_SLUG / RISK_SLUG printed and written to /tmp/pr_models.env
#   Appended to /tmp/pr_state.env

set -euo pipefail

map_model_slug() {
  case "$1" in
    inherit|"") echo "" ;;
    sonnet|opus|haiku|fable) echo "$1" ;;
    *haiku*) echo "haiku" ;;
    *sonnet*) echo "sonnet" ;;
    *opus*) echo "opus" ;;
    *fable*) echo "fable" ;;
    *) echo "haiku" ;;
  esac
}

RISK_MODEL="${PR_REVIEWER_RISK_MODEL:-inherit}"
QUALITY_MODEL="${PR_REVIEWER_QUALITY_MODEL:-haiku}"
if [ -n "${PR_REVIEWER_MODEL:-}" ]; then
  RISK_MODEL="$PR_REVIEWER_MODEL"
  QUALITY_MODEL="$PR_REVIEWER_MODEL"
fi

QUALITY_SLUG=$(map_model_slug "$QUALITY_MODEL")
RISK_SLUG=$(map_model_slug "$RISK_MODEL")

echo "Reviewer models — quality: ${QUALITY_SLUG:-inherit} | risk: ${RISK_SLUG:-inherit}"

{
  echo "export QUALITY_SLUG=$(printf %q "$QUALITY_SLUG")"
  echo "export RISK_SLUG=$(printf %q "$RISK_SLUG")"
} | tee ${PR_STATE_DIR:-/tmp}/pr_models.env

if [ -f ${PR_STATE_DIR:-/tmp}/pr_state.env ]; then
  grep -vE '^export (QUALITY_SLUG|RISK_SLUG)=' ${PR_STATE_DIR:-/tmp}/pr_state.env > ${PR_STATE_DIR:-/tmp}/pr_state.env.tmp 2>/dev/null || cp ${PR_STATE_DIR:-/tmp}/pr_state.env ${PR_STATE_DIR:-/tmp}/pr_state.env.tmp
  cat ${PR_STATE_DIR:-/tmp}/pr_models.env >> ${PR_STATE_DIR:-/tmp}/pr_state.env.tmp
  mv ${PR_STATE_DIR:-/tmp}/pr_state.env.tmp ${PR_STATE_DIR:-/tmp}/pr_state.env
else
  cp ${PR_STATE_DIR:-/tmp}/pr_models.env ${PR_STATE_DIR:-/tmp}/pr_state.env
fi

exit 0
