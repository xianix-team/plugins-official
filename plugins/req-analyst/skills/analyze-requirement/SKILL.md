---
name: analyze-requirement
description: Take the next grooming step on a backlog item (GitHub Issue, Azure DevOps Work Item, or plain text). Reads the comment thread, determines the conversation state, and either posts a short round of clarifying questions, folds the humans' answers into the description, or marks the item ready to proceed. Usage: /analyze-requirement [issue-number or work-item-id]
argument-hint: [issue-number | work-item-id]
---

Take one grooming turn on item $ARGUMENTS.

Use the **orchestrator** agent. It will:

1. Detect the platform from `git remote get-url origin` (or `PLATFORM` / `REPO_URL` / `ISSUE_NUMBER` in CI).
2. Fetch the item **and every comment**, ordered chronologically.
3. Determine the state from its own previous comments (footer `req-analyst · round N/3 · status: …`) and the human replies after them:
   - **NEW** — no previous round → analyse (repo docs, `context-analyst`, `gap-risk-analyst`) and post round 1 with ≤5 numbered questions, each with a default. Label `needs-clarification`.
   - **ANSWERED** — humans replied (`@xianix …`) → fold answers into the description per `styles/refined-description-template.md`, then post the next round with what is still open, or the *Ready to proceed* comment and label `groomed`.
   - **AWAITING** — no new replies → re-check the description for answers; otherwise do nothing.
   - **READY** — item groomed, human asks for a change → update the description and post a one-line *Updated* comment.
   - **SPLIT-PENDING** — waiting on `@xianix split` → create child items on confirmation.
4. Post **one** comment per `styles/round-comment-template.md`, swap the readiness label / tag, and output a single status line.

Rounds are capped at 3; afterwards the stated defaults apply and the item is marked ready with the assumptions listed.

If no argument is given, prompt the user for an item number or the requirement text.
