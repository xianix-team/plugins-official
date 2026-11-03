#!/usr/bin/env bash
# select-reviewers.sh — gate specialist reviewers from the changed-file mix (step 6B).
#
# Why this exists as a real script: agents skip reviewers or invent wrong gates.
# When uncertain, prefer running a reviewer (matches commands/pr-review.md).
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/select-reviewers.sh"
#
# Inputs:
#   /tmp/pr_changed_files.txt
#   /tmp/pr_full_diff.patch     — optional; used for content heuristics
#
# Outputs:
#   RUN_CODE / RUN_TEST / RUN_SECURITY / RUN_PERFORMANCE = true|false
#   Written to /tmp/pr_reviewers.env and appended to /tmp/pr_state.env

set -euo pipefail

# shellcheck disable=SC1091
[ -f ${PR_STATE_DIR:-/tmp}/pr_state.env ] && source ${PR_STATE_DIR:-/tmp}/pr_state.env

if [ ! -f ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt ]; then
  echo "ERROR: need ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt (run pr-setup.sh first)" >&2
  exit 1
fi

FILES=${PR_STATE_DIR:-/tmp}/pr_changed_files.txt
DIFF=${PR_STATE_DIR:-/tmp}/pr_full_diff.patch

has_path() { grep -qiE "$1" "$FILES"; }
non_matching_paths() { grep -vE "$1" "$FILES" | grep -q .; }
added_matches() {
  [ -f "$DIFF" ] && grep -E '^\+[^+]' "$DIFF" | grep -qiE "$1"
}

DOCS_IMG_RE='\.(md|markdown|rst|txt|png|jpg|jpeg|gif|svg|ico|webp)$'
SOURCE_RE='\.(cs|go|py|js|jsx|ts|tsx|java|kt|rb|php|rs|c|cc|cpp|h|hpp|swift|scala|vue|svelte|mjs|cjs)$'
LOCK_OR_MANIFEST_RE='(package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.(toml|lock)|go\.(mod|sum)|.*\.csproj|packages\.lock\.json|Pipfile(\.lock)?|poetry\.lock|requirements.*\.txt|Gemfile(\.lock)?|composer\.(json|lock)|Dockerfile|.*\.tf$|.*\.tfvars$|helm/|k8s/|kubernetes/)'
PERF_PATH_RE='(query|sql|orm|repo|repository|cache|handler|controller|route|middleware|auth|batch|stream|worker|queue|async|database|mongo|redis|postgres|mysql)'
PERF_CONTENT_RE='(SELECT |INSERT |UPDATE |DELETE |findMany|findAll|N\+1|for\s*\(|\.map\(|\.forEach\(|await |Promise\.all|readFile|writeFile|fetch\()'
CODE_SIGNAL_RE='(function|class |def |fn |func |public |private |export |import |require\(|=>)'

RUN_CODE=true
RUN_TEST=true
RUN_SECURITY=true
RUN_PERFORMANCE=true

# --- security: skip only docs/markdown/images ---
if ! non_matching_paths "$DOCS_IMG_RE"; then
  RUN_TEST=false
  RUN_SECURITY=false
  RUN_PERFORMANCE=false
  echo "Diff is docs/images only — code-reviewer only."
else
  HAS_SOURCE=false
  has_path "$SOURCE_RE" && HAS_SOURCE=true
  HAS_LOCK=false
  has_path "$LOCK_OR_MANIFEST_RE" && HAS_LOCK=true
  HAS_CODE_IN_DIFF=false
  added_matches "$CODE_SIGNAL_RE" && HAS_CODE_IN_DIFF=true

  # --- test: skip when only docs/config/formatting (no behavioural source) ---
  if [ "$HAS_SOURCE" = false ] && [ "$HAS_CODE_IN_DIFF" = false ]; then
    RUN_TEST=false
  fi

  # --- security: keep for source, lockfiles/IaC, or any non-docs surface ---
  # (already true; only docs-only cleared it above)

  # --- performance: skip when only docs/config with no executable / hot-path ---
  HAS_PERF=false
  if has_path "$PERF_PATH_RE" || added_matches "$PERF_CONTENT_RE"; then
    HAS_PERF=true
  elif [ "$HAS_SOURCE" = true ]; then
    # Source present but no hot-path signal — still run (uncertain → run)
    HAS_PERF=true
  fi
  if [ "$HAS_PERF" = false ]; then
    RUN_PERFORMANCE=false
  fi

  # Lockfile-only without source: keep security, skip test + performance
  if [ "$HAS_SOURCE" = false ] && [ "$HAS_LOCK" = true ] && [ "$HAS_CODE_IN_DIFF" = false ]; then
    RUN_TEST=false
    RUN_PERFORMANCE=false
    echo "Lockfile/manifest-only — security kept for dependency risk."
  fi
fi

{
  echo "export RUN_CODE=$(printf %q "$RUN_CODE")"
  echo "export RUN_TEST=$(printf %q "$RUN_TEST")"
  echo "export RUN_SECURITY=$(printf %q "$RUN_SECURITY")"
  echo "export RUN_PERFORMANCE=$(printf %q "$RUN_PERFORMANCE")"
} | tee ${PR_STATE_DIR:-/tmp}/pr_reviewers.env

if [ -f ${PR_STATE_DIR:-/tmp}/pr_state.env ]; then
  grep -vE '^export RUN_(CODE|TEST|SECURITY|PERFORMANCE)=' ${PR_STATE_DIR:-/tmp}/pr_state.env > ${PR_STATE_DIR:-/tmp}/pr_state.env.tmp || true
  cat ${PR_STATE_DIR:-/tmp}/pr_reviewers.env >> ${PR_STATE_DIR:-/tmp}/pr_state.env.tmp
  mv ${PR_STATE_DIR:-/tmp}/pr_state.env.tmp ${PR_STATE_DIR:-/tmp}/pr_state.env
else
  cp ${PR_STATE_DIR:-/tmp}/pr_reviewers.env ${PR_STATE_DIR:-/tmp}/pr_state.env
fi

SELECTED=1
[ "$RUN_TEST" = true ] && SELECTED=$((SELECTED + 1))
[ "$RUN_SECURITY" = true ] && SELECTED=$((SELECTED + 1))
[ "$RUN_PERFORMANCE" = true ] && SELECTED=$((SELECTED + 1))
echo "Reviewers: code=$RUN_CODE test=$RUN_TEST security=$RUN_SECURITY performance=$RUN_PERFORMANCE"
echo "SELECTED_REVIEWERS=$SELECTED"
exit 0
