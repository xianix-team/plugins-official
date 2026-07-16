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

When using `--fix`, the agent pushes commits. `GITHUB_TOKEN` must be present in the container environment (injected at startup by the runner; for a local interactive run, pass it inline):

```bash
GITHUB_TOKEN=ghp_your_token_here claude ...
```

The push command itself carries the token via an inline `GIT_CONFIG_*` prefix — see `docs/git-auth.md`.

---

## Azure DevOps

### Prerequisites

Only `git` and `curl` are needed — the plugin calls the Azure DevOps REST API directly with a Personal Access Token (PAT). The `az` CLI is **not** used at runtime (the review procedure explicitly forbids `az login` — see the platform-exclusive CLI rule in `commands/pr-review.md`), so there is nothing to install.

### Platform identity (`PLATFORM=azuredevops`)

The Xianix Agent/Executor standard platform string is **`azuredevops`** (no hyphen). The plugin:

1. Detects the host from `git remote get-url origin` (authoritative).
2. Normalizes env hints (`azuredevops`, `azure-devops`, `azure_devops`, `ado`, `azure`) to the canonical script value **`azure`**.
3. Never defaults to GitHub when the remote is Azure, even if `PLATFORM` was unset or still held the raw executor string.

Do not call `gh` on Azure remotes. Scripts must compare against `PLATFORM=azure` after normalization — a raw `!= "azure"` check against `azuredevops` incorrectly takes the GitHub path.

### Authentication

The plugin authenticates with a Personal Access Token read from the `AZURE_DEVOPS_TOKEN` environment variable.

Every run happens in a **temporary Docker container**, so there is nothing to persist in a shell profile — the token must be injected into the container environment at startup. In the containerized runner (e.g. the Xianix Executor), configure the secret on the runner/pipeline; it may arrive under the dashed key `AZURE-DEVOPS-TOKEN`, which the Executor re-exports as the underscored alias.

For a local interactive run, pass it inline:

```bash
AZURE_DEVOPS_TOKEN=<your-pat> claude ...
```

> **Variable-name hygiene (important):** reference the token as `AZURE_DEVOPS_TOKEN` — **underscores only**. Some CI systems and orchestrators (e.g. when reading from a YAML key like `azure-devops-token`) inject it as `AZURE-DEVOPS-TOKEN` with hyphens. Bash cannot reference hyphenated names (a dashed reference parses as `$AZURE` minus `DEVOPS-TOKEN`), so a dashed `curl -u ":..."` would silently send an empty password and every Azure DevOps API call would fail with 401. The Xianix Executor automatically re-exports any dashed env var as an underscored alias, so `AZURE_DEVOPS_TOKEN` is normally already set. If it is missing while a dashed `AZURE-DEVOPS-TOKEN` exists, the plugin's `PreToolUse` hook blocks with an actionable message; re-export under the underscore name:
>
> ```bash
> export AZURE_DEVOPS_TOKEN="$(printenv AZURE-DEVOPS-TOKEN)"
> ```
>
> **Never echo secrets.** Do not run `echo "$AZURE_DEVOPS_TOKEN"`, `env | grep TOKEN`, or `printenv` without redirecting away from the transcript. Presence-check only:
>
> ```bash
> echo "AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}"
> ```

**PAT scopes needed:**
- `Code` → Read & Write (`vso.code_write` — required to cast the reviewer vote and for fix-mode `git push`; Read alone is not enough)
- `Pull Request Threads` → Read & Write
- `User Profile` → Read (required to resolve the reviewer ID for casting the vote)

### Credentials for `git push` (fix mode)

The plugin reuses `AZURE_DEVOPS_TOKEN` for `git push` — no separate `GITHUB_TOKEN` is needed for Azure DevOps remotes. The push command carries the token via an inline `GIT_CONFIG_*` prefix (see `docs/git-auth.md`).

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
| `PLATFORM` | unset (detect from `origin`) | Optional hint from the runner. Xianix Executor sends **`azuredevops`** for Azure DevOps. The setup script normalizes aliases to canonical `github` / `azure` / `generic` and **always prefers `git remote get-url origin`** when they disagree. Never leave the raw `azuredevops` string for later equality checks. |
| `PR_REVIEWER_BLOCK_ON_CRITICAL` | `false` | Advisory by default: CRITICAL findings post a non-blocking review (GitHub `--comment`, Azure DevOps vote `-5`). Set to `true` to post a blocking review (GitHub `--request-changes`, Azure DevOps vote `-10`). See above. |
| `PR_REVIEWER_MODEL` | unset | **Override:** pins *every* reviewer sub-agent to one model (e.g. `haiku`), ignoring the tiers below. Env values like `claude-haiku-4-5` are mapped to Agent-tool slugs (`haiku`, `sonnet`, `opus`, `fable`) before invocation. |
| `PR_REVIEWER_QUALITY_MODEL` | `haiku` | Model for the **quality-tier** reviewers (`code-reviewer`, `test-reviewer`) on the escalated specialist path — pattern/coverage tasks a small model handles well. Ignored if `PR_REVIEWER_MODEL` is set. Passed to `Agent` as `haiku` (not `claude-haiku-4-5`). |
| `PR_REVIEWER_RISK_MODEL` | inherit (omit `model`) | Model for the **risk-tier** reviewers (`security-reviewer`, `performance-reviewer`) on the escalated specialist path — vulnerability/performance reasoning where frontier accuracy pays off. Ignored if `PR_REVIEWER_MODEL` is set. When unset, omit the `model` field so reviewers inherit the lead's model. |

> **How the review picks a model.** Ordinary PRs use the cheap default path (two `haiku` finders) regardless of these variables. Only when the diff touches a **high-risk surface** (auth, crypto, payments, migrations, public APIs) does the plugin escalate to the four specialist reviewers, which then split across the quality/risk tiers above. The `Agent`/`Task` tool accepts only `sonnet`, `opus`, `haiku`, or `fable` — never pass full model names like `claude-haiku-4-5`. The tier is chosen by *risk surface*, not diff size. See steps 5–6 of `commands/pr-review.md`.
| `PR_REVIEWER_RECONCILE` | `true` | Re-review and existing-thread awareness. When the plugin has already reviewed a PR (detected via its own comment markers), a follow-up run reconciles prior findings — resolving the ones the author fixed, leaving unresolved ones open without re-posting duplicates, and reviewing only the commits pushed since the last review. Independently of re-review mode, when `true` the plugin also loads **all open inline review threads** (humans, other bots, and this plugin), uses them to avoid duplicate findings, validates whether non-plugin threads look addressed at `HEAD`, and **replies** on addressed ones without resolving them (resolution stays with the original author). Set to `false` to force a full, stateless review that ignores prior findings **and** skips external-thread awareness. GitHub and Azure DevOps only (the generic provider just regenerates the report file). See *Comment markers and finding identity* and *Existing inline review awareness* in `commands/pr-review.md`. |

---

## Related

- `docs/git-auth.md` — details on how git credentials are injected at runtime without touching `~/.gitconfig`
- `providers/github.md` — GitHub-specific posting logic
- `providers/azure-devops.md` — Azure DevOps-specific posting logic
- `providers/generic.md` — fallback for unsupported platforms
