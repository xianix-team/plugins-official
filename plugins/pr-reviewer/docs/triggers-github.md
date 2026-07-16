# Automated Triggering — GitHub

This guide shows how to make the **Xianix Agent** run the PR Reviewer plugin automatically on GitHub, driven by webhook events. Each example is an **execution block** you add to the `executions` array of your `rules.json`.

For manual/interactive use (`/pr-review` in a chat), see the main [README](../README.md). For token setup and scopes, see [`platform-setup.md`](./platform-setup.md) and [`git-auth.md`](./git-auth.md).

---

## How GitHub triggering works

GitHub webhook payloads **include label data**, so the plugin uses **label-based** triggering for reviews: apply the `ai-dlc/pr/pr-review` label to a PR (or open a PR that already has it) and the agent reviews it. User-driven, ad-hoc requests use **`@xianix` comment mentions** instead.

| Scenario | Webhook event | Filter rule |
|---|---|---|
| PR opened with the review label | `pull_request` | `action==opened` and `ai-dlc/pr/pr-review` in `pull_request.labels` |
| Label applied to an existing PR | `pull_request` | `action==labeled` and `label.name=='ai-dlc/pr/pr-review'` |
| New commits pushed to a labeled PR | `pull_request` | `action==synchronize` and `ai-dlc/pr/pr-review` in `pull_request.labels` |
| User `@xianix` comment on a PR | `issue_comment` | `action==created` and `comment.body` contains `@xianix` and `issue.pull_request?` |

---

## Execution-block shape

Every execution block shares this top-level shape:

| Field | Purpose |
|---|---|
| `name` | Human-readable id for the execution |
| `platform` | `"github"` — drives which provider the plugin uses |
| `repository.url` | Webhook path to the repository URL (`repository.clone_url`) |
| `match-any` | Array of trigger filters — the first one to match fires the execution |
| `use-inputs` | The values the prompt needs — usually just the PR number |
| `use-plugins` | The plugin to invoke (optionally with a `slash-command`) |
| `with-envs` | Required environment variables, sourced from the agent's `secrets.*` store |
| `conversation-key` | Groups repeated events for the same PR into one conversation so re-reviews reconcile against prior state |
| `model` / `max-budget-usd` | Model and cost cap for the run |
| `execute-prompt` | The prompt sent to the agent. Implicit interpolations: `{{repository-name}}`, plus any `name` from `use-inputs` |

The `GITHUB-TOKEN` secret is injected via `with-envs` and authenticates `gh` for fetching PR data and posting the review. See [`platform-setup.md`](./platform-setup.md#github) for the exact permissions.

---

## Recommended: one block covering create + label + update

In production, the three review triggers (opened-with-label, label-applied, new-commits) are best combined into a **single execution block** using `match-any`. The `conversation-key` on `pull_request.number` ties every event for a PR to the same conversation, so a push after the initial review automatically runs as a **re-review** (prior findings reconciled) rather than a fresh full review.

```json
{
  "name": "github-pull-request-review",
  "platform": "github",
  "repository": {
    "url": "repository.clone_url"
  },
  "match-any": [
    {
      "name": "github-pr-tag-applied",
      "rule": "action==labeled&&label.name=='ai-dlc/pr/pr-review'&&pull_request.state=='open'"
    },
    {
      "name": "github-pr-opened-with-tag",
      "rule": "action==opened&&pull_request.labels.*.name=='ai-dlc/pr/pr-review'&&pull_request.state=='open'"
    },
    {
      "name": "github-pr-synchronize-with-tag",
      "rule": "action==synchronize&&pull_request.labels.*.name=='ai-dlc/pr/pr-review'&&pull_request.state=='open'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "pull_request.number", "mandatory": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "GITHUB-TOKEN", "value": "secrets.GITHUB-TOKEN", "mandatory": true }
  ],
  "conversation-key": "pull_request.number",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 3,
  "execute-prompt": "You are reviewing pull request #{{pr-number}} in the repository {{repository-name}}. Run /pr-review {{pr-number}} to perform the automated review."
}
```

The scenarios below break the same behavior into standalone blocks if you prefer separate budgets or prompts per event.

---

## Scenario 1 — PR opened with the review label

A PR is created with `ai-dlc/pr/pr-review` already applied. This runs a full initial review immediately.

```json
{
  "name": "github-pr-review-opened-with-tag",
  "platform": "github",
  "repository": {
    "url": "repository.clone_url"
  },
  "match-any": [
    {
      "name": "github-pr-opened-with-tag",
      "rule": "action==opened&&pull_request.labels.*.name=='ai-dlc/pr/pr-review'&&pull_request.state=='open'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "pull_request.number", "mandatory": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "GITHUB-TOKEN", "value": "secrets.GITHUB-TOKEN", "mandatory": true }
  ],
  "conversation-key": "pull_request.number",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 3,
  "execute-prompt": "You are reviewing pull request #{{pr-number}} in the repository {{repository-name}}. Run /pr-review {{pr-number}} to perform the automated review."
}
```

---

## Scenario 2 — Review label applied to an existing PR (tag trigger)

A human (or another rule) adds the `ai-dlc/pr/pr-review` label to an already-open PR. This is the on-demand "review this now" trigger.

```json
{
  "name": "github-pr-review-tag-applied",
  "platform": "github",
  "repository": {
    "url": "repository.clone_url"
  },
  "match-any": [
    {
      "name": "github-pr-tag-applied",
      "rule": "action==labeled&&label.name=='ai-dlc/pr/pr-review'&&pull_request.state=='open'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "pull_request.number", "mandatory": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "GITHUB-TOKEN", "value": "secrets.GITHUB-TOKEN", "mandatory": true }
  ],
  "conversation-key": "pull_request.number",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 3,
  "execute-prompt": "You are reviewing pull request #{{pr-number}} in the repository {{repository-name}}. Run /pr-review {{pr-number}} to perform the automated review."
}
```

> **Changing the tag.** The trigger phrase `ai-dlc/pr/pr-review` is just the string in the filter rule — change it in both the `labeled` and `opened` rules if your team uses a different label. Make sure the label actually exists in the repository's label list so it can be applied.

---

## Scenario 3 — New commits pushed to a labeled PR (PR update)

When the author pushes new commits to a labeled PR, GitHub fires `action==synchronize`. Because a prior review already exists (matched via `conversation-key`), the plugin runs in **re-review mode** — reconciling prior findings and focusing on the new commits.

To scope the run to only the incremental diff (cheaper), use the `--push-update` flag and a lower budget:

```json
{
  "name": "github-pr-review-update",
  "platform": "github",
  "repository": {
    "url": "repository.clone_url"
  },
  "match-any": [
    {
      "name": "github-pr-synchronize-with-tag",
      "rule": "action==synchronize&&pull_request.labels.*.name=='ai-dlc/pr/pr-review'&&pull_request.state=='open'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "pull_request.number", "mandatory": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "GITHUB-TOKEN", "value": "secrets.GITHUB-TOKEN", "mandatory": true }
  ],
  "conversation-key": "pull_request.number",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 1.5,
  "execute-prompt": "New commits were pushed to pull request #{{pr-number}} in the repository {{repository-name}}. Run /pr-review {{pr-number}} --push-update to perform a focused review of the new commits since the last review."
}
```

> **Budget.** The update block uses a lower `max-budget-usd` because `--push-update` scopes the review to only the incremental diff since the last review — it does not re-scan the full PR.

---

## Scenario 4 — User `@xianix` comment on a PR

Lets a human ask the agent for something ad hoc by mentioning `@xianix` in a PR comment (e.g. "@xianix re-review the auth changes"). This does **not** depend on the label — any PR comment containing `@xianix` triggers it. The `issue.pull_request?` guard ensures the comment is on a PR (not a plain issue).

```json
{
  "name": "github-pr-agent-comment-instruction",
  "platform": "github",
  "repository": {
    "url": "repository.clone_url"
  },
  "match-any": [
    {
      "name": "github-pr-agent-re-instruction-requested",
      "rule": "action==created&&comment.body*='@xianix'&&issue.pull_request?"
    }
  ],
  "use-inputs": [
    { "name": "pr-number", "value": "issue.number" },
    { "name": "user-instruction", "value": "comment.body" },
    { "name": "comment-author", "value": "comment.user.login" },
    { "name": "comment-id", "value": "comment.id" }
  ],
  "use-plugins": [
    {
      "plugin-name": "pr-reviewer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official",
      "slash-command": "/pr-review"
    }
  ],
  "with-envs": [
    { "name": "GITHUB-TOKEN", "value": "secrets.GITHUB-TOKEN", "mandatory": true }
  ],
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 5,
  "execute-prompt": "You are @xianix. {{comment-author}} mentioned @xianix in a comment on pull request #{{pr-number}}. The comment: \"{{user-instruction}}\"\n\nFirst, decide whether this comment is actually addressed to you, versus just mentioning your name in passing (e.g. referencing past actions, or talking about you to someone else). If the comment is NOT addressed to you, do nothing and post no reply.\n\nIf the comment IS addressed to you, you MUST post a reply back as a comment. IMPORTANT: your text output alone is NOT delivered to the user — you have to create the comment yourself by calling the platform's comment API/CLI noted in the host context above (e.g. `gh pr comment`/`gh api` for GitHub). A run that produces reply text but never posts a comment is a failure.\n1. If it's a greeting, question, or casual message with no technical task (e.g. \"how are you?\"), post a brief, conversational reply comment.\n2. If it's a direct instruction, strip the @xianix mention, perform the requested action using the tools available to you, then post a comment stating what you did.\n\nGuidelines:\n- Keep your reply concise — state what you did and any findings, don't restate the request back.\n- If the instruction is ambiguous, ask a clarifying question in your reply rather than guessing.\n- If you lack access or the request is out of scope for this PR, say so plainly.\n- If necessary, read the other comments on the PR to understand the context.\n- Only act within this PR's files and branch; do not touch unrelated code.\n- Post at most one reply comment per invocation."
}
```

> **Why the "is it addressed to me?" preamble?** A bare substring match on `@xianix` also fires when someone mentions the agent in passing. The prompt makes the agent decide whether it is actually being asked to do something before it acts or replies.

---

## Notes

- **Filter order matters.** Within `match-any`, the first matching rule wins — order the more specific rules first.
- **`pull_request.state=='open'`** guards against triggering on labels applied to closed/merged PRs.
- **`conversation-key`** is what enables re-review reconciliation across events. Omit it and every event starts a stateless conversation (the plugin can still detect its own prior comments, but grouping is cleaner with the key).
- These blocks go inside the `executions` array of a rule set. See the [Rules Configuration](/agent-configuration/rules/) guide for the full file structure and filter syntax.
