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

## GitHub Rule

```json
{
  "name": "github-performance-optimizer",
  "match-any": [
    {
      "name": "github-issue-label-applied",
      "rule": "action==labeled&&label.name=='ai-dlc/perf/optimize'"
    }
  ],
  "use-inputs": [
    { "name": "issue-number",     "value": "issue.number" },
    { "name": "issue-title",      "value": "issue.title" },
    { "name": "issue-body",       "value": "issue.body" },
    { "name": "repository-url",   "value": "repository.clone_url" },
    { "name": "repository-name",  "value": "repository.full_name" },
    { "name": "default-branch",   "value": "repository.default_branch" },
    { "name": "platform",         "value": "github", "constant": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "perf-optimizer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official",
      "envs": [
        { "name": "GITHUB-TOKEN", "value": "GITHUB_TOKEN" }
      ]
    }
  ],
  "execute-prompt": "You are running a whole-codebase performance review for repository {{repository-name}} triggered by issue #{{issue-number}} titled \"{{issue-title}}\".\n\nFetch the default branch ({{default-branch}}), parse any `Scope:` / `Target:` hints from the issue body below, and run /perf-optimize across the selected scope (default: entire codebase).\n\nApply only low-risk optimizations on a new branch named `perf/issue-{{issue-number}}-<slug>` and open a pull request against {{default-branch}}. The PR body MUST embed the full performance report and include `Closes #{{issue-number}}`. After opening the PR, post a comment on issue #{{issue-number}} linking to it.\n\nIssue body:\n{{issue-body}}"
}
```

> **Required env:** `GITHUB-TOKEN` must be mapped from a secret that holds a GitHub PAT with `repo` + `workflow` scopes (or a GitHub App token with equivalent permissions). The plugin's `validate-prerequisites.sh` hook relies on it for both `gh` calls and `git push` over HTTPS.

## Azure DevOps Rule

Because work items are project-scoped (not repo-scoped), the target repository URL must be configured on the rule itself rather than read from the event payload. Deploy one rule per repository you want to cover.

```json
{
  "name": "azuredevops-performance-optimizer",
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
    { "name": "repository-url",  "value": "https://dev.azure.com/<org>/<project>/_git/<repo>", "constant": true },
    { "name": "repository-name", "value": "<org>/<project>/<repo>", "constant": true },
    { "name": "default-branch",  "value": "main", "constant": true },
    { "name": "platform",        "value": "azuredevops", "constant": true }
  ],
  "use-plugins": [
    {
      "plugin-name": "perf-optimizer@xianix-plugins-official",
      "marketplace": "xianix-team/plugins-official",
      "envs": [
        { "name": "AZURE-DEVOPS-TOKEN", "value": "AZURE_DEVOPS_TOKEN" }
      ]
    }
  ],
  "execute-prompt": "You are running a whole-codebase performance review for repository {{repository-name}} triggered by work item #{{workitem-id}} titled \"{{workitem-title}}\".\n\nFetch the default branch ({{default-branch}}), parse any `Scope:` / `Target:` hints from the work item description below, and run /perf-optimize across the selected scope (default: entire codebase).\n\nApply only low-risk optimizations on a new branch named `perf/workitem-{{workitem-id}}-<slug>` and open a pull request against {{default-branch}}. The PR body MUST embed the full performance report and reference work item #{{workitem-id}}. After opening the PR, post a comment on the work item linking to it.\n\nWork item description:\n{{workitem-body}}"
}
```

> **Note:** Replace the `<org>`, `<project>`, and `<repo>` placeholders in the Azure DevOps rule with your actual values.
>
> **Required env:** `AZURE-DEVOPS-TOKEN` must be mapped from a secret holding an Azure DevOps PAT with `Work Items (Read & Write)` and `Code (Read, Write & Manage)` scopes. The `validate-prerequisites.sh` hook uses it for both `curl` REST calls and `git push`.

---

## Notes

- These blocks belong inside the `executions` array of a rule set.
- The single `ai-dlc/perf/optimize` trigger runs analysis and opens a PR in one shot. There is no separate "analysis only" or "opt-in fix" label.
- **One user action → one container.** The `match-any` array deliberately contains a single clause per platform (`action==labeled` for GitHub, `eventType==workitem.updated` for Azure DevOps). Do **not** add a second clause for `action==opened` / `eventType==workitem.created` — both platforms fire the later event in every path anyway, and adding the earlier one causes two containers to race on `git push` and PR creation for the same issue / work item.
- The agent never pushes to the repository's default branch. All edits land on a new `perf/issue-<number>-<slug>` or `perf/workitem-<id>-<slug>` branch, which becomes the source branch of the opened PR.
- Only findings classified as **Quick wins** by the analyzers are auto-applied. Deeper / architectural suggestions surface in the embedded report but are not committed.
