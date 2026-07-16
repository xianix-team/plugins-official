#!/usr/bin/env bash
# ado-post-review.sh — post vote + summary thread + inline findings to Azure DevOps.
#
# Uses deterministic state-based approach:
# - Reads canonical REVIEW_MODE from /tmp/pr_review_state.json (written by command)
# - Does NOT make independent mode decisions (prevents duplicates)
# - Validates all required state before proceeding
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ado-post-review.sh"
#
# Inputs (all required):
#   /tmp/pr_review_state.json          — canonical mode decision (written by command step 3)
#   /tmp/pr_azure.env                  — from starting-comment / parse step (API_BASE, AZURE_REPO, PR_ID, …)
#   /tmp/pr_thread_body.md             — compiled report (fallback: /tmp/pr_review_summary.md)
#   /tmp/pr_inline_findings.jsonl      — one JSON object per finding (fallback: /tmp/pr_findings.jsonl)
#   /tmp/pr_review_reconcile_state.json — (in re-review mode) finding buckets from step 7
#   VERDICT                            — env var ("REQUEST CHANGES" etc.)
#   AZURE_DEVOPS_TOKEN                 — required

set -euo pipefail

: "${VERDICT:=NEEDS DISCUSSION}"

# --- 0. Load state management library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/state.sh"

# --- 1. Validate and load review state ---
if [ ! -f /tmp/pr_review_state.json ]; then
  echo "ERROR: /tmp/pr_review_state.json missing" >&2
  echo "  The command should write this in step 3 after detecting prior review" >&2
  exit 1
fi

echo "Loading canonical review state..."
eval "$(read_review_state)"

echo "Review mode: ${REVIEW_MODE}"
echo "Head SHA: ${REVIEW_HEAD_SHA:0:8}"
if [ -n "$REVIEW_PRIOR_SHA" ]; then
  echo "Prior SHA: ${REVIEW_PRIOR_SHA:0:8}"
fi

# --- 2. Validate token and load API config ---
if [ -z "${AZURE_DEVOPS_TOKEN:-}" ]; then
  echo "ERROR: AZURE_DEVOPS_TOKEN unset — cannot post review" >&2
  exit 1
fi

if [ ! -f /tmp/pr_azure.env ]; then
  echo "ERROR: /tmp/pr_azure.env missing — run starting-comment step first" >&2
  exit 1
fi
# shellcheck disable=SC1091
source /tmp/pr_azure.env

PR_ID="${PR_ID:-${PR_NUMBER:-}}"
[ -n "$PR_ID" ] && [ -n "${API_BASE:-}" ] && [ -n "${AZURE_REPO:-}" ] || {
  echo "ERROR: PR_ID, API_BASE, or AZURE_REPO not in /tmp/pr_azure.env" >&2
  exit 1
}

echo "Posting to ${API_BASE}/_git/${AZURE_REPO}/pullrequest/${PR_ID}"

# --- 3. Normalize input files ---
if [ ! -f /tmp/pr_thread_body.md ] && [ -f /tmp/pr_review_summary.md ]; then
  cp /tmp/pr_review_summary.md /tmp/pr_thread_body.md
fi
if [ ! -f /tmp/pr_inline_findings.jsonl ] && [ -f /tmp/pr_findings.jsonl ]; then
  cp /tmp/pr_findings.jsonl /tmp/pr_inline_findings.jsonl
fi
[ -f /tmp/pr_thread_body.md ] || { echo "ERROR: /tmp/pr_thread_body.md missing" >&2; exit 1; }
touch /tmp/pr_inline_findings.jsonl

# Normalize findings to JSONL format
python3 - <<'PY'
import json
from pathlib import Path
src = Path('/tmp/pr_inline_findings.jsonl')
text = src.read_text().strip()
findings = []
if text:
    try:
        data = json.loads(text)
        if isinstance(data, list):
            findings = data
        elif isinstance(data, dict):
            findings = [data]
    except json.JSONDecodeError:
        dec = json.JSONDecoder()
        i = 0
        while i < len(text):
            while i < len(text) and text[i].isspace():
                i += 1
            if i >= len(text):
                break
            obj, end = dec.raw_decode(text, i)
            findings.append(obj)
            i = end
with Path('/tmp/pr_inline_findings.jsonl').open('w') as f:
    for item in findings:
        f.write(json.dumps(item) + '\n')
print(f"Normalized {len(findings)} finding(s)")
PY

# --- 4. Map verdict → vote ---
case "${VERDICT}" in
  waitForAuthor|Waiting*|"WAITING FOR AUTHOR") VERDICT="REQUEST CHANGES" ;;
  Rejected|REJECT|"REQUEST_CHANGES"|"CHANGES REQUESTED") VERDICT="REQUEST CHANGES" ;;
  Approved|APPROVED|LGTM) VERDICT="APPROVE" ;;
  COMMENT) VERDICT="NEEDS DISCUSSION" ;;
esac
case "${PR_REVIEWER_BLOCK_ON_CRITICAL:-false}" in
  true|True|TRUE|1|yes|Yes|YES) BLOCK_ON_CRITICAL=true ;;
  *)                              BLOCK_ON_CRITICAL=false ;;
esac
case "${VERDICT}" in
  "APPROVE")                     VOTE=10  ;;
  "APPROVE WITH SUGGESTIONS")    VOTE=5   ;;
  "REQUEST CHANGES")
    if [ "$BLOCK_ON_CRITICAL" = "true" ]; then VOTE=-10; else VOTE=-5; fi
    ;;
  "NEEDS DISCUSSION")            VOTE=-5  ;;
  *)                             echo "WARN: unknown verdict '${VERDICT}' — defaulting to -5" >&2; VOTE=-5 ;;
esac

# --- 5. Cast vote (never abort posting on vote failure) ---
REVIEWER_ID=""
if [ -n "${AZURE_ORG:-}" ]; then
  REVIEWER_ID=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
    "https://dev.azure.com/${AZURE_ORG}/_apis/connectionData?api-version=7.1-preview.1" \
    | python3 -c "import sys,json
try:
  d=json.load(sys.stdin)
  print((d.get('authenticatedUser') or d.get('authorizedUser') or {}).get('id',''))
except Exception:
  print('')" 2>/dev/null || true)
fi
if [ -z "$REVIEWER_ID" ]; then
  REVIEWER_ID=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
    "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1" \
    | python3 -c "import sys,json
try:
  print(json.load(sys.stdin).get('id',''))
except Exception:
  print('')" 2>/dev/null || true)
fi
if [ -z "$REVIEWER_ID" ]; then
  echo "WARN: could not resolve reviewer ID — vote will not be cast; continuing with summary + inline" >&2
else
  VOTE_BODY=$(printf '{"vote": %s, "id": "%s"}' "$VOTE" "$REVIEWER_ID")
  VOTE_RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" -u ":${AZURE_DEVOPS_TOKEN}" -X PUT \
    -d "$VOTE_BODY" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/reviewers/${REVIEWER_ID}?api-version=7.1" \
    || true)
  VOTE_STATUS=$(echo "$VOTE_RESP" | sed -n 's/^HTTP_STATUS://p')
  if ! echo "${VOTE_STATUS:-}" | grep -qE '^2'; then
    ADD_RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
      -H "Content-Type: application/json" -u ":${AZURE_DEVOPS_TOKEN}" -X POST \
      -d "[${VOTE_BODY}]" \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/reviewers?api-version=7.1" \
      || true)
    ADD_STATUS=$(echo "$ADD_RESP" | sed -n 's/^HTTP_STATUS://p')
    if echo "${ADD_STATUS:-}" | grep -qE '^2'; then
      echo "Vote ${VOTE} cast via reviewer add (HTTP $ADD_STATUS)"
    else
      echo "WARN: vote failed PUT HTTP ${VOTE_STATUS:-?} and POST HTTP ${ADD_STATUS:-?} — continuing" >&2
    fi
  else
    echo "Vote ${VOTE} cast (HTTP $VOTE_STATUS)"
  fi
fi

# --- 6. Post summary thread (with deduplication) ---
echo ""
echo "=== Posting Summary ==="

HEAD_SHA="$REVIEW_HEAD_SHA"
export HEAD_SHA

# Check if a summary already exists for this HEAD_SHA to prevent duplicate posts
EXISTING_SUMMARY_THREAD=""
if [ -f /tmp/pr_threads.json ]; then
  EXISTING_SUMMARY_THREAD=$(python3 - "$HEAD_SHA" <<'PY'
import json, re, sys
target_sha = sys.argv[1] if len(sys.argv) > 1 else ""
try:
  data = json.load(open("/tmp/pr_threads.json"))
  for t in data.get("value", []):
    comments = t.get("comments") or []
    if not comments:
      continue
    first = comments[0]
    props = t.get("properties") or {}

    # Check property-based marker
    sha = None
    if isinstance(props.get("pr-reviewer.sha"), dict):
      sha = props["pr-reviewer.sha"].get("$value")
    elif "pr-reviewer.sha" in props:
      sha = props["pr-reviewer.sha"]

    # Check body marker if properties weren't found
    if not sha:
      body = first.get("content") or ""
      m = re.search(r"<!--\s*pr-reviewer:v1.2\s+kind=summary\s+sha=([0-9a-fA-F]+)", body)
      if not m:
        m = re.search(r"<!--\s*pr-reviewer:v1\s+kind=summary\s+sha=([0-9a-fA-F]+)", body)
      if m:
        sha = m.group(1)

    if sha == target_sha:
      print(str(t.get("id", "")))
      break
except Exception:
  pass
PY
  )
fi

if [ -n "$EXISTING_SUMMARY_THREAD" ]; then
  echo "✓ Summary for HEAD_SHA=${HEAD_SHA:0:8} already exists in thread $EXISTING_SUMMARY_THREAD"
  echo "  Skipping duplicate post"
  SUMMARY_POSTED=false
else
  echo "Summary does not exist for this commit, posting new thread..."
  SUMMARY_POSTED=false

  # Sanitize and embed body marker (survives property stripping / retry modes)
  python3 - <<'PY'
import os, pathlib, re
sha = os.environ["HEAD_SHA"]
path = pathlib.Path("/tmp/pr_thread_body.md")
body = path.read_text()

# Newline-density check: if body is large but nearly devoid of newlines, log a warning
# (indicates the Write-tool mandate was bypassed and a Bash heredoc collapsed the lines)
body_len = len(body)
newline_count = body.count('\n')
if body_len > 500 and newline_count < max(1, body_len // 200):
  print(f"WARN: compiled report body has an abnormally low newline density ({body_len} chars, {newline_count} newlines) — applying best-effort paragraph repair; verify the posted comment renders correctly.", file=__import__('sys').stderr)
  # Broader repair: insert \n\n before headings and list markers that aren't already preceded by newline
  body = re.sub(r'([^\n])(#{1,6} )', r'\1\n\n\2', body)  # before ## / ### etc
  body = re.sub(r'([^\n])(- \*\*)', r'\1\n\n\2', body)    # before - ** (list items)
  body = re.sub(r'([^\n])(\d+\. )', r'\1\n\n\2', body)    # before 1. 2. etc (numbered lists)

# Defensive: fix common formatting issues (verdict directly attached to body, headers without spacing)
# Pattern: "## PR Review: REQUEST CHANGESThis PR" → "## PR Review: REQUEST CHANGES\n\nThis PR"
body = re.sub(r'(REQUEST CHANGES|NEEDS DISCUSSION|APPROVE)([A-Z])', r'\1\n\n\2', body)
# Pattern: "...merge.### Critical" → "...merge.\n\n### Critical"
body = re.sub(r'(\.)([#*-])', r'\1\n\n\2', body)

marker = f"\n\n<!-- pr-reviewer:v1.2 kind=summary sha={sha} -->\n"
if "pr-reviewer:v1.2 kind=summary" not in body:
    path.write_text(body.rstrip() + marker)
    print("✓ Summary marker embedded in body (formatting sanitized)")
else:
    print("✓ Summary marker already present")
PY

  # Seed first payload (full PropertiesCollection form), then retry in bash if needed
  python3 - <<'PY' > /tmp/pr_thread_payload.json
import json, os, pathlib
sha = os.environ["HEAD_SHA"]
body = pathlib.Path("/tmp/pr_thread_body.md").read_text()
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {
        "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": {"$type": "System.Int32", "$value": 1},
        "pr-reviewer.kind": {"$type": "System.String", "$value": "summary"},
        "pr-reviewer.sha": {"$type": "System.String", "$value": sha},
        "pr-reviewer.version": {"$type": "System.String", "$value": "v2"},
    },
}))
PY

  post_summary() {
    local label="$1"
    SUM_RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
      -H "Content-Type: application/json" -u ":${AZURE_DEVOPS_TOKEN}" -X POST \
      --data @/tmp/pr_thread_payload.json \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1" \
      || true)
    SUM_STATUS=$(echo "$SUM_RESP" | sed -n 's/^HTTP_STATUS://p')
    if echo "${SUM_STATUS:-}" | grep -qE '^2'; then
      # Verify marker is present in response body (post-post audit trail)
      SUM_RESP_BODY=$(echo "$SUM_RESP" | sed '$d')
      if ! echo "$SUM_RESP_BODY" | grep -q 'pr-reviewer:v1.2.*kind=summary'; then
        echo "ERROR: posted summary thread is missing its expected marker in response body — re-review detection will fail on the next run." >&2
        export MARKER_VERIFY_FAILED=$((${MARKER_VERIFY_FAILED:-0} + 1))
      fi
      echo "✓ Summary thread posted (HTTP $SUM_STATUS, mode=$label)"
      return 0
    fi
    echo "✗ Summary thread failed HTTP ${SUM_STATUS:-curl-error} (mode=$label)" >&2
    echo "  Response: $(echo "$SUM_RESP" | sed '$d' | head -c 200)" >&2
    return 1
  }

  if ! post_summary full; then
    python3 - <<'PY' > /tmp/pr_thread_payload.json
import json, pathlib
body = pathlib.Path("/tmp/pr_thread_body.md").read_text()
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {
        "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": {"$type": "System.Int32", "$value": 1},
    },
}))
PY
    if ! post_summary markdown; then
      python3 - <<'PY' > /tmp/pr_thread_payload.json
import json, pathlib
body = pathlib.Path("/tmp/pr_thread_body.md").read_text()
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
}))
PY
      post_summary bare || true
    fi
  fi
  SUMMARY_POSTED=true
fi

# --- 7. Reconciliation: resolve fixed findings (re-review mode only) ---
echo ""
if [ "${REVIEW_MODE}" = "rereview" ] && [ -f /tmp/pr_reconcile.json ]; then
  echo "=== Reconciling Prior Findings ==="
  : > /tmp/pr_resolved.log
  python3 -c "import json; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_reconcile.json')).get('fixed',[])]" \
  | while IFS= read -r f; do
    [ -z "$f" ] && continue
    THREAD_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin)['thread_ref'])")
    cat > /tmp/pr_resolve_body.md <<BODY
✅ Resolved as of \`${HEAD_SHA:0:8}\`. This finding no longer reproduces against the current head.
BODY
    python3 - <<'PY' > /tmp/pr_resolve_payload.json
import json
print(json.dumps({"content": open('/tmp/pr_resolve_body.md').read(), "commentType": 1}))
PY
    curl -sS -o /dev/null -H "Content-Type: application/json" -u ":${AZURE_DEVOPS_TOKEN}" -X POST \
      --data @/tmp/pr_resolve_payload.json \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}/comments?api-version=7.1" || true
    RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" -H "Content-Type: application/json" \
      -u ":${AZURE_DEVOPS_TOKEN}" -X PATCH -d '{"status":"fixed"}' \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}?api-version=7.1" || true)
    STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
    if echo "${STATUS:-}" | grep -qE '^2'; then echo ok >> /tmp/pr_resolved.log; else echo "fail $THREAD_ID HTTP ${STATUS:-?}" >> /tmp/pr_resolved.log; fi
  done
  RESOLVED_OK=$(grep -c '^ok' /tmp/pr_resolved.log 2>/dev/null || echo 0)
  RESOLVED_FAIL=$(grep -c '^fail' /tmp/pr_resolved.log 2>/dev/null || echo 0)
  echo "✓ Reconciled: ${RESOLVED_OK} prior finding(s) resolved (${RESOLVED_FAIL} failed)"

  # Handle reopened findings (prior finding marked resolved, but still reproduces)
  : > /tmp/pr_reopened.log
  python3 -c "import json; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_reconcile.json')).get('reopened',[])]" \
  | while IFS= read -r f; do
    [ -z "$f" ] && continue
    THREAD_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin)['thread_ref'])")
    cat > /tmp/pr_reopened_body.md <<BODY
⚠️ This finding still reproduces as of \`${HEAD_SHA:0:8}\` despite being marked resolved. Reactivating thread.
BODY
    python3 - <<'PY' > /tmp/pr_reopened_payload.json
import json
print(json.dumps({"content": open('/tmp/pr_reopened_body.md').read(), "commentType": 1}))
PY
    curl -sS -o /dev/null -H "Content-Type: application/json" -u ":${AZURE_DEVOPS_TOKEN}" -X POST \
      --data @/tmp/pr_reopened_payload.json \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}/comments?api-version=7.1" || true
    RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" -H "Content-Type: application/json" \
      -u ":${AZURE_DEVOPS_TOKEN}" -X PATCH -d '{"status":"active"}' \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}?api-version=7.1" || true)
    STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
    if echo "${STATUS:-}" | grep -qE '^2'; then echo ok >> /tmp/pr_reopened.log; else echo "fail $THREAD_ID HTTP ${STATUS:-?}" >> /tmp/pr_reopened.log; fi
  done
  REOPENED_OK=$(grep -c '^ok' /tmp/pr_reopened.log 2>/dev/null || echo 0)
  REOPENED_FAIL=$(grep -c '^fail' /tmp/pr_reopened.log 2>/dev/null || echo 0)
  if [ "$REOPENED_OK" -gt 0 ] || [ "$REOPENED_FAIL" -gt 0 ]; then
    echo "✓ Reopened: ${REOPENED_OK} finding(s) reactivated (${REOPENED_FAIL} failed)"
    export REOPENED_OK REOPENED_FAIL
  fi
  export RESOLVED_OK RESOLVED_FAIL
fi

# --- 8. Reply on addressed external threads ---
EXTERNAL_REPLY_OK=0
EXTERNAL_REPLY_FAIL=0
: > /tmp/pr_external_replies.log
if [ -f /tmp/pr_external_reconcile.json ]; then
  echo ""
  echo "=== External Thread Replies ==="
  python3 -c "import json; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_external_reconcile.json')).get('addressed',[])]" \
  | while IFS= read -r f; do
    [ -z "$f" ] && continue
    THREAD_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('thread_ref') or '')")
    [ -n "$THREAD_ID" ] || { echo "fail missing thread_ref" >> /tmp/pr_external_replies.log; continue; }
    cat > /tmp/pr_external_reply_body.md <<BODY
Looks addressed as of \`${HEAD_SHA:0:8}\` — leaving this thread open for the original author to resolve.
BODY
    python3 - <<'PY' > /tmp/pr_external_reply_payload.json
import json
print(json.dumps({"content": open('/tmp/pr_external_reply_body.md').read(), "commentType": 1}))
PY
    RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" -H "Content-Type: application/json" \
      -u ":${AZURE_DEVOPS_TOKEN}" -X POST --data @/tmp/pr_external_reply_payload.json \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}/comments?api-version=7.1" || true)
    STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
    if echo "${STATUS:-}" | grep -qE '^2'; then echo ok >> /tmp/pr_external_replies.log; else echo "fail $THREAD_ID HTTP ${STATUS:-?}" >> /tmp/pr_external_replies.log; fi
  done
  EXTERNAL_REPLY_OK=$(grep -c '^ok' /tmp/pr_external_replies.log 2>/dev/null || echo 0)
  EXTERNAL_REPLY_FAIL=$(grep -c '^fail' /tmp/pr_external_replies.log 2>/dev/null || echo 0)
  echo "✓ External replies: ${EXTERNAL_REPLY_OK} addressed thread(s) acknowledged (${EXTERNAL_REPLY_FAIL} failed)"
  export EXTERNAL_REPLY_OK EXTERNAL_REPLY_FAIL
fi

# --- 9. Post inline findings ---
echo ""
echo "=== Posting Inline Findings ==="
INLINE_TOTAL=0
INLINE_OK=0
INLINE_FAIL=0
: > /tmp/pr_inline_failures.log

# In re-review mode, build set of carried-over FIDs to skip (read from canonical /tmp/pr_reconcile.json)
CARRIED_OVER_FIDS=""
if [ "${REVIEW_MODE}" = "rereview" ] && [ -f /tmp/pr_reconcile.json ]; then
  CARRIED_OVER_FIDS=$(python3 -c "import json; s=json.load(open('/tmp/pr_reconcile.json')); print(' '.join(s.get('carried_over_fids',[])))" 2>/dev/null || echo "")
fi

while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "$line" > /tmp/pr_inline_finding.json

  # In re-review mode, skip findings that are carried over
  if [ "${REVIEW_MODE}" = "rereview" ] && [ -n "$CARRIED_OVER_FIDS" ]; then
    CURRENT_FID=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json')).get('fid',''))" 2>/dev/null || echo "")
    if [ -n "$CURRENT_FID" ] && echo " $CARRIED_OVER_FIDS " | grep -q " $CURRENT_FID "; then
      echo "Skipping carried-over finding: fid=$CURRENT_FID"
      continue
    fi
  fi

  INLINE_TOTAL=$((INLINE_TOTAL + 1))

  # Validate and self-heal fid format before posting
  python3 - <<'VALIDATE_FID' > /tmp/fid_validation.json 2>/dev/null
import json, re, hashlib
f = json.load(open('/tmp/pr_inline_finding.json'))
fid = f.get('fid') or ""
file_path = f.get('file') or f.get('path') or ""
line_no = f.get('line') or f.get('line_number') or 0
snippet = f.get('snippet') or ""
occurrence_index = f.get('occurrence_index') or 1

valid_fid = re.match(r'^[0-9a-f]{12}$', fid) is not None
result = {"valid": valid_fid, "fid": fid, "recomputed": False}

if not valid_fid and snippet:
    try:
        occurrence_str = str(int(occurrence_index)) if occurrence_index else "1"
        hash_input = f"{file_path}|{snippet}|{occurrence_str}"
        new_fid = hashlib.md5(hash_input.encode()).hexdigest()[:12]
        result["fid"] = new_fid
        result["recomputed"] = True
    except Exception as e:
        result["error"] = str(e)

json.dump(result, open('/tmp/fid_validation.json', 'w'))
print(json.dumps(result))
VALIDATE_FID

  VALIDATE_RESULT=$(python3 -c "import json; j=json.load(open('/tmp/fid_validation.json')); print(json.dumps(j))" 2>/dev/null || echo '{}')
  VALID_FID=$(python3 -c "import json,sys; print(json.load(open('/tmp/fid_validation.json')).get('valid', False))" 2>/dev/null || echo "false")
  RECOMPUTED_FID=$(python3 -c "import json,sys; print(json.load(open('/tmp/fid_validation.json')).get('recomputed', False))" 2>/dev/null || echo "false")

  if [ "$VALID_FID" = "False" ] && [ "$RECOMPUTED_FID" = "True" ]; then
    NEW_FID=$(python3 -c "import json; print(json.load(open('/tmp/fid_validation.json')).get('fid', ''))" 2>/dev/null || echo "")
    OLD_FID=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json')).get('fid', ''))" 2>/dev/null || echo "")
    FILE_PATH=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json')).get('file') or json.load(open('/tmp/pr_inline_finding.json')).get('path', ''))" 2>/dev/null || echo "")
    LINE_NO=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json')).get('line') or json.load(open('/tmp/pr_inline_finding.json')).get('line_number', ''))" 2>/dev/null || echo "")
    echo "WARN: fid '$OLD_FID' for $FILE_PATH:$LINE_NO failed format validation (expected 12 hex chars) — recomputed as '$NEW_FID'. This indicates compute_fid was not invoked correctly; check the run's tool-call history." >&2
    python3 - <<'UPDATE_FID' > /tmp/pr_inline_finding_updated.json
import json
f = json.load(open('/tmp/pr_inline_finding.json'))
result = json.load(open('/tmp/fid_validation.json'))
f['fid'] = result['fid']
json.dump(f, open('/tmp/pr_inline_finding_updated.json', 'w'))
UPDATE_FID
    mv /tmp/pr_inline_finding_updated.json /tmp/pr_inline_finding.json
  fi

  if ! HEAD_SHA="$REVIEW_HEAD_SHA" python3 - <<'PY' > /tmp/pr_thread_payload.json 2>>/tmp/pr_inline_failures.log
import json, os
f = json.load(open('/tmp/pr_inline_finding.json'))
file_path = f.get("file") or f.get("path") or ""
line_no = int(f.get("line") or f.get("line_number") or 0)
body = f.get("body") or f.get("comment") or ""
fid = f.get("fid") or ""
if not file_path or not line_no or not body:
    raise SystemExit("missing file/line/body in finding")
sha = os.environ["HEAD_SHA"]
if fid and "pr-reviewer:v1.2 kind=finding" not in body:
    body = body.rstrip() + f"\n\n<!-- pr-reviewer:v1.2 kind=finding fid={fid} sha={sha} -->\n"
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {
        "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": {"$type": "System.Int32", "$value": 1},
        "pr-reviewer.kind": {"$type": "System.String", "$value": "finding"},
        "pr-reviewer.fid": {"$type": "System.String", "$value": fid},
        "pr-reviewer.sha": {"$type": "System.String", "$value": sha},
    },
    "threadContext": {
        "filePath": "/" + file_path.lstrip("/"),
        "rightFileStart": {"line": line_no, "offset": 1},
        "rightFileEnd":   {"line": line_no, "offset": 1},
    },
}))
PY
  then
    INLINE_FAIL=$((INLINE_FAIL + 1))
    { echo "---"; echo "finding: $line"; echo "payload build failed"; } >> /tmp/pr_inline_failures.log
    continue
  fi
  RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" -u ":${AZURE_DEVOPS_TOKEN}" -X POST \
    --data @/tmp/pr_thread_payload.json \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1" \
    || true)
  STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
  if echo "${STATUS:-}" | grep -qE '^2'; then
    # Verify marker is present in response body (post-post audit trail)
    RESP_BODY=$(echo "$RESP" | sed '$d')
    if ! echo "$RESP_BODY" | grep -q 'pr-reviewer:v1.2.*kind=finding'; then
      echo "ERROR: posted inline thread is missing its expected marker in response body — re-review detection for this finding will fail on the next run." >&2
      export MARKER_VERIFY_FAILED=$((${MARKER_VERIFY_FAILED:-0} + 1))
    fi
    INLINE_OK=$((INLINE_OK + 1))
  else
    # Retry without custom properties (keep file anchor + markdown)
    if ! HEAD_SHA="$REVIEW_HEAD_SHA" python3 - <<'PY' > /tmp/pr_thread_payload.json 2>>/tmp/pr_inline_failures.log
import json, os
f = json.load(open('/tmp/pr_inline_finding.json'))
file_path = f.get("file") or f.get("path") or ""
line_no = int(f.get("line") or f.get("line_number") or 0)
body = f.get("body") or f.get("comment") or ""
fid = f.get("fid") or ""
sha = os.environ["HEAD_SHA"]
if fid and "pr-reviewer:v1.2 kind=finding" not in body:
    body = body.rstrip() + f"\n\n<!-- pr-reviewer:v1.2 kind=finding fid={fid} sha={sha} -->\n"
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {
        "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": {"$type": "System.Int32", "$value": 1},
    },
    "threadContext": {
        "filePath": "/" + file_path.lstrip("/"),
        "rightFileStart": {"line": line_no, "offset": 1},
        "rightFileEnd":   {"line": line_no, "offset": 1},
    },
}))
PY
    then
      INLINE_FAIL=$((INLINE_FAIL + 1))
      { echo "---"; echo "finding: $line"; echo "HTTP ${STATUS:-?}:"; echo "$RESP" | sed '$d'; echo "retry payload build failed"; } >> /tmp/pr_inline_failures.log
      continue
    fi
    RESP2=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
      -H "Content-Type: application/json" -u ":${AZURE_DEVOPS_TOKEN}" -X POST \
      --data @/tmp/pr_thread_payload.json \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1" \
      || true)
    STATUS2=$(echo "$RESP2" | sed -n 's/^HTTP_STATUS://p')
    if echo "${STATUS2:-}" | grep -qE '^2'; then
      INLINE_OK=$((INLINE_OK + 1))
      echo "WARN: inline posted without custom properties after HTTP ${STATUS:-?} (fid retained in body marker)" >&2
    else
      INLINE_FAIL=$((INLINE_FAIL + 1))
      { echo "---"; echo "finding: $line"; echo "HTTP ${STATUS:-?} then retry ${STATUS2:-?}:"; echo "$RESP2" | sed '$d'; } >> /tmp/pr_inline_failures.log
    fi
  fi
done < /tmp/pr_inline_findings.jsonl

echo "✓ Inline comments: ${INLINE_OK}/${INLINE_TOTAL} posted (${INLINE_FAIL} failed)"
if [ "$INLINE_FAIL" -gt 0 ]; then
  echo "WARN: see /tmp/pr_inline_failures.log" >&2
  head -40 /tmp/pr_inline_failures.log >&2
fi

export INLINE_OK INLINE_FAIL INLINE_TOTAL
EXTERNAL_REPLY_OK="${EXTERNAL_REPLY_OK:-0}"

# --- 10. Final status ---
echo ""
echo "========================================"
if [ "$REVIEW_MODE" = "rereview" ]; then
  echo "Re-review posted on PR #${PR_ID}: ${VERDICT}"
  echo "  — ${INLINE_OK}/${INLINE_TOTAL} new inline comments"
  echo "  — ${RESOLVED_OK:-0} prior finding(s) resolved"
  echo "  — ${EXTERNAL_REPLY_OK} external thread(s) replied"
else
  echo "Review posted on PR #${PR_ID}: ${VERDICT}"
  echo "  — ${INLINE_OK}/${INLINE_TOTAL} inline comments"
  echo "  — ${EXTERNAL_REPLY_OK} external thread(s) replied"
fi
echo "  → ${API_BASE}/_git/${AZURE_REPO}/pullrequest/${PR_ID}"
echo "========================================"

if [ "$INLINE_FAIL" -gt 0 ]; then
  echo "WARN: ${INLINE_FAIL} inline comment(s) failed to post"
  exit 1
fi

if [ "${MARKER_VERIFY_FAILED:-0}" -gt 0 ]; then
  echo "ERROR: ${MARKER_VERIFY_FAILED} posted thread(s) missing expected marker in response — reconciliation will fail on next re-review"
fi
