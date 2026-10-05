---
name: post-summary
description: "Post the PR comment resolution disposition summary to the pull request. Requires a PR number and dispositions compiled earlier in the conversation. Usage: /post-summary [pr-number]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Post the PR comment resolution disposition summary to PR #$ARGUMENTS.

This skill posts dispositions **already compiled earlier in this conversation** by a `/resolve-comments` run whose posting step did not complete. It does not resolve anything itself. If no dispositions exist in the conversation, **stop immediately** with an error — do not re-run the resolution flow and do not invent a summary.

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
   - Applied threads (with the commit rendered as a markdown link — see the providers' "Linking to Commits" section — plus file, line, and description)
   - Discuss threads (with file, line, and reason)
   - Declined threads (with file, line, and justification)
   - Non-code declined threads

3. **Post the summary**

   Follow the instructions in the appropriate provider file. First check for a prior summary comment via the plugin marker (see the provider's "Comment Markers and Prior-Run Detection" section) — if one exists, **update it in place** (cumulative totals + Run History) instead of posting a duplicate:
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

   If any step fails, output the error and stop — do not retry or ask for input.
