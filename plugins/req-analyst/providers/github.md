# Provider: GitHub

Use this provider when `git remote get-url origin` contains `github.com`.

## Prerequisites

The `gh` CLI must be installed and authenticated (`gh auth status`). If not, run `gh auth login` or set `GITHUB-TOKEN`.

The token needs `repo` scope — the plugin **edits the issue body** and **adds/removes labels**, not just comments.

---

## Fetching the Issue and the Full Thread

```bash
gh issue view ${ISSUE_NUMBER} --json number,title,body,state,labels,assignees,milestone,updatedAt,comments
```

From `comments[]` use:

| Field | Purpose |
|---|---|
| `author.login` | Who wrote it |
| `body` | Content — look for the `` `req-analyst` · `` footer marker, `@xianix`, numbered answers |
| `createdAt` | Ordering |
| `viewerDidAuthor` | `true` when the current token wrote it — fallback for identifying agent comments |
| `url` | Link to record in the *Decisions* table (`…#issuecomment-<id>`) |

`gh issue view` does not return numeric comment ids. When you need one (to react to a comment), fetch via the API:

```bash
gh api "repos/{owner}/{repo}/issues/${ISSUE_NUMBER}/comments?per_page=100" \
  --jq '.[] | {id, user: .user.login, created_at, body}'
```

`{owner}/{repo}` placeholders are filled by `gh` from the current repo.

### Finding related issues (analysis context only)

```bash
gh issue list --milestone "${MILESTONE}" --json number,title,state,labels --limit 20
gh issue list --label "${LABEL}" --json number,title,state --limit 20
gh issue list --search "${KEYWORD}" --json number,title,state --limit 10
```

---

## Acknowledging a Human Comment

Before doing any long work on a follow-up round, react to the human comment you are acting on so they know it was picked up:

```bash
gh api -X POST "repos/{owner}/{repo}/issues/comments/${COMMENT_ID}/reactions" -f content=eyes
```

Do not post an "in progress" comment on follow-up rounds — the reaction is the acknowledgement.

---

## Posting the Round-1 Starting Comment

Only on the very first turn (state `NEW`):

```bash
gh issue comment ${ISSUE_NUMBER} --body "Looking at this now — I'll come back with a few clarifying questions in a couple of minutes."
```

If this fails, warn and continue.

---

## Posting a Round Comment

Write the body to a temp file first — round comments contain backticks, `<details>`, and pipes that are fragile inside inline quoting.

```bash
cat > /tmp/req-analyst-comment.md <<'EOF'
## Requirement analysis — round 1 of 3

...

---
`req-analyst` · round 1/3 · status: **awaiting answers** · open: 3
EOF

gh issue comment ${ISSUE_NUMBER} --body-file /tmp/req-analyst-comment.md
```

Post **one** comment per invocation.

---

## Updating the Issue Description

Write the refined description (see `styles/refined-description-template.md`, Markdown version) to a file and replace the body:

```bash
cat > /tmp/req-analyst-body.md <<'EOF'
<!-- req-analyst: managed section — humans may edit; the agent rewrites it as decisions land in the thread -->

## Summary
...

<details><summary>Original description</summary>

<original body verbatim>

</details>
EOF

gh issue edit ${ISSUE_NUMBER} --body-file /tmp/req-analyst-body.md
```

On the **first** edit, the `Original description` block receives the current `body` exactly as fetched. On later edits, copy that block forward unchanged from the current body.

---

## Swapping the Readiness Label

Exactly one readiness label at a time. Add the new one and remove the others in a single call:

```bash
# → awaiting answers
gh issue edit ${ISSUE_NUMBER} --add-label needs-clarification --remove-label groomed,needs-decomposition

# → ready to proceed
gh issue edit ${ISSUE_NUMBER} --add-label groomed --remove-label needs-clarification,needs-decomposition

# → decomposition
gh issue edit ${ISSUE_NUMBER} --add-label needs-decomposition --remove-label needs-clarification,groomed
```

`--remove-label` on a label that is not present is a no-op. Never remove `ai-dlc/issue/analyze`.

If a label does not exist in the repo, create it once:

```bash
gh label create groomed             --color 0E8A16 --description "Requirement groomed — ready to proceed" 2>/dev/null || true
gh label create needs-clarification --color FBCA04 --description "req-analyst is waiting on answers"     2>/dev/null || true
gh label create needs-decomposition --color D93F0B --description "Too large — split proposed"           2>/dev/null || true
```

---

## Creating Child Issues (confirmed decomposition only)

```bash
gh issue create \
  --title "${CHILD_TITLE}" \
  --label "ai-dlc/issue/analyze" \
  --body "$(cat <<EOF
${CHILD_DESCRIPTION}

Split from #${ISSUE_NUMBER}.
EOF
)"
```

Capture the returned issue number for the parent's *Split into* list. Add the children to the same milestone as the parent if it has one (`--milestone`).

---

## Output

On completion, one status line — see the orchestrator's Step 6.
