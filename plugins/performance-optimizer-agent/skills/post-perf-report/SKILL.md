---
name: post-perf-report
description: Post an already-compiled performance analysis report as a comment on a pull request. Requires a PR number. Usage: /post-perf-report <pr-number>
argument-hint: <pr-number>
disable-model-invocation: true
---

Post the compiled performance analysis report as a PR comment on PR #$ARGUMENTS.

Do not ask for confirmation at any point. Execute all steps autonomously.

## Steps

1. **Detect Platform**

   ```bash
   git remote get-url origin
   ```

   - Contains `github.com` → **GitHub**
   - Contains `dev.azure.com` or `visualstudio.com` → **Azure DevOps**
   - Anything else → **Generic**

2. **Verify PR exists**

   **GitHub:**

   ```bash
   gh pr view <pr-number> --json state,title,headRefName
   ```

   If the PR does not exist or is merged / closed, stop and output a single error line.

   **Azure DevOps:**

   ```bash
   curl -s -u ":${AZURE_DEVOPS_TOKEN}" \
     "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_NUMBER}?api-version=7.1"
   ```

   Parse org / project / repo / `API_BASE` from `git remote get-url origin` per `providers/azure-devops.md`. If the PR is completed or abandoned, stop and output a single error line.

3. **Post the report**

   Follow the instructions in the matching provider file:

   - **GitHub** → `providers/github.md` (section: *Posting the final analysis report*)
   - **Azure DevOps** → `providers/azure-devops.md` (section: *Posting the Analysis Report*)
   - **Generic / unknown** → `providers/generic.md` (write / update `performance-report.md`)

4. **Output result**

   **GitHub:**

   ```
   Posted performance analysis on PR #<number>: <N> bottlenecks ranked — https://github.com/<owner>/<repo>/pull/<number>
   ```

   **Azure DevOps:**

   ```
   Posted performance analysis on PR #<number>: <N> bottlenecks ranked — ${API_BASE}/_git/<repo>/pullrequest/<number>
   ```

   **Generic:**

   ```
   Performance analysis complete: <N> bottlenecks ranked — report written to performance-report.md
   ```

   If any step fails, emit a single error line and stop. Do not retry or prompt the user.

> **Note:** This skill only posts the already-compiled report. It does not create a fix PR. Use `/create-fix-pr <pr-number>` or apply the `ai-dlc/pr/perf-optimize-fix` label to trigger fix-PR mode.
