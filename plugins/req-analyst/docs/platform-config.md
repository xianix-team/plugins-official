# Platform Configuration

The `req-analyst` plugin supports **GitHub**, **Azure DevOps**, and **plain text** as backlog sources. The platform is auto-detected from `git remote get-url origin`, or set explicitly via the `PLATFORM` environment variable in CI.

---

## GitHub

### Prerequisites

The `gh` CLI must be installed and authenticated.

**Install:**

```bash
# macOS
brew install gh

# Windows
winget install --id GitHub.cli

# Linux (Debian/Ubuntu)
sudo apt install gh
```

**Authenticate:**

```bash
gh auth login
```

Or set the token directly:

```bash
export GITHUB-TOKEN=ghp_your_actual_token_here
```

### Generating a GitHub Token

1. Go to [github.com/settings/tokens](https://github.com/settings/tokens)
2. Click **Generate new token (classic)**
3. Select `repo` scope (required for issues)
4. Copy the token and export as `GITHUB-TOKEN` or use `gh auth login`

### Verification

```bash
gh auth status
```

You should see your account listed with the `repo` scope.

### What the plugin uses

| Command | Purpose |
|---|---|
| `gh issue view --json …,comments` | Fetch the issue and the full comment thread |
| `gh api …/issues/{n}/comments` | Comment ids (for reactions) |
| `gh api -X POST …/comments/{id}/reactions` | Acknowledge a human reply with `eyes` |
| `gh issue list` | Related issues (analysis context) |
| `gh issue comment --body-file` | Post the one round comment per turn |
| `gh issue edit --body-file` | Rewrite the description with the refined requirement |
| `gh issue edit --add-label / --remove-label` | Swap the readiness label |
| `gh issue create` | Child issues — only on a confirmed split |

The token therefore needs `repo` scope (write), not just read.

---

## Azure DevOps

### Authentication

Azure DevOps uses a Personal Access Token (PAT) passed via the `AZURE-DEVOPS-TOKEN` environment variable. The plugin calls the REST API directly via `curl`.

```bash
export AZURE-DEVOPS-TOKEN=<your-pat>
```

### Generating an Azure DevOps PAT

1. Go to `https://dev.azure.com/<your-org>/_usersSettings/tokens`
2. Click **New Token**
3. Select scopes: `Work Items` → **Read & Write**
4. Copy the token and export as `AZURE-DEVOPS-TOKEN`

### What the plugin uses

| API | Purpose |
|---|---|
| `GET _apis/wit/workitems/{id}?$expand=all` | Work item fields, tags, relations |
| `GET _apis/wit/workItems/{id}/comments` | The full discussion thread (comments are not in the work item payload) |
| `PUT …/comments/{cid}/reactions/like` | Acknowledge a human reply |
| `POST _apis/wit/wiql` | Related work items (analysis context) |
| `POST …/workItems/{id}/comments?format=markdown` | Post the one round comment per turn |
| `PATCH _apis/wit/workitems/{id}` | Rewrite `System.Description` (HTML), `Microsoft.VSTS.Common.AcceptanceCriteria`, and `System.Tags` |
| `POST _apis/wit/workitems/${type}` | Child work items — only on a confirmed split |

See `providers/azure-devops.md` for full API details.

### Verification

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "https://dev.azure.com/<your-org>/<your-project>/_apis/wit/workitems?ids=1&api-version=7.1"
```

---

## Plain Text / Unknown Platform

If the git remote does not match GitHub or Azure DevOps — or if there is no repo at all — the plugin runs in **generic** mode. The conversation lives in `requirement-grooming.md` in the working directory: the plugin appends a round, you write your answers under it, and re-run the command. See `providers/generic.md`.

No credentials are required.

---

## CI Environment Variables

For CI pipelines or webhook-driven runs, these variables drive the plugin without interactive input:

| Variable | Purpose |
|---|---|
| `PLATFORM` | `github` \| `azuredevops` \| `generic` — overrides remote-URL detection |
| `REPO_URL` | Full HTTPS URL of the target repository |
| `ISSUE_NUMBER` | Issue / work item ID to groom |
| `GITHUB-TOKEN` | Required when `PLATFORM=github` |
| `AZURE-DEVOPS-TOKEN` | Required when `PLATFORM=azuredevops` |

---

## Summary

| Platform | Thread | Description edit | Credentials |
|---|---|---|---|
| GitHub | `gh issue view` / `gh issue comment` | `gh issue edit --body-file` | `GITHUB-TOKEN` (`repo` scope) or `gh auth login` |
| Azure DevOps | `wit/workItems/{id}/comments` | `PATCH wit/workitems/{id}` | `AZURE-DEVOPS-TOKEN` (Work Items Read & Write) |
| Generic / plain text | `requirement-grooming.md` | Same file | — |
