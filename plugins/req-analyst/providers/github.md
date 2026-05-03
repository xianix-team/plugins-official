# Provider: GitHub

Use this provider when `git remote get-url origin` contains `github.com`.

## Prerequisites

The `gh` CLI must be installed and authenticated. Verify with:

```bash
gh auth status
```

If not authenticated, the user needs to run `gh auth login` or set the `GITHUB-TOKEN` environment variable.

---

## Fetching Issue Details

Fetch the full issue with metadata, labels, milestone, and comments:

```bash
gh issue view ${ISSUE_NUMBER} --json number,title,body,state,labels,assignees,milestone,comments,projectItems
```

Extract from the JSON response:
- `title` — issue title
- `body` — issue description
- `state` — OPEN / CLOSED
- `labels[].name` — existing labels
- `assignees[].login` — assigned users
- `milestone.title` — milestone name
- `comments[].body` — prior discussion and context

---

## Finding Related Issues

Find issues in the same milestone:

```bash
gh issue list --milestone "${MILESTONE}" --json number,title,state,labels --limit 20
```

Find issues with the same label:

```bash
gh issue list --label "${LABEL}" --json number,title,state --limit 20
```

Search by keyword from the issue body:

```bash
gh issue list --search "${KEYWORD}" --json number,title,state --limit 10
```

---

## Posting the Elaboration

The original issue body is **never modified**. All elaboration is posted as **separate comments** — one per lens. This preserves the author's description and creates a reviewable discussion thread.

### Comment Order

Post each lens as its own comment using `gh issue comment`. Each comment must have a clear heading so the thread is scannable.

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

```bash
gh issue comment ${ISSUE_NUMBER} --body "${COMMENT_BODY}"
```

For multi-line content, use a heredoc:

```bash
gh issue comment ${ISSUE_NUMBER} --body "$(cat <<'EOF'
## 📋 Elaboration Summary

${SUMMARY_CONTENT}
EOF
)"
```

---

## Applying the Readiness Signal

After posting all comments, apply the readiness label as a **triage hint**:

```bash
gh issue edit ${ISSUE_NUMBER} --add-label "${SIGNAL_LABEL}"
```

| Plugin signal | GitHub label |
|---|---|
| `GROOMED` | `groomed` |
| `NEEDS CLARIFICATION` | `needs-clarification` |
| `NEEDS DECOMPOSITION` | `needs-decomposition` |

---

## Posting Open Questions

If the gap-risk-analyst identified open questions, post each as a **separate comment** after the elaboration comments, tagging the relevant person and framed as a prompt:

```bash
gh issue comment ${ISSUE_NUMBER} --body "❓ **Open question for refinement**

${QUESTION_TEXT} — @${PERSON}"
```

---

## Resolving the Issue

If no issue number was passed as an argument:

1. Parse the GitHub remote to get `{owner}` and `{repo}`:

```bash
git remote get-url origin
# e.g. https://github.com/org/repo.git  →  owner=org, repo=repo
```

2. List recent issues: `gh issue list --limit 10 --json number,title`

---

## Output

On completion:

```
Elaboration posted on issue #<number>: <signal> — <N> comments — <N> open questions
```
