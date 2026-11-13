#!/usr/bin/env bash
# group-lock.sh — one group review at a time, using a state comment on the work item.
#
# Why this exists: there is no long-running workflow per group, so two pushes to two
# member PRs start two containers. The group's state (lock owner, heartbeat, the commit
# each PR was last reviewed at) is stored next to the work item; the first run takes the lock and
# the other one exits. After posting, `next` decides: done, review again in this same
# container (a member got new commits or a PR was linked meanwhile), or — when time or
# passes run out — hand over to a new run with one follow-up comment.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-lock.sh" acquire     # prints LOCK=acquired | LOCK=busy …
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-lock.sh" heartbeat   # LOCK=heartbeat | disabled (label removed) | lost
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-lock.sh" release     # free the lock (any early stop)
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-lock.sh" next        # NEXT=done | again | handed-off
#
# Inputs:
#   $PRG_WS/discovery.json and run.env (from group-discover.sh)
#   $PRG_ROOT/group_state.json (from group-setup.sh) — read by `release`
#   PR_GROUP_LOCK_TTL_SECONDS — a lock without a heartbeat for this long is taken over (default 2100)
#   PR_GROUP_TIME_LIMIT_SECONDS, PR_GROUP_MAX_PASSES — when `next` may review again here
#
# Outputs:
#   The group state (GitHub: hidden ref refs/xianix/pr-group/issue-<N>; Azure DevOps or
#   no ref permission: a state comment on the work item); one status line on stdout.
#   `next` with NEXT=again also rewrites $PRG_WS/discovery.json for the next pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PRG_WS="${PRG_WS:-/tmp/prg-ws}"

case "${1:-}" in
  acquire|heartbeat|release|next) ;;
  *) echo "Usage: group-lock.sh acquire | heartbeat | release | next" >&2; exit 2 ;;
esac

python3 "$SCRIPT_DIR/group_platform.py" lock "$1"
