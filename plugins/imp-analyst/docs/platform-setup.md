# Platform Setup Guide

The `imp-analyst` plugin uses **git** for diffs, commit history, and file content on **all** supported hosts. **GitHub MCP server** (preferred) or **GitHub CLI (`gh`)** (fallback) are used for posting reports to GitHub. **Azure DevOps REST API** (`curl`) is used for posting to Azure DevOps. The core analysis phase is platform-agnostic — only posting requires platform credentials.

---

## GitHub

### GitHub MCP Server — preferred for posting reports on GitHub

The plugin calls `mcp__github__get_pull_request` and `mcp__github__create_issue_comment` to fetch PR metadata and post the impact report as a PR comment. These require the GitHub MCP server to be connected in your Claude environment.

Run `/mcp` to confirm `github` appears as `connected`. If it is not connected, see `docs/mcp-config.md` for setup instructions.

### GitHub CLI (`gh`) — fallback if MCP is unavailable

If the GitHub MCP server is not connected, the plugin falls back to `gh` CLI for resolving the PR number and posting comments.

```bash
# Install: https://cli.github.com
gh auth login
```

For CI or scripts, set **`GH_TOKEN`** or **`GITHUB_TOKEN`** instead of interactive login.

**Token scopes:** `repo` (private repos) or `public_repo` (public repos only), `read:org` (optional).

---

## Azure DevOps

### Authentication

The plugin calls the Azure DevOps REST API directly via `curl` using a Personal Access Token (PAT). No `az` CLI is required.

**Export the token before launching Claude:**

```bash
export AZURE_TOKEN=<your-pat>
```

Add to `~/.zshrc` or `~/.bashrc` to persist across sessions.

> **Variable-name hygiene (important):** the variable name must be `AZURE_TOKEN` — **underscores only**. Some CI systems export it with hyphens (e.g. `AZURE-TOKEN`). Bash cannot reference hyphenated names, so `curl -u ":${AZURE-TOKEN}"` silently sends an empty password and every API call returns 401. If this happens, re-export under the correct name:
>
> ```bash
> export AZURE_TOKEN="$(env | sed -n 's/^AZURE-TOKEN=//p')"
> ```

**PAT scopes required:**
- `Code` → Read
- `Pull Request Threads` → Read & Write

### Optional override variables

The plugin parses org, project, and repo from the remote URL automatically. Set these only if the parsed values are wrong (e.g. when using a non-standard URL format):

| Variable | Default | Purpose |
|---|---|---|
| `AZURE_ORG` | Parsed from remote URL | Azure DevOps organisation name |
| `AZURE_PROJECT` | Parsed from remote URL | Project name |
| `AZURE_REPO` | Parsed from remote URL | Repository name |

### Generating a PAT

1. Go to `https://dev.azure.com/<your-org>/_usersSettings/tokens`
2. Click **New Token**
3. Set the name and expiry, then select the scopes listed above
4. Copy the token and export it as `AZURE_TOKEN`

---

## Generic / Unknown Platform

For platforms without native API support (Bitbucket, self-hosted GitLab, on-premises git servers, local runs), the plugin writes the report to `impact-analysis-report.md` in the repository root. No additional setup is required beyond a working git installation.

---

## Summary

| Platform | Analysis | Report posting | Token / Auth | Report location |
|---|---|---|---|---|
| GitHub | `git diff`, `git log`, … | GitHub MCP server (`mcp__github__*`) or `gh` CLI (fallback) | MCP connection / `GH_TOKEN` | PR comment + linked issue comment |
| Azure DevOps | `git diff`, `git log`, … | REST (`curl`) per `providers/azure-devops.md` | `AZURE_TOKEN` (PAT) | PR comment thread |
| Generic | `git diff`, `git log`, … | Local file write | — | `impact-analysis-report.md` |

---

## Related

- `docs/git-auth.md` — how git credentials are injected at runtime without touching `~/.gitconfig`
- `docs/mcp-config.md` — how to connect the GitHub MCP server
- `providers/github.md` — GitHub-specific posting logic (MCP and CLI paths)
- `providers/azure-devops.md` — Azure DevOps-specific posting logic
- `providers/generic.md` — fallback for unsupported platforms
