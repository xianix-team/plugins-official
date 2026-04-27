# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## Prerequisites

The Azure DevOps REST API is called directly via `curl` using a Personal Access Token (PAT).

Required environment variable:

| Variable | Purpose |
|---|---|
| `AZURE_DEVOPS_TOKEN` | Azure DevOps PAT — must have `Code (Read)`, `Pull Request Threads (Read & Write)`, and `User Profile (Read)` scopes |

> **Note on var-name hygiene:** the variable name must be `AZURE_DEVOPS_TOKEN` (underscores). Some upstream environments export `AZURE-DEVOPS-TOKEN` (hyphens) — bash cannot reference hyphenated names, and `curl -u ":${AZURE-DEVOPS-TOKEN}"` will silently send an empty password. The plugin's `PreToolUse` hook detects this case and blocks with a clear message; if you hit it, re-export with underscores.

Optional — used to override values parsed from the remote URL:

| Variable | Default |
|---|---|
| `AZURE_ORG` | Parsed from remote URL |
| `AZURE_PROJECT` | Parsed from remote URL |
| `AZURE_REPO` | Parsed from remote URL |

---

## Parsing the Remote URL

Extract org, project, and repo from the remote URL before making any API calls. Strip any embedded basic-auth (`user@`) component first — it appears in remotes injected by CI runners.

Azure DevOps uses **four** URL shapes in the wild. **All must be handled** — the legacy `DefaultCollection` form is common in tenants that migrated from on-prem TFS, and getting it wrong means inline threads silently 4xx (plain threads still post because the repo can be resolved at collection level — that is the #1 cause of "main comment posts but inline comments don't show up").

| # | Shape | Example |
|---|---|---|
| 1 | `dev.azure.com/{org}/{project}/_git/{repo}` | `https://dev.azure.com/contoso/Web/_git/api` |
| 2 | `dev.azure.com/{org}/{collection}/{project}/_git/{repo}` | rare — usually only seen on imported orgs |
| 3 | `{org}.visualstudio.com/{project}/_git/{repo}` | `https://contoso.visualstudio.com/Web/_git/api` |
| 4 | `{org}.visualstudio.com/{collection}/{project}/_git/{repo}` | `https://contoso.visualstudio.com/DefaultCollection/Web/_git/api` |

Use the parser below — it anchors on the `_git` segment (always exactly one position before the repo and one position after the project), so it works for all four shapes:

```bash
REMOTE=$(git remote get-url origin)

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

## Posting pattern (use this exact form for every write call)

The pattern below is what production runs converge on. **Use it as-is** rather than inventing a wrapper function — wrapper functions get ignored by the model in favor of inline curl.

Two rules:
1. **Always send the body via `--data @file`**, never inline. Heredocs inside `curl -d "$(...)"` produce hard-to-debug quoting bugs.
2. **Always capture HTTP status** with `-w "\nHTTP_STATUS:%{http_code}\n"` and check it. Silent 401 / 404 responses are the #1 cause of "post succeeded but nothing showed up on the PR".

#### Generic comment thread

```bash
# 1. Write the markdown body to a file
cat > /tmp/pr_thread_body.md <<'BODY'
**Your markdown content here.**
BODY

# 2. Build the JSON payload (use python so the markdown is escaped correctly)
python3 - <<'PY' > /tmp/pr_thread_payload.json
import json
body = open('/tmp/pr_thread_body.md').read()
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {"Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1},
}))
PY

# 3. POST and check status
RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n ":${AZURE_DEVOPS_TOKEN}" | base64 -w0)" \
  -X POST \
  --data @/tmp/pr_thread_payload.json \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1")

STATUS=$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p')
if echo "$STATUS" | grep -qE '^2'; then
  echo "Thread posted (HTTP $STATUS)"
else
  echo "WARN: thread post failed HTTP $STATUS — body: $(echo "$RESP" | sed '$d')" >&2
fi
```

#### Inline comment thread

Same as above, but extend the JSON payload with `threadContext`. Replace the `python3 -c` step with:

```bash
FILE_PATH="Xians.Lib/Common/Caching/CacheService.cs" LINE_NUMBER=42 \
python3 - <<'PY' > /tmp/pr_thread_payload.json
import json, os
body = open('/tmp/pr_thread_body.md').read()
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {"Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1},
    "threadContext": {
        "filePath": "/" + os.environ["FILE_PATH"].lstrip("/"),
        "rightFileStart": {"line": int(os.environ["LINE_NUMBER"]), "offset": 1},
        "rightFileEnd":   {"line": int(os.environ["LINE_NUMBER"]), "offset": 1},
    },
}))
PY
```

Then POST exactly as in step 3 above.

> **Authentication note:** Both `-u ":${AZURE_DEVOPS_TOKEN}"` and `-H "Authorization: Basic $(echo -n ":${AZURE_DEVOPS_TOKEN}" | base64 -w0)"` work for Azure DevOps PAT auth. The `-H` form is shown above because it makes the auth header visible in `curl -v` traces and is what the model converges on in practice.

---

## Resolving the PR Number

If no PR number was passed as an argument, find the active PR for the current branch.

In a detached-HEAD worktree (which is how the Xianix Executor runs the plugin), `git rev-parse --abbrev-ref HEAD` returns the literal string `HEAD`. Resolve the source branch from `git branch --contains` instead, or pass the branch name explicitly.

```bash
if [ "$(git rev-parse --abbrev-ref HEAD)" = "HEAD" ]; then
  BRANCH=$(git branch --contains "$(git rev-parse HEAD)" \
    | sed 's|^[* ] *||' | grep -v '^(' | head -1)
else
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

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

Use `$PR_TARGET` as the **base branch** for diffs. Resolve it to a concrete SHA the same way the orchestrator step 3 does — try `refs/remotes/origin/${PR_TARGET}` first, then fall back to `refs/heads/${PR_TARGET}` (worktrees may not have remote-tracking refs), then take `git merge-base` against `HEAD`.

---

## Markdown in PR threads

This plugin posts via the **Git** [Pull Request Threads](https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pull-request-threads/create?view=azure-devops-rest-7.1) API (`.../pullrequests/.../threads`). That is **not** the same as Work Item Tracking discussion comments.

For PR threads, put Markdown in `comments[].content`. Also set thread `properties` so the web UI treats the thread as Markdown-capable (otherwise headings, tables, and emphasis can appear as raw text):

| Key | Value |
|---|---|
| `Microsoft.TeamFoundation.Discussion.SupportsMarkdown` | `1` (integer) |

The posting pattern above includes this on every call.

---

## Posting the Starting Comment

Before running any analysis, post a plain PR comment thread to inform the author that a review is underway. This fires as the very first action on Azure DevOps, before sub-agents are launched.

```bash
cat > /tmp/pr_thread_body.md <<'BODY'
**PR review in progress**

I'm running a comprehensive review covering code quality, security, test coverage, and performance. The full results will be posted as a review comment when complete — this may take a few minutes.
BODY

python3 - <<'PY' > /tmp/pr_thread_payload.json
import json
body = open('/tmp/pr_thread_body.md').read()
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {"Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1},
}))
PY

curl -sS -w "\nHTTP_STATUS:%{http_code}\n" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n ":${AZURE_DEVOPS_TOKEN}" | base64 -w0)" \
  -X POST --data @/tmp/pr_thread_payload.json \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1"
```

If posting the starting comment fails, output a single warning line and continue — do not stop the review.

---

## Posting the Review

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

A `-10` Rejected vote on Azure DevOps is treated as blocking by repo branch policies that have *"Require a minimum number of reviewers"* with *"Allow requestors to approve their own changes"* disabled — it both blocks completion and resets approval counters. In some workflows (advisory bot, shadow-mode rollout, repos where the bot is not yet in the trusted reviewer set) you want the review and the report visible but the vote *non-blocking*.

The `PR_REVIEWER_BLOCK_ON_CRITICAL` environment variable controls this:

| Value | Vote cast on `REQUEST CHANGES` verdict |
|---|---|
| unset / `true` *(default)* | `-10` (Rejected — blocking under branch policy) |
| `false` / `0` / `no` | `-5` (Waiting for author — visible, non-blocking) |

The verdict label in the report body, the Critical Issues section, and the inline comment threads are identical in both modes — only the cast vote changes.

```bash
case "${PR_REVIEWER_BLOCK_ON_CRITICAL:-true}" in
  false|False|FALSE|0|no|No|NO) BLOCK_ON_CRITICAL=false ;;
  *)                              BLOCK_ON_CRITICAL=true ;;
esac

case "${VERDICT}" in
  "APPROVE")                     VOTE=10  ;;
  "APPROVE WITH SUGGESTIONS")    VOTE=5   ;;
  "REQUEST CHANGES")
    if [ "$BLOCK_ON_CRITICAL" = "true" ]; then
      VOTE=-10
    else
      VOTE=-5
      echo "INFO: PR_REVIEWER_BLOCK_ON_CRITICAL=false — casting -5 (non-blocking) instead of -10"
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

> **Important:** the documented `reviewers/me` alias does **not** work with PAT authentication — it returns an HTML error page that breaks JSON parsers. Resolve the actual profile ID first.

```bash
REVIEWER_ID=$(curl -sS \
  -H "Authorization: Basic $(echo -n ":${AZURE_DEVOPS_TOKEN}" | base64 -w0)" \
  "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")

if [ -z "$REVIEWER_ID" ]; then
  echo "WARN: could not resolve reviewer ID — vote will not be cast" >&2
else
  VOTE_RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Basic $(echo -n ":${AZURE_DEVOPS_TOKEN}" | base64 -w0)" \
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

```bash
cat > /tmp/pr_thread_body.md <<'REPORT'
${REPORT_BODY}
REPORT

python3 - <<'PY' > /tmp/pr_thread_payload.json
import json
body = open('/tmp/pr_thread_body.md').read()
print(json.dumps({
    "comments": [{"content": body, "commentType": 1}],
    "status": "active",
    "properties": {"Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1},
}))
PY

curl -sS -w "\nHTTP_STATUS:%{http_code}\n" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n ":${AZURE_DEVOPS_TOKEN}" | base64 -w0)" \
  -X POST --data @/tmp/pr_thread_payload.json \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1"
```

### 4. Post inline comments (one thread per finding) — MANDATORY

This step is mandatory whenever the report contains at least one Critical Issue, Warning, or Suggestion with a file path and line number. **Skipping it is a P0 bug** — the whole point of running four specialized reviewers is to surface findings inline next to the offending code, not just bury them in a summary thread.

Use the loop below — do not try to "remember" the findings and post them with one-off `curl` invocations. Production runs converge on a serialized findings file plus a single posting loop because that is the only way the run stays auditable when there are 5–20 findings.

#### a. Serialize findings to JSONL

After compiling the report (step 7 of the orchestrator), write **one JSON object per finding** to `/tmp/pr_inline_findings.jsonl`. Each object must have:

| Field | Type | Required | Notes |
|---|---|---|---|
| `file` | string | yes | Repo-relative path. The script prepends `/` automatically. |
| `line` | int | yes | 1-indexed line number on the **right** (post-change) side of the diff. |
| `body` | string | yes | Markdown body of the comment. Must include severity tag, e.g. `**[CRITICAL]** ...`. |
| `severity` | string | no | `critical` / `warning` / `suggestion` — used only for the summary log. |

```bash
python3 - <<'PY' > /tmp/pr_inline_findings.jsonl
import json
findings = [
    {"file": "Xians.Lib/Agents/Core/ActivityRegistrar.cs", "line": 62, "severity": "critical",
     "body": "**[CRITICAL] Sync-over-async deadlock risk**\n\n`.GetAwaiter().GetResult()` on `GetClientAsync()` in a sync context is a well-known deadlock pattern..."},
    # ... one entry per Critical / Warning / Suggestion with a precise file:line ...
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
  python3 - <<'PY' > /tmp/pr_thread_payload.json
import json
f = json.load(open('/tmp/pr_inline_finding.json'))
print(json.dumps({
    "comments": [{"content": f["body"], "commentType": 1}],
    "status": "active",
    "properties": {"Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1},
    "threadContext": {
        "filePath": "/" + f["file"].lstrip("/"),
        "rightFileStart": {"line": int(f["line"]), "offset": 1},
        "rightFileEnd":   {"line": int(f["line"]), "offset": 1},
    },
}))
PY

  RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Basic $(echo -n ":${AZURE_DEVOPS_TOKEN}" | base64 -w0)" \
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

If `INLINE_OK` is `0` while `INLINE_TOTAL` is `0`, the orchestrator skipped step (a) — the JSONL file is empty. Go back to step 7 and serialize the findings.

If `INLINE_OK` is `0` while `INLINE_TOTAL` is `> 0`, every POST failed. Read `/tmp/pr_inline_failures.log` and check:

| HTTP | Cause | Fix |
|---|---|---|
| `401` | Token missing or hyphenated (`AZURE-DEVOPS-TOKEN` instead of `AZURE_DEVOPS_TOKEN`). | Re-export with underscores (the hook normally catches this). |
| `404` | `API_BASE` is wrong — most often the legacy `DefaultCollection` URL was parsed without the project segment. | Re-run the parser at the top of this file; print `API_BASE` and confirm it ends with `/{project}`, not `/{collection}`. |
| `400` with `threadContext` in the body | `filePath` doesn't match a file in the iteration, or the line number is past EOF. | Confirm the file path is repo-relative (no leading `/` in your JSONL — the script adds one) and the line is on the right (post-change) side. |

---

## Output

On completion, use the counters from the inline-comment loop in step 4 (`$INLINE_OK` / `$INLINE_TOTAL`) — do **not** print a hard-coded number.

```
Review posted on PR #<id>: <verdict> — ${INLINE_OK}/${INLINE_TOTAL} inline comments — ${API_BASE}/_git/${AZURE_REPO}/pullrequest/<id>
```

If `INLINE_OK == 0` but the report had findings with file:line references, treat the run as a partial failure and surface the first few lines of `/tmp/pr_inline_failures.log` in the output so the user knows the inline step did not actually deliver.
