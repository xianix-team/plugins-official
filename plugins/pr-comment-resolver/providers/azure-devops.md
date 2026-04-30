# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## Prerequisites

Required environment variable:

| Variable | Purpose |
|---|---|
| `AZURE-DEVOPS-TOKEN` | PAT with `Code (Read & Write)` and `Pull Request Threads (Read & Write)` scopes |

Optional overrides:

| Variable | Default |
|---|---|
| `AZURE_ORG` | Parsed from remote URL |
| `AZURE_PROJECT` | Parsed from remote URL |
| `AZURE_REPO` | Parsed from remote URL |

---

## Parsing the Remote URL

**HTTPS format:** `https://dev.azure.com/{org}/{project}/_git/{repo}`

```bash
REMOTE=$(git remote get-url origin)
AZURE_ORG=$(echo "$REMOTE"     | sed 's|https://dev.azure.com/||' | cut -d'/' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | sed 's|https://dev.azure.com/||' | cut -d'/' -f2)
AZURE_REPO=$(echo "$REMOTE"    | sed 's|.*/_git/||' | sed 's|\.git$||')
```

**Legacy format:** `https://{org}.visualstudio.com/{project}/_git/{repo}`

```bash
AZURE_ORG=$(echo "$REMOTE"     | sed 's|https://||' | cut -d'.' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | cut -d'/' -f4)
AZURE_REPO=$(echo "$REMOTE"    | sed 's|.*/_git/||' | sed 's|\.git$||')
```

### API Base URL

```bash
if [[ "$REMOTE" =~ \.visualstudio\.com ]]; then
  API_BASE="https://${AZURE_ORG}.visualstudio.com/${AZURE_PROJECT}"
else
  API_BASE="https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}"
fi
```

Use `${API_BASE}` in every API call below.

---

## Resolving the PR Number

If no PR number was passed as an argument:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)

curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH}&searchCriteria.status=active&api-version=7.1" \
  | python3 -c "import sys,json; prs=json.load(sys.stdin)['value']; print(prs[0]['pullRequestId'] if prs else '')"
```

Store as `PR_ID`. If empty, the branch has no open PR — output a warning and stop.

---

## Markdown in PR Threads

Post via the **Git Pull Request Threads** API (`.../pullrequests/.../threads`). Set thread `properties` so the web UI renders Markdown:

| Key | Value |
|---|---|
| `Microsoft.TeamFoundation.Discussion.SupportsMarkdown` | `1` (integer) |

Include this `properties` object on **every** `POST .../threads` body.

---

## Posting the Starting Comment

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads?api-version=7.1" \
  -d '{"comments":[{"content":"🔧 **PR comment resolution in progress**\n\nI'\''m reviewing all unresolved threads and will apply actionable ones as commits, reply to the rest, and post a disposition summary when complete.","commentType":1}],"status":"active","properties":{"Microsoft.TeamFoundation.Discussion.SupportsMarkdown":1}}'
```

If posting fails, output a single warning line and continue.

---

## Fetching Unresolved Threads

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads?api-version=7.1"
```

Parse the response with python3. For each thread where `status != "fixed"` and `status != "byDesign"` and `isDeleted != true`:

```python
import sys, json

data = json.load(sys.stdin)
for thread in data.get('value', []):
    if thread.get('isDeleted'):
        continue
    status = thread.get('status', '')
    if status in ('fixed', 'byDesign', 'wontFix'):
        continue
    thread_id = thread['id']
    comments = thread.get('comments', [])
    if not comments:
        continue
    first_comment = comments[0]
    body = first_comment.get('content', '')
    comment_id = first_comment.get('id')
    thread_context = thread.get('threadContext') or {}
    file_path = thread_context.get('filePath', '')
    line = (thread_context.get('rightFileStart') or {}).get('line')
    print(f"thread_id={thread_id} comment_id={comment_id} file={file_path} line={line}")
    print(f"body={body}")
```

Collect each thread's `id`, first comment `id`, `content`, `filePath`, and `line` for classification.

---

## Updating Thread Status (After Applying)

For **apply** threads — mark as resolved (`"fixed"`):

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X PATCH \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads/${THREAD_ID}?api-version=7.1" \
  -d '{"status": "fixed"}'
```

---

## Posting a Reply to a Thread

Reply to an existing thread with a follow-up comment:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads/${THREAD_ID}/comments?api-version=7.1" \
  -d "$(python3 -c "
import json
print(json.dumps({
  'content': '${REPLY_TEXT}',
  'commentType': 1
}))
")"
```

---

## Posting the Disposition Summary

Post the compiled summary as a new thread:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads?api-version=7.1" \
  -d "$(python3 -c "
import json, sys
body = sys.stdin.read()
print(json.dumps({
  'comments': [{'content': body, 'commentType': 1}],
  'status': 'active',
  'properties': {'Microsoft.TeamFoundation.Discussion.SupportsMarkdown': 1}
}))
" <<'SUMMARY'
${SUMMARY_BODY}
SUMMARY
)"
```

---

## Creating a Follow-up PR (Merged PR Flow)

When the original PR was already merged:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?api-version=7.1" \
  -d "$(python3 -c "
import json
print(json.dumps({
  'title': 'fix: apply review comments from merged PR #${ORIGINAL_PR_ID}',
  'description': 'Follow-up to !${ORIGINAL_PR_ID}. Applies the actionable review comments that were not addressed before merge.',
  'sourceRefName': 'refs/heads/${NEW_BRANCH}',
  'targetRefName': 'refs/heads/${BASE_BRANCH}'
}))
")"
```

---

## Output

On completion:

```
Resolution complete on PR #<id>: <N> applied, <N> discussed, <N> declined — ${API_BASE}/_git/<repo>/pullrequest/<id>
```
