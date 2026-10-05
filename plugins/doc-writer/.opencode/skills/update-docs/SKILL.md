---
name: update-docs
description: Update the codebase documentation to match the changes introduced by a pull request. Analyses the PR diff, edits or creates the documentation entries that describe the changed surfaces, commits the doc-only edits on a separate docs branch, and opens a companion documentation PR targeting the original PR's head branch.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Update the documentation in the codebase to match the source changes in pull request $ARGUMENTS.

## Execute this yourself now — do not delegate

You, the top-level agent, run the full documentation-update flow **yourself**, in this context, using your own `Bash`, `Read`, `Write`, `Edit`, `Grep`, and `Glob` tools. There is no background "orchestrator" agent that runs on your behalf — nothing happens unless you run it.

- Do **not** spawn a sub-agent to do the work, and do **not** narrate the steps in the future tense and then stop. Describing the flow is not the same as executing it.
- Do **not** report success or "in progress" until you have actually pushed the docs branch and opened (or confirmed) the companion docs PR — or genuinely confirmed that no documentation changes are required.

The authoritative, step-by-step flow lives in the `/update-docs` command (`commands/update-docs.md`). Follow it exactly, running every step in order:

1. Index the codebase structure
2. Detect the hosting platform from `git remote get-url origin`
3. Resolve the PR number (normalising a bare number, PR URL, or API URL; or from the current branch) and check whether the PR is open or already merged
4. Post a "documentation update in progress" comment on the original PR
5. Cut a new `docs/pr-<n>-sync` branch off the PR's head (never commit onto the PR's own branch)
6. Inventory the documentation surfaces (README, `docs/`, OpenAPI, CHANGELOG, ADRs, …) and the conventions they use
7. Fetch the PR diff and classify every changed file
8. Map each source change to the documentation entries that describe it today
9. Plan dispositions for each entry: **update**, **add**, **remove**, **rename**, or **no-op**
10. Apply the documentation edits — preserving the repo's existing style
11. Add a CHANGELOG entry under `[Unreleased]` for user-visible changes (when the repo uses a changelog)
12. Verify cross-references, code samples, and links still resolve
13. Commit the doc-only changes in a single commit on the docs branch and push it (authenticate the push inline with `GITHUB_TOKEN` / `AZURE_DEVOPS_TOKEN`)
14. Open a **companion documentation PR** whose target / base is the original PR's head branch (so it merges into the feature branch)
15. Post a structured documentation summary comment on the original PR, linking the new docs PR
16. Only after verifying the docs PR exists (or confirming a genuine no-op) emit the final result line

If the original PR is already merged, the companion docs PR targets the original PR's base branch instead (since the head branch may no longer exist). If no argument is given, update docs for the open PR on the **current branch**.

## Hard constraints

- **Source code is read-only.** Never edit `.ts`, `.js`, `.py`, `.go`, `.cs`, `.java`, `.rs`, `.cpp`, `.rb`, `.kt`, `.swift`, etc. The only exception is inline reference doc comments (JSDoc/TSDoc, docstrings, Rustdoc, GoDoc, XML doc comments) **inside source files that the PR itself already touched** — and only when those comments describe the symbol whose signature or behaviour changed.
- **Tests, lockfiles, build configuration, and dependency manifests are off limits.**
- **Every doc edit must trace back to a specific change in the PR diff.** Never reflow paragraphs, re-order sections, or "improve" documentation for unchanged code.
- **Match existing conventions** — heading levels, table style, code-block language tags, link style, CHANGELOG format.
- **Never commit onto the original PR's own branch** — all doc changes ship on a separate `docs/pr-<n>-sync` branch via a companion PR.
