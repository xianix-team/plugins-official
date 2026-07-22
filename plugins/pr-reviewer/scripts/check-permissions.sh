#!/usr/bin/env bash
# check-permissions.sh — preflight auth + capability check for GitHub / Azure DevOps.
#
# Run once at the start of a review (before start-comment / setup). Fails fast when
# posting will be impossible; warns when vote / fix-mode push may fail.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-permissions.sh"
#   bash …/check-permissions.sh --pr 20 --fix
#
# Inputs (flags preferred; env names kept as fallback):
#   origin remote (authoritative platform)
#   --pr N / --fix
#   GitHub token via resolve_token (GH_TOKEN / GITHUB_TOKEN / GITHUB-TOKEN) or gh auth
#   Azure token via resolve_token (AZURE_DEVOPS_TOKEN / AZURE-DEVOPS-TOKEN)
#
# Outputs:
#   /tmp/pr_permissions.env            — PLATFORM, AUTH_OK, capability flags, WARNINGS
#   exit 0 = required checks passed (warnings may still be printed)
#   exit 1 = hard failure (stop the review)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-args.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-token.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib-azure-remote.sh"

parse_pr_args "$@" || exit 1

CURL="${CURL:-curl}"
command -v "$CURL" >/dev/null 2>&1 || CURL=/usr/bin/curl

HARD_FAIL=0
WARNINGS=()
CAP_AUTH=false
CAP_REPO_READ=false
CAP_PR_READ=false
CAP_COMMENT_WRITE=false   # threads / review comments
CAP_VOTE=false            # cast reviewer vote / gh approve|request-changes
CAP_PUSH=false            # fix-mode git push (soft — inferred / warned)
SCOPES_SEEN=""
PLATFORM=""
AUTH_USER=""

warn()  { WARNINGS+=("$1"); echo "WARN: $1" >&2; }
fail()  { HARD_FAIL=1; echo "ERROR: $1" >&2; }
ok()    { echo "OK: $1"; }

# --- Detect platform from origin ---
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [ -z "$REMOTE_URL" ]; then
  fail "no git remote 'origin' — cannot detect platform"
  {
    echo "export PLATFORM=generic"
    echo "export AUTH_OK=false"
    echo "export HARD_FAIL=1"
  } > /tmp/pr_permissions.env
  exit 1
fi
REMOTE_CLEAN=$(echo "$REMOTE_URL" | sed -E 's|https?://[^@]+@|https://|')
case "$REMOTE_CLEAN" in
  *github.com*) PLATFORM=github ;;
  *dev.azure.com*|*visualstudio.com*) PLATFORM=azure ;;
  *) PLATFORM=generic ;;
esac
echo "PLATFORM=${PLATFORM} (from origin)"

# =============================================================================
# GitHub
# =============================================================================
check_github() {
  if ! command -v gh >/dev/null 2>&1; then
    fail "gh CLI not installed — required to post reviews on GitHub (https://cli.github.com)"
    return
  fi
  ok "gh CLI present"

  # Prefer explicit token env if set (CI); otherwise rely on gh's stored auth.
  resolve_token github || true
  echo "$(token_present github) (or gh auth login)"

  # Auth + scopes from /user response headers
  HEADERS=$(mktemp)
  BODY=$(mktemp)
  HTTP=$($CURL -sS -o "$BODY" -D "$HEADERS" -w "%{http_code}" \
    -H "Authorization: token ${GH_TOKEN:-}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/user" 2>/dev/null || echo "000")

  # If no GH_TOKEN, fall back to gh (handles gh auth login / keyring)
  if [ "$HTTP" != "200" ] || [ -z "${GH_TOKEN:-}" ]; then
    if gh api user >/dev/null 2>"$BODY.err"; then
      HTTP=200
      gh api user >"$BODY" 2>/dev/null || true
      # gh api -i for scopes
      gh api -i user 2>/dev/null | tr -d '\r' >"$HEADERS" || true
    fi
  fi

  if [ "$HTTP" != "200" ]; then
    fail "GitHub auth failed (HTTP ${HTTP}). Set GH_TOKEN/GITHUB_TOKEN or run: gh auth login"
    rm -f "$HEADERS" "$BODY" "$BODY.err"
    return
  fi
  CAP_AUTH=true
  AUTH_USER=$(python3 -c "import json; print(json.load(open('$BODY')).get('login',''))" 2>/dev/null || true)
  ok "authenticated as ${AUTH_USER:-unknown}"

  SCOPES_SEEN=$(grep -i '^x-oauth-scopes:' "$HEADERS" 2>/dev/null | cut -d: -f2- | tr -d ' \r' || true)
  ACCEPTED=$(grep -i '^x-accepted-oauth-scopes:' "$HEADERS" 2>/dev/null | cut -d: -f2- | tr -d ' \r' || true)
  TOKEN_TYPE="classic"
  if [ -z "$SCOPES_SEEN" ]; then
    # Fine-grained PATs often omit X-OAuth-Scopes — rely on capability probes.
    TOKEN_TYPE="fine-grained-or-app"
    SCOPES_SEEN="(not listed — fine-grained/app token; probing capabilities)"
  fi
  echo "Token type: ${TOKEN_TYPE}  |  scopes: ${SCOPES_SEEN}"
  [ -n "$ACCEPTED" ] && echo "Accepted scopes (hint): ${ACCEPTED}"

  has_scope() {
    local want="$1"
    [ "$TOKEN_TYPE" != "classic" ] && return 1
    echo ",${SCOPES_SEEN}," | grep -qi ",${want},"
  }

  OWNER=$(echo "$REMOTE_CLEAN" | sed 's|https://github.com/||;s|git@github.com:||;s|ssh://git@github.com/||' | cut -d'/' -f1)
  REPO=$(echo "$REMOTE_CLEAN"  | sed 's|https://github.com/||;s|git@github.com:||;s|ssh://git@github.com/||' | cut -d'/' -f2 | sed 's|\.git$||')

  if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
    fail "could not parse owner/repo from origin"
    rm -f "$HEADERS" "$BODY"
    return
  fi

  # Repo read
  if gh api "repos/${OWNER}/${REPO}" --jq '.full_name' >/dev/null 2>&1; then
    CAP_REPO_READ=true
    ok "repo read: ${OWNER}/${REPO}"
  else
    fail "cannot read repos/${OWNER}/${REPO} — need scope 'repo' (private) or 'public_repo' (public), or fine-grained Contents: Read"
  fi

  # PR metadata read
  if [ -n "${PR_NUMBER:-}" ]; then
    if gh pr view "$PR_NUMBER" --repo "${OWNER}/${REPO}" --json number >/dev/null 2>&1; then
      CAP_PR_READ=true
      ok "PR #${PR_NUMBER} readable"
    else
      fail "cannot view PR #${PR_NUMBER} — need pull-request read access"
    fi
  else
    # Soft: list PRs
    if gh pr list --repo "${OWNER}/${REPO}" --limit 1 >/dev/null 2>&1; then
      CAP_PR_READ=true
      ok "PR list readable"
    else
      warn "cannot list PRs on ${OWNER}/${REPO} — posting may still work if PR number is provided"
      CAP_PR_READ=true  # do not hard-fail without a specific PR
    fi
  fi

  # Classic scope requirements for posting reviews / inline comments
  if [ "$TOKEN_TYPE" = "classic" ]; then
    if has_scope "repo" || has_scope "public_repo"; then
      CAP_COMMENT_WRITE=true
      CAP_VOTE=true
      CAP_PUSH=true
      ok "classic scopes include repo/public_repo (comment + review + push)"
    else
      fail "classic token missing 'repo' or 'public_repo' — required to post reviews and inline comments"
    fi
    if ! has_scope "repo" && ! has_scope "public_repo"; then
      :
    fi
  else
    # Fine-grained: probe GraphQL reviewThreads (read) — write cannot be probed without side effects.
    CAP_COMMENT_WRITE=true
    CAP_VOTE=true
    CAP_PUSH=true
    ok "fine-grained/app token — assuming PR write if repo read succeeded (ensure Contents: Read/Write, Pull requests: Read/Write, Metadata: Read)"
    warn "fine-grained tokens: confirm Pull requests = Read and write (and Contents write for --fix push)"
  fi

  # Fix-mode elevates push warning if GITHUB_TOKEN missing while using gh keyring only
  if [ "${FIX_MODE:-false}" = "true" ] && [ -z "${GITHUB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ]; then
    warn "FIX_MODE: GITHUB_TOKEN/GH_TOKEN unset — git push may fail even if gh auth works; inject GITHUB_TOKEN for HTTPS push"
    CAP_PUSH=false
  fi

  rm -f "$HEADERS" "$BODY" "$BODY.err"
}

# =============================================================================
# Azure DevOps
# =============================================================================
check_azure() {
  if ! resolve_token azure; then
    fail "AZURE_DEVOPS_TOKEN unset — required for Azure DevOps posting (see docs/platform-setup.md)"
    return
  fi
  token_present azure

  if ! parse_azure_remote; then
    fail "could not parse Azure DevOps remote URL"
    return
  fi
  write_azure_env

  # 1. Auth + User Profile (Read) via connectionData
  BODY=$(mktemp)
  HTTP=$($CURL -sS -o "$BODY" -w "%{http_code}" -u ":${AZURE_DEVOPS_TOKEN}" \
    "https://dev.azure.com/${AZURE_ORG}/_apis/connectionData?api-version=7.1-preview.1" || echo "000")
  if [ "$HTTP" != "200" ]; then
    fail "Azure auth failed on connectionData (HTTP ${HTTP}) — check PAT validity / org access"
    rm -f "$BODY"
    return
  fi
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$BODY" 2>/dev/null; then
    fail "connectionData returned non-JSON (HTTP ${HTTP}) — refuse to continue"
    rm -f "$BODY"
    return
  fi
  CAP_AUTH=true
  # Parse identity once — display name, id, account email, descriptor type
  eval "$(python3 -c "
import json, shlex
d=json.load(open('$BODY'))
u=d.get('authenticatedUser') or d.get('authorizedUser') or {}
props=u.get('properties') or {}
account=''
if isinstance(props, dict):
    acc=props.get('Account') or {}
    if isinstance(acc, dict):
        account=acc.get('\$value') or ''
    elif isinstance(acc, str):
        account=acc
desc=u.get('descriptor') or ''
desc_type=desc.split(';')[0] if desc else ''
print('AUTH_USER=' + shlex.quote(u.get('providerDisplayName') or u.get('uniqueName') or u.get('id') or ''))
print('REVIEWER_ID=' + shlex.quote(u.get('id') or ''))
print('AUTH_ACCOUNT=' + shlex.quote(account))
print('AUTH_DESCRIPTOR_TYPE=' + shlex.quote(desc_type))
" 2>/dev/null || true)"
  ok "authenticated as ${AUTH_USER:-unknown}${AUTH_ACCOUNT:+ ($AUTH_ACCOUNT)}"
  if [ -n "${AUTH_DESCRIPTOR_TYPE:-}" ]; then
    echo "Identity descriptor: ${AUTH_DESCRIPTOR_TYPE}"
  fi
  rm -f "$BODY"

  # 2. Code (Read) — repository GET
  HTTP=$($CURL -sS -o /tmp/pr_perm_repo.json -w "%{http_code}" -u ":${AZURE_DEVOPS_TOKEN}" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}?api-version=7.1" || echo "000")
  if [ "$HTTP" = "200" ]; then
    CAP_REPO_READ=true
    ok "repo read: ${AZURE_PROJECT}/${AZURE_REPO}"
  else
    fail "cannot read repository (HTTP ${HTTP}) — need Code (Read) on this project"
  fi

  # 3. PR list / specific PR — Code (Read) + PR access
  if [ -n "${PR_NUMBER:-}" ]; then
    HTTP=$($CURL -sS -o /tmp/pr_perm_pr.json -w "%{http_code}" -u ":${AZURE_DEVOPS_TOKEN}" \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_NUMBER}?api-version=7.1" || echo "000")
    if [ "$HTTP" = "200" ]; then
      CAP_PR_READ=true
      ok "PR #${PR_NUMBER} readable"
    else
      fail "cannot read PR #${PR_NUMBER} (HTTP ${HTTP})"
    fi
  else
    HTTP=$($CURL -sS -o /tmp/pr_perm_pr.json -w "%{http_code}" -u ":${AZURE_DEVOPS_TOKEN}" \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?searchCriteria.status=active&\$top=1&api-version=7.1" || echo "000")
    if [ "$HTTP" = "200" ]; then
      CAP_PR_READ=true
      ok "PR list readable"
    else
      fail "cannot list pull requests (HTTP ${HTTP})"
    fi
  fi

  # 4. Pull Request Threads (Read) — required for detect-prior / reconcile
  PR_PROBE="${PR_NUMBER:-}"
  if [ -z "$PR_PROBE" ] && [ -f /tmp/pr_perm_pr.json ]; then
    PR_PROBE=$(python3 -c "import json; v=json.load(open('/tmp/pr_perm_pr.json')).get('value') or []; print(v[0]['pullRequestId'] if v else '')" 2>/dev/null || true)
  fi
  if [ -n "$PR_PROBE" ]; then
    HTTP=$($CURL -sS -o /tmp/pr_perm_threads.json -w "%{http_code}" -u ":${AZURE_DEVOPS_TOKEN}" \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_PROBE}/threads?\$top=1&api-version=7.1" || echo "000")
    if [ "$HTTP" = "200" ]; then
      CAP_COMMENT_WRITE=true  # Read confirmed; Write required to post — probed softly below
      ok "PR threads readable on #${PR_PROBE} (Pull Request Threads Read)"
    else
      fail "cannot read PR threads (HTTP ${HTTP}) — need Pull Request Threads (Read & Write)"
    fi
  else
    warn "no PR id available — skipped threads probe; ensure PAT has Pull Request Threads (Read & Write)"
    CAP_COMMENT_WRITE=true
  fi

  # 5. Vote capability — valid PR-reviewer identity + Code (Write)
  # Azure quirks (confirmed against real orgs):
  #   GET  …/reviewers/{id} → 200 if already on the PR; **400 if not yet on the
  #     list** even for a fully valid licensed user. Do NOT treat GET 400 as
  #     "invalid identity".
  #   PUT  …/reviewers/{id} with vote:0 is the reliable probe (adds no-vote
  #     reviewer). We DELETE afterward to avoid leaving a side effect.
  #   PUT 401/403 → authz / identity cannot vote (service PATs often land here).
  VOTE_BLOCK_REASON=""
  if [ -n "${REVIEWER_ID:-}" ] && [ -n "$PR_PROBE" ]; then
    HTTP=$($CURL -sS -o /tmp/pr_perm_reviewer.json -w "%{http_code}" -u ":${AZURE_DEVOPS_TOKEN}" \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_PROBE}/reviewers/${REVIEWER_ID}?api-version=7.1" || echo "000")
    REV_MSG=$(python3 -c "
import json
try:
  d=json.load(open('/tmp/pr_perm_reviewer.json'))
  print((d.get('message') or '')[:200])
except Exception:
  print('')
" 2>/dev/null || true)
    case "$HTTP" in
      200)
        CAP_VOTE=true
        ok "reviewer already on PR #${PR_PROBE} — vote path available"
        ;;
      400|404)
        # Not on the reviewer list yet (normal). Confirm with a no-vote PUT, then remove.
        echo "Reviewer GET HTTP ${HTTP} (not on PR list yet) — probing with vote:0 PUT…"
        PUT_HTTP=$($CURL -sS -o /tmp/pr_perm_vote_probe.json -w "%{http_code}" \
          -u ":${AZURE_DEVOPS_TOKEN}" -X PUT -H "Content-Type: application/json" \
          -d "{\"vote\":0,\"id\":\"${REVIEWER_ID}\"}" \
          "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_PROBE}/reviewers/${REVIEWER_ID}?api-version=7.1" \
          || echo "000")
        if echo "$PUT_HTTP" | grep -qE '^2'; then
          CAP_VOTE=true
          ok "vote probe PUT vote:0 succeeded (HTTP ${PUT_HTTP}) — identity can cast votes"
          # Best-effort cleanup so we don't leave a no-vote reviewer row
          $CURL -sS -o /dev/null -u ":${AZURE_DEVOPS_TOKEN}" -X DELETE \
            "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_PROBE}/reviewers/${REVIEWER_ID}?api-version=7.1" \
            >/dev/null 2>&1 || true
        elif [ "$PUT_HTTP" = "401" ] || [ "$PUT_HTTP" = "403" ]; then
          CAP_VOTE=false
          VOTE_BLOCK_REASON=authz
          warn "vote probe PUT HTTP ${PUT_HTTP} — need Code (Read & Write) and a licensed org user that can be a PR reviewer"
          warn "authenticated as ${AUTH_USER:-unknown}${AUTH_ACCOUNT:+ ($AUTH_ACCOUNT)}; summary/inline may still post"
        else
          CAP_VOTE=false
          VOTE_BLOCK_REASON=invalid_reviewer_identity
          PUT_MSG=$(python3 -c "
import json
try:
  print((json.load(open('/tmp/pr_perm_vote_probe.json')).get('message') or '')[:200])
except Exception:
  print('')
" 2>/dev/null || true)
          warn "vote probe PUT HTTP ${PUT_HTTP}${PUT_MSG:+ — $PUT_MSG}"
          warn "PAT identity cannot cast PR votes (connectionData id=${REVIEWER_ID:0:8}…). Use a PAT from a full AAD/org user who can be added as a PR reviewer — Code Write alone may not be enough for service/agent identities."
        fi
        ;;
      401|403)
        CAP_VOTE=false
        VOTE_BLOCK_REASON=authz
        warn "reviewer endpoint HTTP ${HTTP} — vote will likely fail (need Code Read & Write, and a licensed org user). Summary/inline threads may still post."
        ;;
      *)
        CAP_VOTE=false
        VOTE_BLOCK_REASON=unknown
        warn "reviewer probe HTTP ${HTTP}${REV_MSG:+ — $REV_MSG} — vote may fail; continuing"
        ;;
    esac
  else
    if [ -z "${REVIEWER_ID:-}" ]; then
      warn "could not resolve reviewer id from connectionData — vote may be skipped"
      VOTE_BLOCK_REASON=no_reviewer_id
    fi
    CAP_VOTE=false
  fi

  # 6. Push (fix mode) — cannot probe without writing; document requirement
  if [ "${FIX_MODE:-false}" = "true" ]; then
    CAP_PUSH=false
    warn "FIX_MODE: git push requires Code (Read & Write); this preflight cannot verify write without mutating the repo"
  else
    CAP_PUSH=true  # not required for advisory review
  fi

  # Threads Write cannot be proven without posting. If Read works, assume Write is
  # co-scoped on standard PATs; surface the required scope list clearly.
  echo "Required PAT scopes: Code (Read & Write), Pull Request Threads (Read & Write), User Profile (Read)"
  if [ "$CAP_VOTE" = false ]; then
    case "${VOTE_BLOCK_REASON:-}" in
      invalid_reviewer_identity)
        warn "summary + inline comments can still post; reviewer VOTE will be skipped until the PAT belongs to a valid PR-reviewer identity (Code Write alone will not fix this)"
        ;;
      *)
        warn "without a working vote path the summary + inline comments can still post, but the reviewer vote will be skipped"
        ;;
    esac
  fi
}

# =============================================================================
# Generic
# =============================================================================
check_generic() {
  ok "generic platform — no remote API; review will write pr-review-report.md"
  CAP_AUTH=true
  CAP_REPO_READ=true
  CAP_PR_READ=true
  CAP_COMMENT_WRITE=true
  CAP_VOTE=true
  CAP_PUSH=true
}

case "$PLATFORM" in
  github) check_github ;;
  azure)  check_azure ;;
  *)      check_generic ;;
esac

# --- Persist + summary ---
WARN_JOINED=$(printf '%s | ' "${WARNINGS[@]+"${WARNINGS[@]}"}" | sed 's/ | $//')
{
  echo "export PLATFORM=$(printf %q "$PLATFORM")"
  echo "export AUTH_OK=$(printf %q "$CAP_AUTH")"
  echo "export AUTH_USER=$(printf %q "${AUTH_USER:-}")"
  echo "export CAP_REPO_READ=$(printf %q "$CAP_REPO_READ")"
  echo "export CAP_PR_READ=$(printf %q "$CAP_PR_READ")"
  echo "export CAP_COMMENT_WRITE=$(printf %q "$CAP_COMMENT_WRITE")"
  echo "export CAP_VOTE=$(printf %q "$CAP_VOTE")"
  echo "export CAP_PUSH=$(printf %q "$CAP_PUSH")"
  echo "export AUTH_ACCOUNT=$(printf %q "${AUTH_ACCOUNT:-}")"
  echo "export AUTH_DESCRIPTOR_TYPE=$(printf %q "${AUTH_DESCRIPTOR_TYPE:-}")"
  echo "export VOTE_BLOCK_REASON=$(printf %q "${VOTE_BLOCK_REASON:-}")"
  echo "export SCOPES_SEEN=$(printf %q "${SCOPES_SEEN:-}")"
  echo "export PERMISSIONS_WARNINGS=$(printf %q "${WARN_JOINED:-}")"
  echo "export HARD_FAIL=$(printf %q "$HARD_FAIL")"
} > /tmp/pr_permissions.env

echo "---- permissions summary ----"
echo "PLATFORM=${PLATFORM}  AUTH=${CAP_AUTH}  REPO_READ=${CAP_REPO_READ}  PR_READ=${CAP_PR_READ}  COMMENT=${CAP_COMMENT_WRITE}  VOTE=${CAP_VOTE}  PUSH=${CAP_PUSH}"
[ -n "${WARN_JOINED:-}" ] && echo "Warnings: ${WARN_JOINED}"
echo "Wrote /tmp/pr_permissions.env"

if [ "$HARD_FAIL" -ne 0 ]; then
  echo "PERMISSIONS CHECK FAILED — fix auth/scopes before continuing (see docs/platform-setup.md)" >&2
  exit 1
fi
echo "PERMISSIONS CHECK PASSED"
exit 0
