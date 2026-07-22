#!/usr/bin/env bash
# gh-post-review.sh — post verdict + summary + inline findings to GitHub.
#
# Why this exists as a real script (not just markdown): agents invent shortened
# gh api flows that skip markers, self-review handling, or inline loops.
# Run this file instead of retyping.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/gh-post-review.sh" \
#     --verdict "REQUEST CHANGES" --mode initial --pr 123
#
# Inputs (flags preferred; env names kept as fallback):
#   --verdict TEXT / --mode initial|rereview / --pr N / --block-on-critical
#   /tmp/pr_state.env              — PLATFORM, PR_NUMBER, HEAD_SHA (optional)
#   /tmp/pr_thread_body.md         — compiled report (fallback: /tmp/pr_review_body.md, /tmp/pr_review_summary.md)
#   /tmp/pr_inline_findings.jsonl  — one JSON object per finding
#   gh CLI authenticated (tokens via resolve_token)
#   Optional: /tmp/pr_reconcile.json (fixed[]/carried_over[]/reopened[]/new[]), /tmp/pr_external_reconcile.json
#
# Emits RESOLVED_OK/FAIL, REOPENED_OK/FAIL, EXTERNAL_REPLY_OK/FAIL,
# INLINE_OK/FAIL/TOTAL, MARKER_VERIFY_FAILED (post-POST audit, warn-only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-token.sh"

parse_pr_args "$@" || exit 1
resolve_token github || true

: "${VERDICT:=NEEDS DISCUSSION}"
: "${REVIEW_MODE:=initial}"

CALLER_PR="${PR_NUMBER:-${PR_ID:-}}"
# shellcheck disable=SC1091
[ -f /tmp/pr_state.env ] && source /tmp/pr_state.env

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found — required for GitHub posting" >&2
  exit 1
fi

PR_NUMBER="${CALLER_PR:-${PR_NUMBER:-${PR_ID:-}}}"
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null || true)
fi
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PR id unknown — re-run with --pr <number>" >&2
  exit 1
fi

REMOTE=$(git remote get-url origin)
# Strip embedded credentials (https://user:token@host/...) before parsing — never log secrets.
REMOTE_CLEAN=$(echo "$REMOTE" | sed -E 's|https?://[^@]+@|https://|')
OWNER=$(echo "$REMOTE_CLEAN" | sed 's|https://github.com/||;s|git@github.com:||;s|ssh://git@github.com/||' | cut -d'/' -f1)
REPO=$(echo "$REMOTE_CLEAN"  | sed 's|https://github.com/||;s|git@github.com:||;s|ssh://git@github.com/||' | cut -d'/' -f2 | sed 's|\.git$||')
[ -n "$OWNER" ] && [ -n "$REPO" ] || {
  echo "ERROR: could not parse owner/repo from origin (credentials stripped)" >&2
  exit 1
}
echo "Posting to https://github.com/${OWNER}/${REPO}/pull/${PR_NUMBER}"

# --- Normalize input files ---
if [ ! -f /tmp/pr_thread_body.md ]; then
  if [ -f /tmp/pr_review_body.md ]; then
    cp /tmp/pr_review_body.md /tmp/pr_thread_body.md
  elif [ -f /tmp/pr_review_summary.md ]; then
    cp /tmp/pr_review_summary.md /tmp/pr_thread_body.md
  fi
fi
if [ ! -f /tmp/pr_inline_findings.jsonl ] && [ -f /tmp/pr_findings.jsonl ]; then
  cp /tmp/pr_findings.jsonl /tmp/pr_inline_findings.jsonl
fi
[ -f /tmp/pr_thread_body.md ] || { echo "ERROR: /tmp/pr_thread_body.md missing" >&2; exit 1; }
touch /tmp/pr_inline_findings.jsonl

# Normalize pretty-printed / array / concatenated JSON into one-object-per-line JSONL
python3 - <<'PY'
import json
from pathlib import Path
src = Path('/tmp/pr_inline_findings.jsonl')
text = src.read_text().strip()
out = Path('/tmp/pr_inline_findings.normalized.jsonl')
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
with out.open('w') as f:
    for item in findings:
        f.write(json.dumps(item) + '\n')
print(f"Normalized {len(findings)} finding(s) for inline posting")
PY
mv /tmp/pr_inline_findings.normalized.jsonl /tmp/pr_inline_findings.jsonl

# --- Map verdict → gh flag ---
case "${VERDICT}" in
  waitForAuthor|Waiting*|"WAITING FOR AUTHOR") VERDICT="REQUEST CHANGES" ;;
  Rejected|REJECT|"REQUEST_CHANGES"|"CHANGES REQUESTED") VERDICT="REQUEST CHANGES" ;;
  Approved|APPROVED|LGTM) VERDICT="APPROVE" ;;
  COMMENT) VERDICT="NEEDS DISCUSSION" ;;
esac

PR_AUTHOR=$(gh pr view "$PR_NUMBER" --json author --jq '.author.login')
CURRENT_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
SELF_REVIEW=false
if [ -n "$CURRENT_USER" ] && [ "$PR_AUTHOR" = "$CURRENT_USER" ]; then
  SELF_REVIEW=true
  echo "INFO: self-review detected (author=$PR_AUTHOR) — will post as --comment, not --approve/--request-changes"
fi

case "${PR_REVIEWER_BLOCK_ON_CRITICAL:-false}" in
  true|True|TRUE|1|yes|Yes|YES) BLOCK_ON_CRITICAL=true ;;
  *)                              BLOCK_ON_CRITICAL=false ;;
esac

case "${VERDICT}" in
  "APPROVE"|"APPROVE WITH SUGGESTIONS")
    if [ "$SELF_REVIEW" = "true" ]; then
      REVIEW_FLAG="--comment"
      echo "INFO: self-review — posting APPROVE verdict as non-blocking comment review"
    else
      REVIEW_FLAG="--approve"
    fi
    ;;
  "REQUEST CHANGES")
    if [ "$SELF_REVIEW" = "true" ]; then
      REVIEW_FLAG="--comment"
      echo "INFO: self-review — posting REQUEST CHANGES verdict as non-blocking comment review"
    elif [ "$BLOCK_ON_CRITICAL" = "true" ]; then
      REVIEW_FLAG="--request-changes"
    else
      REVIEW_FLAG="--comment"
      echo "INFO: advisory mode (PR_REVIEWER_BLOCK_ON_CRITICAL not set to true) — posting REQUEST CHANGES as non-blocking comment"
    fi
    ;;
  "NEEDS DISCUSSION"|*)
    REVIEW_FLAG="--comment" ;;
esac

HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD)}"
if ! grep -q 'pr-reviewer:v1.2 kind=summary' /tmp/pr_thread_body.md; then
  printf '\n\n<!-- pr-reviewer:v1.2 kind=summary sha=%s -->\n' "$HEAD_SHA" >> /tmp/pr_thread_body.md
fi

# --- Cast verdict + post summary ---
# Marker verification for the summary is best-effort only: `gh pr review`'s own
# response isn't easily inspected for the posted body, unlike the per-finding
# REST POSTs below, which return the created comment and are checked for real.
MARKER_VERIFY_FAILED=0
if ! gh pr review "$PR_NUMBER" $REVIEW_FLAG --body "$(cat /tmp/pr_thread_body.md)" 2>/tmp/pr_review_err.txt; then
  echo "WARN: gh pr review failed: $(cat /tmp/pr_review_err.txt)" >&2
  echo "WARN: falling back to gh pr comment for the summary body" >&2
  gh pr comment "$PR_NUMBER" --body "$(cat /tmp/pr_thread_body.md)" || {
    echo "ERROR: could not post review summary — see /tmp/pr_review_err.txt" >&2
    exit 1
  }
fi
echo "Summary review posted (flag=${REVIEW_FLAG})"

# --- Sub-step R: reconcile fixed prior findings ---
RESOLVED_OK=0
RESOLVED_FAIL=0
: > /tmp/pr_resolved.log
if [ "${REVIEW_MODE}" = "rereview" ] && [ -f /tmp/pr_reconcile.json ]; then
  python3 -c "import json; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_reconcile.json')).get('fixed',[])]" \
  | while IFS= read -r f; do
    [ -z "$f" ] && continue
    COMMENT_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('comment_ref') or '')")
    THREAD_ID=$(echo  "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('thread_ref') or '')")
    [ -n "$COMMENT_ID" ] && [ -n "$THREAD_ID" ] || { echo "fail missing refs" >> /tmp/pr_resolved.log; continue; }

    gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments/${COMMENT_ID}/replies" \
      --method POST \
      --field body="✅ Resolved as of \`${HEAD_SHA}\`. This finding no longer reproduces against the current head.

<!-- pr-reviewer:v1.2 kind=resolve sha=${HEAD_SHA} -->" \
      >/dev/null 2>/tmp/pr_resolve_err.txt || true

    if gh api graphql -f query='
        mutation($id:ID!) { resolveReviewThread(input:{threadId:$id}) { thread { isResolved } } }' \
        -F id="$THREAD_ID" >/dev/null 2>>/tmp/pr_resolve_err.txt; then
      echo ok >> /tmp/pr_resolved.log
    else
      echo "fail $THREAD_ID" >> /tmp/pr_resolved.log
    fi
  done
  RESOLVED_OK=$(grep -c '^ok' /tmp/pr_resolved.log 2>/dev/null || true); RESOLVED_OK=${RESOLVED_OK:-0}
  RESOLVED_FAIL=$(grep -c '^fail' /tmp/pr_resolved.log 2>/dev/null || true); RESOLVED_FAIL=${RESOLVED_FAIL:-0}
  export RESOLVED_OK RESOLVED_FAIL
  echo "Reconciled: ${RESOLVED_OK} prior finding(s) resolved (${RESOLVED_FAIL} failed)"
fi

# --- Sub-step R2: reactivate reopened prior findings (regression signal) ---
REOPENED_OK=0
REOPENED_FAIL=0
: > /tmp/pr_reopened.log
if [ "${REVIEW_MODE}" = "rereview" ] && [ -f /tmp/pr_reconcile.json ]; then
  python3 -c "import json; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_reconcile.json')).get('reopened',[])]" \
  | while IFS= read -r f; do
    [ -z "$f" ] && continue
    COMMENT_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('comment_ref') or '')")
    THREAD_ID=$(echo  "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('thread_ref') or '')")
    [ -n "$COMMENT_ID" ] && [ -n "$THREAD_ID" ] || { echo "fail missing refs" >> /tmp/pr_reopened.log; continue; }

    gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments/${COMMENT_ID}/replies" \
      --method POST \
      --field body="⚠️ This finding still reproduces as of \`${HEAD_SHA}\` despite being marked resolved. Reactivating.

<!-- pr-reviewer:v1.2 kind=reopen sha=${HEAD_SHA} -->" \
      >/dev/null 2>/tmp/pr_reopen_err.txt || true

    if gh api graphql -f query='
        mutation($id:ID!) { unresolveReviewThread(input:{threadId:$id}) { thread { isResolved } } }' \
        -F id="$THREAD_ID" >/dev/null 2>>/tmp/pr_reopen_err.txt; then
      echo ok >> /tmp/pr_reopened.log
    else
      echo "fail $THREAD_ID" >> /tmp/pr_reopened.log
    fi
  done
  REOPENED_OK=$(grep -c '^ok' /tmp/pr_reopened.log 2>/dev/null || true); REOPENED_OK=${REOPENED_OK:-0}
  REOPENED_FAIL=$(grep -c '^fail' /tmp/pr_reopened.log 2>/dev/null || true); REOPENED_FAIL=${REOPENED_FAIL:-0}
  export REOPENED_OK REOPENED_FAIL
  # A reopened finding is a regression signal and expected to be rare — surface
  # it whenever non-zero rather than folding it silently into ordinary counts.
  [ "$REOPENED_OK" -gt 0 ] && echo "Reopened: ${REOPENED_OK} previously-fixed finding(s) still reproduce (${REOPENED_FAIL} failed to reactivate)"
fi

# --- Sub-step E: reply on addressed external threads — never resolve ---
EXTERNAL_REPLY_OK=0
EXTERNAL_REPLY_FAIL=0
: > /tmp/pr_external_replies.log
if [ -f /tmp/pr_external_reconcile.json ]; then
  python3 -c "import json; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_external_reconcile.json')).get('addressed',[])]" \
  | while IFS= read -r f; do
    [ -z "$f" ] && continue
    COMMENT_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('comment_ref') or '')")
    [ -n "$COMMENT_ID" ] || { echo "fail missing comment_ref" >> /tmp/pr_external_replies.log; continue; }

    gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments/${COMMENT_ID}/replies" \
      --method POST \
      --field body="Looks addressed as of \`${HEAD_SHA}\` — leaving this thread open for the original author to resolve.

<!-- pr-reviewer:v1.2 kind=external-ack sha=${HEAD_SHA} -->" \
      >/dev/null 2>/tmp/pr_external_reply_err.txt \
      && echo ok >> /tmp/pr_external_replies.log \
      || echo "fail $COMMENT_ID" >> /tmp/pr_external_replies.log
  done
  EXTERNAL_REPLY_OK=$(grep -c '^ok' /tmp/pr_external_replies.log 2>/dev/null || true); EXTERNAL_REPLY_OK=${EXTERNAL_REPLY_OK:-0}
  EXTERNAL_REPLY_FAIL=$(grep -c '^fail' /tmp/pr_external_replies.log 2>/dev/null || true); EXTERNAL_REPLY_FAIL=${EXTERNAL_REPLY_FAIL:-0}
fi
export EXTERNAL_REPLY_OK EXTERNAL_REPLY_FAIL
echo "External replies: ${EXTERNAL_REPLY_OK} addressed thread(s) acknowledged (${EXTERNAL_REPLY_FAIL} failed) — threads left open"

# --- Inline findings ---
COMMIT_ID=$(git rev-parse HEAD)
INLINE_TOTAL=0
INLINE_OK=0
INLINE_FAIL=0
: > /tmp/pr_inline_failures.log

while IFS= read -r line; do
  [ -z "$line" ] && continue
  INLINE_TOTAL=$((INLINE_TOTAL + 1))

  # One python call extracts every field AND writes the body file
  eval "$(printf '%s' "$line" | python3 -c "
import sys, json, shlex
d = json.load(sys.stdin)
open('/tmp/pr_inline_body.md', 'w').write(d.get('body') or d.get('comment') or '')
print('F_PATH=' + shlex.quote(str(d.get('file') or d.get('path') or '')))
print('F_LINE=' + shlex.quote(str(d.get('line') or d.get('line_number') or '')))
print('F_FID=' + shlex.quote(str(d.get('fid', ''))))
print('F_SUGGEST_START=' + shlex.quote(str(d.get('suggestion_start_line', ''))))
")"

  if [ -z "$F_PATH" ] || [ -z "$F_LINE" ]; then
    INLINE_FAIL=$((INLINE_FAIL + 1))
    { echo "---"; echo "finding: $line"; echo "missing file/line"; } >> /tmp/pr_inline_failures.log
    continue
  fi

  if [ -n "$F_FID" ] && ! grep -q 'pr-reviewer:v1.2 kind=finding' /tmp/pr_inline_body.md; then
    printf '\n\n<!-- pr-reviewer:v1.2 kind=finding fid=%s sha=%s -->\n' "$F_FID" "$COMMIT_ID" >> /tmp/pr_inline_body.md
  fi

  # Build optional suggestion-range args without tripping `set -u` on empty arrays.
  if [ -n "$F_SUGGEST_START" ] && [ "$F_SUGGEST_START" != "$F_LINE" ]; then
    set -- --field "start_line=${F_SUGGEST_START}" --field start_side=RIGHT
  else
    set --
  fi

  if gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments" \
    --method POST \
    --field path="$F_PATH" \
    --field line="$F_LINE" \
    --field side="RIGHT" \
    --field commit_id="$COMMIT_ID" \
    "$@" \
    --field body="$(cat /tmp/pr_inline_body.md)" \
    >/tmp/pr_inline_resp.json 2>/tmp/pr_inline_err.txt; then
    INLINE_OK=$((INLINE_OK + 1))
    # Post-POST marker verification (audit trail): re-inspect the created
    # comment's own response body for the marker we sent. GitHub echoes the
    # persisted body back on create, so this is a real round-trip check, not
    # just an HTTP-status assumption — see gh-detect-prior.sh's marker regex,
    # which is what actually depends on this having landed.
    if [ -n "$F_FID" ] && ! grep -q 'pr-reviewer:v1.2.*kind=finding' /tmp/pr_inline_resp.json; then
      echo "ERROR: posted inline comment is missing its expected marker in the response body — re-review detection for this finding will fail on the next run." >&2
      MARKER_VERIFY_FAILED=$((MARKER_VERIFY_FAILED + 1))
    fi
  else
    INLINE_FAIL=$((INLINE_FAIL + 1))
    {
      echo "---"
      echo "finding: $line"
      cat /tmp/pr_inline_err.txt
    } >> /tmp/pr_inline_failures.log
  fi
done < /tmp/pr_inline_findings.jsonl

echo "Inline comments: ${INLINE_OK}/${INLINE_TOTAL} posted (${INLINE_FAIL} failed)"
if [ "$INLINE_FAIL" -gt 0 ]; then
  echo "WARN: see /tmp/pr_inline_failures.log for failure details" >&2
  head -40 /tmp/pr_inline_failures.log >&2
fi
if [ "$MARKER_VERIFY_FAILED" -gt 0 ]; then
  echo "ERROR: ${MARKER_VERIFY_FAILED} posted comment(s) failed marker verification — see warnings above" >&2
fi

export INLINE_OK INLINE_FAIL INLINE_TOTAL MARKER_VERIFY_FAILED
EXTERNAL_REPLY_OK="${EXTERNAL_REPLY_OK:-0}"
RESOLVED_OK="${RESOLVED_OK:-0}"
REOPENED_OK="${REOPENED_OK:-0}"

if [ "$REVIEW_MODE" = "rereview" ]; then
  CONFIRM="Re-review posted on PR #${PR_NUMBER}: ${VERDICT} — ${INLINE_OK}/${INLINE_TOTAL} new — ${RESOLVED_OK} resolved — ${EXTERNAL_REPLY_OK} external replies — https://github.com/${OWNER}/${REPO}/pull/${PR_NUMBER}"
  [ "$REOPENED_OK" -gt 0 ] && CONFIRM="${CONFIRM} — ${REOPENED_OK} reopened (regression)"
  echo "$CONFIRM"
else
  echo "Review posted on PR #${PR_NUMBER}: ${VERDICT} — ${INLINE_OK}/${INLINE_TOTAL} inline comments — ${EXTERNAL_REPLY_OK} external replies — https://github.com/${OWNER}/${REPO}/pull/${PR_NUMBER}"
fi
if [ "$MARKER_VERIFY_FAILED" -gt 0 ]; then
  echo "WARN: ${MARKER_VERIFY_FAILED} posted comment(s) failed marker verification — re-review detection for those findings may fail next run."
fi
