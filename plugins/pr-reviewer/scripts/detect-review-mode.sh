#!/usr/bin/env bash
# detect-review-mode.sh — run platform detect-prior + decide initial vs re-review.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-review-mode.sh" [--pr N]
#
# Inputs (flags preferred; env names kept as fallback):
#   --pr N                  — forwarded to platform detect-prior scripts
#   /tmp/pr_state.env       — from pr-setup.sh (PLATFORM, PR_NUMBER, BASE_SHA, HEAD_SHA)
#   PR_REVIEWER_RECONCILE   — default true; set false for stateless full review
#   CLAUDE_PLUGIN_ROOT      — preferred path to scripts/
#
# Outputs:
#   /tmp/pr_prior_findings.jsonl
#   /tmp/pr_open_threads.jsonl
#   /tmp/pr_prior.env
#   /tmp/pr_incremental_diff.patch  (re-review only, when RANGE_BASE != BASE_SHA)
#   Appends REVIEW_MODE and RANGE_BASE to /tmp/pr_state.env
#
# A re-trigger with zero new commits (HEAD_SHA == PRIOR_SUMMARY_SHA) still runs
# a full re-review, not a no-op: finder sub-agents are non-deterministic, so a
# second pass over the same diff can catch something the first pass missed.
# What keeps this safe is reconcile-prior-findings.sh's Gate A, which forces
# any "fixed" candidate back to carried_over whenever HEAD hasn't moved since
# the prior review — the code can't have been fixed if it hasn't changed —
# while a genuinely new finding still gets its own (content-derived, so
# duplicate-safe) fid and posts normally.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"

parse_pr_args "$@" || exit 1
CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"

# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env

# Flag --pr wins over stale state.
if [ -n "${CALLER_PR:-}" ]; then
  PR_NUMBER="$CALLER_PR"
  PR_ID="$CALLER_PR"
  export PR_NUMBER PR_ID
fi

: "${PR_REVIEWER_RECONCILE:=true}"
PLATFORM="${PLATFORM:-}"
if [ -z "$PLATFORM" ]; then
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
  case "$REMOTE_URL" in
    *github.com*) PLATFORM=github ;;
    *dev.azure.com*|*visualstudio.com*) PLATFORM=azure ;;
    *) PLATFORM=generic ;;
  esac
fi

resolve_script() {
  local name="$1"
  local candidate cand
  # shellcheck disable=SC1091
  [ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
  candidate="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/$name}"
  if [ -n "${candidate:-}" ] && [ -f "$candidate" ]; then
    echo "$candidate"
    return 0
  fi
  if [ -f "${SCRIPT_DIR}/${name}" ]; then
    echo "${SCRIPT_DIR}/${name}"
    return 0
  fi
  for cand in \
    ${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/plugins/cache/*/pr-reviewer/*/scripts/$name} \
    ${HOME:+$HOME/.claude/plugins/cache/*/pr-reviewer/*/scripts/$name} \
    /workspace/repo/xianix-claude-config/plugins/cache/*/pr-reviewer/*/scripts/"$name"
  do
    [ -f "$cand" ] || continue
    echo "$cand"
    return 0
  done
  find \
    ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT"} \
    ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR/plugins"} \
    ${HOME:+"$HOME/.claude/plugins"} \
    /workspace/repo/xianix-claude-config/plugins \
    -path "*/pr-reviewer/scripts/${name}" 2>/dev/null | sort -V | tail -1
}

if [ "$PR_REVIEWER_RECONCILE" = "false" ] || [ "$PLATFORM" = "generic" ]; then
  : > /tmp/pr_prior_findings.jsonl
  : > /tmp/pr_open_threads.jsonl
  : > /tmp/pr_prior.env
  if [ "$PLATFORM" = "generic" ]; then
    echo "Generic platform — skipping prior-review detection (no API)"
  else
    echo "PR_REVIEWER_RECONCILE=false — forcing initial (stateless) mode"
  fi
else
  case "$PLATFORM" in
    github)
      DETECT=$(resolve_script gh-detect-prior.sh)
      [ -n "${DETECT:-}" ] && [ -f "$DETECT" ] || {
        echo "ERROR: scripts/gh-detect-prior.sh not found — refuse to invent a GraphQL dump" >&2
        exit 1
      }
      if [ -n "${PR_NUMBER:-${PR_ID:-}}" ]; then
        bash "$DETECT" --pr "${PR_NUMBER:-$PR_ID}"
      else
        bash "$DETECT"
      fi
      ;;
    azure)
      DETECT=$(resolve_script ado-detect-prior.sh)
      [ -n "${DETECT:-}" ] && [ -f "$DETECT" ] || {
        echo "ERROR: scripts/ado-detect-prior.sh not found — refuse to invent a threads curl" >&2
        exit 1
      }
      if [ -n "${PR_NUMBER:-${PR_ID:-}}" ]; then
        bash "$DETECT" --pr "${PR_NUMBER:-$PR_ID}"
      else
        bash "$DETECT"
      fi
      ;;
    *)
      : > /tmp/pr_prior_findings.jsonl
      : > /tmp/pr_open_threads.jsonl
      : > /tmp/pr_prior.env
      ;;
  esac
fi

# shellcheck disable=SC1091
[ -f /tmp/pr_prior.env ] && source /tmp/pr_prior.env
[ -f /tmp/pr_open_threads.jsonl ] || : > /tmp/pr_open_threads.jsonl

if [ "$PR_REVIEWER_RECONCILE" = "false" ] || [ ! -s /tmp/pr_prior_findings.jsonl ]; then
  REVIEW_MODE="initial"
  RANGE_BASE="${BASE_SHA:-}"
else
  REVIEW_MODE="rereview"
  if [ -n "${PRIOR_SUMMARY_SHA:-}" ] && git cat-file -e "${PRIOR_SUMMARY_SHA}^{commit}" 2>/dev/null; then
    RANGE_BASE="$PRIOR_SUMMARY_SHA"
  else
    RANGE_BASE="${BASE_SHA:-}"
  fi
fi

OPEN_THREAD_COUNT=$(wc -l < /tmp/pr_open_threads.jsonl | tr -d ' ')
HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD)}"
echo "Review mode: $REVIEW_MODE  |  incremental range: ${RANGE_BASE}..${HEAD_SHA}  |  open threads: ${OPEN_THREAD_COUNT}"

if [ "$REVIEW_MODE" = "rereview" ] && [ -n "${BASE_SHA:-}" ] && [ "$RANGE_BASE" != "$BASE_SHA" ]; then
  git log --oneline "${RANGE_BASE}..${HEAD_SHA}" || true
  git diff "${RANGE_BASE}...${HEAD_SHA}" > /tmp/pr_incremental_diff.patch
  echo "Incremental diff: $(wc -l < /tmp/pr_incremental_diff.patch) lines since last review"
fi

{
  echo "export REVIEW_MODE=$(printf %q "$REVIEW_MODE")"
  echo "export RANGE_BASE=$(printf %q "$RANGE_BASE")"
} >> /tmp/pr_state.env
export REVIEW_MODE RANGE_BASE
