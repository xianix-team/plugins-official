# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## How this fits with the rest of the plugin

- **Reading / analysis** — Use **git** for diffs, **`curl`** + `AZURE_DEVOPS_TOKEN` for work items and PR metadata.
- **Azure DevOps-specific** — The HTML report is **attached as a file** to the work item via the REST API, and a brief notification comment is posted on the work item (and on the PR if triggered from a PR).

## Prerequisites

The Azure DevOps REST API is called directly via `curl` using a Personal Access Token (PAT).

Required environment variable:

| Variable | Purpose |
|---|---|
| `AZURE_DEVOPS_TOKEN` | Azure DevOps PAT |

### Token Permissions

| Permission | Access | Why it's needed |
|---|---|---|
| **Work Items** | Read & Write | Fetch fields, repro steps, acceptance criteria, root cause, and comments; post the report |
| **Code** | Read | Access PR diffs, file history, commit details, and changesets |
| **Pull Requests** | Read | Fetch PR metadata and navigate work item ↔ PR links |

Optional — used to override values parsed from the remote URL:

| Variable | Default |
|---|---|
| `AZURE_ORG` | Parsed from remote URL |
| `AZURE_PROJECT` | Parsed from remote URL |
| `AZURE_REPO` | Parsed from remote URL |

---

## Parsing the Remote URL

Extract org, project, and repo from the remote URL before making any API calls.

**HTTPS format:** `https://dev.azure.com/{org}/{project}/_git/{repo}`

```bash
REMOTE=$(git remote get-url origin)

AZURE_ORG=$(echo "$REMOTE"   | sed 's|https://dev.azure.com/||' | cut -d'/' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | sed 's|https://dev.azure.com/||' | cut -d'/' -f2)
AZURE_REPO=$(echo "$REMOTE"  | sed 's|.*/_git/||' | sed 's|\.git$||')
```

**Legacy HTTPS format:** `https://{org}.visualstudio.com/{project}/_git/{repo}`

```bash
AZURE_ORG=$(echo "$REMOTE"   | sed 's|https://||' | cut -d'.' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | cut -d'/' -f4)
AZURE_REPO=$(echo "$REMOTE"  | sed 's|.*/_git/||' | sed 's|\.git$||')
```

### API Base URL

```bash
if [[ "$REMOTE" =~ \.visualstudio\.com ]]; then
  API_BASE="https://${AZURE_ORG}.visualstudio.com/${AZURE_PROJECT}"
else
  API_BASE="https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}"
fi
```

Use `${API_BASE}` for every API call below.

---

## Entry Point: Work Item (`wi`)

### Fetching Work Item Details

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/wit/workitems/${WORK_ITEM_ID}?api-version=7.1&\$expand=all"
```

Extract from the response:
- `fields.System.Title` — title
- `fields.System.Description` — body/description (HTML)
- `fields.Microsoft.VSTS.Common.AcceptanceCriteria` — acceptance criteria (PBI/Feature)
- `fields.Microsoft.VSTS.TCM.ReproSteps` — reproduction steps (Bug)
- `fields.Microsoft.VSTS.Common.RootCause` — root cause analysis (Bug)
- `fields.System.WorkItemType` — Bug, User Story, Task, etc.
- `fields.System.State` — New, Active, Closed, etc.
- `fields.Microsoft.VSTS.Common.Severity` — severity
- `fields.Microsoft.VSTS.Common.Priority` — priority
- `fields.System.Tags` — existing tags
- `fields.System.AssignedTo` — assigned developer
- `fields.Microsoft.VSTS.Common.ActivatedBy` — tester (or look for a custom field)
- `fields.System.IterationPath` — sprint/iteration
- `fields.System.AreaPath` — area/team
- `relations` — linked work items (parent, child, related) and **pull request links** and **changesets**
- `comments` (from `$expand=all`) — prior discussion

### Fetching Child Work Items

From the work item `relations`, filter for child links (`System.LinkTypes.Hierarchy-Forward`):

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/wit/workitems?ids=${CHILD_IDS_CSV}&api-version=7.1&\$expand=all"
```

For each child, extract title, description, acceptance criteria, repro steps, state, and tags.

### Fetching Linked Pull Requests

From the work item `relations`, filter for pull request links (`ArtifactLink` with `vstfs:///Git/PullRequestId/`):

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1"
```

### Fetching Changesets

From the work item `relations`, filter for changeset links (`ArtifactLink` with `vstfs:///VersionControl/Changeset/`):

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/tfvc/changesets/${CHANGESET_ID}?api-version=7.1&includeDetails=true"

# Get changeset changes
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/tfvc/changesets/${CHANGESET_ID}/changes?api-version=7.1"
```

---

## Entry Point: PR (`pr`)

### Fetching PR Details

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1"
```

### Discovering Linked Work Items from a PR

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/workitems?api-version=7.1"
```

For each linked work item, fetch it with `$expand=all` (see above).

### PR Iterations and Changes

```bash
# Get iterations (each push to the PR)
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/iterations?api-version=7.1"

# Get changes for the latest iteration
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/iterations/${ITERATION_ID}/changes?api-version=7.1"
```

Alternatively, use git locally if the PR branch is available:

```bash
git diff origin/${BASE}...${PR_BRANCH}
```

---

## Finding Related Work Items

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/wit/wiql?api-version=7.1" \
  -d "{\"query\": \"SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType] FROM WorkItems WHERE [System.IterationPath] = '${ITERATION_PATH}' AND [System.Id] <> ${WORK_ITEM_ID} ORDER BY [System.Id] DESC\"}"
```

---

## Posting the Report

On Azure DevOps, the HTML report is **attached as a file** to the work item, and a brief notification comment is posted.

### 1. Attach the HTML report to the work item

First, upload the file as an attachment:

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/octet-stream" \
  "${API_BASE}/_apis/wit/attachments?fileName=impact-analysis-report.html&api-version=7.1" \
  --data-binary @impact-analysis-report.html
```

Extract the `url` from the response — this is the attachment URL.

Then link the attachment to the work item:

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X PATCH \
  -H "Content-Type: application/json-patch+json" \
  "${API_BASE}/_apis/wit/workitems/${WORK_ITEM_ID}?api-version=7.1" \
  -d "$(python3 -c "
import json
print(json.dumps([
  {
    'op': 'add',
    'path': '/relations/-',
    'value': {
      'rel': 'AttachedFile',
      'url': '${ATTACHMENT_URL}',
      'attributes': {
        'comment': 'Impact Analysis & Test Strategy Report — generated by Test Strategist plugin'
      }
    }
  }
]))
")"
```

### 2. Post a notification comment on the work item

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/wit/workitems/${WORK_ITEM_ID}/comments?format=markdown&api-version=7.1-preview.4" \
  -d "$(python3 -c "
import json, sys
body = sys.stdin.read()
print(json.dumps({'text': body}))
" <<'COMMENT'
## 🧪 Impact Analysis & Test Strategy Generated

**Overall Risk:** ${RISK_LEVEL}
**Test Cases:** ${TOTAL_COUNT} (🟢 ${FUNCTIONAL} Functional | 🔵 ${PERF} Performance | 🔴 ${SECURITY} Security | 🟡 ${PRIVACY} Privacy | 🟣 ${A11Y} Accessibility | ⚪ ${RESILIENCE} Resilience | 🟤 ${COMPAT} Compatibility)

${EXECUTIVE_SUMMARY}

**Developer Changes Requiring Clarification:** ${CLARIFICATION_COUNT} items flagged — review before testing begins.

📎 The full HTML report has been attached to this work item.
COMMENT
)"
```

### 3. If triggered from a PR, also post a notification on the PR

```bash
curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads?api-version=7.1" \
  -d '{"comments":[{"content":"🧪 **Impact analysis & test strategy generated** for work item #'"${WORK_ITEM_ID}"'.\n\nThe full HTML report has been attached to the work item. Overall risk: '"${RISK_LEVEL}"' — '"${TOTAL_COUNT}"' test cases generated.","commentType":1}],"status":"active","properties":{"Microsoft.TeamFoundation.Discussion.SupportsMarkdown":1}}'
```

### 4. Apply the tag

```bash
EXISTING_TAGS=$(curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  "${API_BASE}/_apis/wit/workitems/${WORK_ITEM_ID}?api-version=7.1&fields=System.Tags" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('fields',{}).get('System.Tags',''))")

NEW_TAGS="${EXISTING_TAGS}; test-strategy-generated"

curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
  -X PATCH \
  -H "Content-Type: application/json-patch+json" \
  "${API_BASE}/_apis/wit/workitems/${WORK_ITEM_ID}?api-version=7.1" \
  -d "$(python3 -c "
import json
print(json.dumps([
  {'op': 'replace', 'path': '/fields/System.Tags', 'value': '''${NEW_TAGS}'''}
]))
")"
```

---

## Output

On completion:

```
Impact analysis and test strategy generated for <entry-type> #<id>: <risk-level> — <N> test cases — report written to impact-analysis-report.html
```
