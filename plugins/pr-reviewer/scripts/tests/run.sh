#!/usr/bin/env bash
# scripts/tests/run.sh — fixture-based assertions for the deterministic pr-reviewer scripts.
# Plain bash + python3, no framework needed. Run from anywhere:
#   bash scripts/tests/run.sh
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$TESTS_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "ok   - $desc"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $desc"
    echo "       expected: $expected"
    echo "       actual:   $actual"
  fi
}

echo "=== ado_parse_remote — all 4 URL shapes ==="
source "$SCRIPTS_DIR/lib/azure-devops.sh"

_ado_parse_remote_url "https://dev.azure.com/contoso/Web/_git/api"
assert_eq "shape 1: org"        "contoso" "$AZURE_ORG"
assert_eq "shape 1: project"    "Web" "$AZURE_PROJECT"
assert_eq "shape 1: repo"       "api" "$AZURE_REPO"
assert_eq "shape 1: collection" "" "$AZURE_COLLECTION"
assert_eq "shape 1: api_base"   "https://dev.azure.com/contoso/Web" "$API_BASE"

_ado_parse_remote_url "https://dev.azure.com/contoso/MyCollection/Web/_git/api"
assert_eq "shape 2: org"        "contoso" "$AZURE_ORG"
assert_eq "shape 2: collection" "MyCollection" "$AZURE_COLLECTION"
assert_eq "shape 2: project"    "Web" "$AZURE_PROJECT"
assert_eq "shape 2: repo"       "api" "$AZURE_REPO"
assert_eq "shape 2: api_base"   "https://dev.azure.com/contoso/MyCollection/Web" "$API_BASE"

_ado_parse_remote_url "https://contoso.visualstudio.com/Web/_git/api"
assert_eq "shape 3: org"        "contoso" "$AZURE_ORG"
assert_eq "shape 3: project"    "Web" "$AZURE_PROJECT"
assert_eq "shape 3: repo"       "api" "$AZURE_REPO"
assert_eq "shape 3: api_base"   "https://contoso.visualstudio.com/Web" "$API_BASE"

_ado_parse_remote_url "https://contoso.visualstudio.com/DefaultCollection/Web/_git/api"
assert_eq "shape 4 (legacy DefaultCollection): org"        "contoso" "$AZURE_ORG"
assert_eq "shape 4 (legacy DefaultCollection): collection" "DefaultCollection" "$AZURE_COLLECTION"
assert_eq "shape 4 (legacy DefaultCollection): project"    "Web" "$AZURE_PROJECT"
assert_eq "shape 4 (legacy DefaultCollection): api_base"   "https://contoso.visualstudio.com/DefaultCollection/Web" "$API_BASE"

# Embedded basic-auth prefix (as injected by CI runners) must be stripped.
_ado_parse_remote_url "https://azureacc02@dev.azure.com/azureacc02/Xianix%20Platform/_git/TestRepo"
assert_eq "auth-prefix: org"     "azureacc02" "$AZURE_ORG"
assert_eq "auth-prefix: project" "Xianix%20Platform" "$AZURE_PROJECT"
assert_eq "auth-prefix: repo"    "TestRepo" "$AZURE_REPO"

echo
echo "=== gh_parse_remote ==="
source "$SCRIPTS_DIR/lib/github.sh"
_gh_parse_remote_url "https://github.com/acme/widgets.git"
assert_eq "https form: owner" "acme" "$OWNER"
assert_eq "https form: repo"  "widgets" "$REPO"
_gh_parse_remote_url "git@github.com:acme/widgets.git"
assert_eq "ssh form: owner" "acme" "$OWNER"
assert_eq "ssh form: repo"  "widgets" "$REPO"

echo
echo "=== _gh_extract_pr_number_from_arg — Agent Studio chat / comment re-review trigger ==="
assert_eq "plain PR URL"        "123" "$(_gh_extract_pr_number_from_arg 'https://github.com/acme/widgets/pull/123')"
assert_eq "PR URL with /files"  "123" "$(_gh_extract_pr_number_from_arg 'https://github.com/acme/widgets/pull/123/files')"
assert_eq "PR URL with #anchor" "123" "$(_gh_extract_pr_number_from_arg 'https://github.com/acme/widgets/pull/123#pullrequestreview-1')"
assert_eq "bare number is not a URL match (falls through to numeric branch)" "" "$(_gh_extract_pr_number_from_arg '123')"
assert_eq "branch name is not a URL match" "" "$(_gh_extract_pr_number_from_arg 'feature/foo')"

echo
echo "=== _ado_extract_pr_number_from_arg — Agent Studio chat / comment re-review trigger ==="
assert_eq "dev.azure.com PR URL"     "456" "$(_ado_extract_pr_number_from_arg 'https://dev.azure.com/contoso/Web/_git/api/pullrequest/456')"
assert_eq "visualstudio.com PR URL"  "456" "$(_ado_extract_pr_number_from_arg 'https://contoso.visualstudio.com/Web/_git/api/pullrequest/456')"
assert_eq "PR URL with query string" "456" "$(_ado_extract_pr_number_from_arg 'https://dev.azure.com/contoso/Web/_git/api/pullrequest/456?_a=files')"
assert_eq "bare number is not a URL match" "" "$(_ado_extract_pr_number_from_arg '456')"
assert_eq "branch name is not a URL match" "" "$(_ado_extract_pr_number_from_arg 'feature/foo')"

echo
echo "=== compute-fid.py — pinned known-good hash ==="
FID=$(python3 "$SCRIPTS_DIR/compute-fid.py" "src/auth/login.ts" "security" "if (user.role = 'admin') {")
EXPECTED_FID=$(python3 -c "
import hashlib, re
path = 'src/auth/login.ts'.strip().lower()
category = 'security'
snippet = re.sub(r'[^a-z0-9 ]', ' ', \"if (user.role = 'admin') {\".lower())
snippet = re.sub(r'\s+', ' ', snippet).strip()
print(hashlib.sha1(f'{path}|{category}|{snippet}'.encode()).hexdigest()[:12])
")
assert_eq "fid matches independently-computed reference" "$EXPECTED_FID" "$FID"

FID_A=$(python3 "$SCRIPTS_DIR/compute-fid.py" "a.py" "correctness" "if user is None:")
FID_B=$(python3 "$SCRIPTS_DIR/compute-fid.py" "a.py" "CORRECTNESS" "  IF   user IS None:!!")
assert_eq "fid is stable under case/punctuation/whitespace normalization" "$FID_A" "$FID_B"

FID_SAME_LINE_DIFF_CATEGORY=$(python3 "$SCRIPTS_DIR/compute-fid.py" "a.py" "performance" "if user is None:")
if [ "$FID_A" != "$FID_SAME_LINE_DIFF_CATEGORY" ]; then
  PASS=$((PASS + 1)); echo "ok   - same file+snippet but different category produces a different fid"
else
  FAIL=$((FAIL + 1)); echo "FAIL - same file+snippet but different category produces a different fid"
fi

if python3 "$SCRIPTS_DIR/compute-fid.py" "a.py" "not-a-real-category" "if user is None:" > /dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "FAIL - invalid category should be rejected"
else
  PASS=$((PASS + 1)); echo "ok   - invalid category should be rejected"
fi

echo
echo "=== extract-snippet.py — deterministic source-line extraction ==="
WORKDIR_SNIPPET=$(mktemp -d)
printf 'line one\nline two\nline three\n' > "$WORKDIR_SNIPPET/sample.txt"
SNIPPET=$(python3 "$SCRIPTS_DIR/extract-snippet.py" "$WORKDIR_SNIPPET/sample.txt" 2)
assert_eq "extracts exactly the requested line, no surrounding context" "line two" "$SNIPPET"

if python3 "$SCRIPTS_DIR/extract-snippet.py" "$WORKDIR_SNIPPET/sample.txt" 99 > /dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "FAIL - out-of-range line should error"
else
  PASS=$((PASS + 1)); echo "ok   - out-of-range line should error"
fi
rm -rf "$WORKDIR_SNIPPET"

echo
echo "=== resolve-line.py — diff-line to post-change file:line ==="
R=$(python3 "$SCRIPTS_DIR/resolve-line.py" "$FIXTURES/sample.diff" 19)
assert_eq "added import line" "user_service.py:2" "$R"

R=$(python3 "$SCRIPTS_DIR/resolve-line.py" "$FIXTURES/sample.diff" 23)
assert_eq "added API_KEY line" "user_service.py:5" "$R"

R=$(python3 "$SCRIPTS_DIR/resolve-line.py" "$FIXTURES/sample.diff" 30)
assert_eq "added return line" "user_service.py:11" "$R"

R=$(python3 "$SCRIPTS_DIR/resolve-line.py" "$FIXTURES/sample.diff" 29)
assert_eq "deleted line falls back to nearest surviving line" "user_service.py:11" "$R"

R=$(python3 "$SCRIPTS_DIR/resolve-line.py" "$FIXTURES/sample.diff" 9)
assert_eq "added readme line" "README.md:4" "$R"

if python3 "$SCRIPTS_DIR/resolve-line.py" "$FIXTURES/sample.diff" 1 > /dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "FAIL - line pointing at a 'diff --git' header should error"
else
  PASS=$((PASS + 1)); echo "ok   - line pointing at a 'diff --git' header should error"
fi

echo
echo "=== reconcile.py — bucket classification + deterministic verdict ==="

run_reconcile() {
  local dir="$1"
  python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('reconcile', '$SCRIPTS_DIR/reconcile.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)  # runs the module's own top-level assignments first
mod.STATE_FILE = '$dir/state.json'
mod.FINDINGS_FILE = '$dir/findings.json'
mod.PRIOR_FINDINGS_FILE = '$dir/prior.jsonl'
mod.OUTPUT_FILE = '$dir/reconcile.json'
mod.main()
"
}

# --- Scenario 1: HEAD advanced — Gate B (on-disk fid verification) walks through all four
# outcomes for a disappeared prior finding: still-flagged, untouched-file fast path,
# line-still-present, and genuinely-fixed. Also checks the verdict pulls severity from a
# carried-over finding that has no matching current finding (the case the old severity
# lookup silently dropped to "warning" on).
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR" "${WORKDIR2:-}"' EXIT
mkdir -p "$WORKDIR/repo"

printf 'still_broken_call()\n' > "$WORKDIR/repo/a.py"
printf 'safe_call()\n' > "$WORKDIR/repo/b.py"
printf 'risky_call()\n' > "$WORKDIR/repo/d_untouched.py"
printf 'still_here_call()\n' > "$WORKDIR/repo/e_changed.py"
printf 'now_safe_call()\n' > "$WORKDIR/repo/f_fixed.py"

FID_CARRIED=$(python3 "$SCRIPTS_DIR/compute-fid.py" "$WORKDIR/repo/a.py" "security" "still_broken_call()")
FID_NEW=$(python3 "$SCRIPTS_DIR/compute-fid.py" "$WORKDIR/repo/b.py" "correctness" "safe_call()")
FID_UNTOUCHED=$(python3 "$SCRIPTS_DIR/compute-fid.py" "$WORKDIR/repo/d_untouched.py" "security" "risky_call()")
FID_STILL_PRESENT=$(python3 "$SCRIPTS_DIR/compute-fid.py" "$WORKDIR/repo/e_changed.py" "correctness" "still_here_call()")
# The fid this finding was minted from ("vulnerable_call()") no longer exists in f_fixed.py
# on disk (it now reads "now_safe_call()") — that's what makes it genuinely "fixed".
FID_ACTUALLY_FIXED=$(python3 "$SCRIPTS_DIR/compute-fid.py" "$WORKDIR/repo/f_fixed.py" "correctness" "vulnerable_call()")

cat > "$WORKDIR/incremental_files.txt" <<EOF
$WORKDIR/repo/e_changed.py
$WORKDIR/repo/f_fixed.py
EOF

cat > "$WORKDIR/state.json" <<EOF
{
  "review_mode": "rereview",
  "push_update_mode": false,
  "head_sha": "head2",
  "prior_summary_sha": "head1",
  "incremental_changed_files": "$WORKDIR/incremental_files.txt"
}
EOF

cat > "$WORKDIR/findings.json" <<EOF
[
  {"file": "$WORKDIR/repo/a.py", "line": 1, "severity": "critical", "category": "security", "fid": "$FID_CARRIED", "body": "still broken"},
  {"file": "$WORKDIR/repo/b.py", "line": 1, "severity": "warning", "category": "correctness", "fid": "$FID_NEW", "body": "new issue"}
]
EOF

cat > "$WORKDIR/prior.jsonl" <<EOF
{"fid": "$FID_CARRIED", "status": "open", "thread_ref": 1, "file": "$WORKDIR/repo/a.py", "severity": "critical", "category": "security"}
{"fid": "$FID_UNTOUCHED", "status": "open", "thread_ref": 2, "file": "$WORKDIR/repo/d_untouched.py", "severity": "critical", "category": "security"}
{"fid": "$FID_STILL_PRESENT", "status": "open", "thread_ref": 3, "file": "$WORKDIR/repo/e_changed.py", "severity": "warning", "category": "correctness"}
{"fid": "$FID_ACTUALLY_FIXED", "status": "open", "thread_ref": 4, "file": "$WORKDIR/repo/f_fixed.py", "severity": "warning", "category": "correctness"}
{"fid": "fid-already-resolved", "status": "resolved", "thread_ref": 5, "file": "g.py", "severity": "warning", "category": "correctness"}
EOF

run_reconcile "$WORKDIR"

FIXED_FIDS=$(python3 -c "import json; d=json.load(open('$WORKDIR/reconcile.json')); print(','.join(sorted(x['fid'] for x in d['fixed'])))")
assert_eq "fixed bucket: only the finding whose line is genuinely gone from disk" "$FID_ACTUALLY_FIXED" "$FIXED_FIDS"

CARRIED_FIDS=$(python3 -c "import json; d=json.load(open('$WORKDIR/reconcile.json')); print(','.join(sorted(x['fid'] for x in d['carried_over'])))")
EXPECTED_CARRIED=$(printf '%s\n%s\n%s\n' "$FID_CARRIED" "$FID_UNTOUCHED" "$FID_STILL_PRESENT" | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "carried_over: still-flagged + untouched-file fast path + line-still-present" "$EXPECTED_CARRIED" "$CARRIED_FIDS"

NEW_FIDS=$(python3 -c "import json; d=json.load(open('$WORKDIR/reconcile.json')); print(','.join(sorted(x['fid'] for x in d['new'])))")
assert_eq "new bucket: only the current-only finding" "$FID_NEW" "$NEW_FIDS"

VERDICT=$(python3 -c "import json; print(json.load(open('$WORKDIR/reconcile.json'))['verdict'])")
assert_eq "verdict counts a carried-over CRITICAL with no matching current finding" "REQUEST CHANGES" "$VERDICT"

# --- Scenario 2: Gate A — HEAD has NOT advanced since the prior review. Reproduces the
# reported production bug: re-running the reviewer with zero new commits must never mark
# anything "fixed", even if this run's (stochastic) finder pass fails to re-surface a
# finding it raised last time.
WORKDIR2=$(mktemp -d)
mkdir -p "$WORKDIR2/repo"
printf 'still_lurking()\n' > "$WORKDIR2/repo/z.py"
FID_NOTMOVED=$(python3 "$SCRIPTS_DIR/compute-fid.py" "$WORKDIR2/repo/z.py" "security" "still_lurking()")

cat > "$WORKDIR2/state.json" <<EOF
{"review_mode": "rereview", "push_update_mode": false, "head_sha": "same_sha", "prior_summary_sha": "same_sha", "incremental_changed_files": ""}
EOF
cat > "$WORKDIR2/findings.json" <<'EOF'
[]
EOF
cat > "$WORKDIR2/prior.jsonl" <<EOF
{"fid": "$FID_NOTMOVED", "status": "open", "thread_ref": 9, "file": "$WORKDIR2/repo/z.py", "severity": "critical", "category": "security"}
EOF

run_reconcile "$WORKDIR2"

COUNTS2=$(python3 -c "
import json
d = json.load(open('$WORKDIR2/reconcile.json'))
print(d['counts']['fixed'], d['counts']['carried_over'], d['verdict'])
")
assert_eq "Gate A: re-run with no new commits never marks a missed finding as fixed" "0 1 REQUEST CHANGES" "$COUNTS2"

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
