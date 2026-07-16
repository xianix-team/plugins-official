---
name: review-performance
description: Run a focused performance review on the current branch. Identifies bottlenecks, N+1 queries, algorithmic inefficiencies, and resource waste. Usage: /review-performance [branch-name]
argument-hint: [branch-name]
disable-model-invocation: true
---

Run a focused performance review of the current branch changes.

## Steps

1. Gather the diff (one bash call). Use the setup script in `commands/pr-review.md` Step 3, or at minimum produce `/tmp/pr_full_diff_numbered.patch` and `/tmp/pr_changed_files.txt` as in `skills/review-code/SKILL.md` step 1.

2. Launch the **performance-reviewer** agent with `"subagent_type": "performance-reviewer"` — **omit** the `model` field so it inherits the lead's model. Pass `/tmp/pr_full_diff_numbered.patch` and `/tmp/pr_changed_files.txt` (inline the numbered diff only if ≤ 300 lines). Include the line-number constraint from `commands/pr-review.md` Step 6.

3. Output the performance review findings directly. Do not post to any platform — this is a local-only review.

If a branch name is provided, fetch and check out that branch first. Otherwise, review the current branch.
