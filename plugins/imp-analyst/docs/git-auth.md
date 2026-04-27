# Git Authentication — Runtime Credentials

The `imp-analyst` plugin reads git history and diffs using standard git commands. It does **not** push commits or modify the repository — the analysis phase is entirely read-only. Consequently, git push credentials are **not required** for normal use.

However, if your repository is hosted on a private remote and the working clone uses HTTPS rather than SSH, git must be able to authenticate for read operations (e.g. `git fetch` to ensure the base branch is up to date). Credentials are passed at runtime via environment variables — never hardcoded, never written to disk or `~/.gitconfig`.

---

## How it works

The plugin can use **`GIT_CONFIG_COUNT` environment variables** (Git 2.31+) to inject a token transparently into git HTTPS operations for the session. This rewrites any HTTPS remote URL to use the token inline, scoped only to the current shell process. No files are written to disk.

This is only needed when:
- The repo is private and cloned over HTTPS, and
- The git credential helper does not already have valid credentials cached.

For SSH remotes or repos where credentials are already cached, no additional setup is required.

---

## Credentials by Platform

### GitHub

| Variable | Used by | Purpose |
|---|---|---|
| `GH_TOKEN` / `GITHUB_TOKEN` | GitHub CLI (`gh`) | Non-interactive API auth for the `gh` fallback path |
| `GITHUB_TOKEN` | `git fetch` (HTTPS) | Authenticate read access to private HTTPS remotes |

The token can be injected as:

```bash
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="url.https://x-access-token:<GITHUB_TOKEN>@github.com/.insteadOf"
GIT_CONFIG_VALUE_0="https://github.com/"
```

**Generating a GitHub PAT:**
1. Go to [github.com/settings/tokens](https://github.com/settings/tokens)
2. Click **Generate new token (classic)**
3. Select scopes: `repo` (private repos) or `public_repo` (public repos only)
4. For org repos, ensure SSO authorisation if required

### Azure DevOps

| Variable | Used by | Purpose |
|---|---|---|
| `AZURE_TOKEN` | REST API (`curl`) + `git fetch` (HTTPS) | Authenticate API calls and read access to private HTTPS remotes |

A single PAT covers both REST API access and git HTTPS reads. The token can be injected for both `dev.azure.com` and `*.visualstudio.com` remote URL formats:

```bash
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0="url.https://x-access-token:<AZURE_TOKEN>@dev.azure.com/.insteadOf"
GIT_CONFIG_VALUE_0="https://dev.azure.com/"
GIT_CONFIG_KEY_1="url.https://x-access-token:<AZURE_TOKEN>@visualstudio.com/.insteadOf"
GIT_CONFIG_VALUE_1="https://visualstudio.com/"
```

**Generating an Azure DevOps PAT:**
1. Go to `https://dev.azure.com/<your-org>/_usersSettings/tokens`
2. Click **New Token**
3. Select scopes: `Code (Read)`, `Pull Request Threads (Read & Write)`

---

## Passing Credentials at Runtime

### Inline (single session)

**GitHub:**
```bash
GH_TOKEN=ghp_xxx GITHUB_TOKEN=ghp_xxx claude
```

**Azure DevOps:**
```bash
AZURE_TOKEN=<pat> claude
```

### Via shell export (persistent in current shell)

```bash
# GitHub
export GH_TOKEN=ghp_xxx
export GITHUB_TOKEN=ghp_xxx

# Azure DevOps
export AZURE_TOKEN=<pat>
```

### Via `.env` file (per-project, never committed)

Create a `.env` file in your project root (add it to `.gitignore`):

```bash
# GitHub
GH_TOKEN=ghp_xxx
GITHUB_TOKEN=ghp_xxx

# Azure DevOps
AZURE_TOKEN=<pat>
```

Then source it before launching:

```bash
source .env && claude
```

---

## Using different credentials per repository

Because credentials are passed at invocation time, you can use a different token for each repository — no global config changes needed:

```bash
# Analysing a GitHub repo
GITHUB_TOKEN=ghp_my_token claude ...

# Analysing an Azure DevOps repo
AZURE_TOKEN=my_ado_pat claude ...
```

---

## Verification

After setting the token, verify git can read from the remote with a dry-run fetch:

```bash
git fetch --dry-run origin
```

If it completes without a credential prompt, the token is injected correctly.

---

## Summary

| Platform | Token for API / MCP | Token for git read (HTTPS) |
|---|---|---|
| GitHub | MCP connection (no token) or `GH_TOKEN` / `GITHUB_TOKEN` for `gh` fallback | `GITHUB_TOKEN` |
| Azure DevOps | `AZURE_TOKEN` | `AZURE_TOKEN` (same PAT) |
| Generic | — | depends on host |
