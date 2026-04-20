# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## Prerequisites

The Azure DevOps REST API is called directly via `curl` using a Personal Access Token (PAT).

Required environment variable:

| Variable | Purpose |
|---|---|
| `AZURE_DEVOPS_TOKEN` | Azure DevOps PAT — must include `Code (Read & Write)` and `Pull Request Threads (Read & Write)` |

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

## Resolving the PR Number

If no PR number was passed as an argument, find the active PR for the current branch:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)

curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH}&searchCriteria.status=active&api-version=7.1" \
  | python3 -c "import sys,json; prs=json.load(sys.stdin)['value']; print(prs[0]['pullRequestId'] if prs else '')"
```

Store the result as `PR_ID`. If empty, the branch has no open PR — output a warning and skip posting.

---

## Reading PR labels (to confirm fix-PR mode)

Fix-PR mode is opt-in. Before opening any optimization PR, confirm that either the `ai-dlc/pr/perf-optimize-fix` label is present on the source PR **or** the invocation passed `--fix-pr`.

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/labels?api-version=7.1-preview.1" \
  | python3 -c "import sys,json; print('\n'.join(l['name'] for l in json.load(sys.stdin).get('value', [])))"
```

If `ai-dlc/pr/perf-optimize-fix` is **not** in the output and `--fix-pr` was **not** passed, stop after posting the analysis report — **do not** proceed to open an optimization PR.

---

## Markdown in PR threads

This plugin posts via the **Git** [Pull Request Threads](https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pull-request-threads/create?view=azure-devops-rest-7.1) API. Put Markdown in `comments[].content` and set thread `properties` so the web UI renders Markdown:

| Key | Value |
|---|---|
| `Microsoft.TeamFoundation.Discussion.SupportsMarkdown` | `1` (integer) |

Include the same `properties` object on **every** `POST .../threads` body below.

---

## Posting the Starting Comment

Before running any analyzers, post a plain PR comment thread so the author knows the Performance Optimizer Agent has started.

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads?api-version=7.1" \
  -d '{"comments":[{"content":"⚡ **Performance analysis in progress**\n\nI'\''m running an analysis-first performance review covering latency, CPU, memory, and I/O patterns in this change. The consolidated report will be posted here when complete — this may take a few minutes.\n\n_No code changes will be made during analysis. A separate optimization PR is created only when the `ai-dlc/pr/perf-optimize-fix` tag is applied._","commentType":1}],"status":"active","properties":{"Microsoft.TeamFoundation.Discussion.SupportsMarkdown":1}}'
```

If posting fails, output a single warning line and continue — never stop the analysis.

---

## Posting the Analysis Report

Post the compiled report body (per `styles/report-template.md`) as a new PR thread:

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
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
" <<'REPORT'
${REPORT_BODY}
REPORT
)"
```

The Performance Optimizer Agent posts **one consolidated comment** — it does not cast a reviewer vote. The fix-PR phase is the only path that introduces code changes, and those go on a separate branch (see below), not as reviewer approval / rejection on the source PR.

---

## Creating the optimization PR (fix-PR mode only)

Enter this section **only** after the `fix-pr-author` agent has applied Quick-win findings on a new branch and pushed it.

### 1. Push the optimization branch

The agent has already run:

```bash
git push -u origin "${NEW_BRANCH}"
```

### 2. Create the PR via REST

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests?api-version=7.1" \
  -d "$(python3 -c "
import json
print(json.dumps({
  'sourceRefName': 'refs/heads/${NEW_BRANCH}',
  'targetRefName': 'refs/heads/${SOURCE_BASE_BRANCH}',
  'title': 'perf: optimizations for PR #${SOURCE_PR_NUMBER}',
  'description': '''${PR_BODY_MARKDOWN}'''
}))
")"
```

Where `${PR_BODY_MARKDOWN}` contains, in order:

1. Summary paragraph
2. Links to the source PR and the analysis comment
3. Applied optimizations table
4. Not-applied list (or "None")
5. Verification checklist (as literal `- [ ]` items)
6. Expected impact notes (qualitative only — do not fabricate numbers)

Capture the returned `pullRequestId` and construct the web URL:

```
${API_BASE}/_git/${AZURE_REPO}/pullrequest/<new-pr-id>
```

### 3. Link the new PR back to the source PR

Post a comment thread on the **source** PR pointing to the optimization PR:

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${SOURCE_PR_NUMBER}/threads?api-version=7.1" \
  -d "$(python3 -c "
import json
print(json.dumps({
  'comments': [{'content': '🔗 Optimization PR opened with focused, low-risk performance fixes: ${NEW_PR_URL}', 'commentType': 1}],
  'status': 'active',
  'properties': {'Microsoft.TeamFoundation.Discussion.SupportsMarkdown': 1}
}))
")"
```

### 4. Output

```
Optimization PR opened: ${NEW_PR_URL} — targets ${SOURCE_BASE_BRANCH}, linked to source PR #${SOURCE_PR_NUMBER}
```

If the REST call fails (missing scope, branch policy, duplicate PR), emit one error line and stop. Do **not** retry with different auth. Do **not** rewrite the source branch.
