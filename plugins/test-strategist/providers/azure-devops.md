# Provider: Azure DevOps

Use this provider when `git remote get-url origin` contains `dev.azure.com` or `visualstudio.com`.

## How this fits with the rest of the plugin

- **Reading / analysis** — Use **git** for diffs, **`curl`** + `AZURE-DEVOPS-TOKEN` for work items and PR metadata.
- **Azure DevOps-specific** — The test strategy is posted as a **logical series of Markdown comments** on the work item discussion (or on the PR thread if entry was a PR with no linked work item). For work-item entries that are also linked to a PR, a single pointer thread is posted on the PR linking back to the work item discussion.

The deliverable is a **comment series**. Each comment is self-contained with a `[k/N]` header. The first comment includes a Table of Contents that deep-links to every other comment in the series.

**No HTML file is produced and nothing is written to the repository working tree.**

## Prerequisites

The Azure DevOps REST API is called directly via `curl` using a Personal Access Token (PAT).

Required environment variable:

| Variable | Purpose |
|---|---|
| `AZURE-DEVOPS-TOKEN` | Azure DevOps PAT |

### Token Permissions

| Permission | Access | Why it's needed |
|---|---|---|
| **Work Items** | Read & Write | Fetch fields, repro steps, acceptance criteria, root cause, and comments; post the comment series on the work item discussion |
| **Code** | Read | Access PR diffs, file history, commit details, and changesets |
| **Pull Requests** | Read & Write | Fetch PR metadata and navigate work item ↔ PR links; post the comment series on PR threads |

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
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
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
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/wit/workitems?ids=${CHILD_IDS_CSV}&api-version=7.1&\$expand=all"
```

For each child, extract title, description, acceptance criteria, repro steps, state, and tags.

### Fetching Linked Pull Requests

From the work item `relations`, filter for pull request links (`ArtifactLink` with `vstfs:///Git/PullRequestId/`):

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1"
```

### Fetching Changesets

From the work item `relations`, filter for changeset links (`ArtifactLink` with `vstfs:///VersionControl/Changeset/`):

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/tfvc/changesets/${CHANGESET_ID}?api-version=7.1&includeDetails=true"

# Get changeset changes
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/tfvc/changesets/${CHANGESET_ID}/changes?api-version=7.1"
```

---

## Entry Point: PR (`pr`)

### Fetching PR Details

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1"
```

### Discovering Linked Work Items from a PR

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/workitems?api-version=7.1"
```

For each linked work item, fetch it with `$expand=all` (see above).

### PR Iterations and Changes

```bash
# Get iterations (each push to the PR)
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/iterations?api-version=7.1"

# Get changes for the latest iteration
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/iterations/${ITERATION_ID}/changes?api-version=7.1"
```

Alternatively, use git locally if the PR branch is available:

```bash
git diff origin/${BASE}...${PR_BRANCH}
```

---

## Finding Related Work Items

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/wit/wiql?api-version=7.1" \
  -d "{\"query\": \"SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType] FROM WorkItems WHERE [System.IterationPath] = '${ITERATION_PATH}' AND [System.Id] <> ${WORK_ITEM_ID} ORDER BY [System.Id] DESC\"}"
```

---

## Posting the Comment Series

The `test-guide-writer` agent has produced a directory of Markdown files plus an `index.json` describing the planned series. Read the index, then post each comment in order, capture URLs, and finally PATCH Comment 1 to back-fill the Table of Contents.

### Where to post

| Entry point | Linked context | Post the series on |
|---|---|---|
| `wi <id>` | (work item only — possibly with linked PRs) | The **work item discussion** (`/wit/workItems/{id}/comments`) |
| `pr <id>` | Linked work item discovered | The **work item discussion** of the linked work item |
| `pr <id>` | No linked work item | The **PR thread** (`/pullrequests/{id}/threads`) |

When entry is `wi` and the work item is linked to one or more PRs, also post a **single pointer thread** on each linked PR after the series is complete (Step 4 below) — never duplicate the full series on the PR.

### Pre-flight

```bash
WORK_DIR="${1:-${TMPDIR:-/tmp}/test-strategy-${ENTRY_TYPE}-${ENTRY_ID}}"
INDEX="${WORK_DIR}/index.json"
test -f "${INDEX}" || { echo "test strategy index not found at ${INDEX}"; exit 1; }

POST_TARGET=$(jq -r '.azdo_post_target // empty' "${INDEX}")  # "workitem" or "prthread"
if [ -z "${POST_TARGET}" ]; then
  if [ -n "${WORK_ITEM_ID}" ]; then POST_TARGET="workitem"; else POST_TARGET="prthread"; fi
fi
TOTAL=$(jq -r '.comments | length' "${INDEX}")
```

The Azure DevOps comment-body limit is much higher than GitHub's (≈ 150 KB on PR threads, similar on work item discussions), so the per-comment 50 KB budget enforced by `test-guide-writer` always fits comfortably.

### Step 1 — Post Comment 1 (with placeholder TOC)

#### When `POST_TARGET=workitem` (entry = `wi`, or `pr` with linked work item)

```bash
COMMENT_1_FILE="${WORK_DIR}/$(jq -r '.comments[0].file' "${INDEX}")"

RESPONSE=$(curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/wit/workItems/${WORK_ITEM_ID}/comments?format=markdown&api-version=7.1-preview.4" \
  --data-binary @<(jq -Rs '{text: .}' < "${COMMENT_1_FILE}"))

COMMENT_1_ID=$(echo "${RESPONSE}" | jq -r '.id')
COMMENT_1_URL="${API_BASE}/_workitems/edit/${WORK_ITEM_ID}?discussionId=${COMMENT_1_ID}"
```

The work item discussion does not give comments a stable deep-link of the same form as GitHub. The URL above opens the work item with the discussion pane scrolled to (or near) the comment — Azure DevOps does not currently support per-comment fragment links, so we deep-link to the discussion as a whole. Treat `COMMENT_1_URL` as the canonical "first comment" URL throughout the series.

#### When `POST_TARGET=prthread` (entry = `pr` with no linked work item)

Each Markdown comment becomes the **first comment of its own thread**. We capture the thread id and treat the URL `${API_BASE}/_git/${AZURE_REPO}/pullrequest/${PR_ID}?_a=overview&discussionId=${THREAD_ID}` as the comment's deep link.

```bash
COMMENT_1_FILE="${WORK_DIR}/$(jq -r '.comments[0].file' "${INDEX}")"

RESPONSE=$(curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  -X POST \
  -H "Content-Type: application/json" \
  "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads?api-version=7.1" \
  --data-binary @<(jq -Rs '
    {
      comments: [{ content: ., commentType: 1 }],
      status: "active",
      properties: { "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1 }
    }
  ' < "${COMMENT_1_FILE}"))

COMMENT_1_THREAD_ID=$(echo "${RESPONSE}" | jq -r '.id')
COMMENT_1_ID=$(echo "${RESPONSE}" | jq -r '.comments[0].id')
COMMENT_1_URL="${API_BASE}/_git/${AZURE_REPO}/pullrequest/${PR_ID}?_a=overview&discussionId=${COMMENT_1_THREAD_ID}"
```

In both cases, persist the captured ids/URL into `index.json`:

```bash
jq --arg id "${COMMENT_1_ID}" --arg url "${COMMENT_1_URL}" --arg tid "${COMMENT_1_THREAD_ID:-}" \
  '.comments[0].id = $id | .comments[0].url = $url | .comments[0].thread_id = $tid' \
  "${INDEX}" > "${INDEX}.tmp" && mv "${INDEX}.tmp" "${INDEX}"
```

### Step 2 — Post Comments 2..N

For each subsequent comment, substitute the `${COMMENT_1_URL}` placeholder in the file body, then post.

```bash
for k in $(seq 1 $((TOTAL - 1))); do
  REL_FILE=$(jq -r ".comments[$k].file" "${INDEX}")
  ABS_FILE="${WORK_DIR}/${REL_FILE}"
  TITLE=$(jq -r ".comments[$k].title" "${INDEX}")
  BODY_FILE="${WORK_DIR}/.posting-buffer.md"
  sed "s|\${COMMENT_1_URL}|${COMMENT_1_URL}|g" "${ABS_FILE}" > "${BODY_FILE}"

  if [ "${POST_TARGET}" = "workitem" ]; then
    RESPONSE=$(curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
      -X POST \
      -H "Content-Type: application/json" \
      "${API_BASE}/_apis/wit/workItems/${WORK_ITEM_ID}/comments?format=markdown&api-version=7.1-preview.4" \
      --data-binary @<(jq -Rs '{text: .}' < "${BODY_FILE}"))
    ID=$(echo "${RESPONSE}" | jq -r '.id')
    URL="${API_BASE}/_workitems/edit/${WORK_ITEM_ID}?discussionId=${ID}"
    THREAD_ID=""
  else
    RESPONSE=$(curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
      -X POST \
      -H "Content-Type: application/json" \
      "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads?api-version=7.1" \
      --data-binary @<(jq -Rs '
        {
          comments: [{ content: ., commentType: 1 }],
          status: "active",
          properties: { "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1 }
        }
      ' < "${BODY_FILE}"))
    THREAD_ID=$(echo "${RESPONSE}" | jq -r '.id')
    ID=$(echo "${RESPONSE}" | jq -r '.comments[0].id')
    URL="${API_BASE}/_git/${AZURE_REPO}/pullrequest/${PR_ID}?_a=overview&discussionId=${THREAD_ID}"
  fi

  jq --argjson k $k --arg id "${ID}" --arg url "${URL}" --arg tid "${THREAD_ID}" \
    '.comments[$k].id = $id | .comments[$k].url = $url | .comments[$k].thread_id = $tid' \
    "${INDEX}" > "${INDEX}.tmp" && mv "${INDEX}.tmp" "${INDEX}"

  rm -f "${BODY_FILE}"
  echo "Posted [$((k + 1))/${TOTAL}] ${TITLE} → ${URL}"
done
```

### Step 3 — Back-fill the Table of Contents in Comment 1

Build the TOC from the captured URLs, then PATCH Comment 1.

```bash
TOC=$(jq -r '
  .comments
  | to_entries
  | map(
      "\(.key + 1). " +
      ( if .key == 0
        then "[\(.value.title)](\(.value.url)) (this comment)"
        else "[\(.value.title)](\(.value.url))"
        end )
    )
  | join("\n")
' "${INDEX}")

NEW_BODY=$(awk -v toc="${TOC}" '
  BEGIN { in_toc = 0 }
  /^## 📑 Contents/ { print; print ""; print toc; in_toc = 1; next }
  in_toc && /^> _The Contents links/ { in_toc = 0 }
  in_toc && /^---$/ { in_toc = 0 }
  !in_toc { print }
' "${COMMENT_1_FILE}")

echo "${NEW_BODY}" > "${WORK_DIR}/.toc-buffer.md"

if [ "${POST_TARGET}" = "workitem" ]; then
  curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    "${API_BASE}/_apis/wit/workItems/${WORK_ITEM_ID}/comments/${COMMENT_1_ID}?api-version=7.1-preview.4" \
    --data-binary @<(jq -Rs '{text: .}' < "${WORK_DIR}/.toc-buffer.md") >/dev/null
else
  curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads/${COMMENT_1_THREAD_ID}/comments/${COMMENT_1_ID}?api-version=7.1" \
    --data-binary @<(jq -Rs '{content: ., parentCommentId: 0, commentType: 1}' < "${WORK_DIR}/.toc-buffer.md") >/dev/null
fi

rm -f "${WORK_DIR}/.toc-buffer.md"
echo "Back-filled Contents in [1/${TOTAL}] → ${COMMENT_1_URL}"
```

If the PATCH fails the comment series is still readable — every comment carries its `[k/N]` header and a back-link to Comment 1. Surface the failure but do not retry more than once.

### Step 4 — Cross-link the work item ↔ PR (when applicable)

If entry was `wi` (or `pr` with linked work item) **and** there are linked PRs that did not host the series, post a single pointer thread on each such PR:

```bash
for PR_ID in ${LINKED_PR_IDS}; do
  curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
    -X POST \
    -H "Content-Type: application/json" \
    "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}/threads?api-version=7.1" \
    --data-binary "$(jq -n --arg url "${COMMENT_1_URL}" --arg wi "${WORK_ITEM_ID}" '
      {
        comments: [{
          content: ("🧪 **Test strategy generated** for work item #" + $wi + " — see the [comment series starting here](" + $url + ")."),
          commentType: 1
        }],
        status: "active",
        properties: { "Microsoft.TeamFoundation.Discussion.SupportsMarkdown": 1 }
      }
    ')" >/dev/null
done
```

If entry was `pr` with no linked work item and the series was posted on the PR thread directly, no cross-linking is needed.

### Step 5 — Apply the tag

```bash
if [ -n "${WORK_ITEM_ID}" ]; then
  EXISTING_TAGS=$(curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
    "${API_BASE}/_apis/wit/workitems/${WORK_ITEM_ID}?api-version=7.1&fields=System.Tags" \
    | jq -r '.fields["System.Tags"] // ""')

  if ! echo "${EXISTING_TAGS}" | grep -q "test-strategy-generated"; then
    NEW_TAGS=$( [ -z "${EXISTING_TAGS}" ] && echo "test-strategy-generated" || echo "${EXISTING_TAGS}; test-strategy-generated" )

    curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
      -X PATCH \
      -H "Content-Type: application/json-patch+json" \
      "${API_BASE}/_apis/wit/workitems/${WORK_ITEM_ID}?api-version=7.1" \
      --data-binary "$(jq -n --arg tags "${NEW_TAGS}" '
        [{ op: "replace", path: "/fields/System.Tags", value: $tags }]
      ')" >/dev/null
  fi
fi
```

The tag is best-effort — surface failures but do not abort the run.

---

## Output

On completion:

```
Test strategy generated for <entry-type> #<id>: <risk-level> — <N> test cases across <M> comments — first comment: <COMMENT_1_URL>
```
