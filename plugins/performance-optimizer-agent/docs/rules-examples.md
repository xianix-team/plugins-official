# Rules Configuration

The Performance Optimizer Agent is **tag-driven** when invoked through Xianix Agent rules. Use **two** execution blocks in your `rules.json`:

- **Analysis rule** — runs on `ai-dlc/pr/perf-optimize`
- **Fix PR rule** — runs on `ai-dlc/pr/perf-optimize-fix`

Each block belongs inside the `executions` array of a rule set. See [Rules Configuration](/agent-configuration/rules/) for the full syntax.

---

## Trigger behavior

The Performance Optimizer Agent is tag-driven:

| Scenario | What it covers |
|---|---|
| Analysis tag applied | Someone adds `ai-dlc/pr/perf-optimize` to an open PR |
| PR opened with analysis tag | PR is created with `ai-dlc/pr/perf-optimize` already present |
| Fix tag applied | Someone adds `ai-dlc/pr/perf-optimize-fix` after reviewing findings |
| New commits to tagged PR | Branch updates while either tag remains |

### Webhook filters

| Platform | Scenario | Webhook event | Filter rule |
|---|---|---|---|
| GitHub | Tag newly applied | `pull_request` | `action==labeled` and `label.name=='ai-dlc/pr/perf-optimize'` |
| GitHub | PR opened with tag | `pull_request` | `action==opened` and `ai-dlc/pr/perf-optimize` is in `pull_request.labels` |
| GitHub | New commits to tagged PR | `pull_request` | `action==synchronize` and `ai-dlc/pr/perf-optimize` is in `pull_request.labels` |
| GitHub | Fix tag applied | `pull_request` | `action==labeled` and `label.name=='ai-dlc/pr/perf-optimize-fix'` |
| Azure DevOps | Tag newly applied | `git.pullrequest.updated` | `message.text` contains `tagged the pull request` and `ai-dlc/pr/perf-optimize` is in `resource.labels` |
| Azure DevOps | PR created with tag | `git.pullrequest.created` | `ai-dlc/pr/perf-optimize` is in `resource.labels` |
| Azure DevOps | New commits to tagged PR | `git.pullrequest.updated` | `message.text` contains `updated the source branch` and `ai-dlc/pr/perf-optimize` is in `resource.labels` |
| Azure DevOps | Fix tag applied | `git.pullrequest.updated` | `message.text` contains `tagged the pull request` and `ai-dlc/pr/perf-optimize-fix` is in `resource.labels` |

---

## GitHub Analysis Rule

```json
{
  "name": "github-performance-optimizer-analysis",
  "match-any": [
    {
      "name": "github-pr-tag-applied",
      "rule": "action==labeled&&label.name=='ai-dlc/pr/perf-optimize'"
    },
    {
      "name": "github-pr-opened-with-tag",
      "rule": "action==opened&&pull_request.labels.*.name=='ai-dlc/pr/perf-optimize'"
    },
    {
      "name": "github-pr-synchronize-with-tag",
      "rule": "action==synchronize&&pull_request.labels.*.name=='ai-dlc/pr/perf-optimize'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number",       "value": "number" },
    { "name": "repository-url",  "value": "repository.clone_url" },
    { "name": "repository-name", "value": "repository.full_name" },
    { "name": "pr-title",        "value": "pull_request.title" },
    { "name": "pr-head-branch",  "value": "pull_request.head.ref" },
    { "name": "platform",        "value": "github", "constant": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "performance-optimizer-agent@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "execute-prompt": "You are running an analysis-first performance bottleneck review for pull request #{{pr-number}} titled \"{{pr-title}}\" in repository {{repository-name}} (branch: {{pr-head-branch}}).\n\nRun /perf-optimize and post findings only. Do not create a fix PR unless the opt-in fix tag is present."
}
```

## GitHub Fix PR Rule

```json
{
  "name": "github-performance-optimizer-fix-pr",
  "match-any": [
    {
      "name": "github-pr-fix-tag-applied",
      "rule": "action==labeled&&label.name=='ai-dlc/pr/perf-optimize-fix'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number",       "value": "number" },
    { "name": "repository-url",  "value": "repository.clone_url" },
    { "name": "repository-name", "value": "repository.full_name" },
    { "name": "pr-title",        "value": "pull_request.title" },
    { "name": "pr-head-branch",  "value": "pull_request.head.ref" },
    { "name": "platform",        "value": "github", "constant": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "performance-optimizer-agent@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "execute-prompt": "You are running opt-in fix mode for pull request #{{pr-number}} titled \"{{pr-title}}\" in repository {{repository-name}} (branch: {{pr-head-branch}}).\n\nRun /perf-optimize --fix-pr. Create a separate PR with focused, low-risk performance optimizations and link it to the source PR."
}
```

## Azure DevOps Analysis Rule

```json
{
  "name": "azuredevops-performance-optimizer-analysis",
  "match-any": [
    {
      "name": "azuredevops-pr-tag-applied",
      "rule": "eventType==git.pullrequest.updated&&message.text*='tagged the pull request'&&resource.labels.*.name=='ai-dlc/pr/perf-optimize'"
    },
    {
      "name": "azuredevops-pr-created-with-tag",
      "rule": "eventType==git.pullrequest.created&&resource.labels.*.name=='ai-dlc/pr/perf-optimize'"
    },
    {
      "name": "azuredevops-pr-source-branch-updated-with-tag",
      "rule": "eventType==git.pullrequest.updated&&message.text*='updated the source branch'&&resource.labels.*.name=='ai-dlc/pr/perf-optimize'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number",       "value": "resource.pullRequestId" },
    { "name": "repository-url",  "value": "resource.repository.remoteUrl" },
    { "name": "repository-name", "value": "resource.repository.name" },
    { "name": "pr-title",        "value": "resource.title" },
    { "name": "pr-head-branch",  "value": "resource.sourceRefName" },
    { "name": "platform",        "value": "azuredevops", "constant": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "performance-optimizer-agent@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "execute-prompt": "You are running an analysis-first performance bottleneck review for pull request #{{pr-number}} titled \"{{pr-title}}\" in repository {{repository-name}} (branch: {{pr-head-branch}}).\n\nRun /perf-optimize and post findings only. Do not create a fix PR unless the opt-in fix tag is present."
}
```

## Azure DevOps Fix PR Rule

```json
{
  "name": "azuredevops-performance-optimizer-fix-pr",
  "match-any": [
    {
      "name": "azuredevops-pr-fix-tag-applied",
      "rule": "eventType==git.pullrequest.updated&&message.text*='tagged the pull request'&&resource.labels.*.name=='ai-dlc/pr/perf-optimize-fix'"
    }
  ],
  "use-inputs": [
    { "name": "pr-number",       "value": "resource.pullRequestId" },
    { "name": "repository-url",  "value": "resource.repository.remoteUrl" },
    { "name": "repository-name", "value": "resource.repository.name" },
    { "name": "pr-title",        "value": "resource.title" },
    { "name": "pr-head-branch",  "value": "resource.sourceRefName" },
    { "name": "platform",        "value": "azuredevops", "constant": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "performance-optimizer-agent@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "execute-prompt": "You are running opt-in fix mode for pull request #{{pr-number}} titled \"{{pr-title}}\" in repository {{repository-name}} (branch: {{pr-head-branch}}).\n\nRun /perf-optimize --fix-pr. Create a separate PR with focused, low-risk performance optimizations and link it to the source PR."
}
```

---

## Notes

- These blocks belong inside the `executions` array of a rule set.
- The **analysis** rule is safe to fire on every PR update — it only posts a report and never modifies code.
- The **fix-PR** rule is opt-in: it runs only when a maintainer explicitly applies the `ai-dlc/pr/perf-optimize-fix` label after reviewing the analysis findings.
- The agent will never push to the source PR branch, regardless of which rule fires.
