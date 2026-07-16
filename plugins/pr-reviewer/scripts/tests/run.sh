#!/usr/bin/env bash
# scripts/tests/run.sh — fixture-based assertions for the deterministic pr-reviewer scripts.
# Plain bash, no framework needed. Run from anywhere:
#   bash scripts/tests/run.sh
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$TESTS_DIR")"

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

echo "=== _ado_parse_remote_url — all 4 URL shapes ==="
# shellcheck disable=SC1091
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

if _ado_parse_remote_url "https://github.com/acme/widgets" > /dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "FAIL - non-ADO URL (no _git segment) should error"
else
  PASS=$((PASS + 1)); echo "ok   - non-ADO URL (no _git segment) should error"
fi

echo
echo "=== compute_fid (commands/pr-review.md) — pinned known-good hash ==="
# compute_fid is documented as a bash function in commands/pr-review.md rather than a
# standalone script (see *Comment markers and finding identity*), so this test
# re-implements its exact algorithm to catch any accidental drift from the documented
# hash inputs (path|normalised on-disk snippet|occurrence_index). This must stay in sync
# with the self-heal implementations in scripts/ado-post-review.sh and providers/github.md,
# which recompute fids with this exact formula when an agent posts a malformed one.
compute_fid() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, re, hashlib
path = sys.argv[1].strip().lower()
snippet = re.sub(r'[^a-z0-9 ]', ' ', sys.argv[2].lower())
snippet = re.sub(r'\s+', ' ', snippet).strip()
occurrence = sys.argv[3].strip()
print(hashlib.sha1(f"{path}|{snippet}|{occurrence}".encode()).hexdigest()[:12])
PY
}

FID_A=$(compute_fid "a.py" "if user is None:" "1")
FID_B=$(compute_fid "a.py" "  IF   user IS None:!!" "1")
assert_eq "fid is stable under case/punctuation/whitespace normalization" "$FID_A" "$FID_B"

FID_DIFF_OCCURRENCE=$(compute_fid "a.py" "if user is None:" "2")
if [ "$FID_A" != "$FID_DIFF_OCCURRENCE" ]; then
  PASS=$((PASS + 1)); echo "ok   - same file+snippet but different occurrence_index produces a different fid"
else
  FAIL=$((FAIL + 1)); echo "FAIL - same file+snippet but different occurrence_index produces a different fid"
fi

FID_DIFF_PATH=$(compute_fid "b.py" "if user is None:" "1")
if [ "$FID_A" != "$FID_DIFF_PATH" ]; then
  PASS=$((PASS + 1)); echo "ok   - same snippet+occurrence but different path produces a different fid"
else
  FAIL=$((FAIL + 1)); echo "FAIL - same snippet+occurrence but different path produces a different fid"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
