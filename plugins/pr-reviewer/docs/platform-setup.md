# Platform Setup Guide

The `pr-review` plugin uses **git** for diffs, commits, and file lists on **all** supported hosts (including GitHub and Azure DevOps). **GitHub CLI (`gh`)** and **Azure DevOps REST** (or `curl`) are used for **posting** reviews and for GitHub-specific steps like resolving a PR number — not for the core analysis.

---

## GitHub

### GitHub CLI (`gh`) — required to post reviews on GitHub

Diffs and logs come from **git**. Install **`gh`** so the plugin can resolve the PR number (when needed) and post comments and reviews.

```bash
# Install: https://cli.github.com
gh auth login
```

For CI or scripts, set **`GH_TOKEN`** or **`GITHUB_TOKEN`** instead of interactive login (same scopes as below).

**Token scopes:** `repo` (private repos) or `public_repo` (public repos only), `read:org` (optional).

The plugin does **not** use the GitHub MCP server. See `providers/github.md` for `gh` usage.

### Credentials for `git push` (fix mode)

When using `--fix`, the agent pushes commits. Pass the token at runtime:

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

Install the Azure CLI and the Azure DevOps extension:

```bash
# Install Azure CLI: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
az extension add --name azure-devops
```

### Authentication

**Option A: Interactive login**

```bash
az login
az devops configure --defaults organization=https://dev.azure.com/<your-org>
```

**Option B: Personal Access Token (recommended for CI or scripted use)**

```bash
export AZURE_DEVOPS_TOKEN=<your-pat>
echo $AZURE_DEVOPS_TOKEN | az devops login --org https://dev.azure.com/<your-org>
```

Add to `~/.zshrc` or `~/.bashrc` to persist:

```bash
export AZURE_DEVOPS_TOKEN=<your-pat>
```

**PAT scopes needed:**
- `Code` → Read & Write
- `Pull Request Threads` → Read & Write

### Credentials for `git push` (fix mode)

The plugin reuses `AZURE_DEVOPS_TOKEN` for `git push` credential injection automatically — no separate `GIT_TOKEN` is needed for Azure DevOps remotes.

### Generating a PAT

1. Go to `https://dev.azure.com/<your-org>/_usersSettings/tokens`
2. Click **New Token**
3. Set the scopes listed above
4. Copy the token and export it as `AZURE_DEVOPS_TOKEN`

---

## Bitbucket / Other Platforms

For platforms without native CLI support, the plugin writes the review report to `pr-review-report.md` in the repository root. You can then post it manually.

No additional setup is required beyond having a working git installation.

---

## Summary

| Platform | Analysis | Review posting | Token (posting / API) | Fix mode push |
|---|---|---|---|---|
| GitHub | `git diff`, `git log`, … | `gh pr review`, `gh pr comment`, `gh api` | `gh auth` / `GH_TOKEN` | `GIT_TOKEN` |
| Azure DevOps | `git diff`, `git log`, … | REST (`curl`) per `providers/azure-devops.md` | `AZURE_DEVOPS_TOKEN` / `AZURE_DEVOPS_TOKEN` | `AZURE_DEVOPS_TOKEN` |
| Generic | `git diff`, `git log`, … | Write to `pr-review-report.md` | — | `GIT_TOKEN` |

---

## Related

- `docs/git-auth.md` — details on how git credentials are injected at runtime without touching `~/.gitconfig`
- `providers/github.md` — GitHub-specific posting logic
- `providers/azure-devops.md` — Azure DevOps-specific posting logic
- `providers/generic.md` — fallback for unsupported platforms
