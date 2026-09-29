# Automated Triggering — GitHub

This guide shows how to make the **Xianix Agent** run the Architecture Fitness plugin automatically on GitHub, driven by webhook events. Each example is an **execution block** you add to the `executions` array of your `rules.json`.

For manual/interactive use (`/arch-fitness` in a chat), see the main [README](../README.md). For token setup and scopes, see [`platform-setup.md`](./platform-setup.md#github).

---

## How GitHub triggering works

Architecture Fitness is **issue-driven** — it attaches to a GitHub **Issue** (not a PR) and posts its report back as a comment on that issue. GitHub webhook payloads **include label data**, so the plugin supports two trigger styles:

| Trigger style | How a human starts it |
|---|---|
| **Label** | Apply the `ai-dlc/arch/fitness` label to an issue (or open an issue that already has it) |
| **Comment mention** | Comment `@xianix` on an issue with an optional instruction (e.g. `@xianix evaluate PRs merged in the last 3 months`) |

| Scenario | Webhook event | Filter rule |
|---|---|---|
| Issue opened with the fitness label | `issues` | `action==opened` and `ai-dlc/arch/fitness` in `issue.labels` |
| Label applied to an existing issue | `issues` | `action==labeled` and `label.name=='ai-dlc/arch/fitness'` |
| User `@xianix` comment on an issue | `issue_comment` | `action==created` and `comment.body` contains `@xianix` and **not** `issue.pull_request?` |

> **Why guard the comment trigger with `!issue.pull_request?`** GitHub delivers both issue and PR comments through the same `issue_comment` event. Architecture Fitness attaches to issues, so the `!issue.pull_request?` guard keeps it from firing on PR comments (which the PR Reviewer plugin handles).

---

## Execution-block shape

| Field | Purpose |
|---|---|
| `name` | Human-readable id for the execution |
| `platform` | `"github"` — drives which provider the plugin uses |
| `repository.url` | Webhook path to the repository URL (`repository.clone_url`) |
| `repository.ref` | Branch to check out — the repository **default branch** (`repository.default_branch`), since docs bootstrap and merged-PR scopes are whole-repo |
| `match-any` | Array of trigger filters — the first one to match fires the execution |
| `use-inputs` | Values interpolated into the prompt (issue number, title, body) |
| `use-plugins` | The plugin to invoke (optionally with a `slash-command`) |
| `with-envs` | Environment variables sourced from the agent's `secrets.*` store |
| `conversation-key` | Groups repeated events for the same issue into one conversation |
| `model` / `max-budget-usd` | Model and cost cap for the run |
| `execute-prompt` | The prompt sent to the agent. Implicit interpolations: `{{repository-name}}`, plus any `name` from `use-inputs` |

The `GITHUB-TOKEN` secret is injected via `with-envs` and authenticates `gh` for reading the issue, listing/fetching PR diffs, opening the docs PR, and posting the report comment. See [`platform-setup.md`](./platform-setup.md#github) for the exact permissions.

---

## Recommended: one block covering label triggers

The two label triggers (opened-with-label, label-applied) are best combined into a **single execution block** using `match-any`. Matching `labeled` alone would already cover "opened with label" (GitHub fires a `labeled` event after `opened`), but including both keeps the intent explicit; the `conversation-key` on `issue.number` prevents duplicate concurrent runs for the same issue.

```json
{
  "name": "github-architecture-fitness",
  "platform": "github",
  "repository": {
    "url": "repository.clone_url",
    "ref": "repository.default_branch"
  },
  "match-any": [
    {
      "name": "github-issue-label-applied",
      "rule": "action==labeled&&label.name=='ai-dlc/arch/fitness'&&issue.state=='open'"
    },
    {
      "name": "github-issue-opened-with-label",
      "rule": "action==opened&&issue.labels.*.name=='ai-dlc/arch/fitness'&&issue.state=='open'"
    }
  ],
  "use-inputs": [
    { "name": "issue-number",    "value": "issue.number", "mandatory": true },
    { "name": "issue-title",     "value": "issue.title" },
    { "name": "issue-body",      "value": "issue.body" },
    { "name": "default-branch",  "value": "repository.default_branch" }
  ],
  "use-plugins": [
    {
      "plugin-name": "arch-fitness@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "GITHUB-TOKEN", "value": "secrets.GITHUB-TOKEN", "mandatory": true }
  ],
  "conversation-key": "issue.number",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 5,
  "execute-prompt": "You are running an architecture fitness evaluation for repository {{repository-name}} triggered by issue #{{issue-number}} titled \"{{issue-title}}\".\n\nFetch the default branch ({{default-branch}}). Parse the ARCH FITNESS config block (if present) from the issue body below. Run /arch-fitness --issue {{issue-number}} with the resolved scope (default when on the default branch: last 30 days of merged PRs).\n\nDiscover or bootstrap docs/architecture/ constraints, open a docs PR against {{default-branch}} when docs are created or updated, then evaluate the requested scope against those constraints in the same run. Post the fitness report as a comment on issue #{{issue-number}} and apply the arch-fitness-complete label.\n\nIssue body:\n{{issue-body}}"
}
```

> **Changing the label.** The trigger phrase `ai-dlc/arch/fitness` is just the string in the filter rule — change it in both rules if your team uses a different label, and make sure the label exists in the repository's label list so it can be applied.

---

## Scenario — Label applied to an existing issue (standalone)

A human adds the `ai-dlc/arch/fitness` label to an already-open issue. This is the on-demand "evaluate this now" trigger.

```json
{
  "name": "github-architecture-fitness-label",
  "platform": "github",
  "repository": {
    "url": "repository.clone_url",
    "ref": "repository.default_branch"
  },
  "match-any": [
    {
      "name": "github-issue-label-applied",
      "rule": "action==labeled&&label.name=='ai-dlc/arch/fitness'&&issue.state=='open'"
    }
  ],
  "use-inputs": [
    { "name": "issue-number",    "value": "issue.number", "mandatory": true },
    { "name": "issue-title",     "value": "issue.title" },
    { "name": "issue-body",      "value": "issue.body" },
    { "name": "default-branch",  "value": "repository.default_branch" }
  ],
  "use-plugins": [
    {
      "plugin-name": "arch-fitness@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    { "name": "GITHUB-TOKEN", "value": "secrets.GITHUB-TOKEN", "mandatory": true }
  ],
  "conversation-key": "issue.number",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 5,
  "execute-prompt": "You are running an architecture fitness evaluation for repository {{repository-name}} triggered by issue #{{issue-number}} titled \"{{issue-title}}\".\n\nFetch the default branch ({{default-branch}}). Parse the ARCH FITNESS config block (if present) from the issue body below. Run /arch-fitness --issue {{issue-number}}.\n\nDiscover or bootstrap docs/architecture/ constraints, open a docs PR when docs change, then evaluate the requested scope and post the report as a comment on issue #{{issue-number}} with the arch-fitness-complete label.\n\nIssue body:\n{{issue-body}}"
}
```

---

## Scenario — User `@xianix` comment on an issue

Lets a human ask for an evaluation ad hoc by mentioning `@xianix` in an issue comment (e.g. `@xianix evaluate PRs merged in the last 3 months against our architecture constraints`). This does **not** depend on the label. The `!issue.pull_request?` guard keeps it scoped to issues.

```json
{
  "name": "github-architecture-fitness-comment-instruction",
  "platform": "github",
  "repository": {
    "url": "repository.clone_url",
    "ref": "repository.default_branch"
  },
  "match-any": [
    {
      "name": "github-issue-agent-instruction-requested",
      "rule": "action==created&&comment.body*='@xianix'&&issue.pull_request!?"
    }
  ],
  "use-inputs": [
    { "name": "issue-number",     "value": "issue.number", "mandatory": true },
    { "name": "issue-title",      "value": "issue.title" },
    { "name": "issue-body",       "value": "issue.body" },
    { "name": "user-instruction", "value": "comment.body" },
    { "name": "comment-author",   "value": "comment.user.login" },
    { "name": "comment-id",       "value": "comment.id" },
    { "name": "default-branch",   "value": "repository.default_branch" }
  ],
  "use-plugins": [
    {
      "plugin-name": "arch-fitness@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official",
      "slash-command": "/arch-fitness"
    }
  ],
  "with-envs": [
    { "name": "GITHUB-TOKEN", "value": "secrets.GITHUB-TOKEN", "mandatory": true }
  ],
  "conversation-key": "issue.number",
  "model": "claude-sonnet-4-5",
  "max-budget-usd": 5,
  "execute-prompt": "You are @xianix. {{comment-author}} mentioned @xianix in a comment on issue #{{issue-number}} (\"{{issue-title}}\") in repository {{repository-name}}. The comment: \"{{user-instruction}}\"\n\nFirst, decide whether this comment is actually addressed to you, versus just mentioning your name in passing. If it is NOT addressed to you, do nothing and post no reply.\n\nIf it IS addressed to you, treat the comment as the instruction for an architecture fitness run. Extract any scope from it (a PR number, a branch, or a merged-PR window like \"last 3 months\") and any Focus/Skip/Max-findings/Output hints; fall back to the ARCH FITNESS config block in the issue body when present. Run /arch-fitness --issue {{issue-number}} with the resolved scope.\n\nDiscover or bootstrap docs/architecture/ constraints, open a docs PR against {{default-branch}} when docs change, then evaluate the requested scope in the same run. You MUST post the fitness report back as a comment on issue #{{issue-number}} using `gh issue comment` — your text output alone is not delivered to the user. A run that produces a report but never posts a comment is a failure.\n\nIssue body:\n{{issue-body}}"
}
```

> **Why the \"is it addressed to me?\" preamble?** A bare substring match on `@xianix` also fires when someone mentions the agent in passing. The prompt makes the agent decide whether it is actually being asked to do something before it acts or replies.

---

## Notes

- **Filter order matters.** Within `match-any`, the first matching rule wins — order the more specific rules first.
- **`issue.state=='open'`** guards against triggering on labels applied to closed issues.
- **`conversation-key`** on `issue.number` groups repeated events for one issue (e.g. re-labeling, follow-up comments) into a single conversation.
- These blocks go inside the `executions` array of a rule set. See the [Rules Configuration](/agent-configuration/rules/) guide for the full file structure and filter syntax.
