---
description: Resolve unresolved PR review threads. Classifies each comment as apply, discuss, or decline — applies actionable ones as commits, replies to the rest, and posts a disposition summary. Works with GitHub, Azure DevOps, and any git repository.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Resolve all unresolved review threads on pull request $ARGUMENTS.

**Critical execution rule (read first).** This file is not documentation — it is your instruction to act **now, in this turn**. Invoke the **orchestrator** agent via the `Agent`/`Task` tool (`subagent_type: orchestrator`), run it **synchronously** (not in the background), wait for it to finish, and relay its final confirmation line. If the orchestrator sub-agent is unavailable in this environment, read `agents/orchestrator.md` and execute its steps yourself, directly in this context. Do **not** describe or summarize the process instead of performing it — text output alone posts nothing to the PR. Ending the turn before the disposition summary has been posted (or a hard error has been reported with its output) is a **failure**.

## What This Does

This command invokes the **orchestrator** agent (`agents/orchestrator.md` is the authoritative procedure), which:

| Step | Action |
|------|--------|
| 1 | Indexes the codebase structure |
| 2 | Detects the platform from `git remote get-url origin` |
| 3 | Resolves the PR number and checks whether the PR is open or already merged |
| 4 | Detects any prior resolution run via the plugin's invisible comment markers |
| 5 | Posts a "resolution in progress" comment — or updates the previous one on a re-run |
| 6 | Fetches every unresolved review thread, excluding its own comments and threads already dispositioned in a prior run |
| 7 | Filters out non-code-change threads (auto-decline) |
| 8 | Classifies each remaining thread: **apply**, **discuss**, or **decline** |
| 9 | Edits files for all **apply** threads |
| 10 | Runs the repository's test suite — applies that introduce new failures are reverted and reclassified as **discuss** |
| 11 | Commits changes in a single commit and pushes to the PR branch |
| 12 | Marks applied threads as resolved on the platform |
| 13 | Replies to **discuss** and **decline** threads with short explanations |
| 14 | Posts a structured disposition summary comment — or updates the existing one in place on a re-run, appending to its Run History |

## Re-run Behavior

Running the command again on the same PR (e.g. after new review comments arrive) is safe and incremental. Every comment the plugin posts carries an invisible marker, so a re-run only processes threads it hasn't already dispositioned (threads where a human replied after the plugin's response come back into scope), reuses its progress comment, and updates the existing disposition summary in place with cumulative totals and a per-run history — it never stacks duplicate summaries.

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

To run automatically via the Xianix Agent (webhook-driven), see the rule blocks in [docs/triggers-github.md](../docs/triggers-github.md) and [docs/triggers-azure-devops.md](../docs/triggers-azure-devops.md).

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
- **Azure DevOps**: `AZURE-DEVOPS-TOKEN` environment variable set
- **Pushing commits**: `GITHUB_TOKEN` (GitHub) or `AZURE-DEVOPS-TOKEN` (Azure DevOps)

---

Now execute: invoke the **orchestrator** agent with the PR number (`$ARGUMENTS` if given, otherwise resolve from the current branch) and wait for its result. Success means the orchestrator's completion line (`Resolution complete on PR #<n>: …`) has been produced and the summary comment exists on the PR — verify by relaying that line as your final output.
