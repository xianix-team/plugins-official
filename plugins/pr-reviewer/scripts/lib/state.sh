#!/usr/bin/env bash
# state.sh — Deterministic state management for PR review across all platforms
#
# This library ensures that REVIEW_MODE, reconciliation state, and dedup logic
# are consistent across GitHub, Azure DevOps, and Generic platforms.
#
# Core idea: The command writes decision state to files; providers read and validate,
# never make independent decisions.

set -euo pipefail

# --- write_review_state() ---
# Called by command (pr-review.md) after detecting prior review.
# Writes the canonical mode decision so providers don't have to guess.
#
# Args:
#   mode: "initial" | "rereview"
#   prior_sha: <PRIOR_SUMMARY_SHA> or ""
#   head_sha: <HEAD_SHA>
#   range_base: <RANGE_BASE> (for incremental diff)
#   reconcile_enabled: true | false
write_review_state() {
  local mode="$1" prior_sha="$2" head_sha="$3" range_base="$4" reconcile_enabled="$5"

  python3 - "$mode" "$prior_sha" "$head_sha" "$range_base" "$reconcile_enabled" <<'PY'
import json, sys, pathlib
mode, prior_sha, head_sha, range_base, reconcile_enabled = sys.argv[1:6]
state = {
    "mode": mode,
    "prior_sha": prior_sha or None,
    "head_sha": head_sha,
    "range_base": range_base,
    "reconcile_enabled": reconcile_enabled.lower() in ("true", "1", "yes"),
    "_version": 1,
    "_comment": "Canonical review state written by command; providers MUST read from this file, not environment"
}
pathlib.Path("/tmp/pr_review_state.json").write_text(json.dumps(state, indent=2))
print(f"Review state: mode={mode}, reconcile={reconcile_enabled}")
PY
}

# --- read_review_state() ---
# Called by providers at startup to get canonical state.
# Returns 0 if state is valid; prints mode/prior_sha/head_sha/range_base/reconcile_enabled.
# Returns 1 if state file missing or invalid.
read_review_state() {
  if [ ! -f /tmp/pr_review_state.json ]; then
    echo "ERROR: /tmp/pr_review_state.json missing — command did not write review state" >&2
    return 1
  fi

  python3 <<'PY'
import json, sys
try:
  state = json.load(open("/tmp/pr_review_state.json"))
  mode = state.get("mode", "initial")
  prior_sha = state.get("prior_sha") or ""
  head_sha = state.get("head_sha", "")
  range_base = state.get("range_base", "")
  reconcile_enabled = state.get("reconcile_enabled", True)

  if not head_sha:
    print("ERROR: pr_review_state missing head_sha", file=sys.stderr)
    sys.exit(1)

  # Export as sourced variables: REVIEW_MODE, REVIEW_PRIOR_SHA, etc.
  print(f"export REVIEW_MODE={mode}")
  print(f"export REVIEW_PRIOR_SHA={prior_sha!r}")
  print(f"export REVIEW_HEAD_SHA={head_sha!r}")
  print(f"export REVIEW_RANGE_BASE={range_base!r}")
  print(f"export REVIEW_RECONCILE_ENABLED={str(reconcile_enabled).lower()}")
except Exception as e:
  print(f"ERROR: failed to read pr_review_state.json: {e}", file=sys.stderr)
  sys.exit(1)
PY
}

# --- log_state() ---
# Logs current review state for debugging/auditing.
log_state() {
  if [ -f /tmp/pr_review_state.json ]; then
    echo "=== Review State ===" >&2
    python3 -m json.tool /tmp/pr_review_state.json 2>&1 | sed 's/^/  /' >&2
  fi

  if [ -f /tmp/pr_reconcile.json ]; then
    echo "=== Reconcile State ===" >&2
    python3 -c "
import json
try:
  s = json.load(open('/tmp/pr_reconcile.json'))
  print(f'  New findings: {len(s.get(\"new\", []))}')
  print(f'  Carried-over: {len(s.get(\"carried_over_fids\", []))}')
  print(f'  Reopened: {len(s.get(\"reopened\", []))}')
  print(f'  Fixed: {len(s.get(\"fixed\", []))}')
except Exception as e:
  print(f'  (error reading reconcile state: {e})')
" >&2
  fi
}
