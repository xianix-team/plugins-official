# Provider: Azure DevOps

Use when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## Prerequisites

| Variable | Scopes |
|---|---|
| `AZURE-DEVOPS-TOKEN` | Work Items (Read & Write), Code (Read & Write) — pushes `design/*` branches and opens PRs |

## Parsing the remote

```bash
REMOTE=$(git remote get-url origin)
# https://dev.azure.com/{org}/{project}/_git/{repo}
AZURE_ORG=$(echo "$REMOTE"     | sed 's|https://[^@]*@||;s|https://||' | sed 's|dev.azure.com/||' | cut -d'/' -f1)
AZURE_PROJECT=$(echo "$REMOTE" | sed 's|https://[^@]*@||;s|https://||' | sed 's|dev.azure.com/||' | cut -d'/' -f2)
AZURE_REPO=$(echo "$REMOTE"    | sed 's|.*/_git/||;s|\.git$||')
```

Legacy `https://{org}.visualstudio.com/{project}/_git/{repo}`: org is the subdomain, project is path segment 1.

```bash
WIT="https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/wit"
GIT="https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_apis/git/repositories/${AZURE_REPO}"
DEFAULT_BRANCH=$(curl -s -u ":${AZURE-DEVOPS-TOKEN}" "${GIT}?api-version=7.1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['defaultBranch'].replace('refs/heads/',''))")
```

---

## Fetching the work item and thread

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" "${WIT}/workitems/${WORK_ITEM_ID}?api-version=7.1&\$expand=all"
curl -s -u ":${AZURE-DEVOPS-TOKEN}" "${WIT}/workItems/${WORK_ITEM_ID}/comments?order=asc&\$top=200&api-version=7.1-preview.4"
```

Use `System.Title`, `System.Description`, `Microsoft.VSTS.Common.AcceptanceCriteria`, `System.Tags`, `System.WorkItemType`, and `_links.html.href` (item URL). From comments: `id`, `createdBy.displayName`, `createdDate`, `text` (HTML).

**Groomed check:** `groomed` in `System.Tags`, or a comment containing `req-analyst ·` and `status: ready`.

**Description last edited** (STALE check) — the newest update that touched the description or acceptance criteria:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" "${WIT}/workItems/${WORK_ITEM_ID}/updates?api-version=7.1" \
  | python3 -c "
import sys, json
ups = json.load(sys.stdin)['value']
keys = ('System.Description', 'Microsoft.VSTS.Common.AcceptanceCriteria')
ts = [u['revisedDate'] if not u['revisedDate'].startswith('9999') else u['fields'].get('System.ChangedDate', {}).get('newValue')
      for u in ups if any(k in u.get('fields', {}) for k in keys)]
print(ts[-1] if ts else '')"
```

## Acknowledging a comment

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X PUT \
  "${WIT}/workItems/${WORK_ITEM_ID}/comments/${COMMENT_ID}/reactions/like?api-version=7.1-preview.1"
```

---

## Design branch, commit, push

Same git commands as the GitHub provider, with `DESIGN_BRANCH="design/workitem-${WORK_ITEM_ID}-${SLUG}"` and the lookup pattern `design/workitem-${WORK_ITEM_ID}-*`. The pre-tool hook injects `AZURE-DEVOPS-TOKEN` for the push.

## Design PR

Find existing (any status):

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${GIT}/pullrequests?searchCriteria.sourceRefName=refs/heads/${DESIGN_BRANCH}&searchCriteria.status=all&api-version=7.1"
```

`status == "completed"` means merged → approved (report `closedBy.displayName`).

Create, linked to the work item:

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X POST -H "Content-Type: application/json" \
  "${GIT}/pullrequests?api-version=7.1" \
  -d "$(python3 - <<PY
import json
print(json.dumps({
  "sourceRefName": "refs/heads/${DESIGN_BRANCH}",
  "targetRefName": "refs/heads/${DEFAULT_BRANCH}",
  "title": "Design: ${WORKITEM_TITLE} (#${WORK_ITEM_ID})",
  "description": open('/tmp/design-pr.md').read(),
  "workItemRefs": [{"id": "${WORK_ITEM_ID}"}]
}))
PY
)"
```

PR web URL: `https://dev.azure.com/${AZURE_ORG}/${AZURE_PROJECT}/_git/${AZURE_REPO}/pullrequest/<pullRequestId>`.

---

## Posting a comment

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X POST -H "Content-Type: application/json" \
  "${WIT}/workItems/${WORK_ITEM_ID}/comments?format=markdown&api-version=7.1-preview.4" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))' < /tmp/design-comment.md)"
```

## Swapping the design tag

```bash
NEW_TAG="design-proposed"   # or design-needs-decision / design-approved

NEW_TAGS=$(curl -s -u ":${AZURE-DEVOPS-TOKEN}" "${WIT}/workitems/${WORK_ITEM_ID}?api-version=7.1&fields=System.Tags" \
  | python3 -c "
import sys, json
tags = [t.strip() for t in json.load(sys.stdin).get('fields', {}).get('System.Tags', '').split(';') if t.strip()]
tags = [t for t in tags if t not in ('design-needs-decision', 'design-proposed', 'design-approved')]
tags.append('${NEW_TAG}')
print('; '.join(tags))")

curl -s -u ":${AZURE-DEVOPS-TOKEN}" -X PATCH -H "Content-Type: application/json-patch+json" \
  "${WIT}/workitems/${WORK_ITEM_ID}?api-version=7.1" \
  -d "$(python3 -c "import json; print(json.dumps([{'op':'replace','path':'/fields/System.Tags','value':'''${NEW_TAGS}'''}]))")"
```

Never remove `ai-dlc/issue/design` or `groomed`.
