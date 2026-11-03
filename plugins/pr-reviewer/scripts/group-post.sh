#!/usr/bin/env bash
# group-post.sh — validate, fingerprint, reconcile and post every member's review,
# each with the shared group section (step G8).
#
# Why this exists as a real script: posting is the single-PR chain
# (validate-findings → assign-fids → reconcile-prior-findings → gh/ado-post-review)
# run once per member in that member's worktree and PR_STATE_DIR, plus a group
# section that must be identical on every member except for the "this PR" marker.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/group-post.sh"
#
# Inputs (all written by the lead before this runs):
#   $PRG_ROOT/group_state.json               — from group-setup.sh
#   $PRG_ROOT/<slug>/pr_inline_findings.jsonl — from group-route-findings.sh
#   $PRG_ROOT/<slug>/pr_thread_body.md       — that member's own report (report-template)
#   $PRG_ROOT/<slug>/verdict                 — APPROVE | REQUEST CHANGES | NEEDS DISCUSSION
#   $PRG_ROOT/group_notes.md                 — optional: cross-repo findings summary and
#                                              "Suggested merge order (advisory)" sections
#   $PRG_ROOT/<slug>/pr_external_reconcile.json — optional, as for /pr-review
#   PR_REVIEWER_GROUP_FORCE                  — true = post on unchanged members too
#
# Outputs:
#   Posts per member (GitHub / Azure DevOps) or writes <worktree>/pr-review-report.md (generic).
#   $PRG_ROOT/post_results.tsv — slug, outcome, confirmation line
#   Prints one confirmation line per member and a group line. Exit 1 if every post failed.

set -uo pipefail  # not -e: one member failing to post must not stop the others

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRG_ROOT="${PRG_ROOT:-/tmp/prg}"
: "${PR_REVIEWER_GROUP_FORCE:=false}"

[ -f "$PRG_ROOT/group_state.json" ] || { echo "ERROR: $PRG_ROOT/group_state.json missing — run group-setup.sh first" >&2; exit 1; }

ACTIVE=$(python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
for m in s['members']:
    if m['status'] == 'ok':
        print('\x1f'.join([m['slug'], m['dir'], m['state_dir'], m['platform'] or 'generic',
                         'true' if m['unchanged_since_last_review'] else 'false']))
" "$PRG_ROOT/group_state.json")

# --- Pass 1: validate + fingerprint every member, so the group table counts the final set ---
while IFS=$'\x1f' read -r SLUG DIR STATE PLATFORM UNCHANGED; do
  [ -n "$SLUG" ] || continue
  [ -f "$STATE/pr_inline_findings.jsonl" ] || : > "$STATE/pr_inline_findings.jsonl"
  (
    cd "$DIR" || exit 1
    export PR_STATE_DIR="$STATE"
    bash "$SCRIPT_DIR/validate-findings.sh" >/dev/null
    bash "$SCRIPT_DIR/assign-fids.sh" >/dev/null
  ) || echo "WARN: $SLUG — validate/assign-fids failed; posting what is there" >&2
done <<< "$ACTIVE"


# --- Build the group section once (rows are marked "this PR" per member at post time) ---
python3 - "$PRG_ROOT" <<'PY'
import json, os, sys

root = sys.argv[1]
state = json.load(open(os.path.join(root, "group_state.json"), encoding="utf-8"))

def counts(state_dir):
    crit = warn = cross = 0
    path = os.path.join(state_dir, "pr_inline_findings.jsonl")
    if os.path.isfile(path):
        for raw in open(path, encoding="utf-8"):
            raw = raw.strip()
            if not raw:
                continue
            f = json.loads(raw)
            sev = str(f.get("severity", "")).upper()
            crit += sev == "CRITICAL"
            warn += sev == "WARNING"
            cross += bool(f.get("category"))
    return crit, warn, cross

def ref(m):
    if m.get("pr_url"):
        return f"[{m['slug']}]({m['pr_url']})" + (f" #{m['pr_number']}" if m.get("pr_number") else "")
    if m.get("pr_number"):
        return f"{m['slug']} #{m['pr_number']}"
    return f"{m['slug']} ({m.get('branch') or 'branch'})"

title, url = state.get("work-item-title") or "", state.get("work-item-url") or ""
if title and url:
    heading = f"## Group review · work item [{title}]({url}) ({len(state['members'])} PRs)"
elif url:
    heading = f"## Group review · {url} ({len(state['members'])} PRs)"
else:
    heading = f"## Group review · {len(state['members'])} related PRs"

rows = ["| PR | Verdict | Critical | Warnings | Cross-repo | Status |", "|---|---|---|---|---|---|"]
for m in state["members"]:
    if m["status"] != "ok":
        rows.append(f"| {ref(m)}{{{{THIS:{m['slug']}}}}} | — | — | — | — | not reviewed: {m['reason']} |")
        continue
    verdict_path = os.path.join(m["state_dir"], "verdict")
    verdict = open(verdict_path, encoding="utf-8").read().strip() if os.path.isfile(verdict_path) else "NEEDS DISCUSSION"
    crit, warn, cross = counts(m["state_dir"])
    status = f"reviewed @ `{m['head_sha'][:7]}`"
    if m["unchanged_since_last_review"]:
        status = f"no new commits since last review @ `{m['head_sha'][:7]}`"
    rows.append(f"| {ref(m)}{{{{THIS:{m['slug']}}}}} | {verdict} | {crit} | {warn} | {cross} | {status} |")

parts = [heading, ""] + rows + [""]
notes = os.path.join(root, "group_notes.md")
if os.path.isfile(notes):
    text = open(notes, encoding="utf-8").read().strip()
    if text:
        parts += [text, ""]
footer = "_Re-run with `@xianix review group` on any of these PRs."
if state.get("work-item-label"):
    footer += f" Group review is on because the work item has the `{state['work-item-label']}` label; remove it to switch group review off."
parts.append(footer + "_")
parts += ["", "<!-- xianix:group-section -->"]  # not a link to the work item (group_platform.py)
open(os.path.join(root, "group_section.md"), "w", encoding="utf-8").write("\n".join(parts) + "\n")
PY

# --- Pass 2: per member — compose body, reconcile, post ---
: > "$PRG_ROOT/post_results.tsv"
POSTED=0
FAILED=0
SKIPPED=0
while IFS=$'\x1f' read -r SLUG DIR STATE PLATFORM UNCHANGED; do
  [ -n "$SLUG" ] || continue

  if [ "$UNCHANGED" = "true" ] && [ "$PR_REVIEWER_GROUP_FORCE" != "true" ] && [ ! -s "$STATE/pr_inline_findings.jsonl" ]; then
    echo "$SLUG: unchanged since last review and no new findings — previous review stands, nothing posted"
    printf '%s\tskipped\tunchanged\n' "$SLUG" >> "$PRG_ROOT/post_results.tsv"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Keep the lead's own body as the base so a re-run never stacks group sections.
  [ -f "$STATE/pr_thread_body.base.md" ] || cp "$STATE/pr_thread_body.md" "$STATE/pr_thread_body.base.md" 2>/dev/null || {
    echo "WARN: $SLUG — no pr_thread_body.md written by the lead; posting the group section only" >&2
    : > "$STATE/pr_thread_body.base.md"
  }
  python3 - "$PRG_ROOT/group_section.md" "$STATE/pr_thread_body.base.md" "$STATE/pr_thread_body.md" "$SLUG" <<'PY'
import re, sys
section_path, base_path, out_path, slug = sys.argv[1:5]
section = open(section_path, encoding="utf-8").read()
section = re.sub(r"\{\{THIS:([^}]+)\}\}", lambda m: " **(this PR)**" if m.group(1) == slug else "", section)
base = open(base_path, encoding="utf-8").read().rstrip()
open(out_path, "w", encoding="utf-8").write((base + "\n\n---\n\n" if base else "") + section)
PY

  VERDICT=$(cat "$STATE/verdict" 2>/dev/null || echo "NEEDS DISCUSSION")
  RESULT=$(
    cd "$DIR" || exit 1
    export PR_STATE_DIR="$STATE"
    bash "$SCRIPT_DIR/reconcile-prior-findings.sh" >/dev/null 2>"$STATE/reconcile.err" \
      || echo "WARN: $SLUG — reconcile failed; see $STATE/reconcile.err" >&2
    # shellcheck disable=SC1091
    source "$STATE/pr_state.env"
    case "$PLATFORM" in
      github)
        VERDICT="$VERDICT" REVIEW_MODE="${REVIEW_MODE:-initial}" bash "$SCRIPT_DIR/gh-post-review.sh" 2>>"$STATE/post.err" | tail -3 ;;
      azure)
        VERDICT="$VERDICT" REVIEW_MODE="${REVIEW_MODE:-initial}" bash "$SCRIPT_DIR/ado-post-review.sh" 2>>"$STATE/post.err" | tail -3 ;;
      *)
        python3 - "$STATE" "$DIR/pr-review-report.md" <<'PY'
import json, os, sys
state, out = sys.argv[1:3]
body = open(os.path.join(state, "pr_thread_body.md"), encoding="utf-8").read().rstrip()
lines = [body, "", "## Inline findings", ""]
path = os.path.join(state, "pr_inline_findings.jsonl")
items = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()] if os.path.isfile(path) else []
for f in items:
    lines += [f"### `{f.get('file')}:{f.get('line')}` — {f.get('severity', '')}", "", f.get("body", ""), ""]
if not items:
    lines.append("_No inline findings._")
open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
        echo "Review complete: ${VERDICT} — report written to $DIR/pr-review-report.md" ;;
    esac
  )
  RC=$?
  LAST=$(printf '%s\n' "$RESULT" | grep -E '^(Review|Re-review) ' | tail -1)
  if [ $RC -eq 0 ] && [ -n "$LAST" ]; then
    echo "$SLUG: $LAST"
    printf '%s\tposted\t%s\n' "$SLUG" "$LAST" >> "$PRG_ROOT/post_results.tsv"
    POSTED=$((POSTED + 1))
  else
    echo "$SLUG: POST FAILED (exit $RC) — see $STATE/post.err"
    printf '%s\tfailed\t%s\n' "$SLUG" "exit $RC" >> "$PRG_ROOT/post_results.tsv"
    FAILED=$((FAILED + 1))
  fi
done <<< "$ACTIVE"

echo "Group review: ${POSTED} posted, ${SKIPPED} unchanged, ${FAILED} failed"
[ "$POSTED" -gt 0 ] || [ "$FAILED" -eq 0 ]
