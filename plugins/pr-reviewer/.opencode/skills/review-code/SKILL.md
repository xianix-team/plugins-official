---
name: review-code
description: "Run a focused code quality review on the current branch. Checks readability, naming, duplication, error handling, and design patterns. Usage: /review-code [branch-name]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run a focused code quality review of the current branch changes.

## Steps

1. Gather the diff via **`scripts/pr-setup.sh` as one Bash call** (do not invent a shortened checkout/diff script). Resolve the plugin root first (see step 0 in `commands/pr-review.md` — Xianix Executor often leaves `CLAUDE_PLUGIN_ROOT` unset for Bash tools):
   ```bash
   # Use resolve_pr_script / remember_pr_plugin_root from commands/pr-review.md step 0,
   # or: source /tmp/pr_plugin.env if a prior step already wrote it.
   # Optional: BRANCH_ARG=<branch-name>
   bash "$CLAUDE_PLUGIN_ROOT/scripts/pr-setup.sh"
   source /tmp/pr_state.env
   ```
   That writes `/tmp/pr_full_diff_numbered.patch` and `/tmp/pr_changed_files.txt`.

2. Launch the **code-reviewer** agent with `"subagent_type": "code-reviewer"` and `"model": "haiku"`. Pass `/tmp/pr_full_diff_numbered.patch` and `/tmp/pr_changed_files.txt` (inline the numbered diff only if ≤ 300 lines). Include the line-number constraint from `commands/pr-review.md` Step 6.

3. Output the code review findings directly. Do not post to any platform — this is a local-only review.

If a branch name is provided, set `BRANCH_ARG` before running `pr-setup.sh`. Otherwise, review the current branch.
