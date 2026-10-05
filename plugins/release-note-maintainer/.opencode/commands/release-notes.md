---
description: "Generate or regenerate structured release notes for a git tag. Analyzes all merged pull requests, commits, breaking changes, and work items since the previous tag, then publishes the release notes to the hosting platform. Works with GitHub, Azure DevOps, and any git repository. Usage: /release-notes [tag — defaults to the tag at HEAD]"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Generate release notes for the tag $ARGUMENTS (defaults to the tag at HEAD).

## Hand-off Rules (read first)

When invoking the `orchestrator` sub-agent, **do not assume a hosting platform**. Pass only the raw tag name (or empty) and let the orchestrator detect the platform from `git remote get-url origin`.

The orchestrator's first action is always `git remote get-url origin`; do not pre-empt it.

## Trigger Model

This command is the same entry point invoked automatically by a webhook-driven runner on **tag creation only**:

- a GitHub `create` event where `ref_type == "tag"` (e.g. `git push --tags`)
- an Azure DevOps pipeline trigger on `resources.repositories.*.tags` or a webhook on `git.push` with a tag ref

**This agent never fires on branch pushes, PR events, or any other trigger.** Manual invocation (`/release-notes v1.2.0`) and tag-push webhook invocation behave identically — every run is a full regeneration from the current, cumulative set of changes since the previous tag.

## What This Does

This command invokes the **orchestrator** agent, which:

1. Detects the hosting platform from `git remote get-url origin`
2. Identifies the current tag and the previous tag (for the commit range)
3. Gathers all commits in the range `prev_tag..current_tag`
4. Lists merged pull requests in the release window (GitHub/Azure DevOps) or works from commits alone (generic)
5. In parallel: loads or bootstraps the repository's release knowledge profile (`knowledge-curator`) and categorizes the release content (`release-analyst`)
6. Synthesizes structured release notes per `styles/release-notes-template.md` and `styles/release-notes-style.md`
7. Publishes the release notes to the platform — never appends, never posts a comment thread
8. Refines the cached knowledge profile with what was learned this run

## How to Use

```
/release-notes              # Use tag at HEAD (typical on tag-push webhook)
/release-notes v1.2.0       # Generate for a specific tag
```

## Platform Support

| Remote URL contains | Platform | Where release notes are published |
|---|---|---|
| `github.com` | GitHub | GitHub Release for the tag (see `providers/github.md`) |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | Wiki page at `/Release-Notes/<tag>` (see `providers/azure-devops.md`) |
| Anything else | Generic | `RELEASE_NOTES.md` at repo root (see `providers/generic.md`) |

## Output

A single confirmation line naming the tag, platform, and URL or file path.

## Prerequisites

- Must be run inside a git repository with at least one tag
- **GitHub**: `gh` CLI installed and authenticated with `repo` scope — needed to list merged PRs and create/edit the GitHub Release (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE-DEVOPS-TOKEN` environment variable set with `Wiki (Read & Write)` and `Pull Requests (Read)` scopes (see `docs/platform-setup.md`)

---

Starting release note generation now...
