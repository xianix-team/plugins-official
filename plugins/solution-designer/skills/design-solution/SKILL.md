---
name: design-solution
description: Take the next design step on a groomed backlog item — produce or revise a software design that conforms to the repository's accepted architecture, deliver it as a design PR, and post a short comment with the decisions needed. Usage: /design-solution [issue-number | work-item-id] [--force]
argument-hint: [issue-number | work-item-id] [--force]
---

Take one design turn on item $ARGUMENTS.

Use the **orchestrator** agent. It will:

1. Detect the platform and default branch.
2. Fetch the item and thread; determine the state from `solution-designer` footer markers (`` `solution-designer` · r<N> · status: … ``) and addressed `@xianix` replies.
3. Gate on grooming (`groomed` label/tag or `req-analyst` status *ready*) unless `--force` / `@xianix design anyway`.
4. Run `architecture-analyst` → `solution-designer` → `design-reviewer` (one fix pass).
5. Commit `docs/design/<id>-<slug>.md` and any proposed ADRs to `design/<id>-<slug>`, open or update the PR, post one comment per `styles/design-comment-template.md`, and set one of `design-needs-decision` / `design-proposed` / `design-approved`.
6. Output one status line.

If no argument is given, prompt for an item number or the requirement text.
