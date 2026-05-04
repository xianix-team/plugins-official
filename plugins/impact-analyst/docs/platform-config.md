# Platform Configuration

Setup instructions for each supported platform.

---

## GitHub

### Authentication

The `gh` CLI must be installed and authenticated:

```bash
gh auth login
# or
export GITHUB_TOKEN=ghp_xxxxx
```

Verify with:

```bash
gh auth status
```

### Required Token Permissions

| Permission | Access | Purpose |
|---|---|---|
| **Contents** | Read | Access repository contents, commits, and documentation files |
| **Metadata** | Read | Search repositories and access repository metadata |
| **Issues** | Read | Fetch issue body, labels, and comments |
| **Pull requests** | Read & Write | Fetch PR diffs, navigate issue ↔ PR links, and post the report comment |

### Report Delivery

GitHub does not support HTML file attachments on issues or PRs. The plugin:
1. Posts a **markdown summary comment** on the issue or PR
2. Writes the full `impact-analysis-{YYYY-MM-DD}-{id}.html` locally

---

## Azure DevOps

### Authentication

Set the Personal Access Token as an environment variable:

```bash
export AZURE_DEVOPS_TOKEN=xxxxxxxx
```

### Required Token Permissions

| Permission | Access | Purpose |
|---|---|---|
| **Work Items** | Read & Write | Fetch work item fields, repro steps, acceptance criteria, comments; attach report and post notification |
| **Code** | Read | Access PR diffs, file history, commit details, and changesets |
| **Pull Requests** | Read | Fetch PR metadata and navigate work item ↔ PR links |

### Optional Environment Variables

These override values parsed from the git remote URL:

| Variable | Purpose |
|---|---|
| `AZURE_ORG` | Azure DevOps organization name |
| `AZURE_PROJECT` | Project name |
| `AZURE_REPO` | Repository name |

### Report Delivery

On Azure DevOps, the plugin:
1. **Attaches** the HTML report as a file to the work item
2. Posts a **notification comment** on the work item
3. If triggered from a PR, also posts a notification thread on the PR

---

## Generic / Other Platforms

For platforms without native API integration (Jira, GitLab, Bitbucket, on-premises, etc.):

- The report is written locally as `impact-analysis-{YYYY-MM-DD}-{id}.html`
- No API calls are made to the platform
- Work item content must be provided by the user (pasted text, local file, or manual input)
- Code changes are gathered from git against the base branch

---

## Platform Detection

The plugin auto-detects the platform from the git remote URL:

| Remote URL pattern | Platform |
|---|---|
| Contains `github.com` | GitHub |
| Contains `dev.azure.com` or `visualstudio.com` | Azure DevOps |
| Anything else | Generic |
