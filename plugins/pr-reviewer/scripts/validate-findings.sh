#!/usr/bin/env bash
# validate-findings.sh — re-anchor / drop findings with bad line numbers.
#
# Why this exists as a real script: over-shot citations (e.g. :466 on a 322-line
# file) are the most common cause of silently dropped inline comments and dishonest
# summary bodies. Agents invent ad-hoc sed loops; this is the single check.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-findings.sh"
#   FINDINGS=/tmp/pr_inline_findings.jsonl bash …/validate-findings.sh
#
# Inputs:
#   /tmp/pr_inline_findings.jsonl  — one JSON object per line (file, line, body, fid, …)
#   /tmp/pr_full_diff_numbered.patch
#   /tmp/pr_state.env              — HEAD_SHA
#
# Outputs:
#   Rewrites the findings file in place (validated lines)
#   /tmp/pr_findings_validation.log — drops / corrections
#   Exit 0 even when some findings are dropped (log explains)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
[ -f ${PR_STATE_DIR:-/tmp}/pr_state.env ] && source ${PR_STATE_DIR:-/tmp}/pr_state.env

FINDINGS="${FINDINGS:-${PR_STATE_DIR:-/tmp}/pr_inline_findings.jsonl}"
NUMBERED="${NUMBERED:-${PR_STATE_DIR:-/tmp}/pr_full_diff_numbered.patch}"
HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"
LOG=${PR_STATE_DIR:-/tmp}/pr_findings_validation.log

if [ ! -f "$FINDINGS" ]; then
  echo "ERROR: findings file missing: $FINDINGS" >&2
  exit 1
fi
if [ ! -s "$FINDINGS" ]; then
  echo "No findings to validate (empty $FINDINGS)"
  : > "$LOG"
  exit 0
fi
if [ -z "${HEAD_SHA:-}" ]; then
  echo "ERROR: HEAD_SHA unset — run pr-setup.sh first" >&2
  exit 1
fi

python3 - "$FINDINGS" "$NUMBERED" "$HEAD_SHA" "$LOG" <<'PY'
import json, os, re, subprocess, sys, tempfile

findings_path, numbered_path, head_sha, log_path = sys.argv[1:5]
logs = []

# Build map: (file, snippet_prefix) -> lineno from numbered patch margins
# Also: file -> list of (lineno, text) for + and context lines
by_file = {}
if os.path.isfile(numbered_path):
    current_file = None
    with open(numbered_path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            # "      | diff --git a/foo b/foo" or "+++ b/foo"
            if "| diff --git " in line or "| +++ " in line:
                m = re.search(r"\b(?:b/)?([^\s]+)$", line.split("|", 1)[-1].strip())
                if m and not m.group(1).startswith("/dev/null"):
                    current_file = m.group(1)
                    if current_file.startswith("b/"):
                        current_file = current_file[2:]
                continue
            m = re.match(r"^\s*(\d+)\s*\|([ +])(.*)$", line)
            if m and current_file:
                ln = int(m.group(1))
                text = m.group(3)
                by_file.setdefault(current_file, []).append((ln, text))

def file_len(path):
    try:
        out = subprocess.check_output(
            ["git", "show", f"{head_sha}:{path}"],
            stderr=subprocess.DEVNULL,
        )
        return out.count(b"\n") + (0 if out.endswith(b"\n") or not out else 1)
    except Exception:
        return None

def line_at(path, nn):
    try:
        out = subprocess.check_output(
            ["git", "show", f"{head_sha}:{path}"],
            stderr=subprocess.DEVNULL,
        )
        lines = out.decode("utf-8", errors="replace").splitlines()
        if 1 <= nn <= len(lines):
            return lines[nn - 1]
    except Exception:
        pass
    return None

def reanchor(path, nn, body):
    """Return corrected line or None if unlocatable."""
    entries = by_file.get(path) or by_file.get(path.lstrip("./")) or []
    # Prefer exact margin match that still exists
    if nn and any(ln == nn for ln, _ in entries):
        fl = file_len(path)
        if fl is None or nn <= fl:
            return nn
    # Try to find a + line whose text appears in the body
    body_l = (body or "").lower()
    for ln, text in entries:
        snippet = text.strip()
        if len(snippet) >= 8 and snippet.lower() in body_l:
            fl = file_len(path)
            if fl is None or ln <= fl:
                return ln
    # Nearest numbered line in file ≤ file length
    fl = file_len(path)
    if fl is None:
        return None
    candidates = [ln for ln, _ in entries if ln <= fl]
    if not candidates:
        return None
    if nn and nn > 0:
        return min(candidates, key=lambda x: abs(x - nn))
    return candidates[0]

kept = []
corrected = 0
dropped = 0

with open(findings_path, encoding="utf-8", errors="replace") as f:
    for i, raw in enumerate(f, 1):
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError as e:
            logs.append(f"DROP line {i}: invalid JSON ({e})")
            dropped += 1
            continue
        path = (obj.get("file") or obj.get("path") or "").strip()
        try:
            nn = int(obj.get("line") or 0)
        except (TypeError, ValueError):
            nn = 0
        body = obj.get("body") or obj.get("issue") or ""
        if not path:
            logs.append(f"DROP line {i}: missing file")
            dropped += 1
            continue
        fl = file_len(path)
        content = line_at(path, nn) if nn > 0 else None
        ok = fl is not None and nn > 0 and nn <= fl
        # Soft content check: if we have content, don't require substring match
        if not ok:
            new_nn = reanchor(path, nn, body)
            if new_nn is None:
                logs.append(f"DROP {path}:{nn} — unlocatable in HEAD ({head_sha[:7]})")
                dropped += 1
                continue
            if new_nn != nn:
                logs.append(f"CORRECT {path}:{nn} -> {new_nn}")
                corrected += 1
                obj["line"] = new_nn
            else:
                obj["line"] = new_nn
        kept.append(obj)

out_fd, out_tmp = tempfile.mkstemp(prefix="pr_findings_", suffix=".jsonl")
os.close(out_fd)
with open(out_tmp, "w", encoding="utf-8") as out:
    for obj in kept:
        out.write(json.dumps(obj, ensure_ascii=False) + "\n")
os.replace(out_tmp, findings_path)

with open(log_path, "w", encoding="utf-8") as logf:
    logf.write(f"kept={len(kept)} corrected={corrected} dropped={dropped}\n")
    for line in logs:
        logf.write(line + "\n")

print(f"Validated findings: kept={len(kept)} corrected={corrected} dropped={dropped}")
print(f"Log: {log_path}")
PY
