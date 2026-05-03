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
| `gh issue view` | Fetch issue details (title, body, labels, comments) |
| `gh issue list` | Find related issues by milestone, label, or keyword |
| `gh issue comment` | Post each elaboration lens as a comment |
| `gh issue edit --add-label` | Apply readiness signal label |

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
| `GET _apis/wit/workitems/{id}` | Fetch work item details (title, description, tags, comments) |
| `POST _apis/wit/wiql` | Query related work items in the same iteration |
| `POST _apis/wit/workitems/{id}/comments?format=markdown` | Post each elaboration lens as a comment (Markdown rendered in the UI) |
| `PATCH _apis/wit/workitems/{id}` | Apply readiness signal tag |

See `providers/azure-devops.md` for full API details.

### Verification

```bash
curl -s -u ":${AZURE-DEVOPS-TOKEN}" \
  "https://dev.azure.com/<your-org>/<your-project>/_apis/wit/workitems?ids=1&api-version=7.1"
```

---

## Plain Text / Unknown Platform

If the git remote does not match GitHub or Azure DevOps — or if there is no repo at all — the plugin runs in **generic** mode. The user can paste the requirement text or point at a local file, and the elaboration is written to `requirement-elaboration-report.md` in the working directory.

No credentials are required.

---

## CI Environment Variables

For CI pipelines or webhook-driven runs, these variables drive the plugin without interactive input:

| Variable | Purpose |
|---|---|
| `PLATFORM` | `github` \| `azuredevops` \| `generic` — overrides remote-URL detection |
| `REPO_URL` | Full HTTPS URL of the target repository |
| `ISSUE_NUMBER` | Issue / work item ID to elaborate |
| `GITHUB-TOKEN` | Required when `PLATFORM=github` |
| `AZURE-DEVOPS-TOKEN` | Required when `PLATFORM=azuredevops` |

---

## Summary

| Platform | How items are fetched | How elaboration is delivered | Credentials |
|---|---|---|---|
| GitHub | `gh` CLI | `gh issue comment` (one comment per lens) | `GITHUB-TOKEN` or `gh auth login` |
| Azure DevOps | REST API (`curl`) | REST API `wit/comments?format=markdown` | `AZURE-DEVOPS-TOKEN` env var |
| Generic / plain text | User-provided or local file | Written to `requirement-elaboration-report.md` | — |
