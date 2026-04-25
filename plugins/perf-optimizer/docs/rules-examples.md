# Rules Configuration

The Performance Optimizer is **label-driven** when invoked through Xianix Agent rules. A **single** label / tag drives the full analyze-and-fix flow:

- **GitHub:** apply `ai-dlc/perf/optimize` to an issue
- **Azure DevOps:** add `ai-dlc/perf/optimize` as a tag on a work item

Each block below belongs inside the `executions` array of a rule set. See [Rules Configuration](/agent-configuration/rules/) for full syntax.

---

## Trigger behavior

Each rule matches on **exactly one** webhook event per triggering action. The goal is simple: one user action (apply the label / tag) → one container run. To make this safe, the rules deliberately match only the event that is guaranteed to fire in every path.

| Platform | Scenario | Matched webhook event | Filter rule |
|---|---|---|---|
| GitHub | Label applied to an existing issue | `issues` `action==labeled` | `label.name=='ai-dlc/perf/optimize'` |
| GitHub | Issue created **with** the label already on it | `issues` `action==labeled` (fired by GitHub after `opened`) | `label.name=='ai-dlc/perf/optimize'` |
| Azure DevOps | Tag added to an existing work item | `workitem.updated` | `resource.fields['System.Tags']` contains `ai-dlc/perf/optimize` |
| Azure DevOps | Work item created **with** the tag | `workitem.updated` (fired after `workitem.created`) | `resource.fields['System.Tags']` contains `ai-dlc/perf/optimize` |

> **Why we do not also match `opened` / `workitem.created`:** GitHub fires both `issues.opened` **and** a separate `issues.labeled` event (one per label) when an issue is created with labels. Azure DevOps fires `workitem.created` followed by `workitem.updated` when a work item is created with tags. If the rule matched on both events, a single user action would spawn **two** concurrent containers for the same issue / work item, which then race on `git push` and PR creation. Matching only the later event (`labeled` / `workitem.updated`) covers both "created with tag" and "tag added later" with a single container — so these variants are **intentionally omitted** from the rule, not forgotten.

---

## Rule shape

The Xianix Agent rule format expresses four things explicitly:

- `platform` — top-level discriminator (`github` / `azuredevops`), used by the runtime to pick the right provider integration without relying on string-matching the remote URL.
- `repository` — where the runtime should clone / check out. `url` and `ref` are evaluated from the webhook payload (or from constants for ADO work items). For the performance optimizer, `ref` points at the repository's **default branch** because analysis is whole-codebase, not PR-scoped.
- `use-inputs` — named values extracted from the webhook payload and interpolated into `execute-prompt`.
- `with-envs` — **rule-level** environment variables resolved from the agent's secret store. `mandatory: true` means the runtime refuses to start the container if the secret is missing, which is exactly what we want for `GITHUB-TOKEN` / `AZURE-DEVOPS-TOKEN` — without them, the plugin's `validate-prerequisites.sh` hook would block the first `git push` anyway.

## GitHub Rule

```json
{
  "name": "github-performance-optimizer",
  "platform": "github",
  "repository": {
    "url": "repository.clone_url",
    "ref": "repository.default_branch"
  },
  "match-any": [
    {
      "name": "github-issue-label-applied",
      "rule": "action==labeled&&label.name=='ai-dlc/perf/optimize'"
    }
  ],
  "use-inputs": [
    { "name": "issue-number",    "value": "issue.number" },
    { "name": "issue-title",     "value": "issue.title" },
    { "name": "issue-body",      "value": "issue.body" },
    { "name": "repository-name", "value": "repository.full_name" },
    { "name": "default-branch",  "value": "repository.default_branch" }
  ],
  "use-plugins": [
    {
      "plugin-name": "perf-optimizer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    {
      "name": "GITHUB-TOKEN",
      "value": "secrets.GITHUB-TOKEN",
      "mandatory": true
    }
  ],
  "execute-prompt": "You are running a whole-codebase performance review for repository {{repository-name}} triggered by issue #{{issue-number}} titled \"{{issue-title}}\".\n\nFetch the default branch ({{default-branch}}), parse any `Scope:` / `Target:` hints from the issue body below, and run /perf-optimize across the selected scope (default: entire codebase).\n\nApply only low-risk optimizations on a new branch named `perf/issue-{{issue-number}}-<slug>` and open a pull request against {{default-branch}}. The PR body MUST embed the full performance report and include `Closes #{{issue-number}}`. After opening the PR, post a comment on issue #{{issue-number}} linking to it.\n\nIssue body:\n{{issue-body}}"
}
```

> **Required secret:** Store a GitHub PAT (`repo` + `workflow` scopes) or an equivalent GitHub App token in the agent's secret store under the key `GITHUB-TOKEN`. The rule exposes it inside the container as the env var `GITHUB-TOKEN`, which `validate-prerequisites.sh` consumes for both `gh` calls and `git push` over HTTPS.

## Azure DevOps Rule

Because work items are project-scoped (not repo-scoped), the target repository URL and default branch are **constants** on the rule itself rather than fields read from the event payload. Deploy one rule per repository you want to cover.

```json
{
  "name": "azuredevops-performance-optimizer",
  "platform": "azuredevops",
  "repository": {
    "url": "https://dev.azure.com/<org>/<project>/_git/<repo>",
    "ref": "main",
    "constant": true
  },
  "match-any": [
    {
      "name": "azuredevops-workitem-tagged",
      "rule": "eventType==workitem.updated&&resource.fields.System.Tags*='ai-dlc/perf/optimize'"
    }
  ],
  "use-inputs": [
    { "name": "workitem-id",     "value": "resource.id" },
    { "name": "workitem-title",  "value": "resource.fields.System.Title" },
    { "name": "workitem-body",   "value": "resource.fields.System.Description" },
    { "name": "repository-name", "value": "<org>/<project>/<repo>", "constant": true },
    { "name": "default-branch",  "value": "main", "constant": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "perf-optimizer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official"
    }
  ],
  "with-envs": [
    {
      "name": "AZURE-DEVOPS-TOKEN",
      "value": "secrets.AZURE-DEVOPS-TOKEN",
      "mandatory": true
    }
  ],
  "execute-prompt": "You are running a whole-codebase performance review for repository {{repository-name}} triggered by work item #{{workitem-id}} titled \"{{workitem-title}}\".\n\nFetch the default branch ({{default-branch}}), parse any `Scope:` / `Target:` hints from the work item description below, and run /perf-optimize across the selected scope (default: entire codebase).\n\nApply only low-risk optimizations on a new branch named `perf/workitem-{{workitem-id}}-<slug>` and open a pull request against {{default-branch}}. The PR body MUST embed the full performance report and reference work item #{{workitem-id}}. After opening the PR, post a comment on the work item linking to it.\n\nWork item description:\n{{workitem-body}}"
}
```

> **Note:** Replace the `<org>`, `<project>`, and `<repo>` placeholders in both the `repository.url` field and the `repository-name` input with your actual values. The `ref` defaults to `main` — change it if your repository's default branch is different.
>
> **Required secret:** Store an Azure DevOps PAT (`Work Items: Read & Write`, `Code: Read, Write & Manage`) in the agent's secret store under the key `AZURE-DEVOPS-TOKEN`. The rule exposes it inside the container as the env var `AZURE-DEVOPS-TOKEN`, consumed by both `curl` REST calls and `git push` to `dev.azure.com` / `visualstudio.com`.

---

## Notes

- These blocks belong inside the `executions` array of a rule set.
- The single `ai-dlc/perf/optimize` trigger runs analysis and opens a PR in one shot. There is no separate "analysis only" or "opt-in fix" label.
- **`with-envs` is rule-level, not plugin-level.** Secrets are declared once per rule and applied to every plugin the rule runs. `mandatory: true` makes the runtime fail-fast before the container starts if the secret is missing — which is strictly better than discovering it at the first `git push` inside the hook.
- **`repository.ref` is the analysis baseline.** For the performance optimizer it always points at the default branch (not at a PR head), because analysis is whole-codebase. The `perf-pr-author` agent then creates a new `perf/issue-<number>-<slug>` or `perf/workitem-<id>-<slug>` branch from that baseline — the baseline itself is never pushed to.
- **One user action → one container.** The `match-any` array deliberately contains a single clause per platform (`action==labeled` for GitHub, `eventType==workitem.updated` for Azure DevOps). Do **not** add a second clause for `action==opened` / `eventType==workitem.created` — both platforms fire the later event in every path anyway, and adding the earlier one causes two containers to race on `git push` and PR creation for the same issue / work item.
- Only findings classified as **Quick wins** by the analyzers are auto-applied. Deeper / architectural suggestions surface in the embedded report but are not committed.
