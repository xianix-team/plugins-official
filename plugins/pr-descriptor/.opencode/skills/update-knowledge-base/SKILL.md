---
name: update-knowledge-base
description: "Bootstrap or refresh this repository's cached architectural knowledge profile without generating or posting a PR description. Useful for first-time onboarding or after a large refactor. Usage: /update-knowledge-base"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Bootstrap or refresh the PR Description Agent's knowledge profile for this repository — without generating, fetching, or posting any PR description.

This invokes the **knowledge-curator** agent directly, twice in sequence: once in `load` mode and once in `update` mode.

## Steps

1. **Detect repository identity** — run `git remote get-url origin` so `knowledge-curator` can derive the cache key (`~/.claude/pr-descriptor/knowledge/<platform>__<org>__<repo>.md`, see "Where the Profile Lives" in `agents/knowledge-curator.md`).

2. **Load or bootstrap** — invoke `knowledge-curator` in `load` mode.
   - If a profile already exists, it is read back along with a staleness note (whether the paths in its Module Map still exist).
   - If none exists, `knowledge-curator` performs a fresh bootstrap: inspects manifests, top-level layout, language fingerprint, and read-only docs (`README.md`, `CONTRIBUTING.md`, `CLAUDE.md`/`AGENTS.md` if present) to produce either a **tailored architectural profile** or, if signal is too sparse, the **universal fallback guideline set**.

3. **Refresh** — invoke `knowledge-curator` again in `update` mode, passing:
   - The profile (and `PROFILE_PATH`) from step 2
   - In place of `change-analyst`'s "new observations," a fresh look at the current repository structure (re-run the bootstrap scan: top-level layout, manifest files, language fingerprint) and note anything not already reflected in the Module Map, Tech Stack, or Conventions sections
   - In place of a PR number/title for the Change History entry, the literal marker `Manual refresh (no PR)`

4. **Output** — print the resulting `PROFILE_PATH` and a one-line summary of what changed, or `No changes — profile already current.` if nothing was added or corrected.

## What This Never Does

- Never touches the repository's working tree or commit history.
- Never resolves, fetches, or modifies a pull request.
- Never generates or replaces a PR description.

Use this when onboarding the agent to a new repository ahead of its first PR, or after a large structural refactor that you'd like reflected in the profile before the next PR-driven `update` pass would naturally pick it up.
