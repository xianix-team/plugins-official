# Platform Setup

This guide covers how to configure the `pr-comment-resolver` plugin for each supported platform.

---

## GitHub

### Requirements

- **GitHub CLI** (`gh`) installed and authenticated
- `GIT_TOKEN` environment variable set (for pushing commits)
- `GITHUB_TOKEN` or `GH_TOKEN` (alternative to interactive `gh auth login`)

### Install GitHub CLI

```bash
# macOS
brew install gh

# Windows (winget)
winget install --id GitHub.cli
```

### Authenticate

```bash
gh auth login
```

Or set the token in your environment:

```bash
export GH_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
export GIT_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
```

### Required Token Permissions

| Permission | Access |
|---|---|
| **Contents** | Read & Write |
| **Metadata** | Read |
| **Pull requests** | Read & Write |

---

## Azure DevOps

### Requirements

- `AZURE-DEVOPS-TOKEN` environment variable set (PAT)

### Create a Personal Access Token

1. Go to **User Settings → Personal Access Tokens** in Azure DevOps
2. Click **New Token**
3. Set the following scopes:
   - **Code**: Read & Write
   - **Pull Request Threads**: Read & Write

### Set the Token

```bash
export AZURE-DEVOPS-TOKEN=your_pat_here
```

---

## Generic / Local

No credentials required for reading. For pushing commits, ensure your git remote is configured with credentials via your system credential manager or SSH keys.
