#!/usr/bin/env bash
# lib/azure-devops.sh — Azure DevOps REST API helpers.
#
# Sourced by gather-context.sh, post-start-comment.sh, and post-review.sh.
# This file is the single source of truth for ADO API mechanics — providers/azure-devops.md
# now documents *why* these choices were made, not the literal commands to run.
#
# All functions here run to completion within ONE process (whatever script sourced this
# file), so unlike the old markdown-driven flow, AZURE_ORG/AZURE_PROJECT/AZURE_REPO/API_BASE/
# PR_ID are always freshly resolved in the same invocation that uses them — never assumed
# to survive from an earlier, separate `Bash` tool call.
#
# Requires: AZURE_DEVOPS_TOKEN in the environment (validated by hooks/validate-prerequisites.sh
# for LLM-issued curl commands; scripts here re-check it directly since they may run
# standalone).

ado_auth_header() {
  if [ -z "${AZURE_DEVOPS_TOKEN:-}" ]; then
    echo "ERROR: AZURE_DEVOPS_TOKEN is not set. See docs/platform-setup.md." >&2
    return 1
  fi
  echo "Authorization: Basic $(printf ':%s' "${AZURE_DEVOPS_TOKEN}" | base64 | tr -d '\n')"
}

# ado_parse_remote — parse `git remote get-url origin` into AZURE_HOST, AZURE_ORG,
# AZURE_COLLECTION, AZURE_PROJECT, AZURE_REPO, API_BASE.
#
# Handles all 4 URL shapes seen in the wild (see scripts/tests/fixtures for one of each):
#   1. dev.azure.com/{org}/{project}/_git/{repo}
#   2. dev.azure.com/{org}/{collection}/{project}/_git/{repo}
#   3. {org}.visualstudio.com/{project}/_git/{repo}
#   4. {org}.visualstudio.com/{collection}/{project}/_git/{repo}   (legacy DefaultCollection)
#
# Anchors on the `_git` path segment (project is always immediately before it, repo
# immediately after) so it is robust to the collection segment being present or absent.
ado_parse_remote() {
  local remote
  remote=$(git remote get-url origin 2>/dev/null || echo "")
  if [ -z "$remote" ]; then
    echo "ERROR: could not resolve git remote 'origin'." >&2
    return 1
  fi
  _ado_parse_remote_url "$remote"
}

# _ado_parse_remote_url <url> — pure function, no git dependency, so it's directly testable
# against fixture URLs (see scripts/tests/run.sh) without needing a real git repository.
_ado_parse_remote_url() {
  local remote="$1"
  local remote_clean host path_parts git_line prefix_start project_line

  remote_clean=$(echo "$remote" | sed -E 's|https?://[^@]+@|https://|; s|\.git$||')
  host=$(echo "$remote_clean" | awk -F/ '{print $3}')
  path_parts=$(echo "$remote_clean" | awk -F/ '{for (i=4; i<=NF; i++) print $i}')

  git_line=$(echo "$path_parts" | grep -nx '_git' | head -1 | cut -d: -f1)
  if [ -z "$git_line" ]; then
    echo "ERROR: not an Azure DevOps git URL (no _git segment): $remote_clean" >&2
    return 1
  fi

  AZURE_HOST="$host"
  AZURE_PROJECT=$(echo "$path_parts" | sed -n "$((git_line - 1))p")
  AZURE_REPO=$(echo "$path_parts" | sed -n "$((git_line + 1))p")

  if [ "$AZURE_HOST" = "dev.azure.com" ]; then
    AZURE_ORG=$(echo "$path_parts" | sed -n '1p')
    prefix_start=2
  else
    AZURE_ORG=$(echo "$AZURE_HOST" | cut -d'.' -f1)
    prefix_start=1
  fi

  project_line=$((git_line - 1))
  if [ "$project_line" -gt "$prefix_start" ]; then
    AZURE_COLLECTION=$(echo "$path_parts" \
      | sed -n "${prefix_start},$((project_line - 1))p" \
      | tr '\n' '/' | sed 's|/$||')
  else
    AZURE_COLLECTION=""
  fi

  local host_and_org_path
  if [ "$AZURE_HOST" = "dev.azure.com" ]; then
    host_and_org_path="https://dev.azure.com/${AZURE_ORG}"
  else
    host_and_org_path="https://${AZURE_HOST}"
  fi
  if [ -n "$AZURE_COLLECTION" ]; then
    API_BASE="${host_and_org_path}/${AZURE_COLLECTION}/${AZURE_PROJECT}"
  else
    API_BASE="${host_and_org_path}/${AZURE_PROJECT}"
  fi

  case "$AZURE_PROJECT" in
    ""|"_git"|"DefaultCollection"|"https:")
      echo "ERROR: parsed AZURE_PROJECT='${AZURE_PROJECT}' looks wrong from URL: $remote_clean" >&2
      return 1
      ;;
  esac
  if [ -z "$AZURE_ORG" ] || [ -z "$AZURE_REPO" ]; then
    echo "ERROR: parsed AZURE_ORG='${AZURE_ORG}' AZURE_REPO='${AZURE_REPO}' from URL: $remote_clean" >&2
    return 1
  fi

  export AZURE_HOST AZURE_ORG AZURE_COLLECTION AZURE_PROJECT AZURE_REPO API_BASE
}

# _ado_extract_pr_number_from_arg <arg> — pure function, no git/curl dependency, directly
# testable. Prints a PR number if `arg` is an Azure DevOps PR URL, prints nothing otherwise.
# ADO PR URLs use the singular, differently-spelled segment `pullrequest` (not `pullrequests`),
# e.g. https://dev.azure.com/org/project/_git/repo/pullrequest/123[?_a=files].
_ado_extract_pr_number_from_arg() {
  echo "$1" | grep -oiE '/pullrequest/[0-9]+' | grep -oE '[0-9]+' | head -1
}

# ado_resolve_pr_number [explicit-pr-number|pr-url|branch-name] — sets PR_ID and
# TRIGGER_SOURCE (one of: chat-url | chat-number | explicit-branch | current-branch — recorded
# so the state file can show *how* the PR was identified, not just which one).
#
# Precedence mirrors gh_resolve_pr_number:
#   1. A PR URL (Agent Studio chat re-review trigger).
#   2. A bare PR number.
#   3. A branch name, explicitly passed — looked up via the same sourceRefName search the
#      current-branch fallback below uses. Previously any non-numeric explicit argument was
#      silently ignored and this function fell through to the *current* branch instead,
#      meaning an explicit branch name was never actually honored.
#   4. Nothing — comment-triggered runs, resolved from the currently checked-out branch.
ado_resolve_pr_number() {
  local explicit="${1:-}"
  local from_url

  from_url=$(_ado_extract_pr_number_from_arg "$explicit")
  if [ -n "$from_url" ]; then
    PR_ID="$from_url"
    TRIGGER_SOURCE="chat-url"
    export PR_ID TRIGGER_SOURCE
    return 0
  fi

  if [ -n "$explicit" ] && echo "$explicit" | grep -qE '^[0-9]+$'; then
    PR_ID="$explicit"
    TRIGGER_SOURCE="chat-number"
    export PR_ID TRIGGER_SOURCE
    return 0
  fi

  local branch auth
  if [ -n "$explicit" ]; then
    branch="$explicit"
    TRIGGER_SOURCE="explicit-branch"
  elif [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "HEAD" ]; then
    branch=$(git branch --contains "$(git rev-parse HEAD)" 2>/dev/null \
      | sed 's|^[* ] *||' | grep -v '^(' | head -1)
    TRIGGER_SOURCE="current-branch"
  else
    branch=$(git rev-parse --abbrev-ref HEAD)
    TRIGGER_SOURCE="current-branch"
  fi

  if [ -z "$branch" ]; then
    echo "ERROR: could not resolve a branch name to look up the PR." >&2
    return 1
  fi

  auth=$(ado_auth_header) || return 1
  PR_ID=$(curl -sS -H "$auth" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${branch}&searchCriteria.status=active&api-version=7.1" \
    | python3 -c "import sys,json
try:
    prs = json.load(sys.stdin)['value']
    print(prs[0]['pullRequestId'] if prs else '')
except Exception:
    print('')")

  if [ -z "$PR_ID" ]; then
    echo "ERROR: no active PR found for branch '${branch}'." >&2
    return 1
  fi
  export PR_ID TRIGGER_SOURCE
}

# ado_fetch_pr_metadata — sets PR_TITLE, PR_DESC, PR_SOURCE, PR_TARGET, PR_AUTHOR, PR_AUTHOR_EMAIL.
ado_fetch_pr_metadata() {
  local auth pr_json
  auth=$(ado_auth_header) || return 1
  pr_json=$(curl -sS -H "$auth" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1")

  if [ -z "$pr_json" ] || ! echo "$pr_json" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "WARN: PR metadata fetch returned empty/invalid JSON — title/description will be blank." >&2
    PR_TITLE=""; PR_DESC=""; PR_SOURCE=""; PR_TARGET=""; PR_AUTHOR=""; PR_AUTHOR_EMAIL=""
  else
    eval "$(echo "$pr_json" | python3 -c "
import sys, json, shlex
d = json.load(sys.stdin)
def esc(v): return shlex.quote(str(v))
print('PR_TITLE=' + esc(d.get('title','')))
print('PR_DESC=' + esc(d.get('description','')))
print('PR_SOURCE=' + esc(d.get('sourceRefName','').replace('refs/heads/','')))
print('PR_TARGET=' + esc(d.get('targetRefName','').replace('refs/heads/','')))
print('PR_AUTHOR=' + esc(d.get('createdBy',{}).get('displayName','')))
print('PR_AUTHOR_EMAIL=' + esc(d.get('createdBy',{}).get('uniqueName','')))
")"
  fi
  export PR_TITLE PR_DESC PR_SOURCE PR_TARGET PR_AUTHOR PR_AUTHOR_EMAIL
}

# ado_ensure_correct_branch — comment-triggered runs land on the default branch because
# the webhook payload has no sourceRefName. Detect and fix before diffing.
# Only acts when GIT_REF is unset (initial/push-update runs already have the right ref).
ado_ensure_correct_branch() {
  if [ -n "${GIT_REF:-}" ]; then
    return 0
  fi
  if [ -z "${PR_SOURCE:-}" ]; then
    echo "WARN: no PR source branch resolved — continuing on current branch." >&2
    return 0
  fi

  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  if [ "$current_branch" = "$PR_SOURCE" ]; then
    return 0
  fi

  echo "Comment-triggered run: checking out PR source branch '${PR_SOURCE}' (was on '${current_branch}')" >&2
  git fetch origin "refs/heads/${PR_SOURCE}:${PR_SOURCE}" 2>/dev/null \
    || git fetch origin "refs/heads/${PR_SOURCE}" 2>/dev/null
  git checkout "$PR_SOURCE" 2>/dev/null || git checkout -b "$PR_SOURCE" FETCH_HEAD 2>/dev/null \
    || echo "WARN: could not check out '${PR_SOURCE}' — diff will be computed against current HEAD." >&2
}

# ado_detect_prior_review — writes /tmp/pr_prior_findings.jsonl (one finding thread per line)
# and sets PRIOR_SUMMARY_SHA + DETECTION_STATUS (ok|failed|no-prior-review).
#
# This is the exact step that broke in the reported bug: it used to be re-typed by the LLM
# in a separate `Bash` call from the one that resolved API_BASE/PR_ID, so those vars were
# empty and the curl hit a malformed URL. Here it runs in the same process as
# ado_parse_remote/ado_resolve_pr_number, so that failure mode is structurally impossible.
ado_detect_prior_review() {
  local auth
  auth=$(ado_auth_header) || { DETECTION_STATUS="failed"; export DETECTION_STATUS; return 0; }

  curl -sS -H "$auth" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?\$top=1000&api-version=7.1" \
    > /tmp/pr_threads.json

  if [ ! -s /tmp/pr_threads.json ] || ! python3 -c "import json; json.load(open('/tmp/pr_threads.json'))" 2>/dev/null; then
    echo "WARN: prior-review detection call failed or returned invalid JSON — treating as detection failure, not 'no prior review'. Raw response:" >&2
    cat /tmp/pr_threads.json >&2
    DETECTION_STATUS="failed"
    : > /tmp/pr_prior_findings.jsonl
    PRIOR_SUMMARY_SHA=""
    export DETECTION_STATUS PRIOR_SUMMARY_SHA
    return 0
  fi

  python3 - <<'PY' > /tmp/pr_prior_findings.jsonl
import json
data = json.load(open('/tmp/pr_threads.json'))
def prop(props, key):
    v = (props or {}).get(key)
    if isinstance(v, dict):
        return v.get("$value")
    return v
for t in data.get("value", []):
    props = t.get("properties") or {}
    if prop(props, "pr-reviewer.kind") != "finding":
        continue
    fid = prop(props, "pr-reviewer.fid")
    if not fid:
        continue
    status = t.get("status", "active")
    file_path = (t.get("threadContext") or {}).get("filePath", "") or ""
    print(json.dumps({
        "fid": fid,
        "status": "resolved" if status in ("fixed", "closed", "wontFix", "byDesign") else "open",
        "thread_ref": t["id"],
        "file": file_path.lstrip("/"),
        "severity": prop(props, "pr-reviewer.severity") or "",
        "category": prop(props, "pr-reviewer.category") or "",
    }))
PY

  PRIOR_SUMMARY_SHA=$(python3 - <<'PY'
import json
data = json.load(open('/tmp/pr_threads.json'))
def prop(props, key):
    v = (props or {}).get(key)
    return v.get("$value") if isinstance(v, dict) else v
shas = [prop(t.get("properties") or {}, "pr-reviewer.sha")
        for t in data.get("value", [])
        if prop(t.get("properties") or {}, "pr-reviewer.kind") == "summary"]
print([s for s in shas if s][-1] if any(shas) else "")
PY
)
  DETECTION_STATUS="ok"
  export DETECTION_STATUS PRIOR_SUMMARY_SHA
}

# ado_post_comment_thread <body-file> [properties-json-extra] — posts a generic (non-inline)
# comment thread. properties-json-extra is a JSON object fragment (e.g. '"pr-reviewer.kind":"summary","pr-reviewer.sha":"abc"')
# merged into the properties object. Prints the HTTP status; caller checks $? / stdout.
ado_post_comment_thread() {
  local body_file="$1" extra_props="${2:-}" auth payload
  auth=$(ado_auth_header) || return 1

  payload=$(EXTRA_PROPS="$extra_props" python3 - "$body_file" <<'PY'
import json, os, sys
body = open(sys.argv[1]).read()
props = {"Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1}
extra = os.environ.get("EXTRA_PROPS", "").strip()
if extra:
    props.update(json.loads("{" + extra + "}"))
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": props,
}))
PY
)

  local resp status
  resp=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" -H "$auth" \
    -X POST --data "$payload" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1")
  status=$(echo "$resp" | sed -n 's/^HTTP_STATUS://p')
  if echo "$status" | grep -qE '^2'; then
    echo "Thread posted (HTTP $status)"
    return 0
  else
    echo "WARN: thread post failed HTTP $status — body: $(echo "$resp" | sed '$d')" >&2
    return 1
  fi
}

# ado_post_inline_finding <body-file> <fid> <repo-relative-file> <line> [severity] [category] —
# posts one inline finding thread with threadContext + the pr-reviewer.kind=finding / fid / sha
# properties. severity/category are persisted too (when given) so a future re-review can
# recompute the verdict correctly for a carried-over finding the finder fails to re-surface,
# and can narrow which category to try when re-verifying the finding's fid against HEAD.
ado_post_inline_finding() {
  local body_file="$1" fid="$2" file_path="$3" line="$4" severity="${5:-}" category="${6:-}" auth payload
  auth=$(ado_auth_header) || return 1

  payload=$(FID="$fid" FILE_PATH="$file_path" LINE_NUMBER="$line" SHA="$HEAD_SHA" \
            SEVERITY="$severity" CATEGORY="$category" python3 - "$body_file" <<'PY'
import json, os, sys
body = open(sys.argv[1]).read()
properties = {
    "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1,
    "pr-reviewer.kind": "finding",
    "pr-reviewer.fid": os.environ["FID"],
    "pr-reviewer.sha": os.environ["SHA"],
}
if os.environ.get("SEVERITY"):
    properties["pr-reviewer.severity"] = os.environ["SEVERITY"]
if os.environ.get("CATEGORY"):
    properties["pr-reviewer.category"] = os.environ["CATEGORY"]
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": properties,
    "threadContext": {
        "filePath": "/" + os.environ["FILE_PATH"].lstrip("/"),
        "rightFileStart": {"line": int(os.environ["LINE_NUMBER"]), "offset": 1},
        "rightFileEnd":   {"line": int(os.environ["LINE_NUMBER"]), "offset": 1},
    },
}))
PY
)

  local resp status
  resp=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" -H "$auth" \
    -X POST --data "$payload" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1")
  status=$(echo "$resp" | sed -n 's/^HTTP_STATUS://p')
  if echo "$status" | grep -qE '^2'; then
    return 0
  else
    echo "HTTP $status: $(echo "$resp" | sed '$d')"
    return 1
  fi
}

# ado_reply_to_thread <thread-id> <body-file>
ado_reply_to_thread() {
  local thread_id="$1" body_file="$2" auth payload
  auth=$(ado_auth_header) || return 1
  payload=$(python3 -c "import json,sys; print(json.dumps({'content': open(sys.argv[1]).read(), 'commentType': 1}))" "$body_file")
  curl -sS -o /dev/null \
    -H "Content-Type: application/json" -H "$auth" \
    -X POST --data "$payload" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${thread_id}/comments?api-version=7.1"
}

# ado_set_thread_status <thread-id> <status>  (e.g. "fixed")
ado_set_thread_status() {
  local thread_id="$1" status_value="$2" auth resp status
  auth=$(ado_auth_header) || return 1
  resp=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" -H "$auth" \
    -X PATCH -d "{\"status\":\"${status_value}\"}" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${thread_id}?api-version=7.1")
  status=$(echo "$resp" | sed -n 's/^HTTP_STATUS://p')
  echo "$status" | grep -qE '^2'
}

# ado_cast_vote <vote-int> — resolves the reviewer id then PUTs the vote.
ado_cast_vote() {
  local vote="$1" auth reviewer_id resp status
  auth=$(ado_auth_header) || return 1

  reviewer_id=$(curl -sS -H "$auth" \
    "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1" \
    | python3 -c "import sys,json
try:
    print(json.load(sys.stdin).get('id',''))
except Exception:
    print('')")

  if [ -z "$reviewer_id" ]; then
    echo "WARN: could not resolve reviewer ID — vote will not be cast" >&2
    return 1
  fi

  resp=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" -H "$auth" \
    -X PUT \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/reviewers/${reviewer_id}?api-version=7.1" \
    -d "{\"vote\": ${vote}, \"id\": \"${reviewer_id}\"}")
  status=$(echo "$resp" | sed -n 's/^HTTP_STATUS://p')
  if echo "$status" | grep -qE '^2'; then
    echo "Vote ${vote} cast (HTTP $status)"
    return 0
  else
    echo "WARN: vote PUT returned HTTP $status — body: $(echo "$resp" | sed '$d')" >&2
    return 1
  fi
}
