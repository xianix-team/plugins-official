---
name: create-perf-pr
description: Open a single performance optimization pull request for a GitHub issue or Azure DevOps work item. Runs the whole-codebase analysis against the default branch, applies only Quick-win findings, and opens one PR whose body embeds the full performance report. Usage (GitHub) /create-perf-pr issue <issue-number>, (Azure DevOps) /create-perf-pr workitem <workitem-id>
argument-hint: issue <issue-number> | workitem <workitem-id>
disable-model-invocation: true
---

Open a performance optimization PR for $ARGUMENTS.

This skill triggers the full **Performance Optimizer** flow locally, without waiting for a Xianix Agent webhook. It assumes the trigger issue (GitHub) or work item (Azure DevOps) already exists and that the `ai-dlc/perf/optimize` label / tag is (or would be) applied.

Use the **orchestrator** agent to drive the flow. The orchestrator will:

1. Detect the hosting platform from `git remote get-url origin`.
2. Fetch the repository's default branch at its latest commit and align the working tree.
3. Read the trigger issue body (GitHub) or work item description (Azure DevOps) for optional `Scope:` / `Target:` hints.
4. Run latency, CPU, memory, and I/O analyzers across the scoped file set.
5. Rank findings by `impact × confidence` and compile the structured report.
6. Hand the **Quick-win** subset to the `perf-pr-author` sub-agent, which:
   - creates a new branch named `perf/issue-<issue-number>-<slug>` (GitHub) or `perf/workitem-<workitem-id>-<slug>` (Azure DevOps), based on the default branch
   - applies each Quick-win as a separate commit with a `perf:` prefixed message
   - pushes the new branch (never the default branch)
   - opens a new PR targeting the default branch, with the **full performance report embedded in the PR body** and a `Closes #<issue-number>` / work-item reference
   - posts a link-back comment on the originating issue / work item

## Invariants (non-negotiable)

- The default branch is never pushed to or rewritten.
- Only findings classified as Quick-wins are applied — no architectural rewrites.
- If zero findings apply cleanly, no PR is opened. The compiled report body is written to `performance-report.md` so the reporter still has the analysis artifact.
- The PR body always includes: summary, `Closes` / work-item reference, applied-optimizations table, not-applied list, verification checklist, and the full performance report.

## Prerequisites

- Inside a git repository whose remote resolves to GitHub (`github.com`) or Azure DevOps (`dev.azure.com` / `visualstudio.com`).
- **GitHub:** `gh` CLI authenticated (`gh auth login`) or `GH_TOKEN` / `GITHUB_TOKEN` set. Token scopes: Contents (R/W), Metadata (R), Issues (R/W), Pull requests (R/W).
- **Azure DevOps:** `AZURE_DEVOPS_TOKEN` set with **Code (R/W)**, **Work Items (R/W)**, and **Pull Request Threads (R/W)** scopes.

Do not ask follow-up questions. If a prerequisite is missing, emit a single error line and stop.
