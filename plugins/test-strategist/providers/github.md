# Provider: GitHub

Use this provider when `git remote get-url origin` contains `github.com`.

## How this fits with the rest of the plugin

- **Reading / analysis** — Use **git** for diffs and logs, **`gh`** for issue and PR metadata.
- **GitHub-specific** — Use **`gh`** (and the `gh api` REST passthrough) to fetch issues, PRs, comments, linked references, and to post the **comment series** that constitutes the test strategy report.

The deliverable is a **logical series of Markdown comments** posted on the PR or issue. Each comment is self-contained with a `[k/N]` header. The first comment includes a Table of Contents that deep-links (via `https://github.com/.../issues/N#issuecomment-NNNNNNNNNN` URLs) to every other comment in the series.

**No HTML file is produced and nothing is written to the repository working tree.**

## Prerequisites

The `gh` CLI must be installed and authenticated. Verify with:

```bash
gh auth status
```

If not authenticated, the user needs to run `gh auth login` or set the `GITHUB-TOKEN` environment variable.

### Token Permissions

| Permission | Access | Why it's needed |
|---|---|---|
| **Contents** | Read | Access repository contents, commits, and documentation files |
| **Metadata** | Read | Search repositories and access repository metadata |
| **Issues** | Read & Write | Fetch issue body, labels, and comments; post and edit the comment series on issues |
| **Pull requests** | Read & Write | Fetch PR diffs, navigate issue ↔ PR links; post and edit the comment series on PRs |

---

## Entry Point: PR

### Fetching PR Details

```bash
gh pr view ${PR_NUMBER} --json number,title,body,state,headRefName,baseRefName,url,author,labels,files,additions,deletions,commits,closingIssuesReferences
```

### Discovering Linked Issues from a PR

```bash
# Via closingIssuesReferences
gh pr view ${PR_NUMBER} --json closingIssuesReferences --jq '.closingIssuesReferences[].number'
```

Also scan the PR body and commit messages for `#123`, `closes #456`, `fixes #789` patterns.

For each linked issue:
```bash
gh issue view ${ISSUE_NUMBER} --json number,title,body,state,labels,assignees,milestone,comments
```

### Fetching PR Diff

```bash
gh pr diff ${PR_NUMBER}
gh pr view ${PR_NUMBER} --json files,additions,deletions,commits
```

---

## Entry Point: Issue

### Fetching Issue Details

```bash
gh issue view ${ISSUE_NUMBER} --json number,title,body,state,labels,assignees,milestone,comments,projectItems
```

### Discovering Linked PRs from an Issue

```bash
# Via GitHub's timeline / cross-references API
gh api "repos/{owner}/{repo}/issues/${ISSUE_NUMBER}/timeline" --paginate \
  --jq '.[] | select(.event=="cross-referenced" or .event=="closed") | .source.issue.number // empty'

# Also search PR bodies for this issue number
gh pr list --search "${ISSUE_NUMBER} in:body" --state all --json number,title,state,headRefName,url,body --limit 20

# Check merged PRs specifically
gh pr list --state merged --search "${ISSUE_NUMBER}" --json number,title,state,headRefName,url,body --limit 20
```

For each linked PR, fetch its diff:
```bash
gh pr diff ${PR_NUMBER}
```

---

## Entry Point: Current Branch (no argument)

```bash
# Infer PR from current branch
gh pr view --json number,title,body,state,headRefName,baseRefName,url,author,labels,files,additions,deletions,commits,closingIssuesReferences
```

Then follow the same PR flow above.

---

## Finding Child/Related Issues

```bash
gh issue list --milestone "${MILESTONE}" --json number,title,state,labels --limit 20
gh issue list --label "${LABEL}" --json number,title,state --limit 20
gh issue list --search "${KEYWORD}" --json number,title,state --limit 10
```

---

## Resolving Owner and Repo

```bash
REMOTE=$(git remote get-url origin)
OWNER=$(echo "$REMOTE" | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f1)
REPO=$(echo "$REMOTE"  | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f2 | sed 's|\.git$||')
```

---

## Posting the Comment Series

The `test-guide-writer` agent has produced a directory of Markdown files plus an `index.json` describing the planned series. Read the index, then post each comment in order, capture URLs, and finally PATCH Comment 1 to back-fill the Table of Contents with the real comment URLs.

### Determine where to post

| Entry point | Post the series on |
|---|---|
| `pr` | The PR itself |
| `issue` | The issue |
| Current branch (no argument) | The PR (if `gh pr view` resolves one); otherwise stop with an error |

Both PRs and issues use the same underlying API endpoint (`POST /repos/{owner}/{repo}/issues/{number}/comments`), so the posting flow is identical for both. Below `${TARGET_NUMBER}` is the PR number for `pr` / current-branch entries and the issue number for `issue` entries.

### Resolve owner, repo, and target

```bash
WORK_DIR="${1:-${TMPDIR:-/tmp}/test-strategy-${ENTRY_TYPE}-${ENTRY_ID}}"
INDEX="${WORK_DIR}/index.json"
test -f "${INDEX}" || { echo "test strategy index not found at ${INDEX}"; exit 1; }

OWNER=$(jq -r '.owner // empty' "${INDEX}")
REPO=$(jq -r '.repo  // empty' "${INDEX}")
if [ -z "${OWNER}" ] || [ -z "${REPO}" ]; then
  REMOTE=$(git remote get-url origin)
  OWNER=$(echo "$REMOTE" | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f1)
  REPO=$(echo  "$REMOTE" | sed 's|https://github.com/||;s|git@github.com:||' | cut -d'/' -f2 | sed 's|\.git$||')
fi

TARGET_NUMBER=$(jq -r '.target_number // .entry_id' "${INDEX}")
TOTAL=$(jq -r '.comments | length' "${INDEX}")
```

### Step 1 — Post Comment 1 (with placeholder TOC)

Comment 1 already contains placeholder `…` URLs in its Contents section, so it can be posted as-is. We capture its URL and ID for the TOC back-fill in Step 3.

```bash
COMMENT_1_FILE="${WORK_DIR}/$(jq -r '.comments[0].file' "${INDEX}")"

RESPONSE=$(gh api \
  -X POST \
  "repos/${OWNER}/${REPO}/issues/${TARGET_NUMBER}/comments" \
  -F "body=@${COMMENT_1_FILE}")

COMMENT_1_ID=$(echo "${RESPONSE}" | jq -r '.id')
COMMENT_1_URL=$(echo "${RESPONSE}" | jq -r '.html_url')

# Persist for later steps.
jq --arg id "${COMMENT_1_ID}" --arg url "${COMMENT_1_URL}" \
  '.comments[0].id = $id | .comments[0].url = $url' \
  "${INDEX}" > "${INDEX}.tmp" && mv "${INDEX}.tmp" "${INDEX}"
```

### Step 2 — Post Comments 2..N

For each subsequent comment, **substitute** the `${COMMENT_1_URL}` placeholder in the file body with the real URL captured in Step 1, then post:

```bash
for k in $(seq 1 $((TOTAL - 1))); do
  REL_FILE=$(jq -r ".comments[$k].file" "${INDEX}")
  ABS_FILE="${WORK_DIR}/${REL_FILE}"
  TITLE=$(jq -r ".comments[$k].title" "${INDEX}")

  # Substitute the comment-1 URL placeholder in the file body.
  BODY_FILE="${WORK_DIR}/.posting-buffer.md"
  sed "s|\${COMMENT_1_URL}|${COMMENT_1_URL}|g" "${ABS_FILE}" > "${BODY_FILE}"

  RESPONSE=$(gh api \
    -X POST \
    "repos/${OWNER}/${REPO}/issues/${TARGET_NUMBER}/comments" \
    -F "body=@${BODY_FILE}")

  ID=$(echo "${RESPONSE}" | jq -r '.id')
  URL=$(echo "${RESPONSE}" | jq -r '.html_url')

  jq --argjson k $k --arg id "${ID}" --arg url "${URL}" \
    '.comments[$k].id = $id | .comments[$k].url = $url' \
    "${INDEX}" > "${INDEX}.tmp" && mv "${INDEX}.tmp" "${INDEX}"

  rm -f "${BODY_FILE}"
  echo "Posted [$((k + 1))/${TOTAL}] ${TITLE} → ${URL}"
done
```

The `previous → next` navigation footers in each comment use the same `${COMMENT_1_URL}` substitution. They link back to Comment 1 — they do **not** link to immediate neighbours, because GitHub does not provide a stable comment URL until the comment has been posted, and we want every comment to be reachable in one click from the index.

> **Why we don't pre-substitute every neighbour link:** the alternative — a true two-pass posting flow that captures every URL first, then PATCHes every comment to insert real `← prev / next →` links — adds 2N API calls and leaves a window where comments show placeholders if any PATCH fails. The "everything links to Comment 1, Comment 1 has the full TOC" pattern is more resilient.

### Step 3 — Back-fill the Table of Contents in Comment 1

Build the real TOC Markdown from the captured URLs, then PATCH Comment 1.

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

# Replace the entire TOC block in the comment 1 file. The block is delimited
# by the headings "## 📑 Contents" and a trailing horizontal rule or end-of-file
# blockquote (see styles/report-template.md).
NEW_BODY=$(awk -v toc="${TOC}" '
  BEGIN { in_toc = 0 }
  /^## 📑 Contents/ { print; print ""; print toc; in_toc = 1; next }
  in_toc && /^> _The Contents links/ { in_toc = 0 }
  in_toc && /^---$/ { in_toc = 0 }
  !in_toc { print }
' "${COMMENT_1_FILE}")

echo "${NEW_BODY}" > "${WORK_DIR}/.toc-buffer.md"

gh api \
  -X PATCH \
  "repos/${OWNER}/${REPO}/issues/comments/${COMMENT_1_ID}" \
  -F "body=@${WORK_DIR}/.toc-buffer.md" >/dev/null

rm -f "${WORK_DIR}/.toc-buffer.md"
echo "Back-filled Contents in [1/${TOTAL}] → ${COMMENT_1_URL}"
```

If the PATCH fails for any reason, the comment series is still readable — every comment has a `[k/N]` header and `[← Comment 1](${COMMENT_1_URL})` link. Surface the failure but do not retry more than once.

### Step 4 — Cross-link from the linked issue / PR (if applicable)

If the entry was a PR and a linked issue was discovered, post a single pointer comment on the issue:

```bash
LINKED_ISSUE=$(jq -r '.linked_issue_number // empty' "${INDEX}")
if [ -n "${LINKED_ISSUE}" ] && [ "${ENTRY_TYPE}" = "pr" ]; then
  gh api \
    -X POST \
    "repos/${OWNER}/${REPO}/issues/${LINKED_ISSUE}/comments" \
    -f body="🧪 Test strategy generated from PR #${TARGET_NUMBER} — see the [comment series starting here](${COMMENT_1_URL})."
fi
```

If the entry was an issue and a single linked PR was discovered, post the same kind of pointer on the PR (do not duplicate the full series there).

### Step 5 — Apply label

```bash
gh issue edit ${TARGET_NUMBER} --add-label "test-strategy-generated" 2>/dev/null \
  || gh pr edit  ${TARGET_NUMBER} --add-label "test-strategy-generated" 2>/dev/null \
  || true
```

The label is best-effort — if it does not exist on the repository, do not create it and do not error.

---

## Output

On completion:

```
Test strategy generated for <entry-type> #<id>: <risk-level> — <N> test cases across <M> comments — first comment: <COMMENT_1_URL>
```
