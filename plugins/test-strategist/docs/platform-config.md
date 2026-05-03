# Platform Configuration

Setup instructions for each supported platform.

The deliverable on every platform is a **logical series of Markdown comments** posted on the PR / issue / work item discussion. The first comment carries a Table of Contents that deep-links to every other comment in the series. **No HTML file is produced and nothing is written to the repository working tree.**

---

## GitHub

### Authentication

The `gh` CLI must be installed and authenticated:

```bash
gh auth login
# or
export GITHUB-TOKEN=ghp_xxxxx
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
| **Issues** | Read & Write | Fetch issue body, labels, and comments; post and edit the comment series on issues |
| **Pull requests** | Read & Write | Fetch PR diffs, navigate issue ↔ PR links; post and edit the comment series on PRs |

### Report Delivery

The plugin posts the test strategy as a **series of Markdown comments** (typically 5–8) on the target PR or issue:

1. Comment 1 (`[1/N] Overview & Focus Areas`) is posted first with a placeholder Table of Contents.
2. Comments 2..N are posted in order; each captured `html_url` is recorded.
3. Comment 1 is then PATCHed to back-fill the Table of Contents with the captured `#issuecomment-NNN` URLs so every other comment is reachable in one click.
4. The `test-strategy-generated` label is applied to the PR / issue (best-effort).
5. If a linked issue / PR was discovered, a single pointer comment is posted on it linking back to the comment series.

---

## Azure DevOps

### Authentication

Set the Personal Access Token as an environment variable:

```bash
export AZURE-DEVOPS-TOKEN=xxxxxxxx
```

### Required Token Permissions

| Permission | Access | Purpose |
|---|---|---|
| **Work Items** | Read & Write | Fetch work item fields, repro steps, acceptance criteria, comments; post and edit the comment series on the work item discussion |
| **Code** | Read | Access PR diffs, file history, commit details, and changesets |
| **Pull Requests** | Read & Write | Fetch PR metadata and navigate work item ↔ PR links; post the comment series on PR threads when there is no linked work item |

### Optional Environment Variables

These override values parsed from the git remote URL:

| Variable | Purpose |
|---|---|
| `AZURE_ORG` | Azure DevOps organization name |
| `AZURE_PROJECT` | Project name |
| `AZURE_REPO` | Repository name |

### Report Delivery

The plugin posts the test strategy as a **series of Markdown comments**:

| Entry point | Linked context | Posted on |
|---|---|---|
| `wi <id>` | (work item only — possibly with linked PRs) | The work item discussion |
| `pr <id>` | Linked work item discovered | The work item discussion of the linked work item |
| `pr <id>` | No linked work item | The PR thread |

Additional behaviour:

1. After the series is complete, Comment 1's Table of Contents is back-filled with the captured comment IDs.
2. When the series is posted on a work item discussion, a **single pointer thread** is posted on each linked PR, linking back to the work item discussion.
3. The `test-strategy-generated` tag is added to the work item (best-effort).

---

## Generic / Other Platforms

For platforms without native API integration (Jira, GitLab, Bitbucket, on-premises, etc.):

- The comment files are kept in a temp directory: `${TMPDIR:-/tmp}/test-strategy-${ENTRY_TYPE}-${ENTRY_ID}/`
- A combined `impact-analysis-report.md` is written to the same directory for one-shot offline review
- **Nothing is written to the repository working tree** — `git status` remains clean after the run
- No API calls are made to the platform
- Work item content must be provided by the user (pasted text, local file, or manual input)
- Code changes are gathered from git against the base branch

CI environments that need to surface the report can pick up the per-comment files (or the combined `impact-analysis-report.md`) from the temp directory and upload them as build artefacts.

---

## Platform Detection

The plugin auto-detects the platform from the git remote URL:

| Remote URL pattern | Platform |
|---|---|
| Contains `github.com` | GitHub |
| Contains `dev.azure.com` or `visualstudio.com` | Azure DevOps |
| Anything else | Generic |

---

## Common Prerequisite

`jq` must be available on the `PATH` for all providers — it is used to munge the per-comment `index.json` and the API responses captured during posting.

```bash
jq --version
```
