---
description: "Generate or completely regenerate a pull request's description. Analyzes the full diff, commit history, and codebase, then replaces the PR's title and description in place. Works with GitHub, Azure DevOps, and any git repository. Usage: /pr-describe [PR number, branch name, or leave blank for current branch]"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Generate (or completely regenerate) the pull request description for $ARGUMENTS.

## Hand-off Rules (read first)

When invoking the `orchestrator` sub-agent, **do not assume a hosting platform**. Pass only the raw PR identifier (number, branch name, or empty) and let the orchestrator detect the platform from `git remote get-url origin`.

- ❌ Bad: *"Generate a description for PR #12 in the **GitHub** repository foo/bar"* — this primes the orchestrator with the wrong platform when the remote is actually Azure DevOps, leading to wasted `gh` calls and leaked tokens in logs.
- ✅ Good: *"Generate the description for PR #12 in repository `foo/bar` on branch `feature/x`. Detect the hosting platform from the git remote before doing anything else."*

The orchestrator's first action is always `git remote get-url origin`; do not pre-empt it.

## Trigger Model

This command is the same entry point invoked automatically by an external webhook-driven runner on:

- a GitHub `pull_request` event (`opened`, `synchronize`, `reopened`)
- an Azure DevOps pull request service hook (`pullrequest.created`, `pullrequest.updated`)
- a `push` event to a branch that has an open PR

Manual invocation (`/pr-describe`, `/pr-describe 123`, `/pr-describe feature/foo`) and webhook-driven invocation behave **identically** — every run performs a full regeneration of the description from the PR's current, cumulative diff and replaces it in place. There is no "first run" vs "update" mode from the agent's point of view.

## What This Does

This command invokes the **orchestrator** agent, which:

1. Detects the hosting platform from `git remote get-url origin`
2. Resolves the PR and reads its current title/description (used only to extract "Related Work" references before they're overwritten)
3. Gathers the full, cumulative diff and commit history versus the base branch
4. Indexes the codebase structure (skipped for small PRs — the diff alone is enough)
5. In parallel: loads or bootstraps the repository's knowledge profile (`knowledge-curator`) and analyzes the change (`change-analyst`)
6. Synthesizes the description per `styles/pr-description-template.md` and `styles/description-style.md`
7. **Completely replaces** the PR's title and description — never appends, never posts a comment, never opens a thread
8. Refines the cached knowledge profile with anything learned from this PR (Knowledge Creation & Updates — see `agents/knowledge-curator.md`)

## How to Use

```
/pr-describe              # Describe current branch vs main
/pr-describe 123          # Describe PR #123 (GitHub) or PR ID 123 (Azure DevOps)
/pr-describe feature/foo  # Describe branch feature/foo vs main
```

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How the description is replaced |
|---|---|---|
| `github.com` | GitHub | `gh pr edit --title ... --body-file ...` (see `providers/github.md`) |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST `PATCH .../pullrequests/{id}` (see `providers/azure-devops.md`) |
| Anything else | Generic | Written to `pr-description.md` in the repo root (see `providers/generic.md`) |

## Output

A single confirmation line naming the PR, platform, and URL — or, for the generic provider, the path the description was written to.

## Prerequisites

- Must be run inside a git repository
- The current branch must have at least one commit ahead of the base branch
- **GitHub**: `gh` CLI installed and authenticated, with permission to edit pull requests (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE-DEVOPS-TOKEN` environment variable set with `Pull Requests (Read & Write)` scope (see `docs/platform-setup.md`)

---

Starting description generation now...
