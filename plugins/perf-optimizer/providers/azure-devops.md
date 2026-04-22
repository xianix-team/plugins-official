# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## Prerequisites

The Azure DevOps REST API is called directly via `curl` using a Personal Access Token (PAT).

Required environment variable:

| Variable | Purpose |
|---|---|
| `AZURE_DEVOPS_TOKEN` | Azure DevOps PAT — must include `Code (Read & Write)`, `Work Items (Read & Write)`, and `Pull Request Threads (Read & Write)` |

Optional — used to override values parsed from the remote URL:

| Variable | Default |
|---|---|
| `AZURE_ORG` | Parsed from remote URL |
| `AZURE_PROJECT` | Parsed from remote URL |
| `AZURE_REPO` | Parsed from remote URL |

---

## Parsing the Remote URL

**Modern format:** `https://dev.azure.com/{org}/{project}/_git/{repo}`

```bash
REMOTE=$(git remote get-url origin)
AZURE_ORG=$(echo   "$REMOTE" | sed 's|https://dev.azure.com/||' | cut -d'/' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | sed 's|https://dev.azure.com/||' | cut -d'/' -f2)
AZURE_REPO=$(echo  "$REMOTE" | sed 's|.*/_git/||' | sed 's|\.git$||')
```

**Legacy format:** `https://{org}.visualstudio.com/{project}/_git/{repo}`

```bash
AZURE_ORG=$(echo   "$REMOTE" | sed 's|https://||' | cut -d'.' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | cut -d'/' -f4)
AZURE_REPO=$(echo  "$REMOTE" | sed 's|.*/_git/||' | sed 's|\.git$||')
```

### API Base URL

```bash
if [[ "$REMOTE" =~ \.visualstudio\.com ]]; then
  API_BASE="https://${AZURE_ORG}.visualstudio.com/${AZURE_PROJECT}"
else
  API_BASE="https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}"
fi
```

Use `${API_BASE}` in place of a hardcoded host for **every** API call below.

---

## Reading the trigger work item

The orchestrator receives the work item title / description via the rule payload. If you need to re-read it (e.g. local runs), use:

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "https://dev.azure.com/${AZURE_ORG}/_apis/wit/workitems/${WORKITEM_ID}?\$expand=fields&api-version=7.1" \
  | python3 -c "
import sys, json
wi = json.load(sys.stdin)
print(json.dumps({
  'id': wi['id'],
  'title': wi['fields']['System.Title'],
  'description': wi['fields'].get('System.Description', ''),
  'tags': wi['fields'].get('System.Tags', '')
}))"
```

Parse lines matching `^\s*Scope:` and `^\s*Target:` (case-insensitive) from the description.

---

## Markdown in PR / work-item threads

This plugin posts via the **Git** [Pull Request Threads](https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pull-request-threads/create?view=azure-devops-rest-7.1) API for pull requests, and the **Work Item Comments** API for the originating work item. Put Markdown in `content` / `comments[].content` and set thread `properties` on PR threads so the web UI renders Markdown:

| Key | Value |
|---|---|
| `Microsoft.TeamFoundation.Discussion.SupportsMarkdown` | `1` (integer) |

Include the same `properties` object on **every** PR `POST .../threads` body below.

---

## Posting the Starting Comment on the work item

Post a comment on the originating work item so the reporter knows the Performance Optimizer has started.

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit/workItems/${WORKITEM_ID}/comments?api-version=7.1-preview.3" \
  -d '{"text":"Performance review in progress.\n\nI am running a whole-codebase performance review covering latency, CPU, memory, and I/O patterns against the default branch. A pull request with focused, low-risk optimizations and the embedded report will be linked here when complete — this may take a few minutes."}'
```

If posting fails, output a single warning line and continue — never stop the review.

---

## Creating the pull request

Enter this section **only** after the `perf-pr-author` agent has applied Quick-win findings on a new branch and pushed it.

### 1. Push the optimization branch

Performed by `perf-pr-author`:

```bash
git push -u origin "${NEW_BRANCH}"
```

### 2. Create the PR via REST

The PR body MUST contain, in order: summary, `Related work item: #${WORKITEM_ID}` plus `AB#${WORKITEM_ID}`, applied-optimizations table, not-applied list, verification checklist, and the full performance report body.

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?api-version=7.1" \
  -d "$(python3 -c "
import json, os
print(json.dumps({
  'sourceRefName': f\"refs/heads/{os.environ['NEW_BRANCH']}\",
  'targetRefName': f\"refs/heads/{os.environ['DEFAULT_BRANCH']}\",
  'title': f\"perf: {os.environ['WORKITEM_TITLE']}\",
  'description': os.environ['PR_BODY_MARKDOWN']
}))
")"
```

Where `${PR_BODY_MARKDOWN}` is the pre-assembled body string containing:

1. Summary paragraph
2. `Related work item: #${WORKITEM_ID}` and an `AB#${WORKITEM_ID}` smart commit reference (for Azure Boards auto-linking)
3. Applied-optimizations table
4. Not-applied list (or "None")
5. Verification checklist (literal `- [ ]` items)
6. `## Performance Report` heading followed by the full, already-compiled report body

Capture the returned `pullRequestId` and construct the web URL:

```
${API_BASE}/_git/${AZURE_REPO}/pullrequest/<new-pr-id>
```

### 3. Link the PR back to the work item

Post a comment thread on the originating work item pointing to the new PR:

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit/workItems/${WORKITEM_ID}/comments?api-version=7.1-preview.3" \
  -d "$(python3 -c "
import json, os
print(json.dumps({'text': f\"Performance PR opened with focused, low-risk optimizations: {os.environ['NEW_PR_URL']}\"}))
")"
```

Optionally attach the PR to the work item as a `Pull Request` artifact link via the Work Item Updates API — this surfaces the PR directly on the work item card in Azure Boards.

### 4. Output

```
Performance PR opened: ${NEW_PR_URL} — targets ${DEFAULT_BRANCH}, linked to work item #${WORKITEM_ID}
```

If the REST call fails (missing scope, branch policy, duplicate PR), emit one error line and stop. Do **not** retry with different auth. Do **not** rewrite the default branch.
