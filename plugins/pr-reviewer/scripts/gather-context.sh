#!/usr/bin/env bash
# gather-context.sh — THE fix for the silent-full-review-instead-of-rereview bug.
#
# Runs platform detection, PR metadata, base/head resolution, diff generation, prior-review
# detection, review-mode decision, and review-tier decision — ALL in this one process. Writes
# /tmp/pr_review_state.json and prints a short digest.
#
# Why this exists: the old flow had the LLM re-type curl/git commands across many separate
# `Bash` tool calls, threading state through shell `export`. Under harnesses whose `Bash` tool
# does not persist shell state across calls (confirmed behavior under the Xianix Executor's
# Claude Agent SDK-based runner), those exports vanished, `API_BASE`/`PR_NUMBER` went empty,
# the prior-review detection curl hit a malformed URL, got an empty response, and the run
# silently fell back to `initial` mode on a PR that had already been reviewed. Doing the whole
# sequence in one script eliminates that failure mode structurally: there is no cross-call
# boundary for a variable to be lost across, and it behaves identically regardless of whether
# the harness's Bash tool happens to persist shell state.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/gather-context.sh" [pr-number-or-branch] [--push-update]
#
# Env vars respected (all read directly from the process environment — these reliably survive
# across separate Bash calls because they come from the container/invocation env, not from a
# mid-run `export`):
#   PR_REVIEWER_RECONCILE=false   force stateless initial review, skip detection entirely
#   GIT_REF                       set by the executor on initial/push-update runs; when unset
#                                  on an Azure DevOps run, triggers the comment-triggered
#                                  branch-checkout fix
#
# Exit non-zero only for genuinely unrecoverable errors (can't resolve platform / base ref /
# PR number). A failed prior-review-detection API call is NOT fatal — it's recorded as
# detection_status=failed in the state file and the run continues in the safer `initial` mode
# with the failure visible, never silently.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"

PR_ARG=""
PUSH_UPDATE_MODE=false
for arg in "$@"; do
  case "$arg" in
    --push-update) PUSH_UPDATE_MODE=true ;;
    *) PR_ARG="$arg" ;;
  esac
done

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "ERROR: not inside a git repository." >&2
  exit 1
fi

detect_platform || exit 1
echo "Platform: $PLATFORM"

PR_TITLE=""; PR_DESC=""; PR_SOURCE=""; PR_TARGET=""; PR_AUTHOR=""
AZURE_ORG=""; AZURE_PROJECT=""; AZURE_REPO=""; API_BASE=""; PR_ID=""
OWNER=""; REPO=""; PR_NUMBER=""; TRIGGER_SOURCE="current-branch"

case "$PLATFORM" in
  azuredevops)
    # shellcheck source=lib/azure-devops.sh
    source "$SCRIPT_DIR/lib/azure-devops.sh"
    ado_parse_remote || exit 1
    ado_resolve_pr_number "$PR_ARG" || exit 1
    ado_fetch_pr_metadata
    ado_ensure_correct_branch
    ;;
  github)
    # shellcheck source=lib/github.sh
    source "$SCRIPT_DIR/lib/github.sh"
    gh_parse_remote || exit 1
    gh_resolve_pr_number "$PR_ARG" || exit 1
    gh_fetch_pr_metadata
    gh_ensure_correct_branch
    PR_ID="$PR_NUMBER"
    ;;
  bitbucket|generic)
    PR_ID="$PR_ARG"
    ;;
esac

echo "PR: $PR_ID  (identified via: $TRIGGER_SOURCE)"

# --- Keep the base branch fresh before diffing against it ---
# Comment-triggered and Agent Studio chat-triggered runs (PR URL or PR number, no explicit
# ref) may execute in a workspace reused from an earlier run, whose local
# refs/remotes/origin/<base> can lag the real remote. Nothing upstream of this point
# refreshes it, so without this fetch the diff — and any "against latest main" claim in the
# posted review — can silently be computed against a stale base. Best-effort: a fetch
# failure (offline, auth) must not abort the review, it only means we fall back to whatever
# ref state is already present locally, same as before this fix.
if [ -n "$PR_TARGET" ]; then
  git fetch origin "$PR_TARGET" 2>/dev/null || true
else
  git fetch origin 2>/dev/null || true
fi

# --- Resolve base/head SHA (robust to detached HEAD, missing remote-tracking refs) ---
# Prefer the PR's real target branch (PR_TARGET) as the base when known; fall back to the
# origin/HEAD -> main/master/develop -> any-branch chain otherwise.
HEAD_SHA=$(git rev-parse HEAD)

_have_ref() { git show-ref --verify --quiet "$1" 2>/dev/null; }

BASE_REF=""
if [ -n "$PR_TARGET" ]; then
  for candidate in "refs/remotes/origin/${PR_TARGET}" "refs/heads/${PR_TARGET}"; do
    if _have_ref "$candidate"; then BASE_REF="$candidate"; break; fi
  done
fi
if [ -z "$BASE_REF" ]; then
  for candidate in \
    "$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" \
    refs/remotes/origin/main refs/remotes/origin/master refs/remotes/origin/develop \
    refs/heads/main refs/heads/master refs/heads/develop; do
    [ -n "$candidate" ] && _have_ref "$candidate" && { BASE_REF="$candidate"; break; }
  done
fi
if [ -z "$BASE_REF" ]; then
  BASE_REF=$(git for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null | grep -v '/HEAD$' | head -1)
fi
if [ -z "$BASE_REF" ]; then
  BASE_REF=$(git for-each-ref --format='%(refname)' refs/heads 2>/dev/null \
    | grep -v -F "$(git symbolic-ref -q HEAD || echo /no/symbolic/ref)" | head -1)
fi
if [ -z "$BASE_REF" ]; then
  echo "ERROR: could not resolve any base ref." >&2
  exit 1
fi

BASE=$(echo "$BASE_REF" | sed -e 's|^refs/remotes/origin/||' -e 's|^refs/heads/||')
BASE_SHA=$(git merge-base "$BASE_REF" "$HEAD_SHA")

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  CURRENT_BRANCH=$(git branch --contains "$HEAD_SHA" 2>/dev/null | sed 's|^[* ] *||' | grep -v '^(' | head -1)
fi

echo "Base: $BASE ($BASE_REF -> $BASE_SHA)"
echo "Head: $HEAD_SHA"

# --- Diff + changed files ---
git diff --name-only "${BASE_SHA}...${HEAD_SHA}" > /tmp/pr_changed_files.txt
git diff "${BASE_SHA}...${HEAD_SHA}" > /tmp/pr_full_diff.patch
CHANGED_COUNT=$(wc -l < /tmp/pr_changed_files.txt | tr -d ' ')
DIFF_LINES=$(wc -l < /tmp/pr_full_diff.patch | tr -d ' ')

if [ "$CHANGED_COUNT" -eq 0 ]; then
  echo "No changed files between ${BASE_SHA} and ${HEAD_SHA} — nothing to review."
fi

# --- Prior-review detection (the step that broke) ---
DETECTION_STATUS="skipped"
PRIOR_SUMMARY_SHA=""
: > /tmp/pr_prior_findings.jsonl

if [ "${PR_REVIEWER_RECONCILE:-true}" = "false" ]; then
  DETECTION_STATUS="skipped-by-config"
elif [ "$PLATFORM" = "azuredevops" ]; then
  ado_detect_prior_review
elif [ "$PLATFORM" = "github" ]; then
  gh_detect_prior_review
fi
# bitbucket/generic: no PR API, stays "skipped" — matches providers/generic.md (unchanged).

# --- Review-mode decision ---
# NOTE: this fixes a latent bug in the old spec, which used `[ ! -s pr_prior_findings.jsonl ]`
# as an OR-condition for "initial" mode — that treats a *clean* prior review (0 findings, but
# a real PRIOR_SUMMARY_SHA) as if no prior review existed, contradicting the docs' own stated
# rule that PRIOR_SUMMARY_SHA is the authoritative signal. Here, PRIOR_SUMMARY_SHA presence
# alone decides rereview vs. initial; the findings file only supplies what to reconcile.
if [ "$PUSH_UPDATE_MODE" = "true" ]; then
  REVIEW_MODE="rereview"
  if [ -n "$PRIOR_SUMMARY_SHA" ] && git cat-file -e "${PRIOR_SUMMARY_SHA}^{commit}" 2>/dev/null; then
    RANGE_BASE="$PRIOR_SUMMARY_SHA"
  else
    RANGE_BASE=$(git rev-parse "${HEAD_SHA}^" 2>/dev/null || echo "$BASE_SHA")
  fi
elif [ -n "$PRIOR_SUMMARY_SHA" ]; then
  REVIEW_MODE="rereview"
  if git cat-file -e "${PRIOR_SUMMARY_SHA}^{commit}" 2>/dev/null; then
    RANGE_BASE="$PRIOR_SUMMARY_SHA"
  else
    RANGE_BASE="$BASE_SHA"
  fi
else
  REVIEW_MODE="initial"
  RANGE_BASE="$BASE_SHA"
fi

if [ "$REVIEW_MODE" = "rereview" ]; then
  echo "Review mode: RE-REVIEW (focused on changes since prior review)  |  trigger: $TRIGGER_SOURCE  |  push-update: $PUSH_UPDATE_MODE  |  detection: $DETECTION_STATUS  |  range: ${RANGE_BASE}..${HEAD_SHA}"
else
  echo "Review mode: INITIAL (comprehensive)  |  trigger: $TRIGGER_SOURCE  |  push-update: $PUSH_UPDATE_MODE  |  detection: $DETECTION_STATUS  |  range: ${RANGE_BASE}..${HEAD_SHA}"
fi

INCREMENTAL_DIFF_FILE=""
INCREMENTAL_CHANGED_FILES=""
if [ "$REVIEW_MODE" = "rereview" ] && [ "$RANGE_BASE" != "$BASE_SHA" ]; then
  git diff "${RANGE_BASE}...${HEAD_SHA}" > /tmp/pr_incremental_diff.patch
  git diff --name-only "${RANGE_BASE}...${HEAD_SHA}" > /tmp/pr_incremental_changed_files.txt
  INCREMENTAL_DIFF_FILE="/tmp/pr_incremental_diff.patch"
  INCREMENTAL_CHANGED_FILES="/tmp/pr_incremental_changed_files.txt"
fi

# --- Review-tier decision (haiku vs. specialists) ---
if [ "$PUSH_UPDATE_MODE" = "true" ] && [ -n "$INCREMENTAL_DIFF_FILE" ] && [ -s "$INCREMENTAL_DIFF_FILE" ]; then
  TIER_DIFF_FILE="$INCREMENTAL_DIFF_FILE"
  TIER_FILES_FILE="$INCREMENTAL_CHANGED_FILES"
else
  TIER_DIFF_FILE="/tmp/pr_full_diff.patch"
  TIER_FILES_FILE="/tmp/pr_changed_files.txt"
fi
REVIEW_DIFF_FILE="$TIER_DIFF_FILE"

HIGH_RISK_FILES=$(grep -iE '(auth|login|signin|session|password|passwd|secret|token|jwt|oauth|crypto|encrypt|decrypt|payment|billing|charge|invoice|checkout|migration|schema|\.sql$|webhook|/api/|/controllers?/|/routes?/|/handlers?/|iam|rbac|permission)' "$TIER_FILES_FILE" 2>/dev/null || true)
HIGH_RISK_DIFF=$(grep -iE '^\+' "$TIER_DIFF_FILE" 2>/dev/null \
  | grep -iE '(password|secret|api[_-]?key|private[_-]?key|authorize|authenticate|hashpw|bcrypt|jwt|sql|exec\(|eval\(|subprocess|os\.system|pickle\.loads)' || true)

if [ -n "$HIGH_RISK_FILES" ] || [ -n "$HIGH_RISK_DIFF" ]; then
  REVIEW_TIER="specialists"
else
  REVIEW_TIER="haiku"
fi
echo "Tier: $REVIEW_TIER"

# --- Write state file ---
PLATFORM="$PLATFORM" REMOTE_URL="${REMOTE_URL:-}" \
AZURE_ORG="$AZURE_ORG" AZURE_PROJECT="$AZURE_PROJECT" AZURE_REPO="$AZURE_REPO" API_BASE="$API_BASE" \
OWNER="$OWNER" REPO="$REPO" \
PR_ID="$PR_ID" PR_NUMBER="$PR_NUMBER" TRIGGER_SOURCE="$TRIGGER_SOURCE" \
PR_TITLE="$PR_TITLE" PR_DESC="$PR_DESC" PR_SOURCE="$PR_SOURCE" PR_TARGET="$PR_TARGET" PR_AUTHOR="$PR_AUTHOR" \
BASE="$BASE" BASE_SHA="$BASE_SHA" HEAD_SHA="$HEAD_SHA" CURRENT_BRANCH="$CURRENT_BRANCH" \
CHANGED_COUNT="$CHANGED_COUNT" DIFF_LINES="$DIFF_LINES" \
REVIEW_MODE="$REVIEW_MODE" RANGE_BASE="$RANGE_BASE" PUSH_UPDATE_MODE="$PUSH_UPDATE_MODE" \
DETECTION_STATUS="$DETECTION_STATUS" PRIOR_SUMMARY_SHA="$PRIOR_SUMMARY_SHA" \
REVIEW_TIER="$REVIEW_TIER" REVIEW_DIFF_FILE="$REVIEW_DIFF_FILE" \
INCREMENTAL_DIFF_FILE="$INCREMENTAL_DIFF_FILE" INCREMENTAL_CHANGED_FILES="$INCREMENTAL_CHANGED_FILES" \
python3 - <<'PY'
import json, os

def env(k, default=""):
    return os.environ.get(k, default)

state = {
    "platform": env("PLATFORM"),
    "remote_url": env("REMOTE_URL"),
    "azure": {
        "org": env("AZURE_ORG"),
        "project": env("AZURE_PROJECT"),
        "repo": env("AZURE_REPO"),
        "api_base": env("API_BASE"),
    },
    "github": {
        "owner": env("OWNER"),
        "repo": env("REPO"),
    },
    "pr_id": env("PR_ID"),
    "pr_number": env("PR_NUMBER"),
    "trigger_source": env("TRIGGER_SOURCE"),
    "pr_title": env("PR_TITLE"),
    "pr_description": env("PR_DESC"),
    "pr_source_branch": env("PR_SOURCE"),
    "pr_target_branch": env("PR_TARGET"),
    "pr_author": env("PR_AUTHOR"),
    "base": env("BASE"),
    "base_sha": env("BASE_SHA"),
    "head_sha": env("HEAD_SHA"),
    "current_branch": env("CURRENT_BRANCH"),
    "changed_count": int(env("CHANGED_COUNT", "0") or "0"),
    "diff_lines": int(env("DIFF_LINES", "0") or "0"),
    "review_mode": env("REVIEW_MODE"),
    "range_base": env("RANGE_BASE"),
    "push_update_mode": env("PUSH_UPDATE_MODE") == "true",
    "detection_status": env("DETECTION_STATUS"),
    "prior_summary_sha": env("PRIOR_SUMMARY_SHA"),
    "review_tier": env("REVIEW_TIER"),
    "review_diff_file": env("REVIEW_DIFF_FILE"),
    "incremental_diff_file": env("INCREMENTAL_DIFF_FILE"),
    "incremental_changed_files": env("INCREMENTAL_CHANGED_FILES"),
    "full_diff_file": "/tmp/pr_full_diff.patch",
    "changed_files_file": "/tmp/pr_changed_files.txt",
    "prior_findings_file": "/tmp/pr_prior_findings.jsonl",
}

with open("/tmp/pr_review_state.json", "w") as f:
    json.dump(state, f, indent=2)
PY

echo "State written to /tmp/pr_review_state.json"
