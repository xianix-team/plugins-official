---
name: create-fix-pr
description: Open a separate, linked optimization pull request containing focused, low-risk performance fixes derived from a prior analysis. Never pushes to the source PR branch. Requires the source PR number. Usage: /create-fix-pr <pr-number>
argument-hint: <pr-number>
disable-model-invocation: true
---

Open a separate optimization PR for source PR #$ARGUMENTS.

This skill triggers the **opt-in fix-PR phase** of the Performance Optimizer Agent. It assumes an analysis report has already been posted (or will be produced first) and that the **Quick-wins** subset of findings is safe to apply.

Use the **orchestrator** agent to drive the flow. The orchestrator will:

1. If no analysis report is known for this PR, run the analysis phase first (same as `/analyze-performance`).
2. Select only the **Quick-win** findings — safe, localized, low-risk.
3. Hand off to the **fix-pr-author** sub-agent, which:
   - creates a new branch `perf/optimize-<source-pr-number>-<short-sha>` based on the source PR's head branch
   - applies each Quick-win finding as a separate commit with a `perf:` prefixed message
   - pushes the new branch (never the source branch)
   - opens a new PR targeting the source PR's **base** branch
   - links the new PR back to the source PR and the analysis comment

## Invariants (non-negotiable)

- The source PR branch is never pushed to or rewritten.
- Only findings explicitly classified as Quick-wins are applied — no architectural rewrites.
- If zero findings apply cleanly, no PR is opened and the skill reports "No fix PR created".
- The optimization PR body includes: summary, links to source PR + analysis comment, applied optimizations table, not-applied list, verification checklist, and expected impact notes.

## Prerequisites

- The invocation is inside a git repository whose remote resolves to a supported host.
- Credentials for pushing are available: `GIT_TOKEN` (GitHub / generic HTTPS) or `AZURE_DEVOPS_TOKEN` (Azure DevOps).
- For GitHub posting/PR creation: `gh` CLI authenticated (`gh auth login`) or `GH_TOKEN` / `GITHUB_TOKEN` set.
- For Azure DevOps: `AZURE_DEVOPS_TOKEN` set with **Code (Read & Write)** and **Pull Request Threads (Read & Write)** scopes.

Do not ask follow-up questions. If a prerequisite is missing, emit a single error line and stop.
