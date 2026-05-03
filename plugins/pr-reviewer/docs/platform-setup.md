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

For CI or scripts, set **`GH_TOKEN`** or **`GITHUB-TOKEN`** instead of interactive login (same scopes as below).

**Token scopes:** `repo` (private repos) or `public_repo` (public repos only), `read:org` (optional).

The plugin does **not** use the GitHub MCP server. See `providers/github.md` for `gh` usage.

### Credentials for `git push` (fix mode)

When using `--fix`, the agent pushes commits. Pass the token at runtime:

```bash
GITHUB-TOKEN=ghp_your_token_here claude ...
```

Or export in your shell:

```bash
export GITHUB-TOKEN=ghp_your_token_here
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
export AZURE-DEVOPS-TOKEN=<your-pat>
echo $AZURE-DEVOPS-TOKEN | az devops login --org https://dev.azure.com/<your-org>
```

Add to `~/.zshrc` or `~/.bashrc` to persist:

```bash
export AZURE-DEVOPS-TOKEN=<your-pat>
```

> **Variable-name hygiene (important):** the variable name must be `AZURE-DEVOPS-TOKEN` — **underscores only**. Some CI systems and orchestrators (e.g. when reading from a YAML key like `azure-devops-token`) export it as `AZURE-DEVOPS-TOKEN` with hyphens. Bash cannot reference hyphenated names (`$AZURE-DEVOPS-TOKEN` parses as `$AZURE` minus `DEVOPS-TOKEN`), so `curl -u ":${AZURE-DEVOPS-TOKEN}"` will silently send an empty password and every Azure DevOps API call will fail with 401. The plugin's `PreToolUse` hook detects this case and blocks with an actionable message; if you hit it, re-export under the underscore name:
>
> ```bash
> export AZURE-DEVOPS-TOKEN="$(env | sed -n 's/^AZURE-DEVOPS-TOKEN=//p')"
> ```

**PAT scopes needed:**
- `Code` → Read & Write
- `Pull Request Threads` → Read & Write
- `User Profile` → Read (required to resolve the reviewer ID for casting the vote)

### Credentials for `git push` (fix mode)

The plugin reuses `AZURE-DEVOPS-TOKEN` for `git push` credential injection automatically — no separate `GITHUB-TOKEN` is needed for Azure DevOps remotes.

### Generating a PAT

1. Go to `https://dev.azure.com/<your-org>/_usersSettings/tokens`
2. Click **New Token**
3. Set the scopes listed above
4. Copy the token and export it as `AZURE-DEVOPS-TOKEN`

---

## Bitbucket / Other Platforms

For platforms without native CLI support, the plugin writes the review report to `pr-review-report.md` in the repository root. You can then post it manually.

No additional setup is required beyond having a working git installation.

---

## Optional: Non-blocking reviews on CRITICAL findings

By default, when the plugin finds CRITICAL issues it posts a **blocking** review:

- **GitHub** → `gh pr review --request-changes` (under branch protection, this shows `Merging is blocked` until the review is dismissed or re-reviewed)
- **Azure DevOps** → vote `-10` Rejected (under repo branch policy, this prevents PR completion)

In some workflows you want the review and the report to be visible but not actually block merging — e.g.:

- The plugin is rolling out in **shadow / advisory mode** before being trusted to gate merges.
- A human reviewer is the official gate, and the bot's role is to surface findings.
- Branch protection is strict and an over-eager bot review would frequently require manual dismissal.

Set the `PR_REVIEWER_BLOCK_ON_CRITICAL` environment variable to disable blocking:

```bash
export PR_REVIEWER_BLOCK_ON_CRITICAL=false
```

| Value | Effect on `REQUEST CHANGES` verdict |
|---|---|
| unset / `true` *(default)* | GitHub: `--request-changes` · Azure DevOps: vote `-10` (blocking) |
| `false` / `0` / `no` | GitHub: `--comment` · Azure DevOps: vote `-5` Waiting for author (non-blocking) |

The verdict label, Critical Issues section, and inline comments are identical in both modes — only the platform action changes. The variable has no effect on the generic provider.

---

## Summary

| Platform | Analysis | Review posting | Token (posting / API) | Fix mode push |
|---|---|---|---|---|
| GitHub | `git diff`, `git log`, … | `gh pr review`, `gh pr comment`, `gh api` | `gh auth` / `GH_TOKEN` | `GITHUB-TOKEN` |
| Azure DevOps | `git diff`, `git log`, … | REST (`curl`) per `providers/azure-devops.md` | `AZURE-DEVOPS-TOKEN` / `AZURE-DEVOPS-TOKEN` | `AZURE-DEVOPS-TOKEN` |
| Generic | `git diff`, `git log`, … | Write to `pr-review-report.md` | — | `GITHUB-TOKEN` |

### Optional environment variables (all platforms)

| Variable | Default | Purpose |
|---|---|---|
| `PR_REVIEWER_BLOCK_ON_CRITICAL` | `true` | When `false`, posts CRITICAL findings as a non-blocking review (GitHub `--comment`, Azure DevOps vote `-5`). See above. |

---

## Related

- `docs/git-auth.md` — details on how git credentials are injected at runtime without touching `~/.gitconfig`
- `providers/github.md` — GitHub-specific posting logic
- `providers/azure-devops.md` — Azure DevOps-specific posting logic
- `providers/generic.md` — fallback for unsupported platforms
