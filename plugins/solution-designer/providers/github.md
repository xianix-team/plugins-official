# Provider: GitHub

Use when `git remote get-url origin` contains `github.com`.

## Prerequisites

`gh` installed and authenticated (`gh auth login`, or `GITHUB-TOKEN` / `GH_TOKEN`).

| Permission | Access | Purpose |
|---|---|---|
| Contents | Read & Write | Read code; push `design/*` branches |
| Issues | Read & Write | Read the item and thread; post comments; swap labels |
| Pull requests | Read & Write | Open / update / check the design PR |

---

## Repo metadata

```bash
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
```

## Fetching the item and thread

```bash
gh issue view ${ISSUE_NUMBER} --json number,title,body,state,labels,url,comments
```

From `comments[]`: `author.login`, `body`, `createdAt`, `url`, `viewerDidAuthor`. Numeric ids (for reactions):

```bash
gh api "repos/${OWNER_REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" --jq '.[] | {id, user: .user.login, created_at}'
```

**Groomed check:** `groomed` in `labels[].name`, or a comment whose footer contains `` `req-analyst` · `` and `status: **ready**`.

**Description last edited** (for the STALE check against the doc's *Requirement as of*):

```bash
gh api graphql -F owner="${OWNER_REPO%/*}" -F repo="${OWNER_REPO#*/}" -F n=${ISSUE_NUMBER} \
  -f query='query($owner:String!,$repo:String!,$n:Int!){repository(owner:$owner,name:$repo){issue(number:$n){createdAt lastEditedAt}}}' \
  --jq '.data.repository.issue | (.lastEditedAt // .createdAt)'
```

## Acknowledging a comment

```bash
gh api -X POST "repos/${OWNER_REPO}/issues/comments/${COMMENT_ID}/reactions" -f content=eyes
```

---

## Design branch

```bash
SLUG=$(echo "${ISSUE_TITLE}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g;s/--*/-/g;s/^-//;s/-$//' | cut -c1-40)
DESIGN_BRANCH="design/issue-${ISSUE_NUMBER}-${SLUG}"

git fetch origin "${DEFAULT_BRANCH}"
EXISTING=$(git ls-remote --heads origin "design/issue-${ISSUE_NUMBER}-*" | head -1 | sed 's|.*refs/heads/||')
if [ -n "$EXISTING" ]; then
  DESIGN_BRANCH="$EXISTING"
  git checkout -B "${DESIGN_BRANCH}" "origin/${DESIGN_BRANCH}"
  git merge "origin/${DEFAULT_BRANCH}" --no-edit || true
else
  git checkout -b "${DESIGN_BRANCH}" "origin/${DEFAULT_BRANCH}"
fi
```

Reuse the existing branch on revisions (matched by issue number, so a retitled issue keeps its branch).

## Commit and push

```bash
git add docs/design/ docs/architecture/decisions/ 2>/dev/null || git add docs/design/
git commit -m "docs(design): ${ISSUE_TITLE} (#${ISSUE_NUMBER})"
git push -u origin "${DESIGN_BRANCH}"
```

Only paths under `docs/` are committed. Never touch source code.

## Design PR

Find an existing one (open or merged):

```bash
gh pr list --head "${DESIGN_BRANCH}" --state all --json number,url,state,mergedAt,mergedBy --limit 1
```

Create if none:

```bash
cat > /tmp/design-pr.md <<EOF
Design for #${ISSUE_NUMBER}.

${SUMMARY_3_LINES}

**Architecture:** ${CONFORMANCE_LINE}
${PROPOSED_ADRS_LINE}

Merging this PR accepts the design.
EOF

gh pr create --base "${DEFAULT_BRANCH}" --head "${DESIGN_BRANCH}" \
  --title "Design: ${ISSUE_TITLE} (#${ISSUE_NUMBER})" --body-file /tmp/design-pr.md
```

On revisions, the push updates the PR; do not create another. **Merged** (`state == MERGED`) means approved — report `mergedBy.login`.

---

## Posting a comment

```bash
cat > /tmp/design-comment.md <<'EOF'
…
---
`solution-designer` · r1 · status: **needs decision** · open: 2
EOF
gh issue comment ${ISSUE_NUMBER} --body-file /tmp/design-comment.md
```

## Swapping the design label

```bash
# needs decision
gh issue edit ${ISSUE_NUMBER} --add-label design-needs-decision --remove-label design-proposed,design-approved
# proposed
gh issue edit ${ISSUE_NUMBER} --add-label design-proposed --remove-label design-needs-decision,design-approved
# approved
gh issue edit ${ISSUE_NUMBER} --add-label design-approved --remove-label design-needs-decision,design-proposed
```

Create missing labels once:

```bash
gh label create design-needs-decision --color FBCA04 --description "Design waiting on a decision" 2>/dev/null || true
gh label create design-proposed       --color 1D76DB --description "Design PR ready for review"   2>/dev/null || true
gh label create design-approved       --color 0E8A16 --description "Design accepted"              2>/dev/null || true
```

Never remove `ai-dlc/issue/design` or `groomed`.
