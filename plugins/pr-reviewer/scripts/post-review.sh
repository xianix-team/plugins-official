#!/usr/bin/env bash
# post-review.sh — posts the full review: verdict/vote, summary comment (with marker),
# inline findings, and reconciliation of fixed threads. Reads everything except the report
# body prose from /tmp/pr_review_state.json + /tmp/pr_reconcile.json — nothing here depends
# on a shell variable surviving from an earlier, separate Bash call.
#
# Usage: bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.sh" <report-body-file>
#
# Findings in /tmp/pr_reconcile.json's "new" bucket must already carry {file, line, body, fid}
# — file/line are resolved ahead of time via resolve-line.py, fid via compute-fid.py.
#
# Respects PR_REVIEWER_BLOCK_ON_CRITICAL (read directly from the process env — safe, this is
# a container-level/invocation-level var, not something computed mid-run).
#
# Prints the final confirmation line using its own counters — never a hard-coded number.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${PR_REVIEW_STATE_FILE:-/tmp/pr_review_state.json}"
RECONCILE_FILE="${PR_REVIEW_RECONCILE_FILE:-/tmp/pr_reconcile.json}"
REPORT_BODY_FILE="${1:?usage: post-review.sh <report-body-file>}"

for f in "$STATE_FILE" "$RECONCILE_FILE" "$REPORT_BODY_FILE"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file '$f' not found." >&2
    exit 1
  fi
done

PLATFORM=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['platform'])")
REVIEW_MODE=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['review_mode'])")
HEAD_SHA=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['head_sha'])")
VERDICT=$(python3 -c "import json; print(json.load(open('$RECONCILE_FILE'))['verdict'])")

case "${PR_REVIEWER_BLOCK_ON_CRITICAL:-false}" in
  true|True|TRUE|1|yes|Yes|YES) BLOCK_ON_CRITICAL=true ;;
  *)                              BLOCK_ON_CRITICAL=false ;;
esac

INLINE_TOTAL=0
INLINE_OK=0
INLINE_FAIL=0
RESOLVED_OK=0
RESOLVED_FAIL=0
: > /tmp/pr_inline_failures.log
: > /tmp/pr_resolved.log

post_inline_loop_ado() {
  python3 -c "import json; [print(json.dumps(x)) for x in json.load(open('$RECONCILE_FILE'))['new']]" \
  | while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "$line" > /tmp/pr_inline_finding.json
      F_PATH=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json'))['file'])")
      F_LINE=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json'))['line'])")
      F_FID=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json'))['fid'])")
      F_SEVERITY=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json')).get('severity',''))")
      F_CATEGORY=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json')).get('category',''))")
      python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json'))['body'])" > /tmp/pr_inline_body.md
      if err=$(ado_post_inline_finding /tmp/pr_inline_body.md "$F_FID" "$F_PATH" "$F_LINE" "$F_SEVERITY" "$F_CATEGORY" 2>&1); then
        echo ok
      else
        { echo "---"; echo "finding: $line"; echo "$err"; } >> /tmp/pr_inline_failures.log
        echo fail
      fi
    done
}

post_inline_loop_gh() {
  python3 -c "import json; [print(json.dumps(x)) for x in json.load(open('$RECONCILE_FILE'))['new']]" \
  | while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "$line" > /tmp/pr_inline_finding.json
      F_PATH=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json'))['file'])")
      F_LINE=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json'))['line'])")
      F_FID=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json'))['fid'])")
      F_SEVERITY=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json')).get('severity',''))")
      F_CATEGORY=$(python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json')).get('category',''))")
      python3 -c "import json; print(json.load(open('/tmp/pr_inline_finding.json'))['body'])" > /tmp/pr_inline_body.md
      if err=$(gh_post_inline_finding /tmp/pr_inline_body.md "$F_FID" "$F_PATH" "$F_LINE" "$HEAD_SHA" "$F_SEVERITY" "$F_CATEGORY" 2>&1); then
        echo ok
      else
        { echo "---"; echo "finding: $line"; echo "$err"; } >> /tmp/pr_inline_failures.log
        echo fail
      fi
    done
}

case "$PLATFORM" in
  azuredevops)
    source "$SCRIPT_DIR/lib/azure-devops.sh"
    eval "$(python3 -c "
import json, shlex
d = json.load(open('$STATE_FILE'))
a = d['azure']
def e(v): return shlex.quote(str(v))
print('AZURE_ORG=' + e(a['org']))
print('AZURE_PROJECT=' + e(a['project']))
print('AZURE_REPO=' + e(a['repo']))
print('API_BASE=' + e(a['api_base']))
print('PR_ID=' + e(d['pr_id']))
")"

    case "$VERDICT" in
      "APPROVE") VOTE=10 ;;
      "APPROVE WITH SUGGESTIONS") VOTE=5 ;;
      "REQUEST CHANGES")
        if [ "$BLOCK_ON_CRITICAL" = "true" ]; then VOTE=-10; else
          VOTE=-5
          echo "INFO: advisory mode (PR_REVIEWER_BLOCK_ON_CRITICAL not true) — casting -5 instead of -10"
        fi ;;
      "NEEDS DISCUSSION") VOTE=-5 ;;
      *) VOTE=-5; echo "WARN: unrecognized verdict '${VERDICT}' — defaulting vote to -5" >&2 ;;
    esac
    ado_cast_vote "$VOTE" || true

    cp "$REPORT_BODY_FILE" /tmp/pr_thread_body.md
    ado_post_comment_thread /tmp/pr_thread_body.md "\"pr-reviewer.kind\":\"summary\",\"pr-reviewer.sha\":\"${HEAD_SHA}\"" || true

    if [ "$REVIEW_MODE" = "rereview" ]; then
      python3 -c "import json,sys; [print(json.dumps(x)) for x in json.load(open('$RECONCILE_FILE')).get('fixed',[])]" \
      | while IFS= read -r f; do
          echo "$f" > /tmp/pr_fixed_finding.json
          THREAD_ID=$(python3 -c "import json; print(json.load(open('/tmp/pr_fixed_finding.json'))['thread_ref'])")
          cat > /tmp/pr_resolve_body.md <<EOF
✅ Resolved as of \`${HEAD_SHA}\`. This finding no longer reproduces against the current head.
EOF
          ado_reply_to_thread "$THREAD_ID" /tmp/pr_resolve_body.md >/dev/null 2>&1 || true
          if ado_set_thread_status "$THREAD_ID" "fixed"; then echo ok >> /tmp/pr_resolved.log; else echo "fail $THREAD_ID" >> /tmp/pr_resolved.log; fi
        done
    fi

    RESULTS=$(post_inline_loop_ado)
    ;;

  github)
    source "$SCRIPT_DIR/lib/github.sh"
    eval "$(python3 -c "
import json, shlex
d = json.load(open('$STATE_FILE'))
def e(v): return shlex.quote(str(v))
print('OWNER=' + e(d['github']['owner']))
print('REPO=' + e(d['github']['repo']))
print('PR_NUMBER=' + e(d['pr_number']))
")"

    case "$VERDICT" in
      "APPROVE"|"APPROVE WITH SUGGESTIONS") REVIEW_FLAG="--approve" ;;
      "REQUEST CHANGES")
        if [ "$BLOCK_ON_CRITICAL" = "true" ]; then REVIEW_FLAG="--request-changes"; else
          REVIEW_FLAG="--comment"
          echo "INFO: advisory mode (PR_REVIEWER_BLOCK_ON_CRITICAL not true) — posting REQUEST CHANGES as non-blocking comment"
        fi ;;
      *) REVIEW_FLAG="--comment" ;;
    esac

    cp "$REPORT_BODY_FILE" /tmp/pr_review_body.md
    printf '\n\n<!-- pr-reviewer:v1 kind=summary sha=%s -->\n' "$HEAD_SHA" >> /tmp/pr_review_body.md
    gh_post_review "$REVIEW_FLAG" /tmp/pr_review_body.md || true

    if [ "$REVIEW_MODE" = "rereview" ]; then
      python3 -c "import json,sys; [print(json.dumps(x)) for x in json.load(open('$RECONCILE_FILE')).get('fixed',[])]" \
      | while IFS= read -r f; do
          echo "$f" > /tmp/pr_fixed_finding.json
          COMMENT_ID=$(python3 -c "import json; print(json.load(open('/tmp/pr_fixed_finding.json'))['comment_ref'])")
          THREAD_ID=$(python3 -c "import json; print(json.load(open('/tmp/pr_fixed_finding.json'))['thread_ref'])")
          cat > /tmp/pr_resolve_body.md <<EOF
✅ Resolved as of \`${HEAD_SHA}\`. This finding no longer reproduces against the current head.

<!-- pr-reviewer:v1 kind=resolve sha=${HEAD_SHA} -->
EOF
          gh_reply_to_comment "$COMMENT_ID" /tmp/pr_resolve_body.md >/dev/null 2>&1 || true
          if gh_resolve_thread "$THREAD_ID"; then echo ok >> /tmp/pr_resolved.log; else echo "fail $THREAD_ID" >> /tmp/pr_resolved.log; fi
        done
    fi

    RESULTS=$(post_inline_loop_gh)
    ;;

  *)
    REPORT_MD="pr-review-report.md"
    {
      echo "# PR Review Report"
      echo
      echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "Commit: ${HEAD_SHA}"
      echo "Verdict: ${VERDICT}"
      echo
      echo "---"
      echo
      cat "$REPORT_BODY_FILE"
    } > "$REPORT_MD"
    echo "Review complete: ${VERDICT} — report written to ${REPORT_MD}"
    exit 0
    ;;
esac

INLINE_TOTAL=$(echo "$RESULTS" | grep -c . || true)
INLINE_OK=$(echo "$RESULTS" | grep -c '^ok' || true)
INLINE_FAIL=$(echo "$RESULTS" | grep -c '^fail' || true)
RESOLVED_OK=$(grep -c '^ok' /tmp/pr_resolved.log 2>/dev/null || echo 0)
RESOLVED_FAIL=$(grep -c '^fail' /tmp/pr_resolved.log 2>/dev/null || echo 0)

echo "Inline comments: ${INLINE_OK}/${INLINE_TOTAL} posted (${INLINE_FAIL} failed)"
if [ "$INLINE_FAIL" -gt 0 ]; then
  echo "WARN: see /tmp/pr_inline_failures.log for failure details" >&2
  head -40 /tmp/pr_inline_failures.log >&2
fi

if [ "$REVIEW_MODE" = "rereview" ]; then
  echo "Reconciled: ${RESOLVED_OK} prior finding(s) resolved (${RESOLVED_FAIL} failed)"
fi

PR_LABEL=$(python3 -c "
import json
d = json.load(open('$STATE_FILE'))
print(d.get('pr_id') or d.get('pr_number') or '')
")

if [ "$REVIEW_MODE" = "rereview" ]; then
  CARRIED=$(python3 -c "import json; print(json.load(open('$RECONCILE_FILE'))['counts']['carried_over'])")
  echo "Re-review posted on PR #${PR_LABEL}: ${VERDICT} — ${INLINE_OK}/${INLINE_TOTAL} new — ${RESOLVED_OK} resolved — ${CARRIED} still open"
else
  echo "Review posted on PR #${PR_LABEL}: ${VERDICT} — ${INLINE_OK}/${INLINE_TOTAL} inline comments"
fi

if [ "$INLINE_OK" -eq 0 ] && [ "$INLINE_TOTAL" -gt 0 ]; then
  echo "WARN: ${INLINE_TOTAL} inline comment(s) failed to post — see /tmp/pr_inline_failures.log" >&2
fi
