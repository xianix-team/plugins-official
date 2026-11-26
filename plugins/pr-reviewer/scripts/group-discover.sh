#!/usr/bin/env bash
# group-discover.sh — find the review group and tell its member PRs (step D1).
#
# Why this exists as a real script: everything that decides *whether* a group review
# runs — the work item, its label, the linked open PRs, the quiet period — is plain API
# work. Running it as a script costs no model tokens and is the same on every run.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-discover.sh" --work-item <owner/repo#N | ADO work item URL>
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-discover.sh" --pr <N> [--repo URL] [--force]   # default: the current repo
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-discover.sh" --from-event   # the agent's webhook event (XIANIX_INPUTS)
#
# Inputs:
#   GITHUB_TOKEN / AZURE_DEVOPS_TOKEN
#   PR_GROUP_SETTLE_SECONDS     — wait until the newest push in the group is this old (default 0;
#                                 with --from-event, 180 for PR events unless this is set)
#   PR_GROUP_SETTLE_MAX_SECONDS — never wait longer than this in total (default 300)
#   PR_GROUP_SINGLE_WAIT_MAX_SECONDS — Azure DevOps: longest wait for running single-PR reviews (default 900)
#   PR_GROUP_SINGLE_POLL_SECONDS     — how often to look again while waiting (default 30)
#   PR_GROUP_*                  — see group_platform.py (label name, member cap, owners)
#   PRG_WS                      — work folder (default /tmp/prg-ws)
#
# Outputs:
#   $PRG_WS/discovery.json, $PRG_WS/run.env
#   Prints STATUS=group | not-labelled | too-small | no-work-item | skipped (--from-event:
#   not a group event, with REASON=), TRIGGER_MEMBER (with
#   --pr), the member list and a NOTES line. Exit 0 in every case except an error.
#   Azure DevOps reviews every active PR on its own (/pr-review) when it is created or pushed.
#   If those reviews are still running when the group is found, this waits for them (posting
#   nothing — no group notes this run) and prints SINGLE_WAITED=<seconds>; their results then
#   count as the members' reviews and the group run only adds the cross-repo check.
#   A PR that is in no labelled group stops here, before any waiting — so it is cheap
#   for the push rule to start this on every PR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PRG_WS="${PRG_WS:-/tmp/prg-ws}"
SETTLE="${PR_GROUP_SETTLE_SECONDS:-0}"
SETTLE_MAX="${PR_GROUP_SETTLE_MAX_SECONDS:-300}"
mkdir -p "$PRG_WS"

# One agent rule per platform sends every group-related event here; the event decides the mode.
if [ "${1:-}" = "--from-event" ]; then
  EVENT=$(python3 "$SCRIPT_DIR/group_platform.py" event)
  SKIP=$(printf '%s\n' "$EVENT" | sed -n 's/^EVENT_SKIP=//p')
  if [ -n "$SKIP" ]; then
    echo "STATUS=skipped"
    echo "REASON=$SKIP"
    exit 0
  fi
  mapfile -t EVENT_ARGS < <(printf '%s\n' "$EVENT" | sed -n 's/^EVENT_ARG=//p')
  [ -n "${PR_GROUP_SETTLE_SECONDS:-}" ] || SETTLE=$(printf '%s\n' "$EVENT" | sed -n 's/^EVENT_SETTLE=//p')
  echo "Event → ${EVENT_ARGS[*]} (quiet period ${SETTLE}s)" >&2
  set -- "${EVENT_ARGS[@]}"
fi

case " $* " in *" --force "*) SETTLE=0 ;; esac

WAITED=0
while :; do
  OUT=$(python3 "$SCRIPT_DIR/group_platform.py" discover "$@")
  STATUS=$(printf '%s\n' "$OUT" | sed -n 's/^STATUS=//p')
  AGE=$(printf '%s\n' "$OUT" | sed -n 's/^NEWEST_PUSH_AGE=//p')
  # Quiet period: members are often pushed minutes apart. Wait (no tokens spent) until
  # the newest push is SETTLE seconds old, then look again — the group may have changed.
  if [ "$STATUS" = "group" ] && [ "$SETTLE" -gt 0 ] && [ "${AGE:-999999}" -lt "$SETTLE" ] && [ "$WAITED" -lt "$SETTLE_MAX" ]; then
    WAIT=$(( SETTLE - AGE ))
    [ $(( WAITED + WAIT )) -gt "$SETTLE_MAX" ] && WAIT=$(( SETTLE_MAX - WAITED ))
    echo "Newest push is ${AGE}s old — waiting ${WAIT}s for the group to settle" >&2
    sleep "$WAIT"
    WAITED=$(( WAITED + WAIT ))
    continue
  fi
  break
done

# Azure DevOps: wait (no tokens, nothing posted) while single-PR reviews of the members still run.
SINGLE_WAITED=0
if [ "$STATUS" = "group" ] && [ "$(printf '%s\n' "$OUT" | sed -n 's/^PLATFORM=//p')" = "azure" ]; then
  SINGLE_MAX="${PR_GROUP_SINGLE_WAIT_MAX_SECONDS:-900}"
  SINGLE_POLL="${PR_GROUP_SINGLE_POLL_SECONDS:-30}"
  while :; do
    SR=$(python3 "$SCRIPT_DIR/group_platform.py" single-reviews)
    RUNNING=$(printf '%s\n' "$SR" | sed -n 's/^SINGLE_REVIEWS_RUNNING=//p')
    [ "${RUNNING:-0}" -gt 0 ] || break
    if [ "$SINGLE_WAITED" -ge "$SINGLE_MAX" ]; then
      echo "WARN: single-PR reviews still running after ${SINGLE_WAITED}s ($(printf '%s\n' "$SR" | sed -n 's/^SINGLE_REVIEWS=//p')) — continuing" >&2
      break
    fi
    echo "Single-PR reviews still running: $(printf '%s\n' "$SR" | sed -n 's/^SINGLE_REVIEWS=//p') — waiting ${SINGLE_POLL}s" >&2
    sleep "$SINGLE_POLL"
    SINGLE_WAITED=$(( SINGLE_WAITED + SINGLE_POLL ))
  done
  # Their summaries are now on the PRs; read the group again (a PR may have closed meanwhile).
  [ "$SINGLE_WAITED" -gt 0 ] && OUT=$(python3 "$SCRIPT_DIR/group_platform.py" discover "$@")
fi

printf '%s\n' "$OUT"
echo "SINGLE_WAITED=$SINGLE_WAITED"
if [ "$SINGLE_WAITED" -gt 0 ]; then
  echo "NOTES skipped (waited for single-PR reviews; nothing is posted until the group result)"
else
  python3 "$SCRIPT_DIR/group_platform.py" announce
fi
