#!/usr/bin/env bash
# ado-detect-prior.sh — list Azure DevOps PR threads for re-review awareness.
#
# Why this exists as a real script (not just markdown): agents invent shortened
# THREADS_JSON=$(curl …) flows, then json.load crashes on 401 HTML / empty
# bodies. Run this file instead of retyping.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ado-detect-prior.sh" --pr 123
#
# Inputs (flags preferred; env names kept as fallback):
#   --pr N
#   /tmp/pr_azure.env   — from starting-comment / parse step (API_BASE, AZURE_REPO, PR_ID, …)
#   AZURE_DEVOPS_TOKEN (via resolve_token) — required
#
# Outputs:
#   /tmp/pr_threads.json
#   /tmp/pr_prior_findings.jsonl
#   /tmp/pr_open_threads.jsonl
#   /tmp/pr_prior.env          — PRIOR_SUMMARY_SHA=… (source this; shell state does not persist)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-token.sh"

parse_pr_args "$@" || exit 1
CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"

# --- 0. Token (never echo the value) ---
if ! resolve_token azure; then
  echo "ERROR: AZURE_DEVOPS_TOKEN unset — cannot detect prior review" >&2
  echo "Presence-check only: echo \"AZURE_DEVOPS_TOKEN=\${AZURE_DEVOPS_TOKEN:+yes}\"" >&2
  exit 1
fi

# --- 1. Load API targets ---
# shellcheck disable=SC1091
[ -f /tmp/pr_azure.env ] && source /tmp/pr_azure.env
# Flag --pr wins over a stale / empty PR_ID left in /tmp/pr_azure.env.
PR_ID="${CALLER_PR:-${PR_ID:-${PR_NUMBER:-}}}"
[ -n "$PR_ID" ] && [ -n "${API_BASE:-}" ] && [ -n "${AZURE_REPO:-}" ] || {
  echo "ERROR: detect prior review needs API_BASE, AZURE_REPO, and PR id" >&2
  echo "Run scripts/ado-start-comment.sh --pr <number> first, or pass --pr <number> here." >&2
  exit 1
}

echo "Detecting prior review on ${API_BASE}/_git/${AZURE_REPO}/pullrequest/${PR_ID}"
echo "AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}"

# --- 2. Paginated thread listing (follow x-ms-continuationtoken) ---
: > /tmp/pr_threads_pages.jsonl
CONTINUATION=""
PAGE=0
while :; do
  PAGE=$((PAGE + 1))
  URL="${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1"
  if [ -n "$CONTINUATION" ]; then
    TOK_Q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$CONTINUATION")
    URL="${URL}&continuationToken=${TOK_Q}"
  fi
  HEADERS=$(mktemp)
  BODY_FILE=$(mktemp)
  HTTP_CODE=$(curl -sS -o "$BODY_FILE" -w "%{http_code}" -D "$HEADERS" -u ":${AZURE_DEVOPS_TOKEN}" "$URL" || echo "000")

  if ! echo "$HTTP_CODE" | grep -qE '^2'; then
    SNIP=$(head -c 400 "$BODY_FILE" | tr '\n' ' ')
    echo "ERROR: threads GET page ${PAGE} failed HTTP ${HTTP_CODE}" >&2
    case "$HTTP_CODE" in
      401|403)
        echo "Auth failed — confirm presence with: echo \"AZURE_DEVOPS_TOKEN=\${AZURE_DEVOPS_TOKEN:+yes}\"" >&2
        echo "If only dashed AZURE-DEVOPS-TOKEN exists: export AZURE_DEVOPS_TOKEN=\"\$(printenv AZURE-DEVOPS-TOKEN)\"" >&2
        ;;
      404)
        echo "Check API_BASE / AZURE_REPO / PR_ID from /tmp/pr_azure.env" >&2
        ;;
    esac
    [ -n "$SNIP" ] && echo "Body snippet: ${SNIP}" >&2
    rm -f "$HEADERS" "$BODY_FILE"
    exit 1
  fi

  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$BODY_FILE" 2>/dev/null; then
    SNIP=$(head -c 400 "$BODY_FILE" | tr '\n' ' ')
    echo "ERROR: threads GET page ${PAGE} returned non-JSON (HTTP ${HTTP_CODE})" >&2
    [ -n "$SNIP" ] && echo "Body snippet: ${SNIP}" >&2
    rm -f "$HEADERS" "$BODY_FILE"
    exit 1
  fi

  # One JSON object per line for the merge step
  tr -d '\n' < "$BODY_FILE" >> /tmp/pr_threads_pages.jsonl
  printf '\n' >> /tmp/pr_threads_pages.jsonl
  CONTINUATION=$(grep -i '^x-ms-continuationtoken:' "$HEADERS" | cut -d' ' -f2- | tr -d '\r' || true)
  rm -f "$HEADERS" "$BODY_FILE"
  [ -n "$CONTINUATION" ] || break
done

# --- 3. Merge pages → /tmp/pr_threads.json ---
python3 - <<'PY'
import json, sys
threads = []
for line in open("/tmp/pr_threads_pages.jsonl"):
    line = line.strip()
    if not line:
        continue
    try:
        data = json.loads(line)
    except json.JSONDecodeError as e:
        print(f"ERROR: corrupt page in /tmp/pr_threads_pages.jsonl: {e}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict) or "value" not in data:
        print("ERROR: unexpected threads payload (missing 'value') — refuse to invent a parser", file=sys.stderr)
        sys.exit(1)
    threads.extend(data.get("value") or [])
json.dump({"value": threads}, open("/tmp/pr_threads.json", "w"))
print(f"Loaded {len(threads)} thread(s)")
PY

# --- 4. Prior plugin findings + all open inline threads ---
python3 - <<'PY'
import json, re
data = json.load(open("/tmp/pr_threads.json"))

def prop(props, key):
    v = (props or {}).get(key)
    if isinstance(v, dict):  # PropertiesCollection form: {"$type":..,"$value":..}
        return v.get("$value")
    return v

RESOLVED = ("fixed", "closed", "wontFix", "byDesign")
prior = open("/tmp/pr_prior_findings.jsonl", "w")
open_threads = open("/tmp/pr_open_threads.jsonl", "w")
for t in data.get("value", []):
    props = t.get("properties") or {}
    comments = t.get("comments") or []
    first = comments[0] if comments else {}
    body = first.get("content") or ""
    fid = prop(props, "pr-reviewer.fid")
    kind = prop(props, "pr-reviewer.kind")
    # Fall back to body HTML marker when properties were stripped on create
    if not fid:
        m = re.search(r"<!--\s*pr-reviewer:v1\.2\s+kind=finding\s+fid=([0-9a-fA-F]+)", body)
        if m:
            fid = m.group(1)
            kind = kind or "finding"
    is_plugin = kind == "finding" and bool(fid)
    status = t.get("status", "active")
    resolved = status in RESOLVED
    ctx = t.get("threadContext") or {}
    file_path = (ctx.get("filePath") or "").lstrip("/")
    line = None
    for side in ("rightFileStart", "leftFileStart"):
        loc = ctx.get(side) or {}
        if loc.get("line"):
            line = loc["line"]
            break
    if is_plugin:
        prior.write(json.dumps({
            "fid": fid,
            "file": file_path,
            "line": line,
            "status": "resolved" if resolved else "open",
            "thread_ref": t["id"],
            "comment_ref": first.get("id"),
        }) + "\n")
    if resolved or not file_path:
        continue
    author = ((first.get("author") or {}) or {}).get("displayName") or \
             ((first.get("author") or {}) or {}).get("uniqueName") or ""
    open_threads.write(json.dumps({
        "file": file_path,
        "line": line,
        "body": body,
        "author": author,
        "is_plugin": is_plugin,
        "thread_ref": t["id"],
        "comment_ref": first.get("id"),
    }) + "\n")
prior.close()
open_threads.close()
PY

# --- 5. Most-recent summary marker sha → /tmp/pr_prior.env ---
PRIOR_SUMMARY_SHA=$(python3 - <<'PY'
import json, re
data = json.load(open("/tmp/pr_threads.json"))

def prop(props, key):
    v = (props or {}).get(key)
    return v.get("$value") if isinstance(v, dict) else v

summaries = []
for t in data.get("value", []):
    sha = prop(t.get("properties") or {}, "pr-reviewer.sha")
    kind = prop(t.get("properties") or {}, "pr-reviewer.kind")
    published = (t.get("comments") or [{}])[0].get("publishedDate", "") or t.get("publishedDate", "")
    if kind == "summary" and sha:
        summaries.append((published, sha))
        continue
    body = ((t.get("comments") or [{}])[0].get("content") or "")
    m = re.search(r"<!--\s*pr-reviewer:v1\.2\s+kind=summary\s+sha=([0-9a-fA-F]+)\s*-->", body)
    if m:
        summaries.append((published, m.group(1)))
summaries.sort()
print(summaries[-1][1] if summaries else "")
PY
)

{
  printf 'PRIOR_SUMMARY_SHA=%q\n' "${PRIOR_SUMMARY_SHA}"
} > /tmp/pr_prior.env

PRIOR_COUNT=$(wc -l < /tmp/pr_prior_findings.jsonl | tr -d ' ')
OPEN_COUNT=$(wc -l < /tmp/pr_open_threads.jsonl | tr -d ' ')
echo "Prior plugin findings: ${PRIOR_COUNT}  |  open inline threads: ${OPEN_COUNT}  |  PRIOR_SUMMARY_SHA=${PRIOR_SUMMARY_SHA:-none}"
echo "Wrote /tmp/pr_prior_findings.jsonl /tmp/pr_open_threads.jsonl /tmp/pr_prior.env"
