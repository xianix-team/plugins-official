#!/usr/bin/env bash
# assign-fids.sh — fill missing fid fields on /tmp/pr_inline_findings.jsonl.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/assign-fids.sh"
#
# Run this AFTER validate-findings.sh (step 7 order matters: fid is derived
# from on-disk content at (file, line), so line numbers must already be
# corrected or the fid will be computed against the wrong snippet).
#
# Each finding needs fid = compute-fid(file, on-disk snippet, occurrence-index).
# The snippet is read directly from the repo at HEAD_SHA — not the LLM-authored
# issue sentence, which is regenerated per run and would make the fid unstable
# across re-reviews (see compute-fid.sh). Findings whose line can't be resolved
# on disk (deleted file, out-of-range line) fall back to the old file+issue
# formula and are logged, since they won't benefit from reconcile-prior-findings.sh's
# Gate B re-verification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
[ -f ${PR_STATE_DIR:-/tmp}/pr_state.env ] && source ${PR_STATE_DIR:-/tmp}/pr_state.env

FINDINGS="${FINDINGS:-${PR_STATE_DIR:-/tmp}/pr_inline_findings.jsonl}"
FID_SCRIPT="${SCRIPT_DIR}/compute-fid.sh"
HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"

[ -f "$FINDINGS" ] || { echo "ERROR: missing $FINDINGS" >&2; exit 1; }
[ -f "$FID_SCRIPT" ] || { echo "ERROR: missing $FID_SCRIPT" >&2; exit 1; }

if [ ! -s "$FINDINGS" ]; then
  echo "No findings — nothing to assign"
  exit 0
fi

python3 - "$FINDINGS" "$HEAD_SHA" <<'PY'
import hashlib, json, os, re, subprocess, sys, tempfile

path, head_sha = sys.argv[1:3]

def normalize(text):
    n = re.sub(r"[^a-z0-9 ]", " ", text.lower())
    return re.sub(r"\s+", " ", n).strip()

def compute_fid(file_path, snippet, occurrence):
    # Mirror compute-fid.sh normalisation exactly — a divergence here would
    # produce a fid that never matches what compute-fid.sh generates elsewhere.
    p = file_path.strip().lower()
    return hashlib.sha1(f"{p}|{normalize(snippet)}|{occurrence}".encode()).hexdigest()[:12]

def compute_fid_legacy(file_path, issue):
    # Fallback formula (file + issue text) for findings with no resolvable
    # on-disk line — same shape as the pre-snippet-based fid formula.
    p = file_path.strip().lower()
    return hashlib.sha1(f"{p}|{normalize(issue)}".encode()).hexdigest()[:12]

_file_lines_cache = {}
def file_lines(file_path):
    if file_path not in _file_lines_cache:
        try:
            out = subprocess.check_output(
                ["git", "show", f"{head_sha}:{file_path}"],
                stderr=subprocess.DEVNULL,
            ).decode("utf-8", errors="replace")
            _file_lines_cache[file_path] = out.splitlines()
        except subprocess.CalledProcessError:
            _file_lines_cache[file_path] = None
    return _file_lines_cache[file_path]

def issue_text(obj):
    issue = (obj.get("issue") or "").strip()
    if issue:
        return issue
    body = obj.get("body") or ""
    m = re.search(r"(?:\*\*Issue:\*\*|ISSUE:)\s*(.+)", body, re.I)
    if m:
        return m.group(1).strip().splitlines()[0]
    for bl in body.splitlines():
        bl = bl.strip()
        if bl and not bl.startswith("#") and not bl.startswith("```"):
            return bl.lstrip("-* ").strip()
    return ""

rows = []
with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

# First pass: resolve each fid-less finding's on-disk snippet (if any), so
# occurrence-index can be computed by grouping on (file, normalised snippet)
# before any fid is actually hashed.
pending = []  # indices into rows needing a fid
snippets = {}  # row index -> (file, normalised_snippet) or None
for i, obj in enumerate(rows):
    if obj.get("fid"):
        continue
    pending.append(i)
    file_path = (obj.get("file") or obj.get("path") or "").strip()
    try:
        line_no = int(obj.get("line") or 0)
    except (TypeError, ValueError):
        line_no = 0
    lines = file_lines(file_path) if file_path and head_sha else None
    if file_path and lines is not None and 1 <= line_no <= len(lines):
        snippets[i] = (file_path, normalize(lines[line_no - 1]))
    else:
        snippets[i] = None

occurrence_seen = {}  # (file, normalised_snippet) -> next occurrence index
# Assign occurrence indices in ascending line-number order for stability.
for i in sorted(pending, key=lambda i: (rows[i].get("file") or "", int(rows[i].get("line") or 0))):
    key = snippets.get(i)
    if key is None:
        continue
    occurrence_seen[key] = occurrence_seen.get(key, 0) + 1
    snippets[i] = (*key, occurrence_seen[key])

assigned = 0
legacy = 0
for i in pending:
    obj = rows[i]
    file_path = (obj.get("file") or obj.get("path") or "").strip()
    resolved = snippets.get(i)
    if resolved is not None:
        rfile, rsnippet, occurrence = resolved
        obj["fid"] = compute_fid(rfile, rsnippet, occurrence)
        assigned += 1
    else:
        issue = issue_text(obj)
        if file_path and issue:
            print(f"WARN: no on-disk line for {file_path}:{obj.get('line')} — using legacy file+issue fid (no Gate B coverage)", file=sys.stderr)
            obj["fid"] = compute_fid_legacy(file_path, issue)
            assigned += 1
            legacy += 1

fd, tmp = tempfile.mkstemp(prefix="pr_fid_", suffix=".jsonl")
os.close(fd)
with open(tmp, "w", encoding="utf-8") as out:
    for obj in rows:
        out.write(json.dumps(obj, ensure_ascii=False) + "\n")
os.replace(tmp, path)
print(f"Assigned fid on {assigned}/{len(rows)} findings ({legacy} via legacy fallback)")
PY
