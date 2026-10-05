---
name: post-report
description: "Post a completed archaeology report as ordered comments on a GitHub Issue or Azure DevOps Work Item and apply the 'archaeology-complete' label/tag. Usage: /post-report [issue <n> | wi <id>]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Post the archaeology report as ordered comments on item $ARGUMENTS.

Do not ask for confirmation at any point. Execute all steps autonomously.

## Steps

1. **Detect platform**

   ```bash
   git remote get-url origin
   ```

   - Contains `github.com` → **GitHub**
   - Contains `dev.azure.com` or `visualstudio.com` → **Azure DevOps**
   - Anything else → **Generic** (output to console only)

2. **Read the report** from `ai-dlc/reports/code-archaeology-analysis.md`

   If the file does not exist, output a single error line and stop.

3. **Post each section as a separate comment** in this order:

   | # | Heading | Content |
   |---|---------|---------|
   | 1 | `🗺️ Architecture & Segment Map` | Segment map + module descriptions + service boundaries |
   | 2 | `🔍 Coding Conventions` | Pattern table (Confirmed / Inconsistency / Split) + Split decisions needed |
   | 3 | `🔎 Due Diligence Findings` | All findings grouped Critical → High → Medium → Low |
   | 4 | `📋 Work Backlog` | Prioritized backlog table + summary |
   | 5 | `✅ Analysis Complete` | Overall confidence, recommended next steps, blast radius controls |

   **GitHub:** Use `gh issue comment`. **Azure DevOps:** Use `curl` POST with `format=markdown` — see `providers/azure-devops.md`.

4. **Apply completion label/tag**

   **GitHub:**
   ```bash
   gh issue edit ${ISSUE_NUMBER} --add-label "archaeology-complete"
   ```

   **Azure DevOps:** Append `archaeology-complete` tag — see `providers/azure-devops.md`.

5. **Output result**

   ```
   Report posted on [issue/wi] #<id>: <N> comments posted — archaeology-complete applied
   ```
