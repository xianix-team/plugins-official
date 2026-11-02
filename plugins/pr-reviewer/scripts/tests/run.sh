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
{"fid": "$FID_NEW", "file": "src/other.py", "line": 1, "severity": "WARNING", "body": "WARNING — brand new finding"}
JSON

cat > "$PRIOR1" <<JSON
{"fid": "$FID_LINE2", "visible_id": "W2", "file": "src/foo.py", "line": 2, "status": "open", "thread_ref": "t1", "comment_ref": "c1"}
{"fid": "$FID_LINE3", "visible_id": "S1", "file": "src/foo.py", "line": 3, "status": "resolved", "thread_ref": "t2", "comment_ref": "c2"}
{"fid": "$FID_REMOVED", "visible_id": "W1", "file": "src/foo.py", "line": 99, "status": "open", "thread_ref": "t3", "comment_ref": "c3"}
{"fid": "$FID_LINE4", "visible_id": "C1", "file": "src/foo.py", "line": 4, "status": "open", "thread_ref": "t4", "comment_ref": "c4"}
{"fid": "$FID_RESOLVED_GONE", "visible_id": "S2", "file": "src/foo.py", "line": 50, "status": "resolved", "thread_ref": "t5", "comment_ref": "c5"}
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

echo "=== stable visible IDs across re-review ==="
VISIBLE1="$WORK/run1_visible.json"
PRIOR="$PRIOR1" FINDINGS="$CURRENT1" RECONCILE="$OUT1" VISIBLE_IDS="$VISIBLE1" python3 "${SCRIPT_DIR}/assign-visible-ids.py" >/dev/null
VISIBLE_CHECK=$(python3 - "$OUT1" "$CURRENT1" "$VISIBLE1" "$FID_LINE2" "$FID_LINE3" "$FID_REMOVED" "$FID_NEW" <<'PY'
import json, sys
report, inline, labels = sys.argv[1:4]
carried, reopened, fixed, new = sys.argv[4:]
data = json.load(open(report))
mapping = json.load(open(labels))
posted = json.loads(open(inline).readline())
checks = [
    mapping[carried] == 'W2',
    mapping[reopened] == 'S1',
    mapping[fixed] == 'W1',
    mapping[new] == 'W3',
    data['carried_over'][0]['visible_id'] == 'W2',
    data['reopened'][0]['visible_id'] == 'S1',
    data['fixed'][0]['visible_id'] == 'W1',
    data['new'][0]['visible_id'] == 'W3',
    posted['visible_id'] == 'W3' and posted['body'].startswith('**W3** '),
]
print('yes' if all(checks) else 'no')
PY
)
assert_eq "fixed, carried, reopened, and new findings keep the expected labels" "yes" "$VISIBLE_CHECK"

PRIOR="$PRIOR1" FINDINGS="$CURRENT1" RECONCILE="$OUT1" VISIBLE_IDS="$VISIBLE1" python3 "${SCRIPT_DIR}/assign-visible-ids.py" >/dev/null
assert_eq "running the label step twice does not duplicate the inline label" "1" "$(rg -o '\*\*W3\*\*' "$CURRENT1" | wc -l | tr -d ' ')"

PRIOR3="$WORK/run3_prior.jsonl"
FINDINGS3="$WORK/run3_findings.jsonl"
OUT3="$WORK/run3_reconcile.json"
VISIBLE3="$WORK/run3_visible.json"
cat "$PRIOR1" > "$PRIOR3"
printf '{"fid":"%s","visible_id":"W3","status":"open"}\n' "$FID_NEW" >> "$PRIOR3"
cat > "$FINDINGS3" <<'JSON'
{"fid":"fresh-warning","severity":"WARNING","body":"WARNING — fresh warning"}
{"fid":"fresh-suggestion","severity":"SUGGESTION","body":"SUGGESTION — fresh suggestion"}
JSON
cat > "$OUT3" <<JSON
{"fixed":[],"carried_over":[{"fid":"$FID_LINE2"}],"reopened":[{"fid":"$FID_REMOVED"}],"new":[{"fid":"fresh-warning"},{"fid":"fresh-suggestion"}]}
JSON
PRIOR="$PRIOR3" FINDINGS="$FINDINGS3" RECONCILE="$OUT3" VISIBLE_IDS="$VISIBLE3" python3 "${SCRIPT_DIR}/assign-visible-ids.py" >/dev/null
ROUND3_CHECK=$(python3 - "$VISIBLE3" "$FINDINGS3" "$FID_REMOVED" <<'PY'
import json, sys
labels = json.load(open(sys.argv[1]))
findings = [json.loads(line) for line in open(sys.argv[2])]
checks = [labels[sys.argv[3]] == 'W1', labels['fresh-warning'] == 'W4',
          labels['fresh-suggestion'] == 'S3',
          findings[0]['body'].startswith('**W4** '),
          findings[1]['body'].startswith('**S3** ')]
print('yes' if all(checks) else 'no')
PY
)
assert_eq "later re-review reuses reopened W1 and does not recycle W or S numbers" "yes" "$ROUND3_CHECK"

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

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
