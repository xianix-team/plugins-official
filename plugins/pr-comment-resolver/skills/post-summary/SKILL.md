---
name: post-summary
description: "Post the PR comment resolution disposition summary to the pull request. Requires a PR number."
argument-hint: "[pr-number]"
disable-model-invocation: true
---

Post the PR comment resolution disposition summary to PR #$ARGUMENTS.

Do not ask for confirmation at any point. Execute all steps autonomously and proceed immediately from one step to the next.

## Steps

1. **Detect Platform**

   ```bash
   git remote get-url origin
   ```

   Determine the platform:
   - Contains `github.com` → **GitHub**
   - Contains `dev.azure.com` or `visualstudio.com` → **Azure DevOps**
   - Anything else → **Generic**

2. **Format the summary**

   Use the template defined in `styles/report-template.md`. Populate all sections:
   - Applied threads (with commit SHA, file, line, and description)
   - Discuss threads (with file, line, and reason)
   - Declined threads (with file, line, and justification)
   - Non-code declined threads

3. **Post the summary**

   Follow the instructions in the appropriate provider file:
   - **GitHub** → `providers/github.md` — Posting the Disposition Summary section
   - **Azure DevOps** → `providers/azure-devops.md` — Posting the Disposition Summary section
   - **Generic / unknown** → `providers/generic.md` — write to `pr-comment-resolution.md`

4. **Output result**

   On completion, output a single summary line:

   ```
   Summary posted on PR #<number>: <N> applied, <N> discussed, <N> declined — <URL>
   ```

   On generic:

   ```
   Resolution complete: <N> applied, <N> discussed, <N> declined — report written to pr-comment-resolution.md
   ```
