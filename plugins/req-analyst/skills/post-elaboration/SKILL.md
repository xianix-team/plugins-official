---
name: post-elaboration
description: Post the elaborated requirement as ordered comments on a backlog item (GitHub Issue or Azure DevOps Work Item). Each lens becomes a separate comment, preserving the original description. Applies a lightweight readiness signal as a triage hint. Usage: /post-elaboration [issue-number or work-item-id]
argument-hint: [issue-number | work-item-id]
---

Post the elaborated requirement as comments on item #$ARGUMENTS.

Do not ask for confirmation at any point. Execute all steps autonomously and proceed immediately from one step to the next.

## Steps

1. **Detect platform**

   ```bash
   git remote get-url origin
   ```
   - Contains `github.com` → **GitHub**
   - Contains `dev.azure.com` or `visualstudio.com` → **Azure DevOps**
   - Anything else → **Generic** (write to file)

2. **Verify item exists**

   **GitHub:** Use `gh issue view` to confirm the issue exists.

   ```bash
   gh issue view ${ISSUE_NUMBER} --json state
   ```

   **Azure DevOps:** Use `curl` to fetch the work item — see `providers/azure-devops.md`.

   If the item does not exist or is already closed/completed, stop and output a single error line.

3. **Post each lens as a separate comment**

   **Do not modify the item body.** Post each lens as its own comment, in this order:

   | # | Comment | Heading |
   |---|---------|---------|
   | 1 | Elaboration Summary | `## 📋 Elaboration Summary` |
   | 2 | Fit with Existing Requirements | `## 🧩 Fit with Existing Requirements` |
   | 3 | Intent & User Context | `## 🔍 Intent & User Context` |
   | 4 | User Journey | `## 🗺️ User Journey` |
   | 5 | Personas & Adoption | `## 👥 Personas & Adoption` |
   | 6 | Domain & Competitive Context | `## 🏢 Domain & Competitive Context` |
   | 7 | Open Questions & Gaps | `## ❓ Open Questions & Gaps` |

   Skip any comment whose source produced no meaningful findings.

   **GitHub:** Use `gh issue comment`.

   ```bash
   gh issue comment ${ISSUE_NUMBER} --body "${COMMENT_BODY}"
   ```

   **Azure DevOps:** Use `curl` POST to the work item comments API with `format=markdown` — see `providers/azure-devops.md`.

4. **Apply readiness signal label/tag**

   This is a **triage hint**, not a gate.

   **GitHub:** Use `gh issue edit`.

   ```bash
   gh issue edit ${ISSUE_NUMBER} --add-label "${SIGNAL_LABEL}"
   ```

   **Azure DevOps:** Use `curl` PATCH to add the tag — see `providers/azure-devops.md`.

   | Plugin signal | GitHub label | Azure DevOps tag |
   |---|---|---|
   | `GROOMED` | `groomed` | `groomed` |
   | `NEEDS CLARIFICATION` | `needs-clarification` | `needs-clarification` |
   | `NEEDS DECOMPOSITION` | `needs-decomposition` | `needs-decomposition` |

5. **Post open questions as prompts**

   Post each as a separate comment, framed as a prompt for the next refinement, tagging the relevant person.

6. **Output result**

   ```
   Elaboration posted on issue #<number>: <signal> — <N> comments — <N> open questions
   ```

> **Note:** GitHub requires `gh` CLI installed and authenticated. Azure DevOps requires `AZURE-DEVOPS-TOKEN`. See `docs/platform-config.md` for setup.
