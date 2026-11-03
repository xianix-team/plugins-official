#!/usr/bin/env bash
# reconcile-prior-findings.sh — classify current vs prior findings by fid (step 7).
#
# Why this exists as a real script: fid set-ops are deterministic; agents invent
# incomplete buckets or re-post carried-over findings as duplicates.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/reconcile-prior-findings.sh"
#
# Inputs:
#   /tmp/pr_inline_findings.jsonl   — current findings (must include fid)
#   /tmp/pr_prior_findings.jsonl    — from detect-review-mode / *-detect-prior
#   /tmp/pr_state.env               — REVIEW_MODE, HEAD_SHA, RANGE_BASE
#   /tmp/pr_prior.env               — PRIOR_SUMMARY_SHA (Gate A)
#   /tmp/pr_open_threads.jsonl      — optional; for line±5 dedup
#
# Outputs:
#   /tmp/pr_reconcile.json          — {fixed, carried_over, reopened, new}
#   Rewrites /tmp/pr_inline_findings.jsonl to only the New bucket (re-review)
#   Dedup may also drop findings overlapping open threads (DEDUP_SUPPRESSED)
#   Prints summary counts; appends RECONCILE_* to /tmp/pr_state.env
#
# A prior "open" finding only moves to `fixed` after passing two gates:
#   Gate A — HEAD_SHA must differ from PRIOR_SUMMARY_SHA (the sha the prior
#            review was posted against). Same sha means no commit could
#            possibly have fixed anything; force it to `carried_over` instead.
#            A re-trigger with zero new commits still runs a full re-review
#            (finder sub-agents are non-deterministic — a second pass over the
#            same diff can catch something the first pass missed), so this
#            gate is the normal, load-bearing path on every same-sha run, not
#            an edge case.
#   Gate B — recompute fids for every line currently in the flagged file at
#            HEAD_SHA (same formula as compute-fid.sh/assign-fids.sh) and
#            confirm this fid is NOT among them. If it still reproduces
#            somewhere in the file, this run's finder simply missed it —
#            that is not evidence the underlying code changed.
# A prior "resolved" finding whose fid reappears in the current scan is a
# regression: bucketed `reopened`, not silently dropped (that used to be an
# actual bug — checking resolved-status before fid-presence caused these to
# vanish from the reconcile output entirely with no comment ever posted).
#
# Note: external-thread "addressed vs still_open" judgment stays with the agent
# (needs reading code). This script only does fid buckets + line±5 dedup.

set -euo pipefail

# shellcheck disable=SC1091
[ -f ${PR_STATE_DIR:-/tmp}/pr_state.env ] && source ${PR_STATE_DIR:-/tmp}/pr_state.env
# shellcheck disable=SC1091
[ -f ${PR_STATE_DIR:-/tmp}/pr_prior.env ] && source ${PR_STATE_DIR:-/tmp}/pr_prior.env

CURRENT="${CURRENT:-${PR_STATE_DIR:-/tmp}/pr_inline_findings.jsonl}"
PRIOR="${PRIOR:-${PR_STATE_DIR:-/tmp}/pr_prior_findings.jsonl}"
OPEN="${OPEN:-${PR_STATE_DIR:-/tmp}/pr_open_threads.jsonl}"
OUT="${OUT:-${PR_STATE_DIR:-/tmp}/pr_reconcile.json}"
REVIEW_MODE="${REVIEW_MODE:-initial}"
HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"
RANGE_BASE="${RANGE_BASE:-}"
PRIOR_SUMMARY_SHA="${PRIOR_SUMMARY_SHA:-}"

[ -f "$CURRENT" ] || { echo "ERROR: missing $CURRENT" >&2; exit 1; }
[ -f "$PRIOR" ] || : > "$PRIOR"
[ -f "$OPEN" ] || : > "$OPEN"

python3 - "$CURRENT" "$PRIOR" "$OPEN" "$OUT" "$REVIEW_MODE" "${HEAD_SHA:-}" "${RANGE_BASE:-}" "${PRIOR_SUMMARY_SHA:-}" <<'PY'
import hashlib, json, os, re, subprocess, sys, tempfile

current_path, prior_path, open_path, out_path, mode, head_sha, range_base, prior_summary_sha = sys.argv[1:9]

def normalize(text):
    n = re.sub(r"[^a-z0-9 ]", " ", text.lower())
    return re.sub(r"\s+", " ", n).strip()

_file_fid_cache = {}
def fids_for_file(path):
    # Gate B: recompute the current fid for every line in `path` at HEAD_SHA.
    # Mirror compute-fid.sh / assign-fids.sh's formula and occurrence-grouping
    # exactly — a divergence here would make Gate B pass/fail on the wrong basis.
    if path in _file_fid_cache:
        return _file_fid_cache[path]
    try:
        text = subprocess.check_output(
            ["git", "show", f"{head_sha}:{path}"], stderr=subprocess.DEVNULL
        ).decode("utf-8", errors="replace")
    except subprocess.CalledProcessError:
        _file_fid_cache[path] = set()
        return _file_fid_cache[path]
    p = path.strip().lower()
    occurrence_seen = {}
    fids = set()
    for raw_line in text.splitlines():
        norm = normalize(raw_line)
        occurrence_seen[norm] = occurrence_seen.get(norm, 0) + 1
        fids.add(hashlib.sha1(f"{p}|{norm}|{occurrence_seen[norm]}".encode()).hexdigest()[:12])
    _file_fid_cache[path] = fids
    return fids

# Gate A only blocks when we can positively confirm HEAD hasn't moved since
# the prior review — an unknown PRIOR_SUMMARY_SHA can't prove sameness, so it
# doesn't block (there is simply nothing to gate on). This is the everyday
# case for a same-sha re-trigger, not a rare fallback: those runs are always
# reviewed in full now (see commands/pr-review.md), and this is what stops a
# same-sha rescan from ever marking something "fixed" just because this run's
# finder happened not to re-notice it.
gate_a_blocks = bool(head_sha) and bool(prior_summary_sha) and head_sha == prior_summary_sha

def load_jsonl(path):
    rows = []
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return rows
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows

current = load_jsonl(current_path)
prior = load_jsonl(prior_path)
open_threads = load_jsonl(open_path)

# Enrich prior rows missing file/line from open_threads (same thread_ref)
threads_by_ref = {}
for t in open_threads:
    ref = t.get("thread_ref") or t.get("thread_id")
    if ref is not None:
        threads_by_ref[ref] = t
for p in prior:
    if p.get("file") or p.get("path"):
        continue
    ref = p.get("thread_ref") or p.get("thread_id")
    t = threads_by_ref.get(ref) if ref is not None else None
    if t:
        p["file"] = t.get("file") or t.get("path") or ""
        if p.get("line") is None:
            p["line"] = t.get("line")

current_by_fid = {}
for c in current:
    fid = c.get("fid")
    if fid:
        current_by_fid[fid] = c

prior_by_fid = {}
for p in prior:
    fid = p.get("fid")
    if not fid:
        continue
    # Skip already-resolved prior findings for the Fixed bucket
    status = (p.get("status") or p.get("thread_status") or "open").lower()
    prior_by_fid[fid] = {**p, "_status": status}

RESOLVED_STATUSES = ("resolved", "fixed", "wontfix", "closed")
fixed, carried, reopened, new = [], [], [], []

if mode == "rereview" and prior_by_fid:
    for fid, p in prior_by_fid.items():
        entry = {
            "fid": fid,
            "file": p.get("file") or p.get("path"),
            "line": p.get("line"),
            "thread_ref": p.get("thread_ref") or p.get("thread_id") or p.get("node_id"),
            "comment_ref": p.get("comment_ref") or p.get("comment_id") or p.get("id"),
        }
        resolved_status = p.get("_status") in RESOLVED_STATUSES
        # Check fid-presence BEFORE resolved-status: a resolved finding whose
        # fid reappears is a regression (reopened), not something to silently
        # drop — see the header comment above for the bug this precedence fixes.
        if fid in current_by_fid:
            if resolved_status:
                reopened.append(entry)
            else:
                carried.append(entry)
            continue
        if resolved_status:
            continue  # genuinely resolved and gone — nothing to do
        pfile = (p.get("file") or p.get("path") or "").strip()
        if gate_a_blocks or not pfile or fid in fids_for_file(pfile):
            # Gate A: same-sha re-trigger, nothing could have changed.
            # No file: nothing to verify Gate B against — don't guess fixed.
            # Gate B: fid still reproduces somewhere in the file — the finder
            # simply missed it this pass, not evidence the code changed.
            carried.append(entry)
        else:
            fixed.append(entry)
    for fid, c in current_by_fid.items():
        if fid not in prior_by_fid:
            new.append(c)
    # Current findings without fid — treat as new
    for c in current:
        if not c.get("fid"):
            new.append(c)
else:
    # initial mode: everything is new
    new = list(current)
    carried = []
    fixed = []
    reopened = []

# Dedup new findings against open threads (file + line±5)
dedup_suppressed = 0
surviving = []
for c in new:
    cfile = (c.get("file") or c.get("path") or "").strip()
    try:
        cline = int(c.get("line") or 0)
    except (TypeError, ValueError):
        cline = 0
    overlap = False
    for t in open_threads:
        tfile = (t.get("file") or t.get("path") or "").strip()
        if not cfile or not tfile or cfile != tfile:
            continue
        try:
            tline = int(t.get("line") or 0)
        except (TypeError, ValueError):
            tline = 0
        if cline and tline and abs(cline - tline) <= 5:
            # In rereview, carried-over plugin threads are already excluded from new;
            # still suppress duplicates against any open thread.
            overlap = True
            break
    if overlap:
        dedup_suppressed += 1
        continue
    surviving.append(c)

new = surviving

report = {
    "fixed": fixed,
    "carried_over": carried,
    "reopened": reopened,
    "new": [
        {
            "fid": n.get("fid"),
            "file": n.get("file") or n.get("path"),
            "line": n.get("line"),
        }
        for n in new
    ],
    "dedup_suppressed": dedup_suppressed,
    "review_mode": mode,
    "head_sha": head_sha,
    "range_base": range_base,
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2)
    f.write("\n")

# In re-review, rewrite findings JSONL to New bucket only (what posting should send)
if mode == "rereview":
    fd, tmp = tempfile.mkstemp(prefix="pr_new_", suffix=".jsonl")
    os.close(fd)
    with open(tmp, "w", encoding="utf-8") as out:
        for n in new:
            out.write(json.dumps(n, ensure_ascii=False) + "\n")
    os.replace(tmp, current_path)

print(
    f"Reconcile ({mode}): fixed={len(fixed)} carried_over={len(carried)} "
    f"reopened={len(reopened)} new={len(new)} dedup_suppressed={dedup_suppressed}"
)
print(f"Wrote {out_path}")

# Emit shell-friendly counts on last lines for the wrapper
print(f"FIXED_COUNT={len(fixed)}")
print(f"CARRIED_COUNT={len(carried)}")
print(f"REOPENED_COUNT={len(reopened)}")
print(f"NEW_COUNT={len(new)}")
print(f"DEDUP_SUPPRESSED={dedup_suppressed}")
PY

FIXED_COUNT=$(python3 -c "import json; d=json.load(open('$OUT')); print(len(d.get('fixed',[])))")
CARRIED_COUNT=$(python3 -c "import json; d=json.load(open('$OUT')); print(len(d.get('carried_over',[])))")
REOPENED_COUNT=$(python3 -c "import json; d=json.load(open('$OUT')); print(len(d.get('reopened',[])))")
NEW_COUNT=$(python3 -c "import json; d=json.load(open('$OUT')); print(len(d.get('new',[])))")
DEDUP_SUPPRESSED=$(python3 -c "import json; d=json.load(open('$OUT')); print(d.get('dedup_suppressed',0))")

{
  echo "export FIXED_COUNT=$(printf %q "$FIXED_COUNT")"
  echo "export CARRIED_COUNT=$(printf %q "$CARRIED_COUNT")"
  echo "export REOPENED_COUNT=$(printf %q "$REOPENED_COUNT")"
  echo "export NEW_COUNT=$(printf %q "$NEW_COUNT")"
  echo "export DEDUP_SUPPRESSED=$(printf %q "$DEDUP_SUPPRESSED")"
} >> ${PR_STATE_DIR:-/tmp}/pr_state.env

# Optional re-review delta stub for the report body
if [ "$REVIEW_MODE" = "rereview" ]; then
  COMMIT_COUNT=0
  if [ -n "${RANGE_BASE:-}" ] && [ -n "${HEAD_SHA:-}" ]; then
    COMMIT_COUNT=$(git rev-list --count "${RANGE_BASE}..${HEAD_SHA}" 2>/dev/null || echo 0)
  fi
  if [ "$COMMIT_COUNT" -eq 0 ]; then
    # Same-sha re-trigger: still a full re-review (not a no-op), since finder
    # sub-agents are non-deterministic and a second pass can catch something
    # the first pass missed — make that explicit rather than printing a
    # confusing "0 new commits" line with no explanation.
    DELTA_HEADLINE="Re-scanned \`${HEAD_SHA}\` (no new commits) — re-analysis can surface findings an earlier pass missed."
  else
    DELTA_HEADLINE="Reviewed ${COMMIT_COUNT} new commit(s) since the last review (\`${RANGE_BASE}\`..\`${HEAD_SHA}\`)."
  fi
  cat > ${PR_STATE_DIR:-/tmp}/pr_rereview_delta.md <<EOF
### Re-review delta
${DELTA_HEADLINE}
- ✅ Fixed: ${FIXED_COUNT} previously-flagged issue(s) resolved
- ⏳ Still open: ${CARRIED_COUNT} carried-over issue(s)
- 🆕 New: ${NEW_COUNT} issue(s) introduced since the last review
EOF
  # Regression signal — only ever shown when non-zero, never clutters an
  # ordinary re-review with a zero-count line.
  if [ "${REOPENED_COUNT:-0}" -gt 0 ]; then
    echo "- 🔴 Reopened: ${REOPENED_COUNT} previously-fixed issue(s) still reproduce — regression" >> ${PR_STATE_DIR:-/tmp}/pr_rereview_delta.md
  fi
  echo "Wrote ${PR_STATE_DIR:-/tmp}/pr_rereview_delta.md"
fi

exit 0
