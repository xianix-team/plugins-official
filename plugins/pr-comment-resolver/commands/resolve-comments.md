---
name: resolve-comments
description: Resolve unresolved PR review threads. Classifies each comment as apply, discuss, or decline — applies actionable ones as commits, replies to the rest, and posts a disposition summary. Works with GitHub, Azure DevOps, and any git repository.
argument-hint: [pr-number]
---

Resolve all unresolved review threads on pull request $ARGUMENTS.

## What This Does

This command invokes the **orchestrator** agent which:

| Step | Action |
|------|--------|
| 1 | Detects the platform from `git remote get-url origin` |
| 2 | Posts a "resolution in progress" comment on the PR |
| 3 | Fetches every unresolved review thread (inline and top-level) |
| 4 | Filters out non-code-change threads (auto-decline) |
| 5 | Classifies each remaining thread: **apply**, **discuss**, or **decline** |
| 6 | Edits files for all **apply** threads |
| 7 | Commits changes and pushes to the PR branch |
| 8 | Marks applied threads as resolved on the platform |
| 9 | Replies to **discuss** and **decline** threads with short explanations |
| 10 | Posts a structured disposition summary comment |

## Dispositions

| Disposition | Meaning |
|---|---|
| **Apply** | Clear, actionable code change — edits the relevant files and resolves the thread |
| **Discuss** | Needs human judgement — leaves the thread open with a short explanation |
| **Decline** | Out of scope, conflicts with another decision, or factually wrong — leaves the thread open with a justification |

## How to Use

```
/resolve-comments              # Resolve comments on the current branch's PR
/resolve-comments 42           # Resolve comments on PR #42
```

## Merged PR Handling

When the target PR is already merged, the plugin cuts a new branch from the merge commit, applies all **apply** changes there, pushes it, and opens a follow-up PR linked back to the original.

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How threads are fetched and resolved |
|---|---|---|
| `github.com` | GitHub | GitHub CLI (`gh`) + GraphQL |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`) |
| Anything else | Generic | Report written to `pr-comment-resolution.md` |

## Prerequisites

- Must be run inside a git repository with a remote configured
- **GitHub**: `gh` CLI installed and authenticated (`gh auth login`)
- **Azure DevOps**: `AZURE_DEVOPS_TOKEN` environment variable set
- **Pushing commits**: `GIT_TOKEN` (GitHub) or `AZURE_DEVOPS_TOKEN` (Azure DevOps)

---

Starting comment resolution now...
