# PR Reviewer Claude Code Plugin

The **PR Reviewer** plugin runs a **cost-tiered** automated review and posts a unified, structured report directly on your pull request. Most PRs get a cheap two-pass scan; PRs that touch a high-risk surface (auth, payments, crypto, DB migrations, public APIs) automatically escalate to four specialized reviewers.

| Reviewer | What it looks for | Runs on |
|---|---|---|
| **Code Quality** | Architecture, patterns, readability, maintainability | Escalated path (always) |
| **Security** | Vulnerabilities, exposed secrets, insecure patterns (OWASP) | Escalated path (when in scope) |
| **Test Coverage** | Missing tests, quality gaps, untested code paths | Escalated path (when in scope) |
| **Performance** | Bottlenecks, algorithmic issues, resource waste | Escalated path (when in scope) |

On the default (non-escalated) path, two generic finder passes cover correctness/regressions and security/edge-cases instead — see [Review Tiers](#review-tiers) below.

Works with **GitHub**, **Azure DevOps**, and any generic git repository.
---

## How It Works

```mermaid
flowchart TD
    A[Detect platform] --> B[Fetch PR diff & context]
    B --> C[Detect prior review: initial or re-review]
    C --> D{High-risk surface?}
    D -->|No| E1[2 parallel Haiku finders]
    D -->|Yes| E2[Gated specialist reviewers]
    E1 --> F[Compile & reconcile findings]
    E2 --> F
    F --> G{Platform?}
    G -->|GitHub / Azure DevOps| H[Post PR comment + inline findings]
    G -->|Other| I[Write pr-review-report.md]
```

1. **Detect platform** — reads `git remote` to identify GitHub, Azure DevOps, or generic.
2. **Fetch PR context & detect prior review** — gathers the diff, commit log, and changed file list against the base branch, and checks (via its own comment markers) whether this plugin already reviewed the PR.
3. **Choose a tier** — the diff is checked against a high-risk-surface heuristic to decide between the cheap default path and the escalated specialist path (see [Review Tiers](#review-tiers)).
4. **Run the review** — the selected reviewers run in parallel, then findings are verified, deduplicated, and reconciled against any prior review.
5. **Compile & post** — findings are merged into a single report with a computed verdict and posted as a PR comment with inline per-finding comments (or saved to `pr-review-report.md` for unsupported platforms).

With the `--fix` flag the plugin will also apply fixes (CRITICAL/WARNING only), commit, and push.

---

## Review Tiers

| Tier | When | What runs | Cost |
|---|---|---|---|
| **Default** | Ordinary PRs (the common case) | Two parallel Haiku finder passes — correctness/regressions and security/edge-cases — self-verified and capped at 8 findings | Low |
| **Escalated** | Diff touches a high-risk surface: auth/authz, payments/billing, crypto, DB migrations/schema, or public APIs | `code-reviewer` and `test-reviewer` (cheap quality tier) plus `security-reviewer` and `performance-reviewer` (frontier risk tier), gated individually by whether the diff is relevant to each | Higher, but only where it pays off |

The tier is chosen by **risk surface**, not diff size. Model selection on the escalated path can be tuned or pinned — see [Environment Variables](#environment-variables).

---

## Re-review Support

If the plugin has already reviewed a PR, a follow-up run (e.g. after new commits are pushed) automatically switches to **re-review mode**:

- Prior findings are reconciled — ones the author fixed are marked resolved, unresolved ones stay open without duplicate comments.
- The review focuses on the commits pushed since the last review.
- A re-review delta (fixed / carried-over / new counts) is posted instead of a full new wall of comments.

Set `PR_REVIEWER_RECONCILE=false` to force a stateless full review that ignores prior findings. This is GitHub/Azure DevOps only — the generic provider just regenerates the report file each run.

---

## Inputs

| Input | Source | Required | Description |
|---|---|---|---|
| Repository URL | Agent rule | Yes | The repository to review — provided by the Xianix Agent rule, not typed in the prompt |
| PR number | Prompt | No | Target a specific pull request (e.g. `123`) |
| Branch name | Prompt | No | Compare a branch against the default base |
| `--fix` flag | Prompt | No | Auto-fix CRITICAL/WARNING issues, commit, and push |
| `--push-update` flag | Prompt | No | Force re-review mode scoped to only the commits pushed since the last review (used by the agent's push-update rule blocks) |

The platform (GitHub, Azure DevOps, etc.) is **auto-detected** from `git remote` — you don't need to specify it.

---

## Sample Prompts

**Review the current branch:**

```text
/pr-review
```

**Review a specific PR:**

```text
/pr-review 42
```

**Review and auto-fix:**

```text
/pr-review 42 --fix
```

---

## Focused Single-Dimension Reviews

Besides the comprehensive `/pr-review`, the plugin ships standalone commands for a single dimension against the current branch (not posted to the PR — printed inline). These do **not** auto-trigger from the model's own judgment (`disable-model-invocation: true`) — they must be invoked explicitly.

| Command | Reviewer used |
|---|---|
| `/review-code [branch-name]` | `code-reviewer` — quality, readability, naming, duplication |
| `/review-security [branch-name]` | `security-reviewer` — OWASP, secrets, injection, auth |
| `/review-tests [branch-name]` | `test-reviewer` — coverage gaps, test quality |
| `/review-performance [branch-name]` | `performance-reviewer` — bottlenecks, N+1s, resource waste |
| `/review-pr [pr-number \| branch-name]` | Alias for the full `/pr-review` procedure |
| `/post-review [pr-number]` | Posts findings already compiled earlier in the conversation, using the same posting scripts as step 7 of `/pr-review` — for resuming a run whose posting step didn't complete |

---

## Group Review (several related PRs)

`/pr-group-review` reviews **several related pull requests together** — one feature split across repositories. Every member PR gets its normal `/pr-review` (same finders, posting and re-review reconciliation), plus:

- a `cross-repo-reviewer` pass for defects **between** the PRs — contract drift, missing counterpart changes, merge/deploy ordering hazards, inconsistencies, duplicated logic. Each such finding is posted inline on the PR that should change, with a link to the counterpart;
- the same **group section** appended to every member's summary: members, per-PR verdicts, cross-repo findings and an *advisory* merge order.

Works on **GitHub** and **Azure DevOps** (one platform per group). Everything — finding the group, fetching the other repos, coordinating runs — happens inside the plugin; the Xianix agent only needs the rules in its `rules.json`.

### How a group is formed

1. Link the PRs to one **work item**. GitHub: an issue — link each PR in the issue's **Development** section, write `Fixes #12` / `owner/repo#12` / the issue URL in the PR description, or list the PR links in the issue description or a comment. Azure DevOps: link each PR to the work item.
2. Add the label (GitHub) or tag (Azure DevOps) **`ai-dlc/pr/group-review`** to the work item.

All **open** PRs linked to it, from repositories of the same owner (GitHub) / organization (Azure DevOps), are the group — at most 6, oldest first. A group needs at least 2 open PRs.

### What starts a review

| Event | What happens |
|---|---|
| Label added to the work item | All member PRs are reviewed together. Each member PR gets a note, once: *This PR is reviewed together with the other PRs of work item … (N PRs). New commits here start a group review.* |
| PR opened or pushed | After a 3-minute quiet period, the group is reviewed again — only PRs with new commits get a new review. A PR that is in no labelled group stops right after discovery (no wait, no review). |
| Comment `@xianix review group` on a member PR | Every member is reviewed again, changed or not. |
| A link added or removed: issue description or comment, PR description, Azure DevOps work item link | The group is read again at once. A new PR is reviewed; after a removal nothing is posted until a remaining PR changes. |
| Label removed from the work item | Pushes no longer start group reviews. A review that is running stops before posting. The notes stay on the PRs. |

PRs carry no label: a push rule cannot tell a member from any other PR, so every PR push starts `/pr-group-review --pr N`, which finds the PR's work item and stops when it has no labelled group. `/pr-review` makes the same check first and skips a member PR, so it is not reviewed twice (`PR_REVIEWER_GROUP_CHECK=false` turns that off). A PR that only mentions the issue stays linked while its description, a comment or a commit message still mentions it; the plugin's own comments are ignored. A GitHub **Development** link sends no webhook: a PR linked there after the label joins on its next push or the group's next run.

### One review at a time

There is no long-running process per group. The group's state — lock owner, heartbeat, the commit each PR was last reviewed at — is kept next to the work item:

- **GitHub:** a hidden git ref, `refs/xianix/pr-group/issue-<N>`, in the issue's repository. Moving a ref is compare-and-set, so two runs can never both hold the lock. It is not a branch: it does not show in the UI and triggers nothing. If the token may not write refs there, the plugin falls back to a state comment on the issue (`PR_GROUP_STATE_STORE=comment` forces that).
- **Azure DevOps:** a state comment on the work item (write, then read back — a rare double run is possible and harmless).

A run that finds the lock taken exits straight away. The run holding it checks the group again after posting: if a member got new commits, or a PR was linked, while it ran, it **reviews again in the same container** (up to `PR_GROUP_MAX_PASSES`, while `PR_GROUP_TIME_LIMIT_SECONDS` allows). Only when time or passes run out does it comment `@xianix review group` on the changed PR to start a fresh run — once per set of commits. A lock with no heartbeat for 35 minutes (a crashed run) is taken over.

### Commands

```text
# What the Xianix agent runs (see rules.json)
/pr-group-review --work-item lahirudfe/Test-C-Docs#1          # label added, or links changed
/pr-group-review --pr 7                                         # PR opened or pushed (current repo)
/pr-group-review --pr 7 --force                                 # @xianix review group

# Local run: each repo checked out as a sibling folder, named by repo (no lock, no notes)
/pr-group-review https://github.com/acme/orders-api/pull/41 https://github.com/acme/web/pull/88
/pr-group-review orders-api#41 web#88
/pr-group-review orders-api@feature/checkout-v2 web@feature/checkout-v2
```

Each member's run state lives in `/tmp/prg/<slug>/` (via `PR_STATE_DIR`) instead of `/tmp/pr_*`, so members never share files.

### Settings

Environment variables (constant `with-envs` in the rule, all optional):

| Variable | Default | Meaning |
|---|---|---|
| `PR_GROUP_LABEL` | `ai-dlc/pr/group-review` | Label/tag on the work item that turns group review on |
| `PR_GROUP_MAX_MEMBERS` | `6` | Most PRs in one group (oldest first; the pushed PR is always kept) |
| `PR_GROUP_MAX_DIFF_LINES` | `6000` | Above this, the cross-repo reviewer works from the contract index |
| `PR_GROUP_SETTLE_SECONDS` | `0` (`180` in the push rules) | Wait until the newest push is this old |
| `PR_GROUP_SETTLE_MAX_SECONDS` | `300` | Longest total wait |
| `PR_GROUP_LOCK_TTL_SECONDS` | `2100` | A lock without a heartbeat for this long is taken over |
| `PR_GROUP_STATE_STORE` | `auto` | GitHub: `ref` (fail if refs can't be written), `comment`, or `auto` (ref, else comment) |
| `PR_GROUP_TIME_LIMIT_SECONDS` | `1500` | Time one container may spend; another pass only if it fits |
| `PR_GROUP_MAX_PASSES` | `2` | Reviews in one container before handing over to a new run |
| `PR_GROUP_MIN_USD_PER_MEMBER` | `2` | Below this budget per reviewed PR (+1 for the cross-repo pass), review in lean mode (Haiku finders only) |
| `PR_GROUP_CACHE_DIR` | `<volume>/xianix-group-cache` | Where other members' repos are cached between runs (`none` = fresh clones) |
| `PR_GROUP_CACHE_DAYS` | `14` | Cached repos unused this long are removed |
| `PR_GROUP_PLANNING_REPO` | — | GitHub: only issues in this `owner/repo` can be a work item |
| `PR_GROUP_ALLOWED_OWNERS` | — | GitHub: extra owners (comma separated) whose repos may be in a group |
| `PR_REVIEWER_GROUP_FORCE` | `false` | Re-review members with no new commits (the `--force` path) |

Tokens: `GITHUB_TOKEN` must read every member repo and its issues, write PR/issue comments, and write refs (contents) in the issue's repo for the lock. `AZURE_DEVOPS_TOKEN`: Code (read), Work Items (read & write, for the state comment), Pull Request Threads (read & write).

Keep `PR_GROUP_TIME_LIMIT_SECONDS` below the agent's container timeout (`ContainerExecutionTimeoutSeconds`, at least 1800 s recommended: a 3-PR group takes about 10 minutes).

Tests: `bash scripts/tests/group/run.sh` (a fake GitHub API; no network).

---

## Environment Variables

The Xianix Agent reads these from its secrets store and injects them at runtime via the rule's `with-envs` block (see [Automated Triggering](#automated-triggering-xianix-agent) below). For local CLI use, export them in your shell.

| Variable | Platform | Required | Purpose |
|---|---|---|---|
| `GITHUB-TOKEN` | GitHub | Yes | Authenticate `gh` CLI for fetching PR data and posting comments |
| `AZURE-DEVOPS-TOKEN` | Azure DevOps | Yes | PAT for REST API calls and git push |

### Optional Tuning Variables

Not required to run the plugin — export these to change its default behavior. All are read from the shell environment, not the agent rule's `with-envs` block.

| Variable | Default | Purpose |
|---|---|---|
| `PR_REVIEWER_BLOCK_ON_CRITICAL` | `false` (advisory) | When `true`, a `REQUEST CHANGES` verdict posts as a **blocking** review (GitHub `--request-changes`, Azure DevOps vote `-10`) instead of the default non-blocking one (GitHub `--comment`, Azure DevOps vote `-5`) |
| `PR_REVIEWER_RECONCILE` | `true` | Set to `false` to force a stateless full review that ignores prior findings, disabling [re-review mode](#re-review-support) |
| `PR_REVIEWER_MODEL` | unset | Pins **every** reviewer sub-agent to one model (short slug: `sonnet`/`opus`/`haiku`/`fable`), ignoring the tiers below |
| `PR_REVIEWER_QUALITY_MODEL` | `haiku` | Model for the escalated path's quality-tier reviewers (`code-reviewer`, `test-reviewer`) |
| `PR_REVIEWER_RISK_MODEL` | lead's inherited model | Model for the escalated path's risk-tier reviewers (`security-reviewer`, `performance-reviewer`) |

The default (non-escalated) review path always uses `haiku` for its two finder passes, regardless of these variables.

### GitHub Token Permissions

The `GITHUB-TOKEN` requires the following repository permissions:

| Permission | Access | Why it's needed |
|---|---|---|
| **Contents** | Read | Access repository contents, commits, branches, downloads, releases, and merges |
| **Metadata** | Read | Search repositories, list collaborators, and access repository metadata |
| **Pull requests** | Read & Write | Fetch pull request diffs and context, post review comments, and access related assignees, labels, milestones, and merges |

### Azure DevOps Token Permissions

The `AZURE-DEVOPS-TOKEN` (Personal Access Token) requires:

| Permission | Access | Why it's needed |
|---|---|---|
| **Code** | Read & Write | Fetch PR diffs and metadata, push fix commits when `--fix` is used |
| **Pull Request Threads** | Read & Write | Post and edit the review comment / threads on the PR |

---

## Quick Start

```bash
# Point Claude Code at the plugin
claude --plugin-dir /path/to/xianix-plugins-official/plugins/pr-reviewer

# Then in the chat
/pr-review
```

Or trigger it automatically via the Xianix Agent by adding a rule — see [Automated Triggering](#automated-triggering-xianix-agent) below and the per-platform guides for [GitHub](./docs/triggers-github.md) and [Azure DevOps](./docs/triggers-azure-devops.md).

---

## Automated Triggering (Xianix Agent)

Add execution blocks to your `rules.json` so the Xianix Agent runs the plugin automatically when a webhook fires. The plugin uses **label-based** triggering on GitHub and **PR-lifecycle + reviewer-assignment + comment** triggering on Azure DevOps (Azure DevOps webhook payloads don't include label data).

Full, copy-pasteable execution blocks for every scenario live in dedicated per-platform guides:

- **[Automated Triggering — GitHub](./docs/triggers-github.md)** — PR opened with the review label, label applied, new commits pushed (PR update), and `@xianix` comment mentions.
- **[Automated Triggering — Azure DevOps](./docs/triggers-azure-devops.md)** — PR created, source branch updated (PR update), agent added as a reviewer, and `@xianix` comment mentions.

### Trigger matrix

| Platform | Scenario | Webhook event | Filter rule |
|---|---|---|---|
| GitHub | PR opened with review label | `pull_request` | `action==opened` and `ai-dlc/pr/pr-review` in `pull_request.labels` |
| GitHub | Label applied to a PR | `pull_request` | `action==labeled` and `label.name=='ai-dlc/pr/pr-review'` |
| GitHub | New commits to a labeled PR | `pull_request` | `action==synchronize` and `ai-dlc/pr/pr-review` in `pull_request.labels` |
| GitHub | `@xianix` comment on a PR | `issue_comment` | `action==created` and `comment.body` contains `@xianix` and `issue.pull_request?` |
| Azure DevOps | PR created | `git.pullrequest.created` | `resource.status=='active'` |
| Azure DevOps | New commits (source branch updated) | `git.pullrequest.updated` | `message.text` contains `updated the source branch` |
| Azure DevOps | Agent added as reviewer | `git.pullrequest.updated` | `message.text` contains `changed the reviewer list` and `xianix-agent@99x.io` in `resource.reviewers` |
| Azure DevOps | `@xianix` comment on a PR | `ms.vss-code.git-pullrequest-comment-event` | `resource.comment.commentType=='text'` and `resource.comment.content` contains `@xianix` |

The `GITHUB-TOKEN` / `AZURE-DEVOPS-TOKEN` secrets are injected via each block's `with-envs`. Re-review reconciliation across repeated events for the same PR is enabled by `conversation-key` (`pull_request.number` on GitHub, `resource.pullRequestId` on Azure DevOps). See the per-platform guides for the details.

:::note
These blocks go inside the `executions` array of a rule set. See [Rules Configuration](/agent-configuration/rules/) for the full file structure and filter syntax.
:::
