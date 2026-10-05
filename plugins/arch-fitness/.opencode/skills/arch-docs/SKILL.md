---
name: arch-docs
description: "Discover, bootstrap, or update architecture-constraint documents under docs/architecture/ and open a docs PR. Does not evaluate fitness. Usage: /arch-docs [--issue <n> | --workitem <id>]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run a **docs-only** architecture curation pass for $ARGUMENTS.

This is the documentation half of `/arch-fitness`. It discovers existing architecture material, bootstraps or updates `docs/architecture/`, and opens a docs PR when changes are needed. It does **not** evaluate a changeset for fitness — use `/arch-evaluate` or the full `/arch-fitness` command for that.

## Steps

1. Detect platform from `git remote get-url origin` (`github` / `azuredevops` / `generic`).
2. If `--issue` / `--workitem` is provided, fetch the task body and parse any `ARCH FITNESS` config block (Focus areas, Skip areas).
3. Invoke the **`arch-doc-curator`** agent with `DOCS_MODE=docs-only`.
4. If a docs PR was opened, print its URL (and, in task mode, post a short comment on the issue / work item linking to it).
5. If no changes were needed, print `Architecture docs are up to date — no PR opened.`

Follow `providers/github.md`, `providers/azure-devops.md`, or `providers/generic.md` for platform I/O.

## Output

- Docs PR URL (when created/updated), or a no-op message
- Local `arch-docs-pr-body.md` on generic remotes
