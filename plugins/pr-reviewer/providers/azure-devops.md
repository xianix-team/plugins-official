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

**HTTPS format:** `https://dev.azure.com/{org}/{project}/_git/{repo}`

```bash
REMOTE=$(git remote get-url origin)

# Strip optional "user@" basic-auth prefix
REMOTE_CLEAN=$(echo "$REMOTE" | sed -E 's|https://[^@]+@|https://|')

AZURE_ORG=$(echo "$REMOTE_CLEAN"     | sed 's|https://dev.azure.com/||' | cut -d'/' -f1)
AZURE_PROJECT=$(echo "$REMOTE_CLEAN" | sed 's|https://dev.azure.com/||' | cut -d'/' -f2)
AZURE_REPO=$(echo "$REMOTE_CLEAN"    | sed 's|.*/_git/||' | sed 's|\.git$||')
```

**Legacy HTTPS format:** `https://{org}.visualstudio.com/{project}/_git/{repo}`

```bash
AZURE_ORG=$(echo "$REMOTE_CLEAN"     | sed 's|https://||' | cut -d'.' -f1)
AZURE_PROJECT=$(echo "$REMOTE_CLEAN"  | cut -d'/' -f4)
AZURE_REPO=$(echo "$REMOTE_CLEAN"    | sed 's|.*/_git/||' | sed 's|\.git$||')
```

### API Base URL

After parsing, set the API base URL to match the remote URL format. Organizations on legacy `visualstudio.com` hosts may not resolve via the `dev.azure.com` endpoint, so the base must reflect the actual host:

```bash
if [[ "$REMOTE_CLEAN" =~ \.visualstudio\.com ]]; then
  API_BASE="https://${AZURE_ORG}.visualstudio.com/${AZURE_PROJECT}"
else
  API_BASE="https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}"
fi

# Export so subsequent python heredocs can read them via os.environ
export AZURE_ORG AZURE_PROJECT AZURE_REPO API_BASE
```

Use `${API_BASE}` in place of a hardcoded host for **every** API call below.

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
| `REQUEST CHANGES` | `-10` | Rejected |
| `NEEDS DISCUSSION` | `-5` | Waiting for author |

If the report contains a non-conforming verdict (e.g. `APPROVED WITH SUGGESTIONS`, `LGTM`, `NEEDS WORK`), normalize it to the closest match before mapping:
- `APPROVED*` / `LGTM` → `APPROVE` (or `APPROVE WITH SUGGESTIONS` if there are non-empty Suggestions)
- `BLOCK*` / `REJECT*` / `NEEDS WORK` / `CHANGES REQUESTED` → `REQUEST CHANGES`
- Anything else → `NEEDS DISCUSSION`

```bash
case "${VERDICT}" in
  "APPROVE")                     VOTE=10  ;;
  "APPROVE WITH SUGGESTIONS")    VOTE=5   ;;
  "REQUEST CHANGES")             VOTE=-10 ;;
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

### 4. Post inline comments (one thread per finding)

For each finding with a precise file path and line number, build a payload with `threadContext` and POST to the same threads endpoint:

```bash
cat > /tmp/pr_thread_body.md <<'BODY'
**[CRITICAL] Sync-over-async deadlock risk**

`.GetAwaiter().GetResult()` on `GetClientAsync()` in a sync context is a well-known deadlock pattern…
BODY

FILE_PATH="Xians.Lib/Agents/Core/ActivityRegistrar.cs" LINE_NUMBER=62 \
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

curl -sS -w "\nHTTP_STATUS:%{http_code}\n" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n ":${AZURE_DEVOPS_TOKEN}" | base64 -w0)" \
  -X POST --data @/tmp/pr_thread_payload.json \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullRequests/${PR_ID}/threads?api-version=7.1"
```

Post all inline comments without pausing between them. Always check `HTTP_STATUS:` in the response; non-2xx means the comment did not appear on the PR.

---

## Output

On completion:

```
Review posted on PR #<id>: <verdict> — <N> inline comments — ${API_BASE}/_git/<repo>/pullrequest/<id>
```
