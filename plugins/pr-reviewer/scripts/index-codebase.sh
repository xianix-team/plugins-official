#!/usr/bin/env bash
# index-codebase.sh — capped codebase index for large PRs (step 4).
#
# Why this exists as a real script: agents invent unbounded find/ls walks that
# flood context. Caps below are mandatory.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/index-codebase.sh"
#
# Inputs:
#   /tmp/pr_state.env          — CHANGED_COUNT (from pr-setup.sh)
#   /tmp/pr_changed_files.txt  — for language fingerprint
#
# Outputs:
#   Prints index to stdout (capped). Skips entirely when CHANGED_COUNT ≤ 10.
#   Exit 0 always (skip is success).

set -euo pipefail

# shellcheck disable=SC1091
[ -f ${PR_STATE_DIR:-/tmp}/pr_state.env ] && source ${PR_STATE_DIR:-/tmp}/pr_state.env

CHANGED_COUNT="${CHANGED_COUNT:-0}"
if [ ! -f ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt ] && [ "$CHANGED_COUNT" = "0" ]; then
  if [ -f ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt ]; then
    CHANGED_COUNT=$(wc -l < ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt | tr -d ' ')
  fi
fi

if [ "${CHANGED_COUNT:-0}" -le 10 ]; then
  echo "Small PR (${CHANGED_COUNT:-0} files) — skipping codebase index, diff alone is enough context."
  exit 0
fi

echo "=== Top-level layout ==="
ls -1

echo ""
echo "=== Source tree (depth 3, cap 200 lines) ==="
find . -maxdepth 3 \
  -name .git -prune -o \
  -name node_modules -prune -o \
  -name bin -prune -o \
  -name obj -prune -o \
  -name .vs -prune -o \
  -name dist -prune -o \
  -name build -prune -o \
  -print | sort | head -200

echo ""
echo "=== Language fingerprint (changed files) ==="
if [ -f ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt ]; then
  sed 's/.*\.//' ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt | sort | uniq -c | sort -rn | head -10
else
  echo "(no ${PR_STATE_DIR:-/tmp}/pr_changed_files.txt)"
fi

echo ""
echo "=== Entry points / build manifests ==="
# shellcheck disable=SC2086
ls *.sln *.csproj package.json go.mod Cargo.toml pom.xml build.gradle \
   pyproject.toml setup.py requirements.txt CMakeLists.txt 2>/dev/null || true

exit 0
