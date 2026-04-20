# Platform Setup Guide

The Performance Optimizer Agent uses **git** for diffs, commits, and file lists on **all** supported hosts (including GitHub and Azure DevOps). **GitHub CLI (`gh`)** and **Azure DevOps REST** (via `curl`) are used only for **posting** reviews, reading PR labels, and opening the optimization PR in fix-PR mode — not for the core analysis.

---

## GitHub

### GitHub CLI (`gh`) — required to post analysis reports and open optimization PRs

Diffs and logs come from **git**. Install **`gh`** so the plugin can:

- resolve the PR number when needed
- read PR labels (to detect the `ai-dlc/pr/perf-optimize-fix` opt-in tag)
- post the analysis comment
- open the optimization PR in fix-PR mode

```bash
# Install: https://cli.github.com
gh auth login
```

For CI or scripted use, set **`GH_TOKEN`** or **`GITHUB_TOKEN`** instead of interactive login.

### Token permissions

| Permission | Access | Purpose |
|---|---|---|
| **Contents** | Read | Read repository code, branches, commit history |
| **Metadata** | Read | Resolve repository metadata |
| **Pull requests** | Read & Write | Fetch PR context, post findings, open the optimization PR |

Classic tokens: `repo` (private repos) or `public_repo` (public only); `read:org` (org repos).

The plugin does **not** use the GitHub MCP server.

### Credentials for `git push` (fix-PR mode)

When fix-PR mode is triggered, the `fix-pr-author` agent pushes a brand-new `perf/optimize-*` branch (never the source PR branch). Pass the token at runtime:

```bash
GIT_TOKEN=ghp_your_token_here claude ...
```

Or export in your shell:

```bash
export GIT_TOKEN=ghp_your_token_here
```

---

## Azure DevOps

### Prerequisites

Install the Azure CLI if you want to use the same PAT for other tooling:

```bash
# https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
az extension add --name azure-devops
```

The plugin itself does **not** require the `az` CLI — it uses `curl` against the Azure DevOps REST API.

### Authentication

**Recommended: Personal Access Token**

```bash
export AZURE_DEVOPS_TOKEN=<your-pat>
```

Add to `~/.zshrc` or `~/.bashrc` to persist.

**PAT scopes needed:**

- `Code` → Read & Write
- `Pull Request Threads` → Read & Write

### Credentials for `git push` (fix-PR mode)

The plugin reuses `AZURE_DEVOPS_TOKEN` for `git push` credential injection automatically — no separate `GIT_TOKEN` is needed for Azure DevOps remotes.

### Generating a PAT

1. Go to `https://dev.azure.com/<your-org>/_usersSettings/tokens`
2. Click **New Token**
3. Set the scopes listed above
4. Copy the token and export it as `AZURE_DEVOPS_TOKEN`

---

## Bitbucket / Other Platforms

For platforms without native posting support, the plugin writes the analysis report to `performance-report.md` in the repository root. In fix-PR mode, it pushes the optimization branch and writes the PR body to `performance-fix-pr.md` so the maintainer can open the PR manually. You can then post or PR it however your platform expects.

No additional setup is required beyond a working git installation. For `git push` on an HTTPS remote, set `GIT_TOKEN` at runtime.

---

## Summary

| Platform | Analysis | Report posting | Token | Fix-PR push | Fix-PR open |
|---|---|---|---|---|---|
| GitHub | `git diff`, `git log`, … | `gh pr comment` | `gh auth` / `GH_TOKEN` / `GITHUB_TOKEN` | `GIT_TOKEN` | `gh pr create` |
| Azure DevOps | `git diff`, `git log`, … | REST (`curl`) per `providers/azure-devops.md` | `AZURE_DEVOPS_TOKEN` | `AZURE_DEVOPS_TOKEN` | REST (`curl`) |
| Bitbucket / Generic | `git diff`, `git log`, … | Write to `performance-report.md` | — | `GIT_TOKEN` | manual — body in `performance-fix-pr.md` |

---

## Related

- `providers/github.md` — GitHub-specific posting and PR-creation logic
- `providers/azure-devops.md` — Azure DevOps-specific posting and PR-creation logic
- `providers/generic.md` — fallback for unsupported platforms
- `docs/rules-examples.md` — Xianix Agent rules for tag-driven analysis and fix-PR execution
