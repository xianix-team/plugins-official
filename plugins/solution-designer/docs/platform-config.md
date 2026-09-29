# Platform Configuration

The platform is auto-detected from `git remote get-url origin`, or set with `PLATFORM` in CI.

---

## GitHub

Install and authenticate `gh` (`brew install gh` / `winget install GitHub.cli` / `apt install gh`, then `gh auth login`), or provide `GITHUB-TOKEN` / `GH_TOKEN`.

| Permission (fine-grained) | Access | Why |
|---|---|---|
| Contents | Read & Write | Read code; push `design/*` branches |
| Issues | Read & Write | Read the item and thread; comment; labels |
| Pull requests | Read & Write | Open / update the design PR; detect merge |
| Metadata | Read | Default branch |

Classic token: `repo` scope.

**Labels** (created automatically if the token can):

```bash
gh label create ai-dlc/issue/design   --color 5319E7 --description "Design this item with solution-designer"
gh label create design-needs-decision --color FBCA04 --description "Design waiting on a decision"
gh label create design-proposed       --color 1D76DB --description "Design PR ready for review"
gh label create design-approved       --color 0E8A16 --description "Design accepted"
```

---

## Azure DevOps

`AZURE-DEVOPS-TOKEN` PAT with:

| Scope | Why |
|---|---|
| Work Items — Read & Write | Read the item, thread, and revision history; comment; tags |
| Code — Read & Write | Push `design/*` branches; open the PR linked to the work item |

Tags are created on first use.

---

## Git

`user.name` and `user.email` must be set — the design doc is committed. The pre-tool hook refuses:

- pushes from any branch not named `design/*`
- commits that stage files outside `docs/`

---

## CI Variables

| Variable | Purpose |
|---|---|
| `PLATFORM` | `github` \| `azuredevops` \| `generic` |
| `REPO_URL` | Repository URL |
| `ISSUE_NUMBER` | Issue / work item id |
| `GITHUB-TOKEN` / `AZURE-DEVOPS-TOKEN` | Credentials |
