---
name: update-knowledge-base
description: "Bootstrap or refresh this repository's cached release note knowledge profile without generating or publishing release notes. Useful for first-time onboarding or after a large structural change. Usage: /update-knowledge-base"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Bootstrap or refresh the Release Note Maintainer Agent's knowledge profile for this repository — without generating, publishing, or fetching any release notes.

This invokes the **knowledge-curator** agent directly, twice in sequence: once in `load` mode and once in `update` mode.

## Steps

1. **Detect repository identity** — run `git remote get-url origin` so `knowledge-curator` can derive the cache key (`~/.claude/release-note-maintainer/knowledge/<platform>__<org>__<repo>.md`, see "Where the Profile Lives" in `agents/knowledge-curator.md`).

2. **Load or bootstrap** — invoke `knowledge-curator` in `load` mode.
   - If a profile already exists, it is read back with a freshness note.
   - If none exists, `knowledge-curator` performs a fresh bootstrap: reads manifests, tag history, commit convention patterns, and any existing `CHANGELOG.md` to produce either a **tailored release note profile** or the **universal fallback guideline set**.

3. **Refresh** — invoke `knowledge-curator` again in `update` mode, passing:
   - The profile from step 2
   - A lightweight rescan of the current tag list and recent commit subjects as "new observations" (to catch convention changes not yet in the profile)
   - In place of a tag/release summary, the literal marker `Manual refresh (no release)`

4. **Output** — print the resulting profile path and a one-line summary of what changed, or `No changes — profile already current.`

## What This Never Does

- Never generates or publishes release notes.
- Never touches the repository's working tree or commit history.
- Never reads or writes a GitHub Release or Azure DevOps Wiki page.

Use this when onboarding the agent to a new repository ahead of its first tagged release, or after adopting a new commit convention that you'd like reflected in the profile before the next release run picks it up.
