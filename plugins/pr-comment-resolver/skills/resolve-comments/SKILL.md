---
name: resolve-comments
description: "Resolve all unresolved review threads on a pull request. Classifies each comment as apply, discuss, or decline."
argument-hint: "[pr-number]"
disable-model-invocation: true
---

Resolve all unresolved review threads on pull request $ARGUMENTS.

Use the **orchestrator** agent to run the full comment resolution flow. The orchestrator will:

1. Index the codebase structure
2. Detect the hosting platform from `git remote get-url origin`
3. Resolve the PR number (from argument or current branch)
4. Check whether the PR is open or already merged
5. Post a "resolution in progress" comment on the PR
6. Fetch every unresolved review thread via the platform API
7. Filter out non-code-change threads (auto-decline)
8. Classify each remaining thread: **apply**, **discuss**, or **decline**
9. Apply code changes for all **apply** threads
10. Commit all changes in a single commit and push to the PR branch
11. Mark applied threads as resolved on the platform
12. Reply to all **discuss** and **decline** threads with short explanations
13. Post a structured disposition summary comment

If the PR is already merged, apply changes on a new branch and open a follow-up PR.

If no argument is given, resolve comments on the open PR for the **current branch**.
