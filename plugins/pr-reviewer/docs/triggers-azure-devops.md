# Automated Triggering — Azure DevOps

This guide shows how to make the **Xianix Agent** run the PR Reviewer plugin automatically on Azure DevOps, driven by service-hook events. Each example is an **execution block** you add to the `executions` array of your `rules.json`.

For manual/interactive use (`/pr-review` in a chat), see the main [README](../README.md). For token setup and scopes, see [`platform-setup.md`](./platform-setup.md#azure-devops) and [`git-auth.md`](./git-auth.md).

---

## How Azure DevOps triggering works

> **Why not labels?** Azure DevOps webhook payloads do **not** include label/tag data (`resource.labels` is absent), so label-driven rules cannot filter on PR tags. Instead, the agent triggers on **PR lifecycle events** (created, source branch updated), on being **added as a reviewer**, and on **`@xianix` comment mentions**.

| Scenario | Event type | Filter rule |
|---|---|---|
| PR created | `git.pullrequest.created` | `resource.status=='active'` |
| New commits pushed (PR update) | `git.pullrequest.updated` | `message.text` contains `updated the source branch` and `resource.status=='active'` |
| Agent added as a reviewer | `git.pullrequest.updated` | `message.text` contains `changed the reviewer list` and `xianix-agent@99x.io` in `resource.reviewers` |
| User `@xianix` comment on a PR | `ms.vss-code.git-pullrequest-comment-event` | `resource.comment.commentType=='text'` and `resource.comment.content` contains `@xianix` |

The reviewer identity `xianix-agent@99x.io` is the agent's Azure DevOps account — replace it with whatever account your agent authenticates as.

---

## Execution-block shape

Every execution block shares this top-level shape:

| Field | Purpose |
|---|---|
| `name` | Human-readable id for the execution |
| `platform` | `"azuredevops"` — drives which provider the plugin uses |
| `repository.url` | Webhook path to the repository URL (`resource.repository.remoteUrl`) |
| `match-any` | Array of trigger filters — the first one to match fires the execution |
| `use-inputs` | The values the prompt needs — usually just the PR id |
| `use-plugins` | The plugin to invoke (optionally with a `slash-command`) |
| `with-envs` | Required environment variables, sourced from the agent's `secrets.*` store |
| `conversation-key` | Groups repeated events for the same PR into one conversation so re-reviews reconcile against prior state |
| `model` / `max-budget-usd` | Model and cost cap for the run |
| `execute-prompt` | The prompt sent to the agent. Implicit interpolations: `{{repository-name}}`, plus any `name` from `use-inputs` |

The `AZURE-DEVOPS-TOKEN` secret is injected via `with-envs`; it authenticates the REST API calls used to post the review and cast the reviewer vote, and (in `--fix` mode) `git push`. See [`platform-setup.md`](./platform-setup.md#azure-devops) for the exact PAT scopes.

---

## Recommended: one block covering create + update + reviewer-added

In production, the three review triggers (PR created, source branch updated, agent added as reviewer) are best combined into a **single execution block** using `match-any`. The `conversation-key` on `resource.pullRequestId` ties every event for a PR to the same conversation, so a push after the initial review automatically runs as a **re-review** (prior findings reconciled) rather than a fresh full review.

```json
{
  "name": "azuredevops-pull-request-review",
  "platform": "azuredevops",
  "repository": {
    "url": "resource.repository.remoteUrl"
  },
  "match-any": [
    {
      "name": "azuredevops-pr-created",
      "rule": "eventType==git.pullrequest.created&&resource.status=='active'"
    },
    {
      "name": "azuredevops-pr-source-branch-updated",
      "rule": "eventType==git.pullrequest.updated&&message.text*='updated the source branch'&&resource.status=='active'"
    },
    {
      "name": "azuredevops-pr-agent-added-as-reviewer",
      "rule": "eventType==git.pullrequest.updated&&message.text*='changed the reviewer list'&&resource.reviewers.*.uniqueName=='xianix-agent@99x.io'&&resource.status=='active'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "resource.pullRequestId", "mandatory": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "AZURE-DEVOPS-TOKEN", "value": "secrets.AZURE-DEVOPS-TOKEN", "mandatory": true }
  ],
  "conversation-key": "resource.pullRequestId",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 5,
  "execute-prompt": "You are reviewing pull request #{{pr-number}} in the repository {{repository-name}}. Run /pr-review {{pr-number}} to perform the automated review."
}
```

The scenarios below break the same behavior into standalone blocks if you prefer separate budgets or prompts per event.

---

## Scenario 1 — PR created

A new pull request is opened. This runs a full initial review immediately, for every new active PR in the repository.

```json
{
  "name": "azuredevops-pr-review-created",
  "platform": "azuredevops",
  "repository": {
    "url": "resource.repository.remoteUrl"
  },
  "match-any": [
    {
      "name": "azuredevops-pr-created",
      "rule": "eventType==git.pullrequest.created&&resource.status=='active'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "resource.pullRequestId", "mandatory": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "AZURE-DEVOPS-TOKEN", "value": "secrets.AZURE-DEVOPS-TOKEN", "mandatory": true }
  ],
  "conversation-key": "resource.pullRequestId",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 5,
  "execute-prompt": "You are reviewing pull request #{{pr-number}} in the repository {{repository-name}}. Run /pr-review {{pr-number}} to perform the automated review."
}
```

> **Reviewing every PR is broad.** Because Azure DevOps has no label to gate on, `git.pullrequest.created` fires for *all* new PRs. If you only want to review some PRs, prefer Scenario 3 (reviewer-assignment) or Scenario 4 (`@xianix` comment) as your opt-in trigger instead of PR-created.

---

## Scenario 2 — New commits pushed (PR update)

When the author pushes new commits, Azure DevOps fires `git.pullrequest.updated` with the message text `updated the source branch`. Because a prior review already exists (matched via `conversation-key`), the plugin runs in **re-review mode** — reconciling prior findings and focusing on the new commits.

To scope the run to only the incremental diff (cheaper), use the `--push-update` flag and a lower budget:

```json
{
  "name": "azuredevops-pr-review-update",
  "platform": "azuredevops",
  "repository": {
    "url": "resource.repository.remoteUrl"
  },
  "match-any": [
    {
      "name": "azuredevops-pr-source-branch-updated",
      "rule": "eventType==git.pullrequest.updated&&message.text*='updated the source branch'&&resource.status=='active'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "resource.pullRequestId", "mandatory": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "AZURE-DEVOPS-TOKEN", "value": "secrets.AZURE-DEVOPS-TOKEN", "mandatory": true }
  ],
  "conversation-key": "resource.pullRequestId",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 2,
  "execute-prompt": "New commits were pushed to pull request #{{pr-number}} in the repository {{repository-name}}. Run /pr-review {{pr-number}} --push-update to perform a focused review of the new commits since the last review."
}
```

> **Budget.** The update block uses a lower `max-budget-usd` because `--push-update` scopes the review to only the incremental diff since the last review — it does not re-scan the full PR.

---

## Scenario 3 — Agent added as a reviewer

The cleanest opt-in on Azure DevOps: a human adds `xianix-agent@99x.io` to the PR's reviewer list, and the agent reviews it. This replaces the label trigger used on GitHub.

```json
{
  "name": "azuredevops-pr-review-reviewer-added",
  "platform": "azuredevops",
  "repository": {
    "url": "resource.repository.remoteUrl"
  },
  "match-any": [
    {
      "name": "azuredevops-pr-agent-added-as-reviewer",
      "rule": "eventType==git.pullrequest.updated&&message.text*='changed the reviewer list'&&resource.reviewers.*.uniqueName=='xianix-agent@99x.io'&&resource.status=='active'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "resource.pullRequestId", "mandatory": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "AZURE-DEVOPS-TOKEN", "value": "secrets.AZURE-DEVOPS-TOKEN", "mandatory": true }
  ],
  "conversation-key": "resource.pullRequestId",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 5,
  "execute-prompt": "You are reviewing pull request #{{pr-number}} in the repository {{repository-name}}. Run /pr-review {{pr-number}} to perform the automated review."
}
```

> **Reviewer identity.** `xianix-agent@99x.io` is the `uniqueName` of the account your agent authenticates as (the same account the `AZURE-DEVOPS-TOKEN` PAT belongs to). Change it to match your agent's account, or the vote and reviewer-match will not line up.

---

## Scenario 4 — User `@xianix` comment on a PR

Lets a human ask the agent for something ad hoc by mentioning `@xianix` in a PR comment (e.g. "@xianix re-review the auth changes"). `resource.comment.commentType=='text'` ensures it's a real user comment, not a system entry.

```json
{
  "name": "azuredevops-pr-agent-comment-instruction",
  "platform": "azuredevops",
  "repository": "resource.pullRequest.repository.remoteUrl",
  "match-any": [
    {
      "name": "azuredevops-pr-agent-re-review-requested",
      "rule": "eventType==ms.vss-code.git-pullrequest-comment-event&&resource.comment.commentType=='text'&&resource.comment.content*='@xianix'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "resource.pullRequest.pullRequestId" },
    { "name": "user-instruction", "value": "resource.comment.content" },
    { "name": "comment-author", "value": "resource.comment.author.displayName" },
    { "name": "thread-id", "value": "resource.comment.parentCommentId" }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official",
      "slash-command": "/pr-review"
    }
  ],
  "with-envs": [
    { "name": "AZURE-DEVOPS-TOKEN", "value": "secrets.AZURE-DEVOPS-TOKEN", "mandatory": true }
  ],
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 5,
  "execute-prompt": "You are @xianix. {{comment-author}} mentioned @xianix in a comment on pull request #{{pr-number}}. The comment: \"{{user-instruction}}\"\n\nFirst, decide whether this comment is actually addressed to you, versus just mentioning your name in passing (e.g. referencing past actions, or talking about you to someone else). If the comment is NOT addressed to you, do nothing and post no reply.\n\nIf the comment IS addressed to you, you MUST post a reply back as a comment. IMPORTANT: your text output alone is NOT delivered to the user — you have to create the comment yourself by calling the Azure DevOps REST API noted in the host context above. A run that produces reply text but never posts a comment is a failure.\n1. If it's a greeting, question, or casual message with no technical task (e.g. \"how are you?\"), post a brief, conversational reply comment.\n2. If it's a direct instruction, strip the @xianix mention, perform the requested action using the tools available to you, then post a comment stating what you did.\n\nGuidelines:\n- Keep your reply concise — state what you did and any findings, don't restate the request back.\n- If the instruction is ambiguous, ask a clarifying question in your reply rather than guessing.\n- If you lack access or the request is out of scope for this PR, say so plainly.\n- If necessary read the other comments on the PR to understand the context.\n- Only act within this PR's files and branch; do not touch unrelated code.\n- Post at most one reply comment per invocation."
}
```

> **Why the "is it addressed to me?" preamble?** A bare substring match on `@xianix` also fires when someone mentions the agent in passing. The prompt makes the agent decide whether it is actually being asked to do something before it acts or replies.

---

## Notes

- **Filter order matters.** Within `match-any`, the first matching rule wins — order the more specific rules first.
- **`resource.status=='active'`** guards against triggering on abandoned/completed PRs.
- **`message.text` matching** (`*=`) is how Azure DevOps update events are distinguished, since a single `git.pullrequest.updated` event type covers both branch pushes and reviewer-list changes.
- **`conversation-key`** is what enables re-review reconciliation across events. Omit it and every event starts a stateless conversation (the plugin can still detect its own prior threads via thread properties, but grouping is cleaner with the key).
- **Token name hygiene:** the secret arrives as `AZURE-DEVOPS-TOKEN` (dashes); the executor re-exports it as the underscored `AZURE_DEVOPS_TOKEN` the plugin references. See [`platform-setup.md`](./platform-setup.md#azure-devops).
- These blocks go inside the `executions` array of a rule set. See the [Rules Configuration](/agent-configuration/rules/) guide for the full file structure and filter syntax.
