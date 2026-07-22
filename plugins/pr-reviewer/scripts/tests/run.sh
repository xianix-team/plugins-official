#!/usr/bin/env bash
# run.sh — minimal regression tests for pr-reviewer's pure-logic scripts.
#
# Why this exists: fid computation and reconcile classification are exactly
# the kind of logic that regresses silently without a test — a normalization
# tweak or an off-by-one in occurrence indexing can silently break every
# re-review on the plugin without a single script erroring out. No test
# framework dependency: plain bash assertions, matching every other script
# in this plugin.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run.sh"
#
# Inputs:
#   None — builds its own scratch git repo and JSONL fixtures under a temp dir.
#   Backs up and restores any pre-existing /tmp/pr_state.env / /tmp/pr_prior.env
#   for the duration of the run, since reconcile-prior-findings.sh and
#   assign-fids.sh read those fixed paths rather than an injectable location.
#
# Outputs:
#   Prints PASS/FAIL per assertion group and a final count.
#   Exits non-zero if any assertion fails.

set -uo pipefail  # not -e: a failed assertion must not abort the remaining tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)

STATE_BACKUP="$WORK/pr_state.env.orig"
PRIOR_BACKUP="$WORK/pr_prior.env.orig"
[ -f /tmp/pr_state.env ] && cp /tmp/pr_state.env "$STATE_BACKUP"
[ -f /tmp/pr_prior.env ] && cp /tmp/pr_prior.env "$PRIOR_BACKUP"
rm -f /tmp/pr_state.env /tmp/pr_prior.env

cleanup() {
  if [ -f "$STATE_BACKUP" ]; then cp "$STATE_BACKUP" /tmp/pr_state.env; else rm -f /tmp/pr_state.env; fi
  if [ -f "$PRIOR_BACKUP" ]; then cp "$PRIOR_BACKUP" /tmp/pr_prior.env; else rm -f /tmp/pr_prior.env; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
  fi
}

assert_ne() {
  local desc="$1" a="$2" b="$3"
  if [ "$a" != "$b" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (expected different values, both were: $a)" >&2
  fi
}

fid() {  # fid <file> <snippet> <occurrence>
  bash "${SCRIPT_DIR}/compute-fid.sh" "$1" "$2" "$3"
}

bucket_has() {  # bucket_has <reconcile.json> <bucket> <fid> -> yes|no
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
fids = [x.get('fid') for x in d.get(sys.argv[2], [])]
print('yes' if sys.argv[3] in fids else 'no')
" "$1" "$2" "$3"
}

echo "=== compute-fid.sh ==="

FID_A=$(fid "src/foo.py" "x = 1" "1")
FID_A2=$(fid "src/foo.py" "x = 1" "1")
assert_eq "same input twice -> same fid" "$FID_A" "$FID_A2"

FID_B=$(fid "src/foo.py" "x = 1" "2")
assert_ne "different occurrence -> different fid" "$FID_A" "$FID_B"

FID_NORM=$(fid "SRC/Foo.py" "  X =   1  " "1")
assert_eq "path/case/whitespace normalization -> same fid" "$FID_A" "$FID_NORM"

echo "=== fixture repo ==="

REPO="$WORK/repo"
mkdir -p "$REPO/src"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
cat > "$REPO/src/foo.py" <<'PYFILE'
def foo():
    x = 1
    y = 2
    return x + y
PYFILE
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "fixture"
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

echo "=== assign-fids.sh mirrors compute-fid.sh exactly ==="

FINDINGS="$WORK/inline_findings.jsonl"
cat > "$FINDINGS" <<'JSON'
{"file": "src/foo.py", "line": 2, "body": "issue text is irrelevant to the fid now"}
JSON

( cd "$REPO" && HEAD_SHA="$HEAD_SHA" FINDINGS="$FINDINGS" bash "${SCRIPT_DIR}/assign-fids.sh" >/dev/null )

ASSIGNED_FID=$(python3 -c "import json; print(json.loads(open('$FINDINGS').readline())['fid'])")
EXPECTED_FID=$(fid "src/foo.py" "x = 1" "1")
assert_eq "assign-fids.sh formula matches compute-fid.sh (line 2 = 'x = 1')" "$EXPECTED_FID" "$ASSIGNED_FID"

echo "=== reconcile-prior-findings.sh classification ==="

FID_LINE2=$(fid "src/foo.py" "x = 1" "1")          # still on disk at HEAD
FID_LINE3=$(fid "src/foo.py" "y = 2" "1")          # still on disk at HEAD
FID_LINE4=$(fid "src/foo.py" "return x + y" "1")   # still on disk at HEAD
FID_REMOVED=$(fid "src/foo.py" "this line was deleted long ago" "1")       # not on disk
FID_RESOLVED_GONE=$(fid "src/foo.py" "another deleted line, resolved" "1") # not on disk
FID_NEW=$(fid "src/other.py" "brand new finding" "1")

# --- Run 1: normal re-review (Gate A open — PRIOR_SUMMARY_SHA differs from HEAD) ---
CURRENT1="$WORK/run1_current.jsonl"
PRIOR1="$WORK/run1_prior.jsonl"
OPEN1="$WORK/run1_open.jsonl"
OUT1="$WORK/run1_reconcile.json"
: > "$OPEN1"

cat > "$CURRENT1" <<JSON
{"fid": "$FID_LINE2", "file": "src/foo.py", "line": 2, "body": "still there"}
{"fid": "$FID_LINE3", "file": "src/foo.py", "line": 3, "body": "reproduced again"}
{"fid": "$FID_NEW", "file": "src/other.py", "line": 1, "body": "brand new finding"}
JSON

cat > "$PRIOR1" <<JSON
{"fid": "$FID_LINE2", "file": "src/foo.py", "line": 2, "status": "open", "thread_ref": "t1", "comment_ref": "c1"}
{"fid": "$FID_LINE3", "file": "src/foo.py", "line": 3, "status": "resolved", "thread_ref": "t2", "comment_ref": "c2"}
{"fid": "$FID_REMOVED", "file": "src/foo.py", "line": 99, "status": "open", "thread_ref": "t3", "comment_ref": "c3"}
{"fid": "$FID_LINE4", "file": "src/foo.py", "line": 4, "status": "open", "thread_ref": "t4", "comment_ref": "c4"}
{"fid": "$FID_RESOLVED_GONE", "file": "src/foo.py", "line": 50, "status": "resolved", "thread_ref": "t5", "comment_ref": "c5"}
JSON

(
  cd "$REPO"
  export REVIEW_MODE=rereview HEAD_SHA="$HEAD_SHA" RANGE_BASE="$HEAD_SHA" PRIOR_SUMMARY_SHA="0000000000000000000000000000000000dead"
  CURRENT="$CURRENT1" PRIOR="$PRIOR1" OPEN="$OPEN1" OUT="$OUT1" bash "${SCRIPT_DIR}/reconcile-prior-findings.sh" >/dev/null
)

assert_eq "carried: prior open fid still present" "yes" "$(bucket_has "$OUT1" carried_over "$FID_LINE2")"
assert_eq "reopened: prior resolved fid reappeared" "yes" "$(bucket_has "$OUT1" reopened "$FID_LINE3")"
assert_eq "fixed: prior open fid absent + passes Gate A + Gate B" "yes" "$(bucket_has "$OUT1" fixed "$FID_REMOVED")"
assert_eq "Gate B blocks: fid still reproduces in file -> carried, not fixed" "yes" "$(bucket_has "$OUT1" carried_over "$FID_LINE4")"
assert_eq "Gate B blocks: therefore NOT in fixed" "no" "$(bucket_has "$OUT1" fixed "$FID_LINE4")"
assert_eq "already-resolved-and-gone: not in fixed" "no" "$(bucket_has "$OUT1" fixed "$FID_RESOLVED_GONE")"
assert_eq "already-resolved-and-gone: not in carried_over" "no" "$(bucket_has "$OUT1" carried_over "$FID_RESOLVED_GONE")"
assert_eq "already-resolved-and-gone: not in reopened" "no" "$(bucket_has "$OUT1" reopened "$FID_RESOLVED_GONE")"
assert_eq "new: current fid absent from prior" "yes" "$(bucket_has "$OUT1" new "$FID_NEW")"

# --- Run 2: same-sha re-trigger, the everyday case now that re-triggers always
#     run in full — Gate A must force carried even with no current findings ---
CURRENT2="$WORK/run2_current.jsonl"
PRIOR2="$WORK/run2_prior.jsonl"
OPEN2="$WORK/run2_open.jsonl"
OUT2="$WORK/run2_reconcile.json"
: > "$OPEN2"
: > "$CURRENT2"

cat > "$PRIOR2" <<JSON
{"fid": "$FID_REMOVED", "file": "src/foo.py", "line": 99, "status": "open", "thread_ref": "t3", "comment_ref": "c3"}
JSON

(
  cd "$REPO"
  export REVIEW_MODE=rereview HEAD_SHA="$HEAD_SHA" RANGE_BASE="$HEAD_SHA" PRIOR_SUMMARY_SHA="$HEAD_SHA"
  CURRENT="$CURRENT2" PRIOR="$PRIOR2" OPEN="$OPEN2" OUT="$OUT2" bash "${SCRIPT_DIR}/reconcile-prior-findings.sh" >/dev/null
)

assert_eq "Gate A blocks (same sha): forced to carried_over" "yes" "$(bucket_has "$OUT2" carried_over "$FID_REMOVED")"
assert_eq "Gate A blocks (same sha): fixed bucket stays empty" "no" "$(bucket_has "$OUT2" fixed "$FID_REMOVED")"

echo "=== lib-args.sh flag parsing ==="

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"

# Flag beats env
unset PR_NUMBER BRANCH_ARG FIX_MODE VERDICT REVIEW_MODE PLATFORM PR_ID START_COMMENT_OPTIONAL PR_REVIEWER_BLOCK_ON_CRITICAL
export PR_NUMBER=999
parse_pr_args --pr 123 --branch feat/x --fix --verdict "REQUEST CHANGES" --mode rereview --platform azuredevops --block-on-critical --optional
assert_eq "--pr beats env PR_NUMBER" "123" "$PR_NUMBER"
assert_eq "--branch sets BRANCH_ARG" "feat/x" "$BRANCH_ARG"
assert_eq "--fix sets FIX_MODE" "true" "$FIX_MODE"
assert_eq "--verdict sets VERDICT" "REQUEST CHANGES" "$VERDICT"
assert_eq "--mode sets REVIEW_MODE" "rereview" "$REVIEW_MODE"
assert_eq "--platform sets PLATFORM" "azuredevops" "$PLATFORM"
assert_eq "--block-on-critical sets flag" "true" "$PR_REVIEWER_BLOCK_ON_CRITICAL"
assert_eq "--optional sets START_COMMENT_OPTIONAL" "true" "$START_COMMENT_OPTIONAL"
assert_eq "--pr also sets PR_ID when empty" "123" "$PR_ID"

# Env fallback when flag absent
unset PR_NUMBER BRANCH_ARG FIX_MODE VERDICT REVIEW_MODE PLATFORM PR_ID START_COMMENT_OPTIONAL PR_REVIEWER_BLOCK_ON_CRITICAL
export PR_NUMBER=42 BRANCH_ARG=env-branch VERDICT="APPROVE" REVIEW_MODE=initial
parse_pr_args
assert_eq "env fallback keeps PR_NUMBER" "42" "$PR_NUMBER"
assert_eq "env fallback keeps BRANCH_ARG" "env-branch" "$BRANCH_ARG"
assert_eq "env fallback keeps VERDICT" "APPROVE" "$VERDICT"
assert_eq "default FIX_MODE is false" "false" "$FIX_MODE"

# Unknown flag errors
unset PR_NUMBER
if parse_pr_args --unknown-flag 2>/dev/null; then
  assert_eq "unknown flag should fail" "fail" "ok"
else
  assert_eq "unknown flag should fail" "fail" "fail"
fi

# Equals-form flags
unset PR_NUMBER BRANCH_ARG VERDICT
parse_pr_args --pr=77 --branch=feat/y --verdict=APPROVE
assert_eq "--pr=N equals form" "77" "$PR_NUMBER"
assert_eq "--branch=NAME equals form" "feat/y" "$BRANCH_ARG"
assert_eq "--verdict=TEXT equals form" "APPROVE" "$VERDICT"

echo "=== lib-token.sh resolve_token ==="

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-token.sh"

# Clean slate for azure
unset AZURE_DEVOPS_TOKEN ADO_TOKEN AZURE_TOKEN
# Dashed alias via env (simulate executor inject). Use env -i-style carefully:
# bash cannot `export AZURE-DEVOPS-TOKEN=…` as an identifier, so use env prefix.
OUT_TOKEN=$(
  env -u AZURE_DEVOPS_TOKEN -u ADO_TOKEN -u AZURE_TOKEN \
    "AZURE-DEVOPS-TOKEN=secret-dashed-value" \
    bash -c '
      set -euo pipefail
      # shellcheck disable=SC1091
      source "'"${SCRIPT_DIR}"'/lib-token.sh"
      resolve_token azure
      # Presence only — never print the value
      echo "present=${AZURE_DEVOPS_TOKEN:+yes}"
      # Confirm value was re-exported without leaking into this outer assert string
      [ "$AZURE_DEVOPS_TOKEN" = "secret-dashed-value" ] && echo "value_ok=yes" || echo "value_ok=no"
    '
)
assert_eq "resolve_token azure re-exports dashed alias (present)" "present=yes" "$(echo "$OUT_TOKEN" | grep '^present=')"
assert_eq "resolve_token azure re-exports dashed alias (value)" "value_ok=yes" "$(echo "$OUT_TOKEN" | grep '^value_ok=')"

# GitHub: GITHUB_TOKEN → GH_TOKEN
OUT_GH=$(
  env -u GH_TOKEN -u GITHUB_TOKEN \
    GITHUB_TOKEN=gh-secret \
    bash -c '
      set -euo pipefail
      # shellcheck disable=SC1091
      source "'"${SCRIPT_DIR}"'/lib-token.sh"
      resolve_token github
      echo "gh=${GH_TOKEN:+yes}"
      echo "github=${GITHUB_TOKEN:+yes}"
      [ "$GH_TOKEN" = "gh-secret" ] && [ "$GITHUB_TOKEN" = "gh-secret" ] && echo "sync_ok=yes" || echo "sync_ok=no"
    '
)
assert_eq "resolve_token github maps GITHUB_TOKEN → GH_TOKEN" "gh=yes" "$(echo "$OUT_GH" | grep '^gh=')"
assert_eq "resolve_token github keeps GITHUB_TOKEN" "github=yes" "$(echo "$OUT_GH" | grep '^github=')"
assert_eq "resolve_token github syncs both names" "sync_ok=yes" "$(echo "$OUT_GH" | grep '^sync_ok=')"

# Missing token → non-zero, and token_present never echoes a secret
MISSING=$(
  env -u AZURE_DEVOPS_TOKEN -u ADO_TOKEN -u AZURE_TOKEN \
    bash -c '
      set +e
      # shellcheck disable=SC1091
      source "'"${SCRIPT_DIR}"'/lib-token.sh"
      resolve_token azure
      ec=$?
      token_present azure
      echo "ec=$ec"
    ' 2>/dev/null
)
assert_eq "resolve_token azure missing returns 1" "ec=1" "$(echo "$MISSING" | grep '^ec=')"
assert_eq "token_present never echoes a secret value" "AZURE_DEVOPS_TOKEN=" "$(echo "$MISSING" | grep '^AZURE_DEVOPS_TOKEN=')"
# Guard: the fake secret string must not appear in any output
if echo "$OUT_TOKEN$OUT_GH$MISSING" | grep -q 'secret-dashed-value\|gh-secret'; then
  assert_eq "token values never appear in test outer logs" "clean" "leaked"
else
  assert_eq "token values never appear in test outer logs" "clean" "clean"
fi

echo "=== ado-start-comment.sh hard-fail without --pr on detached HEAD ==="

# Clear any PR_* leaked from the lib-args tests above — ado-start-comment inherits
# the parent env, and a leftover PR_NUMBER would short-circuit the hard-fail path.
unset PR_NUMBER PR_ID BRANCH_ARG CALLER_PR START_COMMENT_OPTIONAL

# Build a tiny azure-remote-shaped repo so parse_azure_remote succeeds, then
# detach HEAD with no branch and no --pr. Expect exit 1 mentioning --pr.
ADO_REPO="$WORK/ado-repo"
mkdir -p "$ADO_REPO"
git -C "$ADO_REPO" init -q -b main
git -C "$ADO_REPO" config user.email "test@example.com"
git -C "$ADO_REPO" config user.name "Test"
echo "x" > "$ADO_REPO/README"
git -C "$ADO_REPO" add -A
git -C "$ADO_REPO" commit -q -m "init"
git -C "$ADO_REPO" remote add origin "https://dev.azure.com/org/project/_git/repo"
# Detach HEAD and delete the only branch name so branch resolution fails
DETACH_SHA=$(git -C "$ADO_REPO" rev-parse HEAD)
git -C "$ADO_REPO" checkout -q --detach "$DETACH_SHA"
git -C "$ADO_REPO" branch -D main >/dev/null 2>&1 || true

ADO_STATUS=0
(
  cd "$ADO_REPO"
  env -u PR_NUMBER -u PR_ID -u BRANCH_ARG -u START_COMMENT_OPTIONAL \
    AZURE_DEVOPS_TOKEN=fake-token \
    bash "${SCRIPT_DIR}/ado-start-comment.sh" >/dev/null 2>"$WORK/ado-stderr.txt"
) || ADO_STATUS=$?
assert_eq "ado-start-comment hard-fails without --pr on detached HEAD" "1" "$ADO_STATUS"
if grep -q '\-\-pr' "$WORK/ado-stderr.txt"; then
  assert_eq "ado-start-comment error mentions --pr" "yes" "yes"
else
  assert_eq "ado-start-comment error mentions --pr" "yes" "no"
  echo "  stderr was: $(cat "$WORK/ado-stderr.txt")" >&2
fi

# --optional soft-skips instead
ADO_OPT_STATUS=0
(
  cd "$ADO_REPO"
  env -u PR_NUMBER -u PR_ID -u BRANCH_ARG \
    AZURE_DEVOPS_TOKEN=fake-token \
    bash "${SCRIPT_DIR}/ado-start-comment.sh" --optional >/dev/null 2>"$WORK/ado-opt-stderr.txt"
) || ADO_OPT_STATUS=$?
assert_eq "ado-start-comment --optional soft-skips (exit 0)" "0" "$ADO_OPT_STATUS"
if grep -qi 'WARN:.*skipping' "$WORK/ado-opt-stderr.txt"; then
  assert_eq "ado-start-comment --optional warns and skips" "yes" "yes"
else
  assert_eq "ado-start-comment --optional warns and skips" "yes" "no"
  echo "  stderr was: $(cat "$WORK/ado-opt-stderr.txt")" >&2
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
