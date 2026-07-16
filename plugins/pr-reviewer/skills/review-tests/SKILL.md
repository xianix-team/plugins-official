---
name: review-tests
description: Run a focused test coverage review on the current branch. Identifies missing tests, coverage gaps, and test quality issues. Usage: /review-tests [branch-name]
argument-hint: [branch-name]
disable-model-invocation: true
---

Run a focused test coverage review of the current branch changes.

## Steps

1. Gather the diff (one bash call). Use the setup script in `commands/pr-review.md` Step 3, or at minimum produce `/tmp/pr_full_diff_numbered.patch` and `/tmp/pr_changed_files.txt` as in `skills/review-code/SKILL.md` step 1.

2. Launch the **test-reviewer** agent with `"subagent_type": "test-reviewer"` and `"model": "haiku"`. Pass `/tmp/pr_full_diff_numbered.patch` and `/tmp/pr_changed_files.txt` (inline the numbered diff only if ≤ 300 lines). Include the line-number constraint from `commands/pr-review.md` Step 6.

3. Output the test review findings directly. Do not post to any platform — this is a local-only review.

If a branch name is provided, fetch and check out that branch first. Otherwise, review the current branch.
