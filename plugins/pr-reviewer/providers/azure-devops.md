# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

**Platform identity:** after Step 1 / the setup script, the canonical internal value is `PLATFORM=azure`. The Xianix Agent/Executor standard env string is `azuredevops` (no hyphen) — treat that (and `azure-devops` / `azure_devops` / `ado`) as Azure DevOps. Never call `gh` when origin is Azure, even if `PLATFORM` was left unset or still holds the raw `azuredevops` string.

## Prerequisites

The Azure DevOps REST API is called directly via `curl` using a Personal Access Token (PAT).

Required environment variable:

| Variable | Purpose |
|---|---|
| `AZURE_DEVOPS_TOKEN` | Azure DevOps PAT — must have `Code (Read & Write)` (`vso.code_write` — casting the reviewer vote and fix-mode `git push` need write; plain `Code (Read)` cannot vote), `Pull Request Threads (Read & Write)`, and `User Profile (Read)` scopes |

> **Note on var-name hygiene:** reference the token as `AZURE_DEVOPS_TOKEN` (**underscores**) everywhere in bash. The framework may inject the secret under the dashed key `AZURE-DEVOPS-TOKEN`; bash cannot reference hyphenated names (a dashed reference parses as `$AZURE` minus `DEVOPS-TOKEN`) and would silently send an empty password. The Xianix Executor re-exports any dashed env var as an underscored alias, so `AZURE_DEVOPS_TOKEN` is the referenceable name. If it is empty but a dashed `AZURE-DEVOPS-TOKEN` exists, the plugin's `PreToolUse` hook blocks with a re-export command (`export AZURE_DEVOPS_TOKEN="$(printenv AZURE-DEVOPS-TOKEN)"`).
>
> **Never echo secrets.** Do not print the PAT (`echo "$AZURE_DEVOPS_TOKEN"`, `env | grep …`, unredirected `printenv`). Presence-check only: `echo "AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}"`.

Optional — used to override values parsed from the remote URL:

| Variable | Default |
|---|---|
| `AZURE_ORG` | Parsed from remote URL |
| `AZURE_PROJECT` | Parsed from remote URL |
| `AZURE_REPO` | Parsed from remote URL |

### Variable names — use ONLY these for API calls

| Use | Do NOT invent |
|---|---|
| `API_BASE` | `https://dev.azure.com/${AZURE_DEVOPS_ORG}/...` hand-built URLs |
| `AZURE_REPO` | `AZURE_DEVOPS_REPO` |
| `PR_ID` | `PR_NUMBER` in REST paths (set `PR_ID` from the argument, then use `PR_ID` everywhere) |
| `AZURE_ORG`, `AZURE_PROJECT` | `AZURE_DEVOPS_ORG`, `AZURE_DEVOPS_PROJECT` |

`source /tmp/pr_azure.env` (written in Step 2) restores all of the above. **Never** hard-code org/project/repo from the PR title or argument — always parse from `git remote get-url origin`.

### Input files — use ONLY these names

| Purpose | Path |
|---|---|
| Full report body | `/tmp/pr_thread_body.md` |
| Inline findings (JSONL) | `/tmp/pr_inline_findings.jsonl` |

The posting script below accepts common agent mistakes (`/tmp/pr_review_summary.md`, `/tmp/pr_findings.jsonl`) as fallbacks, but always **write** the canonical paths when compiling the report.

## Parsing the Remote URL

Extract org, project, and repo from the remote URL before making any API calls. Strip any embedded basic-auth (`user@`) component first — it appears in remotes injected by CI runners.

Azure DevOps uses **four** URL shapes in the wild. **All must be handled** — the legacy `DefaultCollection` form is common in tenants that migrated from on-prem TFS, and getting it wrong means inline threads silently 4xx (plain threads still post because the repo can be resolved at collection level — that is the #1 cause of "main comment posts but inline comments don't show up").

| # | Shape | Example |
|---|---|---|
| 1 | `dev.azure.com/{org}/{project}/_git/{repo}` | `https://dev.azure.com/contoso/Web/_git/api` |
| 2 | `dev.azure.com/{org}/{collection}/{project}/_git/{repo}` | rare — usually only seen on imported orgs |
| 3 | `{org}.visualstudio.com/{project}/_git/{repo}` | `https://contoso.visualstudio.com/Web/_git/api` |
| 4 | `{org}.visualstudio.com/{collection}/{project}/_git/{repo}` | `https://contoso.visualstudio.com/DefaultCollection/Web/_git/api` |

Use the parser below — it anchors on the `_git` segment (always exactly one position before the repo and one position after the project), so it works for all four shapes.

> **Shortcut:** if Step 2 already ran the starting-comment script, `source /tmp/pr_azure.env` restores `API_BASE`, `AZURE_REPO`, `PR_ID`, etc. Re-run the parser only when that file is missing.

```bash
REMOTE=$(git remote get-url origin)

# Normalise SSH remotes to the canonical https shape first, so the _git-anchored
# parser below only has to handle one format. SSH shapes in the wild:
#   git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
#   ssh://git@ssh.dev.azure.com/v3/{org}/{project}/{repo}
#   {org}@vs-ssh.visualstudio.com:v3/{org}/{project}/{repo}
if echo "$REMOTE" | grep -qE '(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)'; then
  V3_PATH=$(echo "$REMOTE" | sed -E 's|^ssh://||; s|^[^@]+@||; s|^[^:/]+[:/]+||')
  V3_ORG=$(echo "$V3_PATH" | cut -d/ -f2)
  V3_PROJECT=$(echo "$V3_PATH" | cut -d/ -f3)
  V3_REPO=$(echo "$V3_PATH" | cut -d/ -f4)
  REMOTE="https://dev.azure.com/${V3_ORG}/${V3_PROJECT}/_git/${V3_REPO}"
fi

# Strip optional "user@" basic-auth prefix and any trailing .git
REMOTE_CLEAN=$(echo "$REMOTE" | sed -E 's|https?://[^@]+@|https://|; s|\.git$||')

# Extract host and the path-after-host
AZURE_HOST=$(echo "$REMOTE_CLEAN" | awk -F/ '{print $3}')
PATH_PARTS=$(echo "$REMOTE_CLEAN" | awk -F/ '{for (i=4; i<=NF; i++) print $i}')

# Anchor on the _git segment. project = segment immediately before, repo = immediately after.
GIT_LINE=$(echo "$PATH_PARTS" | grep -nx '_git' | head -1 | cut -d: -f1)
if [ -z "$GIT_LINE" ]; then
  echo "ERROR: not an Azure DevOps git URL (no _git segment): $REMOTE_CLEAN" >&2
  return 1 2>/dev/null || exit 1
fi
AZURE_PROJECT=$(echo "$PATH_PARTS" | sed -n "$((GIT_LINE - 1))p")
AZURE_REPO=$(echo    "$PATH_PARTS" | sed -n "$((GIT_LINE + 1))p")

# Determine org and the optional collection prefix (segments between org and project)
if [ "$AZURE_HOST" = "dev.azure.com" ]; then
  AZURE_ORG=$(echo "$PATH_PARTS" | sed -n '1p')
  PREFIX_START=2
else
  # *.visualstudio.com — org is the subdomain
  AZURE_ORG=$(echo "$AZURE_HOST" | cut -d'.' -f1)
  PREFIX_START=1
fi

PROJECT_LINE=$((GIT_LINE - 1))
# Collection exists iff there is ≥1 path segment between the org/host and the project.
if [ "$PROJECT_LINE" -gt "$PREFIX_START" ]; then
  AZURE_COLLECTION=$(echo "$PATH_PARTS" \
    | sed -n "${PREFIX_START},$((PROJECT_LINE - 1))p" \
    | tr '\n' '/' | sed 's|/$||')
else
  AZURE_COLLECTION=""
fi

# API_BASE always includes the project — required for inline threads with threadContext.
# Including the collection (e.g. DefaultCollection) when present makes the URL canonical.
HOST_AND_ORG_PATH=$(
  if [ "$AZURE_HOST" = "dev.azure.com" ]; then
    echo "https://dev.azure.com/${AZURE_ORG}"
  else
    echo "https://${AZURE_HOST}"
  fi
)
if [ -n "$AZURE_COLLECTION" ]; then
  API_BASE="${HOST_AND_ORG_PATH}/${AZURE_COLLECTION}/${AZURE_PROJECT}"
else
  API_BASE="${HOST_AND_ORG_PATH}/${AZURE_PROJECT}"
fi

# Sanity-assert the parse — refuse to continue on garbage. Catches the historical bug where
# AZURE_PROJECT silently became "DefaultCollection".
case "$AZURE_PROJECT" in
  ""|"_git"|"DefaultCollection"|"https:")
    echo "ERROR: parsed AZURE_PROJECT='${AZURE_PROJECT}' looks wrong from URL: $REMOTE_CLEAN" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
[ -z "$AZURE_ORG" ] || [ -z "$AZURE_REPO" ] && {
  echo "ERROR: parsed AZURE_ORG='${AZURE_ORG}' AZURE_REPO='${AZURE_REPO}' from URL: $REMOTE_CLEAN" >&2
  return 1 2>/dev/null || exit 1
}

echo "Azure DevOps target: org=${AZURE_ORG} collection=${AZURE_COLLECTION:-<none>} project=${AZURE_PROJECT} repo=${AZURE_REPO}"
echo "API_BASE=${API_BASE}"

# Export so subsequent python heredocs can read them via os.environ
export AZURE_HOST AZURE_ORG AZURE_COLLECTION AZURE_PROJECT AZURE_REPO API_BASE
```

Use `${API_BASE}` in place of a hardcoded host for **every** API call below.

> **Why this matters:** prior versions used `cut -d'/' -f4` on the legacy URL, which returns `DefaultCollection` when the URL is `https://{org}.visualstudio.com/DefaultCollection/{project}/_git/{repo}`. The resulting `API_BASE` skipped the project segment. Plain threads still post (the repo is unique within the collection) but inline threads with `threadContext.filePath` 4xx because the file context can't be resolved without a project. The parser above anchors on `_git` so the project is always picked correctly.

---

## Resolving the PR Number

If no PR number was passed as an argument, find the active PR for the current branch.

In a detached-HEAD worktree (which is how the Xianix Executor runs the plugin), `git rev-parse --abbrev-ref HEAD` returns the literal string `HEAD`. Resolve the source branch from `git branch --contains` instead, or pass the branch name explicitly.

```bash
BRANCH="${BRANCH_ARG:-}"
if [ -z "$BRANCH" ]; then
  if [ "$(git rev-parse --abbrev-ref HEAD)" = "HEAD" ]; then
    BRANCH=$(git branch --contains "$(git rev-parse HEAD)" \
      | sed 's|^[* ] *||' | grep -v '^(' | head -1)
  else
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
  fi
fi
BRANCH="${BRANCH#refs/heads/}"

PR_ID=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH}&searchCriteria.status=active&api-version=7.1" \
  | python3 -c "import sys,json; prs=json.load(sys.stdin)['value']; print(prs[0]['pullRequestId'] if prs else '')")
export PR_ID
```

If empty, the branch has no open PR — output a warning and skip posting.

---

## Fetching PR Metadata

The PR object on Azure DevOps is the source of truth for title, description, source/target branches, and the author display name. **Use these instead of commit messages** when building the report header — commit subjects can drift from the actual PR title.

```bash
PR_JSON=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1")

PR_TITLE=$(echo       "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('title',''))")
PR_DESC=$(echo        "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('description',''))")
PR_SOURCE=$(echo      "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sourceRefName','').replace('refs/heads/',''))")
PR_TARGET=$(echo      "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('targetRefName','').replace('refs/heads/',''))")
PR_AUTHOR=$(echo      "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('createdBy',{}).get('displayName',''))")
PR_AUTHOR_EMAIL=$(echo "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('createdBy',{}).get('uniqueName',''))")

export PR_TITLE PR_DESC PR_SOURCE PR_TARGET PR_AUTHOR PR_AUTHOR_EMAIL
```

Use `$PR_TARGET` as the **base branch** for diffs. Resolve it to a concrete SHA the same way Step 3 of `commands/pr-review.md` does — **always `git fetch origin "refs/heads/${PR_TARGET}"` first and use `FETCH_HEAD` as the base tip** (local `refs/remotes/origin/${PR_TARGET}` or `refs/heads/${PR_TARGET}` may be stale and would inflate the diff with commits already merged into the target), then take `git merge-base` against the PR head. Remember: if `refs/pull/<n>/merge` was checked out, the PR head is `HEAD^2`, not `HEAD`.

---

## Detecting a prior review (re-review awareness)

Called from Step 3 of `commands/pr-review.md` to decide initial vs. re-review mode. On Azure DevOps the plugin's identity metadata lives in thread **`properties`** (HTML comments are not reliably hidden in the web UI), so detection reads `properties["pr-reviewer.fid"]` rather than scanning comment text. The same thread listing also writes **all open inline threads** (humans, bots, and this plugin) to `/tmp/pr_open_threads.jsonl` for external-thread awareness, dedup, and reply-only validation.

**Prerequisites:** `/tmp/pr_azure.env` from the Step 2 starting-comment script (`API_BASE`, `AZURE_REPO`, `PR_ID`) and `AZURE_DEVOPS_TOKEN`.

**Prefer the plugin script (one Bash call) — do not reinvent this flow.** Agents that invent `THREADS_JSON=$(curl …)` then `json.load` crash on 401 HTML / empty bodies. The script paginates with `x-ms-continuationtoken`, checks HTTP status before parsing JSON, and writes `/tmp/pr_prior.env` so `PRIOR_SUMMARY_SHA` survives across tool calls.

```bash
ADO_DETECT="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/ado-detect-prior.sh}"
if [ -z "${ADO_DETECT:-}" ] || [ ! -f "$ADO_DETECT" ]; then
  ADO_DETECT=$(find "${CLAUDE_PLUGIN_ROOT:-.}" ~/.claude/plugins -path '*/pr-reviewer/scripts/ado-detect-prior.sh' 2>/dev/null | head -1)
fi
[ -n "${ADO_DETECT:-}" ] && [ -f "$ADO_DETECT" ] || {
  echo "ERROR: scripts/ado-detect-prior.sh not found — refuse to invent a threads curl" >&2
  exit 1
}
bash "$ADO_DETECT"
# shellcheck disable=SC1091
source /tmp/pr_prior.env   # PRIOR_SUMMARY_SHA
```

**Outputs:** `/tmp/pr_prior_findings.jsonl`, `/tmp/pr_open_threads.jsonl`, `/tmp/pr_threads.json`, `/tmp/pr_prior.env` (`PRIOR_SUMMARY_SHA`).

If `/tmp/pr_prior_findings.jsonl` is empty, the run is an **initial** review. Plugin reconciliation matches on `fid` only, so `file`/`line` are not needed on prior findings. `/tmp/pr_open_threads.jsonl` may still be non-empty when other reviewers left open inline comments (used for dedup and external-thread replies even on the first plugin run).

<details>
<summary>Reference: what the script does (do not paste as a shortened curl)</summary>

1. Presence-check `AZURE_DEVOPS_TOKEN` (underscores); hint re-export if only dashed `AZURE-DEVOPS-TOKEN` exists.
2. `GET .../pullRequests/{id}/threads` with pagination; **fail on non-2xx or non-JSON** (never `json.load` an error page).
3. Filter plugin findings via `properties["pr-reviewer.fid"]` (body HTML marker fallback).
4. Write all open `threadContext` inline threads to `/tmp/pr_open_threads.jsonl`.
5. Export the latest summary `sha` to `/tmp/pr_prior.env`.

</details>

---

## Markdown in PR threads

This plugin posts via the **Git** [Pull Request Threads](https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pull-request-threads/create?view=azure-devops-rest-7.1) API (`.../pullrequests/.../threads`). That is **not** the same as Work Item Tracking discussion comments.

For PR threads, put Markdown in `comments[].content`. Also set thread `properties` so the web UI treats the thread as Markdown-capable (otherwise headings, tables, and emphasis can appear as raw text).

**Critical — PropertiesCollection write format.** Azure returns properties as `{"$type":"…","$value":…}` and often **rejects creates** that send bare custom strings (e.g. `"pr-reviewer.kind": "summary"`). That is a common cause of "review-in-progress posts, but the final summary never appears": progress uses only `SupportsMarkdown`, while the summary historically added bare custom keys and got HTTP 400. Always write properties like this:

```json
"properties": {
  "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": { "$type": "System.Int32", "$value": 1 },
  "pr-reviewer.kind": { "$type": "System.String", "$value": "summary" },
  "pr-reviewer.sha": { "$type": "System.String", "$value": "<HEAD_SHA>" }
}
```

Also append an HTML marker to the comment body (`<!-- pr-reviewer:v1.2 kind=summary sha=… -->`) so re-review detection still works if properties are stripped. `scripts/ado-post-review.sh` does both and retries `full → markdown-only → bare` until the summary thread lands.

---

## Posting the Starting Comment

Before running any analysis, post a plain PR comment thread to inform the author that a review is underway. This fires as the very first action on Azure DevOps, before sub-agents are launched.

**This block is self-contained.** Run it as a **single** `Bash` call immediately after platform detection — do **not** assume `API_BASE` / `PR_ID` already exist (shell state does not persist between tool calls). Set `PR_NUMBER` from the invocation argument when a numeric PR id was given; set `BRANCH_ARG` when the executor passes a branch ref (e.g. `feat/foo` or `refs/heads/feat/foo`); leave both empty to resolve from the current branch.

```bash
set -euo pipefail

# --- 0. Token ---
if [ -z "${AZURE_DEVOPS_TOKEN:-}" ]; then
  echo "WARN: AZURE_DEVOPS_TOKEN unset — skipping review-in-progress comment" >&2
  exit 0
fi

# --- 1. Parse remote → API_BASE / AZURE_REPO (same rules as "Parsing the Remote URL") ---
REMOTE=$(git remote get-url origin)
if echo "$REMOTE" | grep -qE '(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)'; then
  V3_PATH=$(echo "$REMOTE" | sed -E 's|^ssh://||; s|^[^@]+@||; s|^[^:/]+[:/]+||')
  REMOTE="https://dev.azure.com/$(echo "$V3_PATH" | cut -d/ -f2)/$(echo "$V3_PATH" | cut -d/ -f3)/_git/$(echo "$V3_PATH" | cut -d/ -f4)"
fi
REMOTE_CLEAN=$(echo "$REMOTE" | sed -E 's|https?://[^@]+@|https://|; s|\.git$||')
AZURE_HOST=$(echo "$REMOTE_CLEAN" | awk -F/ '{print $3}')
PATH_PARTS=$(echo "$REMOTE_CLEAN" | awk -F/ '{for (i=4; i<=NF; i++) print $i}')
GIT_LINE=$(echo "$PATH_PARTS" | grep -nx '_git' | head -1 | cut -d: -f1 || true)
if [ -z "$GIT_LINE" ]; then
  echo "WARN: not an Azure DevOps git URL — skipping review-in-progress comment" >&2
  exit 0
fi
AZURE_PROJECT=$(echo "$PATH_PARTS" | sed -n "$((GIT_LINE - 1))p")
AZURE_REPO=$(echo    "$PATH_PARTS" | sed -n "$((GIT_LINE + 1))p")
if [ "$AZURE_HOST" = "dev.azure.com" ]; then
  AZURE_ORG=$(echo "$PATH_PARTS" | sed -n '1p')
  PREFIX_START=2
else
  AZURE_ORG=$(echo "$AZURE_HOST" | cut -d'.' -f1)
  PREFIX_START=1
fi
PROJECT_LINE=$((GIT_LINE - 1))
if [ "$PROJECT_LINE" -gt "$PREFIX_START" ]; then
  AZURE_COLLECTION=$(echo "$PATH_PARTS" | sed -n "${PREFIX_START},$((PROJECT_LINE - 1))p" | tr '\n' '/' | sed 's|/$||')
else
  AZURE_COLLECTION=""
fi
if [ "$AZURE_HOST" = "dev.azure.com" ]; then
  HOST_AND_ORG_PATH="https://dev.azure.com/${AZURE_ORG}"
else
  HOST_AND_ORG_PATH="https://${AZURE_HOST}"
fi
if [ -n "$AZURE_COLLECTION" ]; then
  API_BASE="${HOST_AND_ORG_PATH}/${AZURE_COLLECTION}/${AZURE_PROJECT}"
else
  API_BASE="${HOST_AND_ORG_PATH}/${AZURE_PROJECT}"
fi
case "$AZURE_PROJECT" in
  ""|"_git"|"DefaultCollection"|"https:")
    echo "WARN: bad AZURE_PROJECT='${AZURE_PROJECT}' from $REMOTE_CLEAN — skipping review-in-progress comment" >&2
    exit 0
    ;;
esac
if [ -z "$AZURE_ORG" ] || [ -z "$AZURE_REPO" ]; then
  echo "WARN: could not parse org/repo from $REMOTE_CLEAN — skipping review-in-progress comment" >&2
  exit 0
fi

# Persist parse results immediately so Step 3 / posting can proceed even if the
# progress comment is skipped (no PR id yet, soft-fail later, etc.).
write_azure_env() {
  export AZURE_HOST AZURE_ORG AZURE_COLLECTION AZURE_PROJECT AZURE_REPO API_BASE PR_ID
  {
    echo "export AZURE_HOST=$(printf %q "$AZURE_HOST")"
    echo "export AZURE_ORG=$(printf %q "$AZURE_ORG")"
    echo "export AZURE_COLLECTION=$(printf %q "${AZURE_COLLECTION:-}")"
    echo "export AZURE_PROJECT=$(printf %q "$AZURE_PROJECT")"
    echo "export AZURE_REPO=$(printf %q "$AZURE_REPO")"
    echo "export API_BASE=$(printf %q "$API_BASE")"
    echo "export PR_ID=$(printf %q "${PR_ID:-}")"
  } > /tmp/pr_azure.env
}
PR_ID=""
write_azure_env
echo "Azure DevOps target: org=${AZURE_ORG} project=${AZURE_PROJECT} repo=${AZURE_REPO}"
echo "API_BASE=${API_BASE}"

# --- 2. Resolve PR_ID (argument first, else active PR for current branch) ---
PR_ID="${PR_NUMBER:-}"
if [ -z "$PR_ID" ]; then
  BRANCH="${BRANCH_ARG:-}"
  if [ -z "$BRANCH" ] && [ "$(git rev-parse --abbrev-ref HEAD)" = "HEAD" ]; then
    BRANCH=$(git branch --contains "$(git rev-parse HEAD)" \
      | sed 's|^[* ] *||' | grep -v '^(' | head -1 || true)
  elif [ -z "$BRANCH" ]; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
  fi
  # Strip refs/heads/ if the executor passed a full ref
  BRANCH="${BRANCH#refs/heads/}"
  if [ -z "${BRANCH:-}" ] || [ "$BRANCH" = "HEAD" ]; then
    echo "WARN: no PR number and could not resolve branch — skipping review-in-progress comment" >&2
    exit 0
  fi
  PR_ID=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH}&searchCriteria.status=active&api-version=7.1" \
    | python3 -c "import sys,json; prs=json.load(sys.stdin).get('value',[]); print(prs[0]['pullRequestId'] if prs else '')" 2>/dev/null || true)
fi
if [ -z "$PR_ID" ]; then
  echo "WARN: no open PR found — skipping review-in-progress comment" >&2
  exit 0
fi
write_azure_env
echo "PR=#${PR_ID}"

# --- 3. Post the progress thread ---
PLUGIN_VERSION=$(grep -hom1 '"version"[^,}]*' ~/.claude/plugins/pr-reviewer/.claude-plugin/plugin.json \
  "$HOME/Library/Application Support/Claude/plugins/pr-reviewer/.claude-plugin/plugin.json" 2>/dev/null \
  | cut -d'"' -f4 || true)
PLUGIN_VERSION=${PLUGIN_VERSION:-unknown}

cat > /tmp/pr_progress_body.md <<BODY
🔍 PR Review in Progress

Claude Code is analyzing this pull request. The review will be posted here shortly.

PR Reviewer (${PLUGIN_VERSION})
BODY

python3 - <<'PY' > /tmp/pr_thread_payload.json
import json
body = open('/tmp/pr_progress_body.md').read()
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {
        "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": {"$type": "System.Int32", "$value": 1},
    },
}))
PY

RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
  -H "Content-Type: application/json" \
  -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST --data @/tmp/pr_thread_payload.json \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1" \
  || true)
STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
if echo "${STATUS:-}" | grep -qE '^2'; then
  echo "Review-in-progress comment posted on PR #${PR_ID} (HTTP $STATUS)"
else
  echo "WARN: review-in-progress comment failed HTTP ${STATUS:-curl-error} — body: $(echo "$RESP" | sed '$d')" >&2
fi
```

If posting the starting comment fails, output a single warning line and continue — do not stop the review. Later steps that need `API_BASE` / `PR_ID` should `source /tmp/pr_azure.env` (written above) or re-run the remote-URL parser.

---

## Posting the Review

**Prefer the plugin script (one Bash call) — do not reinvent this flow.**

```bash
# Resolve the script (CLAUDE_PLUGIN_ROOT is set when the plugin is active)
ADO_POST="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/ado-post-review.sh}"
if [ -z "${ADO_POST:-}" ] || [ ! -f "$ADO_POST" ]; then
  ADO_POST=$(find "${CLAUDE_PLUGIN_ROOT:-.}" ~/.claude/plugins -path '*/pr-reviewer/scripts/ado-post-review.sh' 2>/dev/null | head -1)
fi
[ -n "${ADO_POST:-}" ] && [ -f "$ADO_POST" ] || {
  echo "ERROR: scripts/ado-post-review.sh not found — refuse to invent a posting script" >&2
  exit 1
}

# Set VERDICT to exactly one of: APPROVE | APPROVE WITH SUGGESTIONS | REQUEST CHANGES | NEEDS DISCUSSION
# (REQUEST_CHANGES / waitForAuthor aliases are normalized inside the script)
export VERDICT="REQUEST CHANGES"   # <- replace with the actual verdict from step 7
export REVIEW_MODE="${REVIEW_MODE:-initial}"
bash "$ADO_POST"
```

That script loads `/tmp/pr_azure.env`, casts the vote, posts the **summary** thread (with PropertiesCollection `$type`/`$value` + body marker + retries), reconciles re-review/external threads, and loops inline findings. **Do not** invent a shortened script, hand-build `curl` URLs, or invent `AZURE_DEVOPS_*` variables — that is the #1 cause of 401/404 posting failures, vote steps aborting under `set -e`, and **summary comments never appearing on the PR**.

**Inputs (written by earlier steps):**
- `/tmp/pr_thread_body.md` — full compiled report (fallback: `/tmp/pr_review_summary.md`)
- `/tmp/pr_inline_findings.jsonl` — one JSON object per finding (fallback: `/tmp/pr_findings.jsonl`)

**If `scripts/ado-post-review.sh` is missing from the plugin install**, stop and report the installation as broken. Do not attempt a manual fallback — a hand-copied script cannot be kept in sync with the dedup/reconciliation logic in the real script and will silently reintroduce duplicate comments. This is the one place where using the shared script is not optional: the stakes are too high for ad-hoc curl.

The subsections below explain each step. **Prefer `scripts/ado-post-review.sh`** — do not reimplement them as separate one-off `curl` calls.

### 1. Map verdict to Azure DevOps vote

The verdict string in the report MUST be exactly one of the four values below — written in uppercase, with no decoration. **Always cast a vote**, even on approve. Skipping the vote means the PR shows no reviewer status, which defeats the purpose of the review.

| Plugin verdict | Azure DevOps vote value | Description |
|---|---|---|
| `APPROVE` | `10` | Approved |
| `APPROVE WITH SUGGESTIONS` | `5` | Approved with suggestions (non-blocking) |
| `REQUEST CHANGES` | `-10` | Rejected *(see `PR_REVIEWER_BLOCK_ON_CRITICAL` below)* |
| `NEEDS DISCUSSION` | `-5` | Waiting for author |

If the report contains a non-conforming verdict (e.g. `APPROVED WITH SUGGESTIONS`, `LGTM`, `NEEDS WORK`), normalize it to the closest match before mapping:
- `APPROVED*` / `LGTM` → `APPROVE` (or `APPROVE WITH SUGGESTIONS` if there are non-empty Suggestions)
- `BLOCK*` / `REJECT*` / `NEEDS WORK` / `CHANGES REQUESTED` → `REQUEST CHANGES`
- Anything else → `NEEDS DISCUSSION`

#### Optional: `PR_REVIEWER_BLOCK_ON_CRITICAL` (controls merge-blocking behavior)

A `-10` Rejected vote on Azure DevOps is treated as blocking by repo branch policies that have *"Require a minimum number of reviewers"* with *"Allow requestors to approve their own changes"* disabled — it both blocks completion and resets approval counters. **By default this plugin runs in advisory / shadow mode**, so a `REQUEST CHANGES` verdict casts a *non-blocking* `-5` vote: the review and report stay visible but never gate the merge. Set `PR_REVIEWER_BLOCK_ON_CRITICAL=true` to make CRITICAL findings cast the blocking `-10` Rejected vote instead.

The `PR_REVIEWER_BLOCK_ON_CRITICAL` environment variable controls this:

| Value | Vote cast on `REQUEST CHANGES` verdict |
|---|---|
| unset / `false` / `0` / `no` *(default)* | `-5` (Waiting for author — visible, non-blocking) |
| `true` / `1` / `yes` | `-10` (Rejected — blocking under branch policy) |

The verdict label in the report body, the Critical Issues section, and the inline comment threads are identical in both modes — only the cast vote changes.

```bash
case "${PR_REVIEWER_BLOCK_ON_CRITICAL:-false}" in
  true|True|TRUE|1|yes|Yes|YES) BLOCK_ON_CRITICAL=true ;;
  *)                              BLOCK_ON_CRITICAL=false ;;
esac

case "${VERDICT}" in
  "APPROVE")                     VOTE=10  ;;
  "APPROVE WITH SUGGESTIONS")    VOTE=5   ;;
  "REQUEST CHANGES")
    if [ "$BLOCK_ON_CRITICAL" = "true" ]; then
      VOTE=-10
    else
      VOTE=-5
      echo "INFO: advisory mode (PR_REVIEWER_BLOCK_ON_CRITICAL not set to true) — casting -5 (non-blocking) instead of -10"
    fi
    ;;
  "NEEDS DISCUSSION")            VOTE=-5  ;;
  *)
    echo "WARN: unknown verdict '${VERDICT}' — defaulting to NEEDS DISCUSSION (vote -5)" >&2
    VOTE=-5
    ;;
esac
```

### 2. Resolve the reviewer ID and post the vote (mandatory)

> **Important:** do **not** use the `reviewers/me` alias with PAT authentication — it returns an HTML error page. Prefer **`/_apis/connectionData`** on the org host (works with PATs). Fall back to `app.vssps.visualstudio.com/.../profiles/me` only if connectionData fails. Always wrap JSON parsing in try/except so a non-JSON body never aborts the rest of posting.

```bash
REVIEWER_ID=""
if [ -n "${AZURE_ORG:-}" ]; then
  REVIEWER_ID=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
    "https://dev.azure.com/${AZURE_ORG}/_apis/connectionData?api-version=7.1-preview.1" \
    | python3 -c "import sys,json
try:
  d=json.load(sys.stdin)
  print((d.get('authenticatedUser') or d.get('authorizedUser') or {}).get('id',''))
except Exception:
  print('')" 2>/dev/null || true)
fi
if [ -z "$REVIEWER_ID" ]; then
  REVIEWER_ID=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
    "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1" \
    | python3 -c "import sys,json
try:
  print(json.load(sys.stdin).get('id',''))
except Exception:
  print('')" 2>/dev/null || true)
fi

if [ -z "$REVIEWER_ID" ]; then
  echo "WARN: could not resolve reviewer ID — vote will not be cast" >&2
else
  VOTE_RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" \
    -u ":${AZURE_DEVOPS_TOKEN}" \
    -X PUT \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/reviewers/${REVIEWER_ID}?api-version=7.1" \
    -d "{\"vote\": ${VOTE}, \"id\": \"${REVIEWER_ID}\"}")

  STATUS=$(echo "$VOTE_RESP" | sed -n 's/^HTTP_STATUS://p')
  if echo "$STATUS" | grep -qE '^2'; then
    echo "Vote ${VOTE} cast (HTTP $STATUS)"
  else
    echo "WARN: vote PUT returned HTTP $STATUS — body: $(echo "$VOTE_RESP" | sed '$d')" >&2
    # If the reviewer isn't on the PR yet, POST .../reviewers (no /id suffix) with the same body.
    # Some org policies require the reviewer to be added explicitly first.
  fi
fi
```

### 3. Post the full report as a PR thread

Write the **compiled report text itself** into `/tmp/pr_thread_body.md` **using the `Write` tool**. Do **not** use a Bash heredoc — a heredoc requires the model to reproduce ~4000 characters of multi-line markdown as a literal tool-call string argument, which risks losing line breaks in complex interactions. The `Write` tool takes the content as structured data and avoids this pitfall. Never write a `${REPORT_BODY}` placeholder inside a quoted (`<<'EOF'`) heredoc — quoting suppresses expansion and the literal string `${REPORT_BODY}` gets posted to the PR.

**Do not hand-roll this step** — `scripts/ado-post-review.sh` posts the summary with the correct PropertiesCollection format, a body marker, and retries. The payload shape it uses:

```bash
# /tmp/pr_thread_body.md now contains the full compiled report markdown
# Properties MUST use {$type,$value} — bare "pr-reviewer.kind":"summary" often 400s the create.

HEAD_SHA=$(git rev-parse HEAD) python3 - <<'PY' > /tmp/pr_thread_payload.json
import json, os, pathlib
sha = os.environ["HEAD_SHA"]
body = pathlib.Path("/tmp/pr_thread_body.md").read_text()
if "pr-reviewer:v1.2 kind=summary" not in body:
    body = body.rstrip() + f"\n\n<!-- pr-reviewer:v1.2 kind=summary sha={sha} -->\n"
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {
        "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": {"$type": "System.Int32", "$value": 1},
        "pr-reviewer.kind": {"$type": "System.String", "$value": "summary"},
        "pr-reviewer.sha": {"$type": "System.String", "$value": sha},
    },
}))
PY

curl -sS -w "\nHTTP_STATUS:%{http_code}\n" \
  -H "Content-Type: application/json" \
  -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST --data @/tmp/pr_thread_payload.json \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1"
```

> The `pr-reviewer.kind` / `pr-reviewer.sha` properties (and the body HTML marker) are the summary marker — they let the next run find this thread and read the head it was generated against. The re-review delta block is already in the compiled report body from step 7. Each re-review posts a fresh summary thread; the prior summary stays as history.

### 4. Post inline comments (one thread per finding) — MANDATORY

This step is mandatory whenever the report contains at least one Critical Issue, Warning, or Suggestion with a file path and line number. **Skipping it is a P0 bug** — the whole point of running four specialized reviewers is to surface findings inline next to the offending code, not just bury them in a summary thread.

Use the loop below — do not try to "remember" the findings and post them with one-off `curl` invocations. Production runs converge on a serialized findings file plus a single posting loop because that is the only way the run stays auditable when there are 5–20 findings.

#### a. Serialize findings to JSONL

After compiling the report (step 7 of `commands/pr-review.md`), write **one JSON object per finding** to `/tmp/pr_inline_findings.jsonl`. In **re-review mode** serialize only the **New** bucket (`/tmp/pr_reconcile.json` → `new[]`); carried-over findings are not re-posted. Each object must have:

| Field | Type | Required | Notes |
|---|---|---|---|
| `file` | string | yes | Repo-relative path. The script prepends `/` automatically. |
| `line` | int | yes | 1-indexed line number on the **right** (post-change) side of the diff. |
| `body` | string | yes | Markdown body of the comment. Must include severity tag, e.g. `**[CRITICAL]** ...`. |
| `fid` | string | yes | Stable finding id from step 7 (`compute_fid`). Stored as a thread property. |
| `severity` | string | no | `critical` / `warning` / `suggestion` — used only for the summary log. |

```bash
python3 - <<'PY' > /tmp/pr_inline_findings.jsonl
import json
findings = [
    {"file": "Xians.Lib/Agents/Core/ActivityRegistrar.cs", "line": 62, "severity": "critical", "fid": "a1b2c3d4e5f6",
     "body": "**[CRITICAL] Sync-over-async deadlock risk**\n\n`.GetAwaiter().GetResult()` on `GetClientAsync()` in a sync context is a well-known deadlock pattern..."},
    # ... one entry per finding to post (initial: all; re-review: New bucket only) ...
]
for f in findings:
    print(json.dumps(f))
PY
```

#### b. Loop and POST, one thread per finding, with HTTP status checks

```bash
INLINE_TOTAL=0
INLINE_OK=0
INLINE_FAIL=0
: > /tmp/pr_inline_failures.log

while IFS= read -r line; do
  [ -z "$line" ] && continue
  INLINE_TOTAL=$((INLINE_TOTAL + 1))

  echo "$line" > /tmp/pr_inline_finding.json
  HEAD_SHA=$(git rev-parse HEAD) python3 - <<'PY' > /tmp/pr_thread_payload.json
import json, os
f = json.load(open('/tmp/pr_inline_finding.json'))
sha = os.environ["HEAD_SHA"]
body = f["body"]
fid = f.get("fid", "")
if fid and "pr-reviewer:v1.2 kind=finding" not in body:
    body = body.rstrip() + f"\n\n<!-- pr-reviewer:v1.2 kind=finding fid={fid} sha={sha} -->\n"
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {
        "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": {"$type": "System.Int32", "$value": 1},
        "pr-reviewer.kind": {"$type": "System.String", "$value": "finding"},
        "pr-reviewer.fid": {"$type": "System.String", "$value": fid},
        "pr-reviewer.sha": {"$type": "System.String", "$value": sha},
    },
    "threadContext": {
        "filePath": "/" + f["file"].lstrip("/"),
        "rightFileStart": {"line": int(f["line"]), "offset": 1},
        "rightFileEnd":   {"line": int(f["line"]), "offset": 1},
    },
}))
PY

  RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" \
    -u ":${AZURE_DEVOPS_TOKEN}" \
    -X POST --data @/tmp/pr_thread_payload.json \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1")

  STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
  if echo "$STATUS" | grep -qE '^2'; then
    INLINE_OK=$((INLINE_OK + 1))
  else
    INLINE_FAIL=$((INLINE_FAIL + 1))
    {
      echo "---"
      echo "finding: $line"
      echo "HTTP $STATUS:"
      echo "$RESP" | sed '$d'
    } >> /tmp/pr_inline_failures.log
  fi
done < /tmp/pr_inline_findings.jsonl

echo "Inline comments: ${INLINE_OK}/${INLINE_TOTAL} posted (${INLINE_FAIL} failed)"
if [ "$INLINE_FAIL" -gt 0 ]; then
  echo "WARN: see /tmp/pr_inline_failures.log for failure details" >&2
  head -40 /tmp/pr_inline_failures.log >&2
fi

export INLINE_OK INLINE_FAIL INLINE_TOTAL
```

#### c. Diagnosing zero inline comments

If `INLINE_OK` is `0` while `INLINE_TOTAL` is `0`, step (a) was skipped — the JSONL file is empty. Go back to step 7 of `commands/pr-review.md` and serialize the findings.

If `INLINE_OK` is `0` while `INLINE_TOTAL` is `> 0`, every POST failed. Read `/tmp/pr_inline_failures.log` and check:

| HTTP | Cause | Fix |
|---|---|---|
| `401` | `AZURE_DEVOPS_TOKEN` empty — often because only the dashed `AZURE-DEVOPS-TOKEN` is set and the underscored alias is missing. Confirm presence with `echo "AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}"` (never echo the value). Same failure mode causes `json.JSONDecodeError` when an agent invents `THREADS_JSON=$(curl …)` instead of running `scripts/ado-detect-prior.sh`. | Re-export with underscores: `export AZURE_DEVOPS_TOKEN="$(printenv AZURE-DEVOPS-TOKEN)"` (the hook normally catches this). Then re-run `ado-detect-prior.sh` / `ado-post-review.sh` — do not hand-roll a replacement curl. |
| `404` | `API_BASE` is wrong — most often the legacy `DefaultCollection` URL was parsed without the project segment. | Re-run the parser at the top of this file; print `API_BASE` and confirm it ends with `/{project}`, not `/{collection}`. |
| `400` with `threadContext` in the body | `filePath` doesn't match a file in the iteration, or the line number is past EOF. | Confirm the file path is repo-relative (no leading `/` in your JSONL — the script adds one) and the line is on the right (post-change) side. |

---

## Reconciling prior findings (re-review mode only — sub-step R)

Runs only when `REVIEW_MODE=rereview`. Acts on `/tmp/pr_reconcile.json` (built in step 7 of `commands/pr-review.md`). Carried-over findings need **no** action. The **Fixed** and **Reopened** buckets are processed — reply on each thread, then set its status (`fixed` for resolved, `active` for reopened).

Azure DevOps thread status is updated with a `PATCH` on the thread; replies are a `POST` of a comment to the existing thread (no `threadContext`).

```bash
RESOLVED_OK=0
RESOLVED_FAIL=0
REOPENED_OK=0
REOPENED_FAIL=0
HEAD_SHA=$(git rev-parse HEAD)
: > /tmp/pr_resolved.log
: > /tmp/pr_reopened.log

# Process Fixed findings
python3 -c "import json,sys; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_reconcile.json')).get('fixed',[])]" \
| while IFS= read -r f; do
  THREAD_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin)['thread_ref'])")

  # 1. Reply on the existing thread
  cat > /tmp/pr_resolve_body.md <<BODY
✅ Resolved as of \`${HEAD_SHA}\`. This finding no longer reproduces against the current head.
BODY
  python3 - <<'PY' > /tmp/pr_resolve_payload.json
import json
print(json.dumps({"content": open('/tmp/pr_resolve_body.md').read(), "commentType": 1}))
PY
  curl -sS -o /dev/null \
    -H "Content-Type: application/json" \
    -u ":${AZURE_DEVOPS_TOKEN}" \
    -X POST --data @/tmp/pr_resolve_payload.json \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}/comments?api-version=7.1"

  # 2. Set thread status to fixed
  RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" \
    -u ":${AZURE_DEVOPS_TOKEN}" \
    -X PATCH -d '{"status":"fixed"}' \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}?api-version=7.1")
  STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
  if echo "$STATUS" | grep -qE '^2'; then echo ok >> /tmp/pr_resolved.log; else echo "fail $THREAD_ID HTTP $STATUS" >> /tmp/pr_resolved.log; fi
done

# Process Reopened findings (marked resolved, but still reproducing)
python3 -c "import json,sys; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_reconcile.json')).get('reopened',[])]" \
| while IFS= read -r f; do
  THREAD_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin)['thread_ref'])")

  # 1. Reply on the existing thread
  cat > /tmp/pr_reopened_body.md <<BODY
⚠️ This finding still reproduces as of \`${HEAD_SHA}\` despite being marked resolved. Reactivating thread.
BODY
  python3 - <<'PY' > /tmp/pr_reopened_payload.json
import json
print(json.dumps({"content": open('/tmp/pr_reopened_body.md').read(), "commentType": 1}))
PY
  curl -sS -o /dev/null \
    -H "Content-Type: application/json" \
    -u ":${AZURE_DEVOPS_TOKEN}" \
    -X POST --data @/tmp/pr_reopened_payload.json \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}/comments?api-version=7.1"

  # 2. Set thread status back to active
  RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" \
    -u ":${AZURE_DEVOPS_TOKEN}" \
    -X PATCH -d '{"status":"active"}' \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}?api-version=7.1")
  STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
  if echo "$STATUS" | grep -qE '^2'; then echo ok >> /tmp/pr_reopened.log; else echo "fail $THREAD_ID HTTP $STATUS" >> /tmp/pr_reopened.log; fi
done

RESOLVED_OK=$(grep -c '^ok' /tmp/pr_resolved.log 2>/dev/null || echo 0)
RESOLVED_FAIL=$(grep -c '^fail' /tmp/pr_resolved.log 2>/dev/null || echo 0)
REOPENED_OK=$(grep -c '^ok' /tmp/pr_reopened.log 2>/dev/null || echo 0)
REOPENED_FAIL=$(grep -c '^fail' /tmp/pr_reopened.log 2>/dev/null || echo 0)
export RESOLVED_OK RESOLVED_FAIL REOPENED_OK REOPENED_FAIL
echo "Reconciled: ${RESOLVED_OK} prior finding(s) resolved (${RESOLVED_FAIL} failed); ${REOPENED_OK} reopened (${REOPENED_FAIL} failed)"
```

> **`status` values:** `active` (open), `fixed` (resolved by a change), `wontFix`, `closed`, `byDesign`, `pending`. Use `fixed` when the finding no longer reproduces; use `active` when reactivating a thread. The counters are read back from log files because the `while` loops run in a pipeline subshell.

---

## Replying on addressed external threads (sub-step E)

Runs when `/tmp/pr_external_reconcile.json` exists and `addressed` is non-empty (initial **or** re-review). Reply only — **never** PATCH the thread status. Resolution stays with the original author. (The self-contained *Posting the Review* script already includes this as step 5c; the block below is the standalone reference.)

```bash
EXTERNAL_REPLY_OK=0
EXTERNAL_REPLY_FAIL=0
HEAD_SHA=$(git rev-parse HEAD)
: > /tmp/pr_external_replies.log

if [ -f /tmp/pr_external_reconcile.json ]; then
  python3 -c "import json,sys; [print(json.dumps(x)) for x in json.load(open('/tmp/pr_external_reconcile.json')).get('addressed',[])]" \
  | while IFS= read -r f; do
    [ -z "$f" ] && continue
    THREAD_ID=$(echo "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('thread_ref') or '')")
    [ -n "$THREAD_ID" ] || { echo "fail missing thread_ref" >> /tmp/pr_external_replies.log; continue; }
    cat > /tmp/pr_external_reply_body.md <<BODY
Looks addressed as of \`${HEAD_SHA}\` — leaving this thread open for the original author to resolve.
BODY
    python3 - <<'PY' > /tmp/pr_external_reply_payload.json
import json
print(json.dumps({"content": open('/tmp/pr_external_reply_body.md').read(), "commentType": 1}))
PY
    RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
      -H "Content-Type: application/json" \
      -u ":${AZURE_DEVOPS_TOKEN}" \
      -X POST --data @/tmp/pr_external_reply_payload.json \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}/comments?api-version=7.1")
    STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
    if echo "$STATUS" | grep -qE '^2'; then echo ok >> /tmp/pr_external_replies.log; else echo "fail $THREAD_ID HTTP $STATUS" >> /tmp/pr_external_replies.log; fi
  done
  EXTERNAL_REPLY_OK=$(grep -c '^ok' /tmp/pr_external_replies.log 2>/dev/null || echo 0)
  EXTERNAL_REPLY_FAIL=$(grep -c '^fail' /tmp/pr_external_replies.log 2>/dev/null || echo 0)
fi
export EXTERNAL_REPLY_OK EXTERNAL_REPLY_FAIL
echo "External replies: ${EXTERNAL_REPLY_OK} addressed thread(s) acknowledged (${EXTERNAL_REPLY_FAIL} failed) — threads left open"
```

---

## Output

On completion, use the counters from the inline-comment loop in step 4 (`$INLINE_OK` / `$INLINE_TOTAL`) — do **not** print a hard-coded number.

```
# initial mode
Review posted on PR #<id>: <verdict> — ${INLINE_OK}/${INLINE_TOTAL} inline comments — ${EXTERNAL_REPLY_OK} external replies — ${API_BASE}/_git/${AZURE_REPO}/pullrequest/<id>

# re-review mode (add reconciliation counters)
Re-review posted on PR #<id>: <verdict> — ${INLINE_OK}/${INLINE_TOTAL} new — ${RESOLVED_OK} resolved — ${EXTERNAL_REPLY_OK} external replies — ${API_BASE}/_git/${AZURE_REPO}/pullrequest/<id>
```

If `INLINE_OK == 0` but the report had findings with file:line references, treat the run as a partial failure and surface the first few lines of `/tmp/pr_inline_failures.log` in the output so the user knows the inline step did not actually deliver.
