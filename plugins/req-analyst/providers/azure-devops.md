# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## Prerequisites

The Azure DevOps REST API is called directly via `curl` using a Personal Access Token (PAT).

Required environment variable:

| Variable | Purpose |
|---|---|
| `AZURE-DEVOPS-TOKEN` | Azure DevOps PAT — must have `Work Items (Read & Write)` scopes |

Optional — used to override values parsed from the remote URL:

| Variable | Default |
|---|---|
| `AZURE_ORG` | Parsed from remote URL |
| `AZURE_PROJECT` | Parsed from remote URL |

---

## Parsing the Remote URL

Extract org and project from the remote URL before making any API calls.

**HTTPS format:** `https://dev.azure.com/{org}/{project}/_git/{repo}`

```bash
REMOTE=$(git remote get-url origin)

AZURE_ORG=$(echo "$REMOTE"   | sed 's|https://dev.azure.com/||' | cut -d'/' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | sed 's|https://dev.azure.com/||' | cut -d'/' -f2)
```

**Legacy HTTPS format:** `https://{org}.visualstudio.com/{project}/_git/{repo}`

```bash
AZURE_ORG=$(echo "$REMOTE"   | sed 's|https://||' | cut -d'.' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | cut -d'/' -f4)
```

---

## Fetching Work Item Details

Fetch the full work item with all fields, comments, and relations:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit/workitems/${WORK_ITEM_ID}?api-version=7.1&\$expand=all"
```

Extract from the response:
- `fields.System.Title` — title
- `fields.System.Description` — body/description (HTML)
- `fields.System.WorkItemType` — Bug, User Story, Task, etc.
- `fields.System.State` — New, Active, Closed, etc.
- `fields.System.Tags` — existing tags
- `fields.System.AssignedTo` — assigned person
- `fields.System.IterationPath` — sprint/iteration
- `fields.System.AreaPath` — area/team
- `relations` — linked work items (parent, child, related)
- `comments` (from `$expand=all`) — prior discussion

---

## Finding Related Work Items

Query for related items in the same iteration or area path using WIQL:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit/wiql?api-version=7.1" \
  -d "{\"query\": \"SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType] FROM WorkItems WHERE [System.IterationPath] = '${ITERATION_PATH}' AND [System.Id] <> ${WORK_ITEM_ID} ORDER BY [System.Id] DESC\"}"
```

Then fetch details for each related item ID:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit/workitems?ids=${ID1},${ID2},${ID3}&api-version=7.1"
```

---

## Posting the Elaboration

The original work item description is **never modified**. All elaboration is posted as **separate comments** — one per lens.

### Comment Order

Post each lens as its own work item comment. Each comment must have a clear heading.

| # | Comment | Heading | Source |
|---|---------|---------|--------|
| 1 | Elaboration Summary | `## 📋 Elaboration Summary` | Orchestrator (compiled) |
| 2 | Fit with Existing Requirements | `## 🧩 Fit with Existing Requirements` | Orchestrator (from doc indexing in Step 2) |
| 3 | Intent & User Context | `## 🔍 Intent & User Context` | intent-analyst |
| 4 | User Journey | `## 🗺️ User Journey` | journey-mapper |
| 5 | Personas & Adoption | `## 👥 Personas & Adoption` | persona-analyst |
| 6 | Domain & Competitive Context | `## 🏢 Domain & Competitive Context` | domain-analyst |
| 7 | Open Questions & Gaps | `## ❓ Open Questions & Gaps` | gap-risk-analyst |

**Skip** any comment whose source produced no meaningful findings (e.g. a narrow bug fix may not need Journey, Personas, or Fit).

### Posting each comment

Azure DevOps must be told that comment bodies are Markdown. If you omit `format=markdown`, the API stores the text as plain content and the UI shows `##`, tables, and emphasis as raw characters.

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit/workitems/${WORK_ITEM_ID}/comments?format=markdown&api-version=7.1-preview.4" \
  -d "$(python3 -c "
import json, sys
body = sys.stdin.read()
print(json.dumps({'text': body}))
" <<'COMMENT'
${COMMENT_BODY}
COMMENT
)"
```

### Applying the readiness signal tag

After posting all comments, add the readiness signal tag without replacing existing tags:

```bash
EXISTING_TAGS=$(curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit/workitems/${WORK_ITEM_ID}?api-version=7.1&fields=System.Tags" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('fields',{}).get('System.Tags',''))")

NEW_TAGS="${EXISTING_TAGS}; ${SIGNAL_TAG}"

curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X PATCH \
  -H "Content-Type: application/json-patch+json" \
  "https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit/workitems/${WORK_ITEM_ID}?api-version=7.1" \
  -d "$(python3 -c "
import json
print(json.dumps([
  {'op': 'replace', 'path': '/fields/System.Tags', 'value': '''${NEW_TAGS}'''}
]))
")"
```

| Plugin signal | Azure DevOps tag |
|---|---|
| `GROOMED` | `groomed` |
| `NEEDS CLARIFICATION` | `needs-clarification` |
| `NEEDS DECOMPOSITION` | `needs-decomposition` |

---

## Output

On completion:

```
Elaboration posted on work item #<id>: <signal> — <N> comments — <N> open questions
```
