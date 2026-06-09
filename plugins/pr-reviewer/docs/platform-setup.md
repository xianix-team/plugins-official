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
GITHUB_TOKEN=ghp_your_token_here claude ...
```

Or export in your shell:

```bash
export GITHUB_TOKEN=ghp_your_token_here
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

> **Variable-name hygiene (important):** reference the token as `AZURE_DEVOPS_TOKEN` — **underscores only**. Some CI systems and orchestrators (e.g. when reading from a YAML key like `azure-devops-token`) inject it as `AZURE-DEVOPS-TOKEN` with hyphens. Bash cannot reference hyphenated names (a dashed reference parses as `$AZURE` minus `DEVOPS-TOKEN`), so a dashed `curl -u ":..."` would silently send an empty password and every Azure DevOps API call would fail with 401. The Xianix Executor automatically re-exports any dashed env var as an underscored alias, so `AZURE_DEVOPS_TOKEN` is normally already set. If it is missing while a dashed `AZURE-DEVOPS-TOKEN` exists, the plugin's `PreToolUse` hook blocks with an actionable message; re-export under the underscore name:
>
> ```bash
> export AZURE_DEVOPS_TOKEN="$(env | sed -n 's/^AZURE-DEVOPS-TOKEN=//p')"
> ```

**PAT scopes needed:**
- `Code` → Read & Write
- `Pull Request Threads` → Read & Write
- `User Profile` → Read (required to resolve the reviewer ID for casting the vote)

### Credentials for `git push` (fix mode)

The plugin reuses `AZURE_DEVOPS_TOKEN` for `git push` credential injection automatically — no separate `GITHUB_TOKEN` is needed for Azure DevOps remotes.

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

## Optional: Blocking reviews on CRITICAL findings

By **default** the plugin runs in **advisory / shadow mode**: even when it finds CRITICAL issues, the review and report are posted but the platform vote does **not** block merging:

- **GitHub** → `gh pr review --comment` (visible, never shows `Merging is blocked`)
- **Azure DevOps** → vote `-5` Waiting for author (visible, does not prevent PR completion)

This is the safest default for rolling the bot out — a human reviewer stays the official gate and an over-eager bot review never forces manual dismissal.

Once you trust the plugin to gate merges, set `PR_REVIEWER_BLOCK_ON_CRITICAL=true` to make CRITICAL findings post a **blocking** review:

```bash
export PR_REVIEWER_BLOCK_ON_CRITICAL=true
```

| Value | Effect on `REQUEST CHANGES` verdict |
|---|---|
| unset / `false` / `0` / `no` *(default)* | GitHub: `--comment` · Azure DevOps: vote `-5` Waiting for author (non-blocking) |
| `true` / `1` / `yes` | GitHub: `--request-changes` · Azure DevOps: vote `-10` Rejected (blocking) |

The verdict label, Critical Issues section, and inline comments are identical in both modes — only the platform action changes. The variable has no effect on the generic provider.

---

## Summary

| Platform | Analysis | Review posting | Token (posting / API) | Fix mode push |
|---|---|---|---|---|
| GitHub | `git diff`, `git log`, … | `gh pr review`, `gh pr comment`, `gh api` | `gh auth` / `GH_TOKEN` | `GITHUB_TOKEN` |
| Azure DevOps | `git diff`, `git log`, … | REST (`curl`) per `providers/azure-devops.md` | `AZURE_DEVOPS_TOKEN` | `AZURE_DEVOPS_TOKEN` |
| Generic | `git diff`, `git log`, … | Write to `pr-review-report.md` | — | `GITHUB_TOKEN` |

### Optional environment variables (all platforms)

| Variable | Default | Purpose |
|---|---|---|
| `PR_REVIEWER_BLOCK_ON_CRITICAL` | `false` | Advisory by default: CRITICAL findings post a non-blocking review (GitHub `--comment`, Azure DevOps vote `-5`). Set to `true` to post a blocking review (GitHub `--request-changes`, Azure DevOps vote `-10`). See above. |
| `PR_REVIEWER_MODEL` | unset | Pins the model used by the four reviewer sub-agents (e.g. `claude-haiku-4-5`). When unset, the reviewers are tiered by diff size: small PRs (≤ 300 diff lines) use a fast low-cost model; larger or high-risk PRs use the lead's inherited model. See step 6 of `commands/pr-review.md`. |

---

## Related

- `docs/git-auth.md` — details on how git credentials are injected at runtime without touching `~/.gitconfig`
- `providers/github.md` — GitHub-specific posting logic
- `providers/azure-devops.md` — Azure DevOps-specific posting logic
- `providers/generic.md` — fallback for unsupported platforms
