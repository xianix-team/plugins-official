---
name: review-code
description: Run a focused code quality review on the current branch. Checks readability, naming, duplication, error handling, and design patterns. Usage: /review-code [branch-name]
argument-hint: [branch-name]
disable-model-invocation: true
---

Run a focused code quality review of the current branch changes.

## Steps

1. Gather the diff (one bash call — see `commands/pr-review.md` Step 3 for the full setup script). At minimum:
   ```bash
   set -euo pipefail
   BASE=$(git ls-remote --symref origin HEAD | awk '/^ref:/ {sub("refs/heads/","",$2); print $2}')
   : "${BASE:=main}"
   git fetch origin "refs/heads/${BASE}"
   BASE_SHA=$(git merge-base FETCH_HEAD HEAD)
   git diff ${BASE_SHA}...HEAD > /tmp/pr_full_diff.patch
   git diff --name-only ${BASE_SHA}...HEAD | tee /tmp/pr_changed_files.txt
   awk '/^@@/{s=substr($0,index($0,"+")+1);newln=s+0;print "      | "$0;next} /^(diff |index |--- |\+\+\+ )/{print "      | "$0;next} /^\+/{printf "%5d |+%s\n",newln,substr($0,2);newln++;next} /^ /{printf "%5d | %s\n",newln,substr($0,2);newln++;next} /^-/{printf "    - |-%s\n",substr($0,2);next} {print "      | "$0}' /tmp/pr_full_diff.patch > /tmp/pr_full_diff_numbered.patch
   ```

2. Launch the **code-reviewer** agent with `"subagent_type": "code-reviewer"` and `"model": "haiku"`. Pass `/tmp/pr_full_diff_numbered.patch` and `/tmp/pr_changed_files.txt` (inline the numbered diff only if ≤ 300 lines). Include the line-number constraint from `commands/pr-review.md` Step 6.

3. Output the code review findings directly. Do not post to any platform — this is a local-only review.

If a branch name is provided, fetch and check out that branch first (`git fetch origin <branch> && git checkout --detach FETCH_HEAD`). Otherwise, review the current branch.
