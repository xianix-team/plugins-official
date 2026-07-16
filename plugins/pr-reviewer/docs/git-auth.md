# Git Authentication — Runtime Credentials

The `pr-review` plugin can apply code fixes and push them directly to the PR branch. Since the agent runtime may operate against **different repositories with different access levels**, git credentials are passed at runtime via environment variables — never hardcoded, never written to disk or `~/.gitconfig`.

---

## How it works

Every run executes in a **temporary Docker container**: there is no credential helper, no `~/.gitconfig`, no shell profile, and nothing survives the run. Tokens exist only as environment variables injected when the container starts.

The plugin uses **`GIT_CONFIG_COUNT` environment variables** (Git 2.31+) to rewrite the HTTPS remote URL with the token inline — prefixed on the `git push` command itself, so the credential is scoped to that single command and never written to disk.

The `validate-prerequisites.sh` hook **validates only** — it blocks a `git push` when the required token is missing from the container environment. It cannot inject anything: hooks run as separate short-lived processes, so variables exported there never reach the agent's shell.

---

## Credentials by Platform

### GitHub

| Variable | Used by | Purpose |
|---|---|---|
| `GH_TOKEN` / `GITHUB_TOKEN` | GitHub CLI (`gh`) | Non-interactive API auth (optional if `gh auth login` was used) |
| `GITHUB_TOKEN` | Local `git push` | Authenticate HTTPS pushes to the PR branch |

These are typically the same PAT. Prefix the push command with the env-scoped config:

```bash
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="url.https://x-access-token:${GITHUB_TOKEN}@github.com/.insteadOf" \
GIT_CONFIG_VALUE_0="https://github.com/" \
git push origin HEAD
```

**Generating a GitHub PAT:**
1. Go to [github.com/settings/tokens](https://github.com/settings/tokens)
2. Click **Generate new token (classic)**
3. Select scopes: `repo` (private repos) or `public_repo` (public repos only)
4. For org repos, ensure SSO authorisation if required

### Azure DevOps

| Variable | Used by | Purpose |
|---|---|---|
| `AZURE_DEVOPS_TOKEN` | `curl` (REST API) + Local `git push` | Authenticate API calls and HTTPS pushes |

A single PAT covers both API access and git push. Derive the host from the actual remote — `insteadOf` is a **prefix match on the full URL**, so legacy remotes need `{org}.visualstudio.com` (a bare `visualstudio.com` prefix would never match) — and prefix the push command:

```bash
REMOTE_HOST=$(git remote get-url origin | sed -E 's|^[a-z+]+://||; s|^[^@/]+@||; s|[:/].*$||')

GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="url.https://x-access-token:${AZURE_DEVOPS_TOKEN}@${REMOTE_HOST}/.insteadOf" \
GIT_CONFIG_VALUE_0="https://${REMOTE_HOST}/" \
git push origin HEAD
```

**Generating an Azure DevOps PAT:**
1. Go to `https://dev.azure.com/<your-org>/_usersSettings/tokens`
2. Click **New Token**
3. Select scopes: `Code (Read & Write)`, `Pull Request Threads (Read & Write)`, `User Profile (Read)`

---

## Passing Credentials at Runtime

### Containerized runner (the normal case — e.g. the Xianix Executor)

Every run happens in a **temporary Docker container**. Configure the secret on the runner/pipeline so it is injected into the container environment at startup — there is no shell profile, `.env` file, or credential store inside the container to persist anything in. Secrets may arrive under dashed keys (`AZURE-DEVOPS-TOKEN`); the Executor re-exports them as the underscored aliases the plugin references (`AZURE_DEVOPS_TOKEN`).

### Inline (local interactive session)

**GitHub:**
```bash
GH_TOKEN=ghp_xxx GITHUB_TOKEN=ghp_xxx claude
```

**Azure DevOps:**
```bash
AZURE_DEVOPS_TOKEN=<pat> claude
```

---

## Using different credentials per repository

Because credentials are passed at invocation time, you can use a different token for each repository — no global config changes:

```bash
# Reviewing a GitHub repo
GITHUB_TOKEN=ghp_my_token claude ...

# Reviewing an Azure DevOps repo
AZURE_DEVOPS_TOKEN=my_ado_pat claude ...
```

---

## What happens if a token is missing

The `validate-prerequisites.sh` hook blocks any `git push` attempt if the required token is not set:

**GitHub:**
```
blocked: GITHUB_TOKEN is not set in the container environment. It must be injected when the container starts (see docs/platform-setup.md).
```

**Azure DevOps:**
```
blocked: AZURE_DEVOPS_TOKEN is not set in the container environment. It must be injected when the container starts (see docs/platform-setup.md).
```

`git commit` and other local operations are unaffected — only push requires the token.

---

## Secret hygiene

**Never echo token values** (`echo "$AZURE_DEVOPS_TOKEN"`, `env | grep …`, unredirected `printenv`). Presence-check only:

```bash
echo "AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}"
echo "GITHUB_TOKEN=${GITHUB_TOKEN:+yes}"
```

If only the dashed `AZURE-DEVOPS-TOKEN` is set: `export AZURE_DEVOPS_TOKEN="$(printenv AZURE-DEVOPS-TOKEN)"`.

## Verification

Verify git can push with a dry-run, using the same inline `GIT_CONFIG_*` prefix as the real push:

```bash
REMOTE_HOST=$(git remote get-url origin | sed -E 's|^[a-z+]+://||; s|^[^@/]+@||; s|[:/].*$||')
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="url.https://x-access-token:${PUSH_TOKEN}@${REMOTE_HOST}/.insteadOf" \
GIT_CONFIG_VALUE_0="https://${REMOTE_HOST}/" \
git push --dry-run origin HEAD
```

If it completes without a credential prompt, the token works.

---

## Summary

| Platform | Token for API | Token for git push |
|---|---|---|
| GitHub | `gh auth login` or `GH_TOKEN` / `GITHUB_TOKEN` | `GITHUB_TOKEN` |
| Azure DevOps | `AZURE_DEVOPS_TOKEN` | `AZURE_DEVOPS_TOKEN` (same) |
| Generic | — | `GITHUB_TOKEN` |
