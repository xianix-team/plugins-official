# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## Prerequisites

The Azure DevOps REST API is called directly via `curl` using a Personal Access Token (PAT).

| Variable | Purpose |
|---|---|
| `AZURE-DEVOPS-TOKEN` | PAT with `Work Items (Read & Write)` scope — the plugin edits the description and tags, not just comments |

Optional overrides: `AZURE_ORG`, `AZURE_PROJECT` (otherwise parsed from the remote URL).

---

## Parsing the Remote URL

**HTTPS:** `https://dev.azure.com/{org}/{project}/_git/{repo}`

```bash
REMOTE=$(git remote get-url origin)
AZURE_ORG=$(echo "$REMOTE"     | sed 's|https://dev.azure.com/||' | cut -d'/' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | sed 's|https://dev.azure.com/||' | cut -d'/' -f2)
```

**Legacy:** `https://{org}.visualstudio.com/{project}/_git/{repo}`

```bash
AZURE_ORG=$(echo "$REMOTE"     | sed 's|https://||' | cut -d'.' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | cut -d'/' -f4)
```

Set `BASE="https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit"` for the calls below.

---

## Fetching the Work Item

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${BASE}/workitems/${WORK_ITEM_ID}?api-version=7.1&\$expand=all"
```

Extract: `System.Title`, `System.Description` (HTML), `System.WorkItemType`, `System.State`, `System.Tags` (`;`-separated), `System.AssignedTo`, `System.IterationPath`, `System.AreaPath`, `Microsoft.VSTS.Common.AcceptanceCriteria` (if present), and `relations`.

## Fetching the Full Discussion Thread

Comments are **not** included in the work item payload. Fetch them separately:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${BASE}/workItems/${WORK_ITEM_ID}/comments?order=asc&\$top=200&api-version=7.1-preview.4"
```

From `comments[]` use:

| Field | Purpose |
|---|---|
| `id` | Needed for reactions |
| `createdBy.displayName` / `createdBy.uniqueName` | Who wrote it |
| `createdDate` | Ordering |
| `text` | Content (HTML). Look for the `` req-analyst · `` footer marker, `@xianix` mentions (rendered as `<a data-vss-mention …>`), numbered answers |

Identify agent comments by the footer marker. If needed, the current identity is:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1"
```

### Finding related work items (analysis context only)

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X POST -H "Content-Type: application/json" \
  "${BASE}/wiql?api-version=7.1" \
  -d "{\"query\": \"SELECT [System.Id], [System.Title], [System.State] FROM WorkItems WHERE [System.IterationPath] = '${ITERATION_PATH}' AND [System.Id] <> ${WORK_ITEM_ID} ORDER BY [System.Id] DESC\"}"
```

---

## Acknowledging a Human Comment

React to the comment you are acting on before doing long work on a follow-up round:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X PUT \
  "${BASE}/workItems/${WORK_ITEM_ID}/comments/${COMMENT_ID}/reactions/like?api-version=7.1-preview.1"
```

No "in progress" comment on follow-up rounds.

---

## Posting the Round-1 Starting Comment

Only on the very first turn:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X POST -H "Content-Type: application/json" \
  "${BASE}/workItems/${WORK_ITEM_ID}/comments?format=markdown&api-version=7.1-preview.4" \
  -d '{"text":"Looking at this now — I will come back with a few clarifying questions in a couple of minutes."}'
```

---

## Posting a Round Comment

Always pass `format=markdown`, otherwise headings and emphasis render as raw characters. Omit `<details>` blocks — they do not render reliably in work item discussions.

```bash
cat > /tmp/req-analyst-comment.md <<'EOF'
## Requirement analysis — round 1 of 3

...

---
`req-analyst` · round 1/3 · status: **awaiting answers** · open: 3
EOF

curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X POST -H "Content-Type: application/json" \
  "${BASE}/workItems/${WORK_ITEM_ID}/comments?format=markdown&api-version=7.1-preview.4" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))' < /tmp/req-analyst-comment.md)"
```

Post **one** comment per invocation.

---

## Updating the Description and Acceptance Criteria

`System.Description` is HTML. Write the HTML version from `styles/refined-description-template.md`.

If `System.WorkItemType` is `User Story` or `Product Backlog Item` (or the item already has `Microsoft.VSTS.Common.AcceptanceCriteria`), write acceptance criteria into that field; otherwise include them in the description.

```bash
cat > /tmp/req-analyst-desc.html <<'EOF'
<p><em>req-analyst managed section — humans may edit; the agent rewrites it as decisions land in the discussion.</em></p>
<h2>Summary</h2>
...
<h2>Original description</h2>
<blockquote>…original System.Description HTML, unchanged…</blockquote>
EOF

cat > /tmp/req-analyst-ac.html <<'EOF'
<ul>
  <li><strong>Given</strong> … <strong>when</strong> … <strong>then</strong> …</li>
</ul>
EOF

curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X PATCH -H "Content-Type: application/json-patch+json" \
  "${BASE}/workitems/${WORK_ITEM_ID}?api-version=7.1" \
  -d "$(python3 - <<'PY'
import json
ops = [
  {"op": "add", "path": "/fields/System.Description", "value": open("/tmp/req-analyst-desc.html").read()},
  {"op": "add", "path": "/fields/Microsoft.VSTS.Common.AcceptanceCriteria", "value": open("/tmp/req-analyst-ac.html").read()},
]
print(json.dumps(ops))
PY
)"
```

Drop the `AcceptanceCriteria` op for types that do not have the field (Bug, Task) — the PATCH fails otherwise.

On the **first** edit, the `Original description` block receives the current `System.Description` exactly as fetched. On later edits, copy it forward unchanged.

---

## Swapping the Readiness Tag

Tags are one `;`-separated string. Remove the other readiness tags, add the new one, keep everything else (including `ai-dlc/issue/analyze`):

```bash
NEW_TAG="needs-clarification"   # or groomed / needs-decomposition

NEW_TAGS=$(curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${BASE}/workitems/${WORK_ITEM_ID}?api-version=7.1&fields=System.Tags" \
  | python3 -c "
import sys, json
tags = [t.strip() for t in json.load(sys.stdin).get('fields', {}).get('System.Tags', '').split(';') if t.strip()]
tags = [t for t in tags if t not in ('groomed', 'needs-clarification', 'needs-decomposition')]
tags.append('${NEW_TAG}')
print('; '.join(tags))")

curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X PATCH -H "Content-Type: application/json-patch+json" \
  "${BASE}/workitems/${WORK_ITEM_ID}?api-version=7.1" \
  -d "$(python3 -c "import json; print(json.dumps([{'op':'replace','path':'/fields/System.Tags','value':'''${NEW_TAGS}'''}]))")"
```

---

## Creating Child Work Items (confirmed decomposition only)

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X POST -H "Content-Type: application/json-patch+json" \
  "${BASE}/workitems/\$${CHILD_TYPE}?api-version=7.1" \
  -d "$(python3 -c "
import json
print(json.dumps([
  {'op':'add','path':'/fields/System.Title','value':'''${CHILD_TITLE}'''},
  {'op':'add','path':'/fields/System.Description','value':'''${CHILD_DESCRIPTION_HTML}'''},
  {'op':'add','path':'/fields/System.Tags','value':'ai-dlc/issue/analyze'},
  {'op':'add','path':'/relations/-','value':{'rel':'System.LinkTypes.Hierarchy-Reverse','url':'https://dev.azure.com/${AZURE_ORG}/_apis/wit/workItems/${WORK_ITEM_ID}'}}
]))")"
```

`CHILD_TYPE` is URL-encoded (`User%20Story`, `Product%20Backlog%20Item`, `Task`). The `Hierarchy-Reverse` relation makes the new item a child of the parent. Use the parent's iteration and area path when set.

---

## Output

On completion, one status line — see the orchestrator's Step 6.
