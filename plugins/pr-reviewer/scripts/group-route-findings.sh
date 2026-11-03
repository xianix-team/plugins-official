#!/usr/bin/env bash
# group-route-findings.sh — split the lead's combined group findings into each
# member's own findings file (step G6).
#
# Why this exists as a real script: every downstream script (validate, assign-fids,
# reconcile, post) works on ONE PR's ${PR_STATE_DIR}/pr_inline_findings.jsonl. A
# finding routed to the wrong member would be anchored on a file that PR doesn't
# have and silently dropped — so routing is mechanical, and unknown members are
# reported instead of guessed.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-route-findings.sh"
#
# Inputs:
#   $PRG_ROOT/findings.jsonl     — one JSON object per finding, written by the lead:
#       member    (required) slug of the PR the finding is anchored on
#       file, line, body, severity (CRITICAL|WARNING|SUGGESTION)
#       category  (optional) cross-repo category, e.g. contract-drift
#       related   (optional) "<slug>:<path>:<line>" of the counterpart
#       suggestion_start_line / suggestion_end_line (optional, passed through)
#   $PRG_ROOT/group_state.json   — from group-setup.sh
#
# Outputs:
#   $PRG_ROOT/<slug>/pr_inline_findings.jsonl  — rewritten for every active member
#                                                (empty when it has no findings)
#   Prints per-member counts; lists findings dropped for an unknown/excluded member.

set -euo pipefail

PRG_ROOT="${PRG_ROOT:-/tmp/prg}"

python3 - "$PRG_ROOT" <<'PY'
import json, os, sys

root = sys.argv[1]
state = json.load(open(os.path.join(root, "group_state.json"), encoding="utf-8"))
active = {m["slug"]: m for m in state["members"] if m["status"] == "ok"}
src = os.path.join(root, "findings.jsonl")

routed = {slug: [] for slug in active}
dropped = []
if os.path.isfile(src):
    for n, raw in enumerate(open(src, encoding="utf-8"), 1):
        raw = raw.strip()
        if not raw:
            continue
        try:
            f = json.loads(raw)
        except json.JSONDecodeError as e:
            dropped.append(f"line {n}: not JSON ({e})")
            continue
        slug = str(f.get("member", "")).strip()
        if slug not in active:
            dropped.append(f"line {n}: member '{slug}' is not an active member")
            continue
        body = f.get("body") or f.get("comment") or ""
        category = f.get("category")
        related = f.get("related")
        if category and not body.startswith("🔗"):
            body = f"🔗 **Cross-repo ({category})** — " + body
        if related:
            other_slug, _, where = str(related).partition(":")
            other = next((m for m in state["members"] if m["slug"] == other_slug), None)
            ref = ""
            if other and other.get("pr_url"):
                ref = f" ({other['pr_url']})"
            elif other and other.get("pr_number"):
                ref = f" (PR #{other['pr_number']})"
            if "Related:" not in body:
                body = body.rstrip() + f"\n\nRelated: {other_slug}{ref} `{where}`"
        out = {k: v for k, v in f.items() if k not in ("member", "comment", "related")}
        out["body"] = body
        routed[slug].append(out)

for slug, items in routed.items():
    path = os.path.join(active[slug]["state_dir"], "pr_inline_findings.jsonl")
    with open(path, "w", encoding="utf-8") as fh:
        for item in items:
            fh.write(json.dumps(item, ensure_ascii=False) + "\n")
    cross = sum(1 for i in items if i.get("category"))
    print(f"  {slug:<20} {len(items)} finding(s) ({cross} cross-repo)")
for d in dropped:
    print(f"  DROPPED {d}")
PY
