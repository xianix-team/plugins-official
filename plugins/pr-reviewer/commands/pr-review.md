---
name: pr-review
description: Run a full PR review. Analyzes code quality, security, tests, and performance. Works with GitHub, Azure DevOps, Bitbucket, and any git repository. Usage: /pr-review [PR number, branch name, or leave blank for current branch]
argument-hint: [pr-number | branch-name]
---

Run a comprehensive pull request review for $ARGUMENTS.

## You are the review lead — run this yourself, do NOT delegate to an orchestrator sub-agent

**Critical execution rule (read first).** You, the top-level agent, perform the orchestration described below directly. The specialized reviews (`code-reviewer`, and whichever of `security-reviewer`, `test-reviewer`, `performance-reviewer` apply per the step 5 gate) are run by spawning those sub-agents **from here, in the main context**.

Do **not** spawn a separate `orchestrator` / "PR review" sub-agent and ask *it* to run the reviewers. A sub-agent cannot spawn further sub-agents — in the Claude Agent SDK that fails with `No such tool available: Task. Task is not available inside subagents`, the parallel review silently degrades, and the report never gets posted. The fan-out in **Step 6** only works when it is emitted from the top-level agent, which is you.

Execute every step below autonomously and in order. Do not ask for confirmation, clarification, or approval at any point. If a step fails, output a single error line describing what failed and stop — except where a step explicitly says "warn and continue".

**Fix mode vs report mode:** if the invocation includes a `--fix` flag or the instruction explicitly says to fix issues, apply fixes and push (see *Applying Fixes*). Otherwise, compile and post the review report only.

**Re-review awareness (first review vs. follow-up review).** Before reviewing, the command checks whether *this plugin* has already reviewed the PR (it stamps every comment it posts with a hidden marker — see *Comment markers* below). If a prior review is found, the run switches to **re-review mode**: it reconciles old findings against the current head (resolving the ones the author fixed, leaving the unresolved ones open without re-posting duplicates), focuses on the commits pushed since the last review, and posts a short re-review delta instead of a brand-new wall of comments. The first review of a PR always runs in **initial mode**. This is automatic; no flag is required. Set `PR_REVIEWER_RECONCILE=false` to force a full, stateless review that ignores prior findings.

**Existing inline review awareness.** On every run (initial *and* re-review), unless `PR_REVIEWER_RECONCILE=false`, the command also loads **all open inline review threads** on the PR — from humans, Copilot, CodeRabbit, other bots, and this plugin. Reviewers use that list to avoid repeating already-raised findings. After analysis, the lead validates whether non-plugin open threads look addressed at `HEAD` and **replies** on those that do — without resolving them (resolution stays with the original author). Still-open external threads get no reply (avoid spam); overlapping new findings are dropped instead.

## What This Does

This command runs a **cost-tiered** review and posts the results back to the PR. The tier is chosen automatically from the diff (see step 5):

- **Default — low-cost path:** two parallel Haiku finder agents scan the diff for correctness/regression bugs and security/edge-case issues; you then self-verify and keep the strongest findings (capped at 8). This is the path for ordinary PRs and keeps token cost low.
- **Escalated — full specialist path:** when the diff touches a **high-risk surface** (auth/authz, payments/billing, crypto, DB migrations/schema, or public APIs), the dedicated specialized reviewers run instead for deeper coverage. They run on **mixed model tiers** so frontier-model spend goes only where it pays off (see *Model selection* in step 6B):

| Reviewer | Focus | Model tier |
|----------|-------|------------|
| `code-reviewer` | Readability, naming, duplication, error handling, design patterns | quality (cheap, e.g. Haiku) |
| `test-reviewer` | Coverage gaps, test quality, edge cases, missing regression tests | quality (cheap, e.g. Haiku) |
| `security-reviewer` | OWASP Top 10, secrets, injection, auth/authz vulnerabilities | risk (frontier / lead's model) |
| `performance-reviewer` | N+1 queries, O(n²) loops, memory leaks, blocking I/O | risk (frontier / lead's model) |

Either way the outcome is identical downstream: a verdict, a summary comment, and **one inline comment per finding** posted to the detected platform.

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL (`origin` is authoritative). The Xianix Executor may inject `PLATFORM=azuredevops` — that alias is normalized to canonical `azure` inside the setup script; never treat `azuredevops` as GitHub.

| Remote URL contains | Canonical `PLATFORM` | How review is posted |
|---|---|---|
| `github.com` | `github` | GitHub CLI (`gh`) — see `providers/github.md` |
| `dev.azure.com` / `visualstudio.com` | `azure` (aliases: `azuredevops`, `azure-devops`, …) | REST API (`curl`) — see `providers/azure-devops.md` |
| Anything else | `generic` | Written to `pr-review-report.md` — see `providers/generic.md` |

## Prerequisites

- Must be run inside a git repository
- The branch under review must have at least one commit ahead of the base branch
- **GitHub**: `gh` CLI installed and authenticated (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE_DEVOPS_TOKEN` environment variable set (see `docs/platform-setup.md`)
- **Fix mode**: `GITHUB_TOKEN` (GitHub) or `AZURE_DEVOPS_TOKEN` (Azure DevOps) must be set for `git push`

---

# Comment markers and finding identity (read before posting)

Re-review depends on the plugin being able to recognise its **own** previous comments and match each old finding to the current code. Two pieces of metadata make this possible. Both are written on **every** comment the plugin posts (initial *and* re-review) so that the *next* run can read them.

### 1. The marker (identifies a comment as ours)

Stamp every comment the plugin posts with a hidden marker string:

```
<!-- pr-reviewer:v1.2 kind=<finding|summary|resolve|reopen|external-ack> fid=<finding-id> sha=<HEAD_SHA> -->
```

- `kind` — `finding` for an inline finding thread, `summary` for the PR-level report comment.
- `fid` — the stable finding id (below). Omit for `kind=summary`.
- `sha` — the `HEAD_SHA` the comment was generated against (lets the next run compute the incremental range).

On **GitHub** the marker is an HTML comment appended to the comment body — it renders invisibly. On **Azure DevOps**, HTML comments are *not* reliably hidden, so the same fields are stored as thread **`properties`** (`pr-reviewer.kind`, `pr-reviewer.fid`, `pr-reviewer.sha`) instead of in the body. The provider files show the exact mechanics.

**Plugin-owned threads** (carrying this marker) are the only ones the plugin may **resolve** or **reopen**. On re-review, fixed plugin findings get a reply and the thread is marked resolved; a plugin finding that was previously marked resolved/fixed but whose `fid` reproduces again gets a reply and the thread is **reactivated** (`kind=reopen`) — see *Sub-step R* below.

**External threads** (humans, other bots, unmarked comments) are never resolved or reopened by this plugin. When an open external thread looks addressed at `HEAD`, the plugin may **reply** that it appears fixed and leave the thread open for the original author. Still-open external threads are left untouched (no reply every run — avoid notification spam). All open inline threads — plugin and external — are used for awareness and dedup so the plugin does not re-post the same finding.

### 2. The finding id `fid` (matches a finding across revisions)

`fid` must be **deterministic** and **independent of line number** (lines drift as the author edits), so the same logical issue produces the same id on every run. Compute it from the file path plus the **on-disk snippet text at the flagged line** (not the LLM-authored issue sentence — that's regenerated per run and unstable across re-reviews) plus an occurrence index that disambiguates duplicate lines within the same file:

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
FID=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/compute-fid.sh" "<file>" "<on-disk snippet text at that line>" "<occurrence-index>")
# fid = first 12 hex of sha1( lowercased path + "|" + normalised snippet + "|" + occurrence-index )
```

In practice this is computed for you by `scripts/assign-fids.sh` in step 7 — reading the snippet from disk and assigning the occurrence index is not something to hand-roll per finding. Because the fid is derived from on-disk content rather than free text, `reconcile-prior-findings.sh` can **deterministically re-verify** that a "fixed" finding's code is actually gone (Gate B) rather than trusting that this run's LLM scan simply didn't reproduce it — see that script.

**Why `v1.2`, not `v1`.** The fid formula changed from `sha1(file + issue-sentence)` (`v1`) to `sha1(file + on-disk snippet + occurrence-index)` (current). These are different hash spaces — a `v1` fid and a current fid for the same finding will not match, so bumping the marker is required: `v1`-marked threads from before this change now fail the marker regex entirely and fall through to generic **external**-thread handling (reply-only, never auto-resolved/auto-reopened) instead of being silently mismatched against new-formula fids. The one-time cost: a PR last reviewed under `v1` runs its next review as a full **initial**-mode pass (everything re-scanned) rather than an incremental re-review; every review after that behaves normally under `v1.2`. This is a deliberate, safe degrade — not a data migration — and is strictly better than the alternative (an unrelated old-formula fid coincidentally failing Gate B and a still-open finding getting silently marked Fixed).

---

# Procedure

When invoked with a PR number, branch name, or no argument (defaults to current branch vs main):

## 0. Resolve plugin scripts (do this before any `scripts/*.sh` call)

**Why:** In Xianix Executor / Claude Code Bash tools, `CLAUDE_PLUGIN_ROOT` is often **unset** (hooks get it; agent Bash often does not). The plugin may live under `CLAUDE_CONFIG_DIR` or `/workspace/repo/xianix-claude-config/plugins/cache/…` instead of `~/.claude/plugins`. A short `find` of only `.` + `~/.claude/plugins` fails → agents invent broken `curl` and the review dies.

**Hard rule:** If a required script cannot be resolved, **STOP immediately**. Output the error. Do **not** invent ad-hoc `curl`/`gh` replacements for permissions, start-comment, setup, detect-prior, or post-review.

**Pass inputs as flags on every script call.** Always pass agent-chosen scalars (`--pr`, `--branch`, `--verdict`, `--mode`, `--fix`) on the same Bash command line — never rely on an `export` from a previous Bash call surviving (each Bash tool call is a fresh shell). Env-name fallbacks still work for backward compatibility, but flags are the required form.

Paste this helper **once** at the start of the first Bash call that needs a script (typically step 1b). It writes `/tmp/pr_plugin.env` so later Bash calls can `source` it:

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env

resolve_pr_script() {
  local name="$1" cand
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/${name}" ]; then
    echo "${CLAUDE_PLUGIN_ROOT}/scripts/${name}"; return 0
  fi
  # Claude Code + Xianix Executor plugin caches (glob; pick any hit)
  for cand in \
    ${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/plugins/cache/*/pr-reviewer/*/scripts/$name} \
    ${HOME:+$HOME/.claude/plugins/cache/*/pr-reviewer/*/scripts/$name} \
    /workspace/repo/xianix-claude-config/plugins/cache/*/pr-reviewer/*/scripts/"$name" \
    /workspace/*/xianix-claude-config/plugins/cache/*/pr-reviewer/*/scripts/"$name"
  do
    [ -f "$cand" ] || continue
    echo "$cand"; return 0
  done
  find \
    ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT"} \
    ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR/plugins"} \
    ${HOME:+"$HOME/.claude/plugins"} \
    /workspace/repo/xianix-claude-config/plugins \
    -path "*/pr-reviewer/scripts/${name}" 2>/dev/null | sort -V | tail -1
}

remember_pr_plugin_root() {
  local script_path="$1" root
  root="$(cd "$(dirname "$script_path")/.." && pwd)"
  export CLAUDE_PLUGIN_ROOT="$root"
  printf 'export CLAUDE_PLUGIN_ROOT=%q\n' "$root" > /tmp/pr_plugin.env
  echo "CLAUDE_PLUGIN_ROOT=$root"
}

# Example — every later step:
#   source /tmp/pr_plugin.env && bash "$CLAUDE_PLUGIN_ROOT/scripts/<name>.sh" --pr <N> …
```

## 1. Detect Platform (do this FIRST, before any other tool call)

**Hard gate — do not call `gh`, do not open `providers/github.md`, and do not assume GitHub until this step completes.** The Xianix Executor may log `Platform: azuredevops` and inject `PLATFORM=azuredevops`, but that string is **not** a reason to skip detection, and it is **not** the canonical value scripts use.

Run **only** the following:

```bash
git remote get-url origin
```

If that fails or returns empty, stop with an error — there is no platform to review against.

From the remote URL, determine the platform (this is authoritative — not the PR title, not the mention prompt, not marketplace clone URLs in the executor log):

| Remote URL contains | Store as `PLATFORM` | Provider |
|---|---|---|
| `github.com` | `github` | `providers/github.md` |
| `dev.azure.com` / `visualstudio.com` | `azure` | `providers/azure-devops.md` |
| `bitbucket.org` / anything else | `generic` | `providers/generic.md` |

**Executor / env alias normalization.** If `PLATFORM` is already set in the environment, treat it only as a *hint* and **normalize** it before comparing. The Xianix Agent/Executor standard value is `azuredevops` (no hyphen). Map aliases to the canonical script values above:

| Injected / hint value | Canonical `PLATFORM` |
|---|---|
| `azuredevops`, `azure-devops`, `azure_devops`, `ado`, `azure` | `azure` |
| `github`, `gh` | `github` |
| `bitbucket`, `generic`, anything else unknown | keep / re-detect from remote |

If the hint disagrees with the remote (e.g. `PLATFORM=github` but origin is `dev.azure.com`), **trust the remote** and continue with the remote-derived value. Never keep a GitHub path on an Azure remote.

Echo one line after detection, e.g. `PLATFORM=azure (from origin; env hint was azuredevops)`, then proceed. Do **not** default to `github` when unset.

### Platform-exclusive CLI rule (mandatory)

After detection, use **only** the platform-appropriate tool for the rest of the run. Mixing them wastes turns and leaks credentials into logs:

| Platform | Allowed for posting / PR API | Forbidden |
|---|---|---|
| GitHub (`PLATFORM=github`) | `gh`, `git` | `curl` to Azure DevOps, `az` |
| Azure DevOps (`PLATFORM=azure`) | `curl` + `AZURE_DEVOPS_TOKEN`, `git` | `gh` (will fail with `gh auth login`), `az login` |
| Bitbucket / Generic | `git` only | `gh`, `curl` to private APIs |

Do **not** probe other CLIs ("just to check"). The hook layer will block obvious mismatches; doing it wrong will block the run.

### Secret hygiene (mandatory)

**Never echo secrets** into the transcript (`echo "$AZURE_DEVOPS_TOKEN"`, `echo "$GITHUB_TOKEN"`, `env | grep TOKEN`, unredirected `printenv`). Use tokens only in `curl -u` / `GIT_CONFIG_*` assignments. Presence-check only:

```bash
echo "AZURE_DEVOPS_TOKEN=${AZURE_DEVOPS_TOKEN:+yes}"
echo "GITHUB_TOKEN=${GITHUB_TOKEN:+yes}"
```

If the underscored Azure alias is empty but a dashed `AZURE-DEVOPS-TOKEN` exists: `export AZURE_DEVOPS_TOKEN="$(printenv AZURE-DEVOPS-TOKEN)"` — then re-check with `:+yes`, never by printing the value.

### 1b. Check permissions (immediately after platform detect — hard gate)

Before posting the starting comment, run **`scripts/check-permissions.sh` as one Bash call**. It verifies auth and the capabilities required to post a review (and warns when vote / fix-mode push may fail). Do **not** invent ad-hoc `gh auth` / `curl` probes.

```bash
# Include the resolve_pr_script / remember_pr_plugin_root helpers from step 0 in this same Bash call.
# Discover the PR number / branch / fix flag from the invocation ($ARGUMENTS), then pass as flags.
PR_ARG=…          # numeric PR from the invocation, or empty
BRANCH_ARG=…      # branch name from the invocation, or empty
FIX_FLAG=()       # set to (--fix) when the invocation includes --fix
PERM=$(resolve_pr_script check-permissions.sh)
[ -n "${PERM:-}" ] && [ -f "$PERM" ] || {
  echo "ERROR: scripts/check-permissions.sh not found" >&2
  echo "Searched CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-unset} CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-unset} ~/.claude/plugins /workspace/repo/xianix-claude-config/plugins" >&2
  echo "Do NOT invent a curl/gh permissions probe — stop the review." >&2
  exit 1
}
remember_pr_plugin_root "$PERM"
PERM_ARGS=()
[ -n "$PR_ARG" ] && PERM_ARGS+=(--pr "$PR_ARG")
[ -n "$BRANCH_ARG" ] && PERM_ARGS+=(--branch "$BRANCH_ARG")
PERM_ARGS+=("${FIX_FLAG[@]}")
bash "$PERM" "${PERM_ARGS[@]}"
# shellcheck disable=SC1091
source /tmp/pr_permissions.env
```

| Result | Action |
|---|---|
| Exit **0** (`PERMISSIONS CHECK PASSED`) | Continue. Surface any `WARN:` lines (e.g. vote may fail) but do not stop. |
| Exit **1** (`PERMISSIONS CHECK FAILED`) | **Stop** with the script's error lines. Do not post a starting comment or run the review. |

**What it checks**

| Platform | Required (hard fail) | Soft warn |
|---|---|---|
| **GitHub** | `gh` installed; authenticated; can read repo (+ PR when `PR_NUMBER` set); classic PAT has `repo` or `public_repo` | Fine-grained scope reminder; missing `GITHUB_TOKEN` in `--fix` mode |
| **Azure DevOps** | `AZURE_DEVOPS_TOKEN` present (re-exports dashed alias); `connectionData` OK; repo + PR readable; threads readable | Vote / Code Write likely missing; `--fix` push not probeable without mutating |
| **Generic** | (none — report file only) | — |

Writes `/tmp/pr_permissions.env` (`PLATFORM`, `AUTH_OK`, `CAP_*`, `PERMISSIONS_WARNINGS`). Never echoes secret values.

## 2. Post a "Review in Progress" Comment (must be within the first 3 tool calls)

Immediately after the permissions check, post a comment so the PR author knows the review has started. **Do not read any files, do not run `find`/`ls`, do not index the codebase before this step.**

Use the platform-appropriate **plugin script** as one `Bash` call — do not invent a shortened version:

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
# Pass --pr / --branch discovered from the invocation. On executor detached-HEAD
# checkouts a PR number is required — without --pr the Azure script exits 1.
START_ARGS=()
[ -n "$PR_ARG" ] && START_ARGS+=(--pr "$PR_ARG")
[ -n "$BRANCH_ARG" ] && START_ARGS+=(--branch "$BRANCH_ARG")
# Branch-only / no-PR reviews may pass --optional to soft-skip instead of failing.
case "$PLATFORM" in
  github) bash "$CLAUDE_PLUGIN_ROOT/scripts/gh-start-comment.sh" "${START_ARGS[@]}" ;;
  azure)  bash "$CLAUDE_PLUGIN_ROOT/scripts/ado-start-comment.sh" "${START_ARGS[@]}" ;;
  *)      echo "Generic platform — skipping start comment" ;;
esac
```

- **GitHub:** `scripts/gh-start-comment.sh --pr <N>` — see `providers/github.md`
- **Azure DevOps:** `scripts/ado-start-comment.sh --pr <N>` — writes `/tmp/pr_azure.env`. See `providers/azure-devops.md`
- **Generic / unknown platform:** Skip — no API available

If `CLAUDE_PLUGIN_ROOT` is missing, re-run the step 0 resolver — **do not** hand-roll a starting-comment `curl`.

If posting the starting comment fails with a non-zero exit because `--pr` was omitted on a detached HEAD, **stop** and re-run with `--pr <number>`. Other soft failures (HTTP errors after a PR id is known): output a single warning line and continue.

## 3. Gather PR Context (do this BEFORE indexing the codebase)

The diff is what matters. Resolve the base/head and pull the diff first — for small PRs (≤10 changed files), this is *all* the context the sub-agents need, and the codebase index in step 4 can be skipped entirely.

### Run the setup script (ONE bash call — mandatory)

> **Shell state does not persist between tool calls.** Each `Bash` invocation starts a fresh shell — variables like `HEAD_SHA` from a prior call are **gone**. This script resolves checkout, base/head SHAs, diffs, and the numbered patch in one shot, then writes everything to `/tmp/pr_state.env`. In any later bash block that needs these values, run `source /tmp/pr_state.env` first. Never assume a variable from a prior tool call still exists.

> **Xianix Executor / CI worktrees:** the runner checks out the repo's **default branch** only — it knows nothing about PRs. When a PR number is provided, this script is a **hard gate**. You must see `Checked out PR #<n> at <sha>` (or branch checkout) in the output before proceeding. If `HEAD_SHA` does not match the platform's `headRefOid`, the script exits with an error.

Pass the PR number / branch discovered from the invocation as flags. You may also pass `--platform <hint>` — the script always resolves the real platform from `origin` and normalizes executor aliases such as `azuredevops`. Canonical values inside the script are only `github`, `azure`, or `generic`. Then run **`scripts/pr-setup.sh` as a single `Bash` call** — do **not** invent a shortened checkout/diff script:

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/scripts/pr-setup.sh" ] || {
  echo "ERROR: CLAUDE_PLUGIN_ROOT unset — re-run step 0/1b resolve (do NOT invent a checkout/diff script)" >&2
  exit 1
}
SETUP_ARGS=()
[ -n "$PR_ARG" ] && SETUP_ARGS+=(--pr "$PR_ARG")
[ -n "$BRANCH_ARG" ] && SETUP_ARGS+=(--branch "$BRANCH_ARG")
bash "$CLAUDE_PLUGIN_ROOT/scripts/pr-setup.sh" "${SETUP_ARGS[@]}"
# shellcheck disable=SC1091
source /tmp/pr_state.env
```

> On **Azure DevOps** the `/merge` ref points at the PR's *merge commit*; its second parent (`HEAD^2`) is the real PR head. The script sets `HEAD_SHA` accordingly when `CHECKED_OUT=refs/pull/<n>/merge`.

Writing the diff to `/tmp/pr_full_diff.patch` lets you pass it by **path** to sub-agents instead of by value — much smaller prompts when the diff is large.

Each kept line in `/tmp/pr_full_diff_numbered.patch` looks like `  147 |+    var x = ParseSubject(dn);` — the number left of the `|` is the exact line to cite. Reviewers must **copy** this number, never recompute it.

> **Anti-pattern:** Do NOT `cat <<'DIFF_EOF' ... DIFF_EOF` the diff back to yourself in a subsequent `Bash` call. The diff is already in your conversation history once you ran the setup script. Echoing it back wastes a turn and tokens.

Use `git show ${HEAD_SHA}:<filepath>` or the `Read` tool to read the full content of any file that requires deeper analysis beyond the patch. Always `source /tmp/pr_state.env` first so `HEAD_SHA` is defined.

**Platform CLIs are not used in this diff step.** Use **`gh`** only when posting to GitHub and **`curl`/Azure DevOps REST** only when posting to Azure DevOps (see the provider docs and "Posting the Review" below).

### Detect a prior review and compute the re-review range

This is the one place reading platform PR comments is required, because it determines whether the run is an **initial** review or a **re-review**, and it loads open inline threads for awareness/dedup. Skip entirely on the generic platform (no API) and when `PR_REVIEWER_RECONCILE=false` (stateless mode also skips external-thread awareness).

**Run `scripts/detect-review-mode.sh` as one Bash call** — it invokes the platform detect-prior script (`gh-detect-prior.sh` / `ado-detect-prior.sh`), decides `REVIEW_MODE` / `RANGE_BASE`, writes the incremental diff when needed, and appends mode vars to `/tmp/pr_state.env`. Do **not** invent a shortened `curl`/`gh` dump (Azure agents inventing `THREADS_JSON=$(curl …)` then `json.load` is a common crash on 401 HTML).

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
DETECT_ARGS=()
[ -n "${PR_ARG:-${PR_NUMBER:-}}" ] && DETECT_ARGS+=(--pr "${PR_ARG:-$PR_NUMBER}")
bash "$CLAUDE_PLUGIN_ROOT/scripts/detect-review-mode.sh" "${DETECT_ARGS[@]}"
# shellcheck disable=SC1091
source /tmp/pr_state.env
# also sources PRIOR_SUMMARY_SHA when present:
[ -f /tmp/pr_prior.env ] && source /tmp/pr_prior.env
```

**Outputs:**
- `/tmp/pr_prior_findings.jsonl` — only threads carrying the plugin marker. Drives `REVIEW_MODE`.
- `/tmp/pr_open_threads.jsonl` — **every open inline thread** (humans, bots, this plugin). Used for reviewer awareness, dedup, and external-thread validation.
- `/tmp/pr_prior.env` — `PRIOR_SUMMARY_SHA`
- `/tmp/pr_incremental_diff.patch` — when re-review and `RANGE_BASE != BASE_SHA`

If the script exits non-zero (missing token, HTTP 401, non-JSON body), **fix auth / env and re-run the script** — do not hand-roll a replacement curl.

> **Why review the full PR diff, not just the increment?** The full diff (`/tmp/pr_full_diff.patch`) stays the authoritative input to the reviewers so the *current* finding set is always complete — an unresolved finding in a file the latest commits didn't touch must still be detected so it stays open. The incremental diff focuses your attention and drives the delta summary; it does not replace the full scan. Reconciliation (step 7 / posting) compares the current finding set to the prior one **by `fid`**, and also validates open external threads against `HEAD`.
>
> **A re-trigger with zero new commits still runs the full review — do not skip ahead.** `REVIEW_MODE=rereview` with `RANGE_BASE == HEAD_SHA` (an incremental range of zero commits) is not a signal to stop: finder sub-agents are non-deterministic, and a second pass over the same diff can surface a real issue the first pass missed. Continue to step 4 exactly as for any other re-review. This is safe because reconciliation is fid-based and content-derived (see *Comment markers and finding identity*): a re-found issue recomputes the same `fid` and is correctly folded into `carried_over` (no duplicate post), a genuinely new one gets a fresh `fid` and posts as `new`, and Gate A in `reconcile-prior-findings.sh` refuses to mark anything `fixed` when HEAD hasn't moved since the prior review.

## 4. Index the Codebase (skip on small PRs)

Every line these commands print lands in your context and is paid for on every subsequent turn — keep the index small. The caps are mandatory, not decorative.

**Run `scripts/index-codebase.sh` as one Bash call** — do not invent an unbounded `find`/`ls` walk. It skips automatically when `CHANGED_COUNT ≤ 10`.

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/index-codebase.sh"
```

If indexing was performed, use `Read` on key config/manifest files (`package.json`, `*.csproj`, `go.mod`) and `Grep` to locate patterns such as the main entry point, base classes, or shared utilities referenced by the changed files. Otherwise skip directly to step 5.

## 5. Understand the Change & Choose the Review Tier

Before launching any agents:
- Identify the type of change (feature, bugfix, refactor, config, docs)
- Note which languages/frameworks are involved
- Estimate scope (small/medium/large)

### Decide the tier: default Haiku finders vs. escalated specialists

The review runs on the **cheap Haiku-finder path by default** (step 6A) and only **escalates to the full specialist reviewers** (step 6B) when the diff touches a high-risk surface. Detect high-risk changes from both the file list and the diff content:

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/review-tier.sh"
# shellcheck disable=SC1091
source /tmp/pr_state.env   # REVIEW_TIER=haiku|specialists
```

- `REVIEW_TIER=haiku` → go to **step 6A** (two Haiku finders). This is the common case.
- `REVIEW_TIER=specialists` → go to **step 6B** (gated specialist sub-agents).

When genuinely uncertain whether a change is high-risk, prefer **specialists** — a missed vulnerability costs far more than one extra review pass. The heuristic above is intentionally broad for exactly this reason.

## 6. Run the Review (parallel sub-agent calls — MANDATORY)

Run **exactly one** of the two paths below, chosen by `REVIEW_TIER` from step 5. Both paths run **real, parallel, top-level sub-agents** (you are the top-level agent, so `Task` / `Agent` is available here) and both feed the same step 7. The tool is exposed under two equivalent names depending on the Claude Code SDK version (`Task` and/or `Agent`). Use whichever your SDK accepts; if one returns `No such tool available`, immediately retry the same call with the other name.

> **Registered agents.** The four specialist reviewers are registered in `plugin.json` (`code-reviewer`, `security-reviewer`, `test-reviewer`, `performance-reviewer`). Always set `"subagent_type"` to the reviewer name — do **not** hand-write a generic `Agent` prompt without `subagent_type`. If your SDK requires the plugin prefix, use `pr-reviewer:code-reviewer` etc.

> **Agent `model` field — valid slugs only.** The `Task`/`Agent` tool accepts **only** `sonnet`, `opus`, `haiku`, or `fable`. Values like `claude-haiku-4-5` are rejected with `InputValidationError`. Map env overrides to these slugs before passing them (see model-selection block in 6B). For the lead's inherited model, **omit** the `model` field entirely.

**Constraints every sub-agent prompt below must include, verbatim:**

- A reminder: *"Do not re-fetch git data; the annotated diff at /tmp/pr_full_diff_numbered.patch is authoritative. Return findings only."*
- A line-number constraint: *"Every `path/to/file.ext:NN` reference must be the POST-CHANGE file line number, and you must READ it — never compute it. In /tmp/pr_full_diff_numbered.patch every context and added (`+`) line is prefixed with `<lineno> |`; `NN` is exactly that number for the flagged line. Copy it verbatim. Never do hunk-header arithmetic, never report the diff's own line position, and never emit a number larger than the file. Findings on deleted (`-`) lines (marked `- |`) have no post-change line — reference the nearest surviving numbered line instead."*
- A suggestion constraint: *"For findings where the fix is a concrete, drop-in replacement (wrong identifier, missing null guard, insecure call swapped for safe equivalent, etc.), add a native GitHub suggestion block immediately after the `**Fix:**` block. Prefix it with an HTML comment that carries the line range, then a ` ```suggestion ` fenced block containing the verbatim replacement lines with indentation preserved. Example for a single-line fix: `<!-- suggestion: line NN -->` on its own line, then ` ```suggestion `, then the replacement line, then ` ``` `. For multi-line: `<!-- suggestion: lines NN-MM -->`. Do not include this for architectural improvements or fixes requiring author judgment."*
- An open-threads constraint (include only when `/tmp/pr_open_threads.jsonl` is non-empty): *"Also read /tmp/pr_open_threads.jsonl — existing open inline review comments on this PR (humans, bots, prior plugin runs). Do not re-report issues already substantially covered by an open thread on the same file (same concern, or within ±5 lines of the same area). Prefer leaving those to the existing thread over inventing a duplicate finding."*

> **Diff size (used by both paths):**
> ```bash
> DIFF_LINES=$(wc -l < /tmp/pr_full_diff.patch)
> echo "Diff size: $DIFF_LINES lines  |  Tier: $REVIEW_TIER"
> ```

---

### 6A. Default path — two parallel Haiku finders (`REVIEW_TIER=haiku`)

Lowest-cost path for ordinary PRs.

**Pre-load context (at most 3 `Read` calls, strict size cap).** From `/tmp/pr_changed_files.txt` pick the **top 3 highest-risk files** (business logic, data access first; skip pure test/generated files unless they are the only changes). For each:
- If the file is **≤ 400 lines**, read it in full.
- If **> 400 lines**, extract only the changed regions: `grep -n '^@@' /tmp/pr_full_diff.patch` to find hunk positions, then `sed -n '<start>,<end>p' <file>` for ±60 lines around each hunk.

Concatenate the snippets into `/tmp/pr_context.txt` (a filepath header before each). **Never read any file in its entirety if it exceeds 400 lines; never read more than 3 files.**

If `/tmp/pr_open_threads.jsonl` is non-empty, also prepare a compact open-threads block for both prompts (Haiku finders cannot call tools). Prefer pasting the file contents when ≤ 80 lines; otherwise paste a truncated summary of `file:line — author — first 120 chars of body` per thread. Prefix with `EXISTING OPEN REVIEW THREADS:` so finders can skip duplicates.

Then emit **both Agent calls in the same assistant turn** (so they run in parallel). Both **must** set `"model": "haiku"`. Neither agent may call `Read`, `Bash`, `Grep`, or any other tool — they work only from the content named in the prompt.

Both prompts share the same shell and tail. Compose each prompt as: the **shared header**, then the agent's **focus list** (below), then the **shared output-format tail**.

**Shared header (start of both prompts):**

```
Read /tmp/pr_full_diff_numbered.patch then /tmp/pr_context.txt (and the EXISTING OPEN REVIEW THREADS block if the lead included one — do not duplicate those issues). The numbered diff prefixes every context/added line with its real post-change file line number (`<lineno> |`); use those numbers for LINE — never compute a line number.
```

**Shared output-format tail (end of both prompts, verbatim):**

```
For each finding output exactly:
FILE: <path>
LINE: <the number printed left of the `|` on the flagged line in /tmp/pr_full_diff_numbered.patch — copied verbatim, never computed, never the diff's own line position, never larger than the file>
SEVERITY: CRITICAL | WARNING | SUGGESTION
ISSUE: <one sentence>
SUGGESTION_START_LINE: <line number, only when the fix is a concrete drop-in single-line or consecutive-block replacement; omit otherwise>
SUGGESTION_END_LINE: <last line of the replacement block; same as SUGGESTION_START_LINE for a single-line fix; omit if no suggestion>
SUGGESTION_CODE: <verbatim replacement lines with indentation preserved exactly; omit if no suggestion>

Include SUGGESTION_* fields only when the fix is an unambiguous drop-in swap (wrong value, missing guard, insecure call replaced by its safe equivalent). Omit for architectural or design-level fixes.

If you find nothing, output: NONE
Do not call any tools.
```

**Agent 1 — Correctness & regressions** (`"description": "Correctness & regression finder"`), focus list:

```
Find correctness bugs and behavioural regressions introduced by the diff. Focus on:
- Logic errors in changed code paths
- Changed conditions that now allow or block cases they shouldn't
- Null / empty / zero edge cases on new code paths
- Removed guards that previously protected against a bad state
- Interface/contract mismatches between callers and the changed function
```

**Agent 2 — Security & edge cases** (`"description": "Security & edge-case finder"`), focus list:

```
Find security issues and missing edge-case handling in the diff. Focus on:
- Input not validated before use (injection, path traversal)
- Authentication or authorisation checks removed or weakened
- Sensitive data written to logs
- Exception or error paths that swallow failures silently
- Resource leaks (connections, file handles) on error paths
- Off-by-one errors or boundary conditions in new loops/ranges
```

**Verify and compile (you are the verifier — no extra agents).** For each finding from both agents: (1) confirm the flagged line appears in `/tmp/pr_full_diff_numbered.patch` as a `+` line (new code, not pre-existing) and that the reported `LINE` matches the number printed in that line's margin — **if the line number is missing, does not match the margin, or exceeds the file's length, correct it to the margin number of the flagged code before keeping the finding** (this is the guard against out-of-range citations like `:466` on a 322-line file); (2) discard pre-existing issues, linter/compiler-caught problems, pedantic style, and obvious false positives; (3) merge duplicates and **cap at 8 findings**, ranked CRITICAL → WARNING → SUGGESTION; (4) **preserve the `SUGGESTION_START_LINE` / `SUGGESTION_END_LINE` / `SUGGESTION_CODE` fields verbatim** — they will be extracted in the "Extract suggestion annotations" step before posting and are what enables the GitHub "Commit suggestion" button. Then go to step 7.

---

### 6B. Escalated path — gated specialist sub-agents (`REVIEW_TIER=specialists`)

Deeper coverage for high-risk diffs. Run `code-reviewer` **always**; gate the other three by the changed-file mix so you never spawn a reviewer with nothing to do:

| `subagent_type` | Focus | Model tier | Run when the diff contains… | Skip when… |
|---|---|---|---|---|
| `code-reviewer` | Code quality, readability, maintainability | **quality** (`haiku`) | **always** | never |
| `test-reviewer` | Test coverage and test quality | **quality** (`haiku`) | source code with behaviour (functions/methods/classes) | the diff is **only** docs, config, or pure formatting/rename |
| `security-reviewer` | Vulnerabilities, secrets, input validation | **risk** (omit `model` / inherit) | source code, auth/authz, input handling, dependencies/lockfiles, IaC, any externally-reachable surface | the diff is **only** docs/markdown/images |
| `performance-reviewer` | Bottlenecks, inefficiencies, resource usage | **risk** (omit `model` / inherit) | DB queries/ORM, loops over collections, I/O, hot paths, caching layers, auth handlers with async/DB lookups, large data structures, algorithm changes | the diff is **only** docs/config with no executable code |

`package.json`/`*.csproj`/lockfile changes are **not** docs — they keep `security-reviewer` in scope (dependency risk). Paths matching `auth`, `cache`, or `handler` keep `performance-reviewer` in scope (request-path latency). When uncertain whether a reviewer applies, **run it**. For `REVIEW_TIER=specialists` on auth/security code, expect **four** agent results unless you document a skip reason.

**Run the two gating scripts as Bash calls before launching agents** — do not invent your own skip logic or model-slug mapping:

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/select-reviewers.sh"
bash "$CLAUDE_PLUGIN_ROOT/scripts/resolve-models.sh"
# shellcheck disable=SC1091
source /tmp/pr_state.env
# RUN_CODE / RUN_TEST / RUN_SECURITY / RUN_PERFORMANCE
# QUALITY_SLUG / RISK_SLUG  (empty RISK_SLUG = omit model field)
```

In **one assistant turn**, emit one parallel sub-agent invocation per selected reviewer (`RUN_*=true`, between 1 and 4). Each invocation prompt must include, in addition to the two shared constraints above:

- The path `/tmp/pr_full_diff_numbered.patch` (the line-number-annotated diff — the authoritative source for `NN`) and the path `/tmp/pr_changed_files.txt`
- `BASE_SHA` and `HEAD_SHA`
- The PR title and description (from the platform metadata fetched in step 2)
- A file-reading constraint: *"When you need full file context, read only the enclosing function/class (±60 lines around each changed hunk). Do not read any file in its entirety if it exceeds 400 lines — use `Bash(sed -n '<start>,<end>p' <file>)` scoped to the changed region instead. Read at most 3 files beyond the diff."*

> **Pass-by-value vs path:** if `DIFF_LINES ≤ 300`, paste the contents of `/tmp/pr_full_diff_numbered.patch` **inline** in each prompt (cheaper than each sub-agent re-opening a shared file) — inline the *numbered* diff, not the raw one, so the line numbers travel with it; if `DIFF_LINES > 300`, pass the path `/tmp/pr_full_diff_numbered.patch`.

> **Model selection (mixed-model tiering).** `scripts/resolve-models.sh` already applied this precedence and wrote `QUALITY_SLUG` / `RISK_SLUG`:
>
> 1. **`PR_REVIEWER_MODEL` (override).** If set, pins **every** reviewer.
> 2. Otherwise: quality tier (`code-reviewer`, `test-reviewer`) → `PR_REVIEWER_QUALITY_MODEL` or `haiku`; risk tier (`security-reviewer`, `performance-reviewer`) → `PR_REVIEWER_RISK_MODEL` or inherit (omit `model`).
>
> Emit each reviewer in the **same assistant turn** with `subagent_type` set. Pass `"model": "<QUALITY_SLUG>"` for quality-tier reviewers; for risk-tier omit `"model"` when `RISK_SLUG` is empty. **Never** pass `claude-haiku-4-5`, `inherit`, or any other string — those cause `InputValidationError`.
>
> **Invocation template (6B — copy per selected reviewer, adjust `subagent_type` and `model`):**
>
> ```json
> {
>   "subagent_type": "code-reviewer",
>   "model": "haiku",
>   "description": "Code quality review",
>   "prompt": "<shared constraints from step 6> + paths /tmp/pr_full_diff_numbered.patch, /tmp/pr_changed_files.txt, and /tmp/pr_open_threads.jsonl (when non-empty) + BASE_SHA/HEAD_SHA from /tmp/pr_state.env + PR title/description + file-reading constraint"
> }
> ```
>
> For `security-reviewer` and `performance-reviewer`, omit `"model"` so they inherit the lead's model (unless `RISK_SLUG` is set). Launch all selected reviewers in one turn — never sequentially.

Wait for all selected sub-agents to return, then go to step 7. **Do not** run `sed`/`git show`/`Read` on changed files yourself while waiting — that is simulating the reviewers (see anti-patterns below).

---

### What NOT to do (anti-patterns — apply to both paths)

These look like progress but are actually you **simulating** sub-agents in your own context. They double cost, double latency, and lose the benefit. **Stop the moment you catch yourself doing any of them:**

- ❌ Spawning a single `orchestrator` / "PR review" sub-agent and asking it to run the reviewers. That sub-agent cannot spawn sub-agents — the fan-out fails and the review degrades to a text summary that never gets posted. Run the agents from here.
- ❌ Running `Bash` with `cat <<'ANALYSIS' ... === CODE QUALITY REVIEW === ... ANALYSIS` — that is **you pretending to be a reviewer**, not invoking it. Delete the heredoc and emit a real agent call instead.
- ❌ A long thinking turn (>20 s) followed by directly compiling the report. That pause is internal reasoning that should have been parallel sub-agent work.
- ❌ Sequential `Task` / `Agent` calls — they MUST be in the same assistant turn so the runtime parallelizes them.
- ❌ Launching agents without `"subagent_type"` — hand-written prompts bypass the registered reviewer definitions and lose checklist coverage.
- ❌ Passing `"model": "claude-haiku-4-5"` or `"model": "inherit"` — use `haiku` or omit the field; invalid slugs fail the whole parallel batch.
- ❌ Running `sed`/`git show`/`Read` on changed files **after** launching specialists but **before** step 7 — you are duplicating reviewer work. If you have more than 3 such calls in that window, stop and wait for sub-agent results.
- ❌ Passing a large diff (> 300 lines) inline when `/tmp/pr_full_diff.patch` exists. Pass the path.
- ❌ `cat <<'DIFF_EOF' ... DIFF_EOF` echoing the diff back into the conversation. You already have it. Don't.
- ❌ Printing "Review posted successfully" when `gh pr review` or inline posting failed — check exit codes and `INLINE_OK` first.

### Fallback if sub-agents are genuinely unavailable

If **both** `Task` and `Agent` return `No such tool available` (a stripped-down runtime that exposes neither), do not give up:

1. Perform the review yourself, inline — for the Haiku path do the two finder passes (correctness, security); for the specialist path do one focused pass per selected dimension — using `/tmp/pr_full_diff.patch` as the source of truth.
2. Then **continue to steps 7 and "Posting the Review" exactly as normal** — a degraded analysis path must still post the report and inline comments. Producing a text summary and stopping is a failure.

### Self-check before emitting the report

Before step 7, your conversation history should contain a `Task` (or `Agent`) tool result in the prior turn for the path you ran: **two Haiku finders** (6A) or **one result per selected specialist** (6B). If those results are missing *and* you did not take the documented fallback above, you skipped the review. Go back and do it.

## 7. Compile Final Report

Aggregate all findings into the structured report format defined in `styles/report-template.md`. Read that file and follow its template exactly.

**Before posting (all platforms):** write the compiled report markdown to `/tmp/pr_thread_body.md` and serialize every finding to post as one JSON object per line in `/tmp/pr_inline_findings.jsonl` (fields: `file`, `line`, `body`, `fid`). Do **not** use alternate names like `pr_review_summary.md` or `pr_findings.jsonl` — the Azure posting script only auto-corrects those as a fallback.

**Guidelines:**
- Reference specific file paths and line numbers for every finding
- Include both the problematic code snippet and a concrete fix example
- Do not flag non-issues — only real problems and genuine improvements
- Tag findings that exist in the base branch (not introduced by this PR) as **pre-existing** — they may warrant a WARNING but must not alone drive a `REQUEST CHANGES` verdict
- Consider the PR's stated intent when evaluating trade-offs
- Group related issues together rather than repeating similar findings

### Validate line numbers, assign fids, reconcile prior findings (MANDATORY — scripts)

After writing `/tmp/pr_inline_findings.jsonl` (and the summary body), run these as Bash calls, **in this exact order** — do **not** invent ad-hoc `sed`/`wc` loops, and do **not** run `assign-fids.sh` before `validate-findings.sh`: fid computation reads the on-disk line the finding is anchored to, so line numbers must already be corrected or the fid is computed against the wrong snippet.

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/validate-findings.sh"        # re-anchor / drop bad lines FIRST
bash "$CLAUDE_PLUGIN_ROOT/scripts/assign-fids.sh"              # fill missing fid from the now-correct line
bash "$CLAUDE_PLUGIN_ROOT/scripts/reconcile-prior-findings.sh" # fid buckets + Gate A/B + dedup
# shellcheck disable=SC1091
source /tmp/pr_state.env
```

**What each script does**

| Script | Purpose |
|---|---|
| `validate-findings.sh` | Drop or re-anchor findings whose `line` is past EOF or unlocatable in `/tmp/pr_full_diff_numbered.patch` / `HEAD` |
| `assign-fids.sh` | `fid = sha1(path\|normalised on-disk snippet\|occurrence-index)[:12]` for every finding missing `fid` |
| `reconcile-prior-findings.sh` | Compare current vs `/tmp/pr_prior_findings.jsonl` **by `fid`** → `fixed` / `carried_over` / `reopened` / `new`; line±5 dedup against open threads; writes `/tmp/pr_rereview_delta.md` in re-review mode |

| Bucket (re-review) | Condition | Posting action |
|---|---|---|
| **Carried-over** | prior open `fid` still in current set | Leave thread open — **no duplicate** |
| **Reopened** | prior *resolved* `fid` still in current set | Reply + reactivate — regression signal |
| **Fixed** | prior open `fid` absent from current set **and** passes Gate A (HEAD actually advanced past the prior review's sha) **and** Gate B (recomputing fids for every line currently in the file does not reproduce this `fid`) | Reply + resolve |
| **New** | current `fid` not in prior set | Post new inline thread |
| **Already-resolved** | prior *resolved* `fid` absent from current set (genuinely gone) | Ignore |

A `fixed` candidate that fails Gate A or Gate B stays `carried_over` instead — the finder simply didn't reproduce it this pass, which is not evidence the underlying code changed. This is a mechanical check, not an LLM judgment call: `reconcile-prior-findings.sh` performs it directly (same-sha comparison for Gate A, a deterministic re-hash of the file's current lines for Gate B).

Prepend `/tmp/pr_rereview_delta.md` into the report body when present. In **initial mode** the reconcile script treats every finding as New. Keep the summary body's `file:NN` references in sync with the validated JSONL.

A finding whose line cannot be validated must not appear with a made-up number — the validate script drops those.

### Reconcile against existing open review threads (initial and re-review)

When `/tmp/pr_open_threads.jsonl` is non-empty, validate **external** open threads (`is_plugin=false`) against current `HEAD` and dedup new findings against **all** open threads (plugin and external). Skip when the file is empty or `PR_REVIEWER_RECONCILE=false`.

1. **Validate external threads.** For each open thread with `is_plugin=false`, inspect the current code at `file` near `line` (`git show ${HEAD_SHA}:<file>` / Read around that line) together with the thread `body`, and classify:
   - **addressed** — the concern no longer reproduces at `HEAD`
   - **still_open** — the concern is still present
   - **unclear** — cannot tell with confidence → treat as **still_open** (no reply)

   Write `/tmp/pr_external_reconcile.json`:
   ```json
   {"addressed":[{"file":"...","line":42,"thread_ref":"...","comment_ref":123,"author":"..."}], "still_open":[...]}
   ```
   Each entry must carry `thread_ref` and `comment_ref` (when available) so posting sub-step **E** can reply without re-fetching.

2. **Dedup before posting.** Drop any finding that would create a new inline thread when an open thread already covers the same issue:
   - same `file`, and
   - finding line within ±5 of the open thread's `line` (when both have lines), **or** the finding's issue text clearly matches the thread body's concern.
   Count dropped findings as `DEDUP_SUPPRESSED`. Prefer the existing thread over a duplicate new inline — including open **plugin** threads (those are already handled as Carried-over in re-review; in initial mode a plugin thread only appears if a previous run's markers somehow exist without flipping mode — still suppress duplicates).

3. **Report block.** Prepend or include an **Existing review threads** block in the report body (see `styles/report-template.md`):
   ```
   ### Existing review threads
   - ✅ Appears addressed: <count> open thread(s) — will reply, leave open for original author
   - ⏳ Still open: <count> open thread(s) — no reply (avoid spam)
   - 🔇 Duplicates avoided: <count> finding(s) not re-posted
   ```
   Omit the block entirely when there were no open threads to consider.

**Do not resolve** any external thread here or in posting — reply-only in sub-step E.

### Recompute the verdict from the *currently open* set

The verdict reflects the finding set at `HEAD` after reconciliation — i.e. carried-over + new findings that survived dedup (fixed plugin findings and suppressed duplicates no longer count). A re-review where the author fixed the last blocker should now produce `APPROVE`. External threads that are still open do **not** by themselves force `REQUEST CHANGES` unless the plugin also has a matching finding it is keeping; they are advisory context.

---

# Applying Fixes (Fix Mode Only)

Only enter this section when running in fix mode (invocation includes `--fix` or explicit fix instruction). Otherwise skip directly to Posting the Review.

### 1. Apply fixes locally

Use `Write` or `Bash` to edit the affected files. Use `git show HEAD:<filepath>` or `Read` to read the full current file content before editing. Only fix CRITICAL and WARNING issues — do not auto-fix suggestions.

### 2. Commit the changes

```bash
git add <file>
git commit -m "fix: <short description of what was fixed>"
```

One commit per logical fix. Commit message format: `fix: <description>`.

### 3. Push to the PR branch

The run executes in a temporary Docker container with no stored git credentials, and the `PreToolUse` hook cannot export variables into your shell (it only validates that the token exists). **Run `scripts/push-fixes.sh` as one Bash call** — do not invent credential helpers that write tokens to disk or echo them into the transcript:

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
# Optional: --branch <name> when HEAD is detached and /tmp/pr_state.env lacks PR_HEAD_BRANCH
bash "$CLAUDE_PLUGIN_ROOT/scripts/push-fixes.sh"
```

The script scopes the token to a single `git push` via `GIT_CONFIG_*` — nothing is written to disk or `~/.gitconfig`.

### 4. Post a fix summary comment

Post a comment listing:
- Which issues were auto-fixed (with file and line references)
- Which issues still require manual attention

Use the platform-appropriate method from the Posting the Review section below with event `COMMENT`.

---

# Posting the Review

After compiling the report (and applying fixes if in fix mode), post it to the platform detected in Step 1 immediately without waiting for user input. Posting has the sub-steps below; all are mandatory when the platform supports them and the run is incomplete if any are skipped. Sub-steps **R** and **R2** run only in re-review mode. Sub-step **E** runs whenever `/tmp/pr_external_reconcile.json` has an non-empty `addressed` list.

| # | Sub-step | GitHub | Azure DevOps | Generic |
|---|---|---|---|---|
| A | Cast the verdict / vote | `gh pr review` flag | `PUT .../reviewers/{id}` with vote | n/a |
| B | Post the full report body (incl. delta) as one PR-level comment, **with the summary marker** | `gh pr review --body` | `POST .../threads` (no `threadContext`) | write to `pr-review-report.md` |
| R | **Re-review only:** reconcile prior **plugin** findings — resolve **Fixed** threads (with a reply), leave **Carried-over** threads open (no duplicate) | reply + `resolveReviewThread` (GraphQL) | reply + `PATCH .../threads/{id}` `status:fixed` | n/a |
| R2 | **Re-review only:** reactivate **Reopened** threads (a prior resolved finding whose `fid` reproduced again) — reply with a regression warning, unresolve | reply + `unresolveReviewThread` (GraphQL) | reply + `PATCH .../threads/{id}` `status:active` | n/a |
| E | Reply on **addressed external** open threads (reply only — **never resolve**) | reply via `.../comments/{id}/replies` | reply via `POST .../threads/{id}/comments` | n/a |
| C | Post **one inline thread per finding** (initial mode: every surviving finding; re-review mode: **only the New bucket** after dedup), **each with a finding marker** | `gh api .../pulls/<n>/comments` per finding | `POST .../threads` with `threadContext` per finding | n/a (skip with note) |

**C is not optional** when there are findings to post (initial mode: all findings with `path/to/file.ext:NN` after dedup; re-review mode: the New bucket after dedup). The whole point of the specialized reviewers is to surface findings inline next to the offending code; collapsing them into the summary thread defeats the plugin's value. If you find yourself about to print "Review posted" without having posted the due inline comments, stop and go back to sub-step C.

**Every comment the plugin posts in B and C must carry its marker** (summary marker on B, finding marker with the finding's `fid` on C — see *Comment markers and finding identity*). A run that posts comments without markers breaks the next re-review (it will re-post everything as duplicates). The provider files show exactly where the marker goes for each call.

### Sub-step R — reconcile prior findings (re-review mode only)

Skip in initial mode and on the generic platform. Drive this from `/tmp/pr_reconcile.json` (built in step 7):

- **Fixed** (`fixed[]`): for each, post a short reply on the existing thread — e.g. `✅ Resolved as of \`<HEAD_SHA>\`` — then mark the thread resolved/fixed. Use the platform mechanics in the provider file's *Reconciling prior findings* section.
- **Carried-over** (`carried_over[]`): take **no** action. The thread is already open; do not reply on every run (avoid notification spam) and never re-post the finding as a new thread.

Track a counter (`RESOLVED_OK` / `RESOLVED_FAIL`) the same way inline posting does, and include resolved-count in the final confirmation line.

### Sub-step R2 — reactivate reopened findings (re-review mode only)

Skip in initial mode and on the generic platform. Drive this from `/tmp/pr_reconcile.json`'s `reopened[]` array (built in step 7) — a finding whose `fid` was previously marked resolved/fixed on the platform but reproduced again in this run's scan. This is a **regression signal** and is expected to be rare.

- For each entry in `reopened[]`, post a reply on the existing thread — `⚠️ This finding still reproduces as of \`<HEAD_SHA>\` despite being marked resolved. Reactivating.` — with a `kind=reopen` marker, then reactivate the thread (unresolve on GitHub, `status:active` on Azure DevOps).

Track `REOPENED_OK` / `REOPENED_FAIL`. **Always** include the reopened count in the final confirmation line when `REOPENED_OK > 0` — unlike Carried-over, this should stand out rather than blend into ordinary re-review noise.

### Sub-step E — reply on addressed external threads

Skip on the generic platform and when `/tmp/pr_external_reconcile.json` is missing or `addressed` is empty. Drive this from that file (built in step 7):

- For each entry in `addressed[]`, post a short reply on the existing thread, e.g. `Looks addressed as of \`<HEAD_SHA>\` — leaving this thread open for the original author to resolve.`
- **Do not** resolve, close, or set status to `fixed` on these threads. Resolution belongs to the original author.
- **Do not** reply on `still_open[]` (avoid notification spam every run).

Track `EXTERNAL_REPLY_OK` / `EXTERNAL_REPLY_FAIL`. Use the provider file's *Replying on addressed external threads* section.

### Resolve every finding to a post-change file line (do this before sub-step C)

Both GitHub (`gh api .../comments --field line=NN --field side=RIGHT`) and Azure DevOps (`threadContext.rightFileStart.line`) anchor inline comments to the line number **in the new (post-change) version of the file** — not the line's position within the diff. Mis-anchored comments either land on the wrong line or are rejected (GitHub `422`, Azure DevOps `400`).

In most cases the number is already correct and validated — it was read from the margin of `/tmp/pr_full_diff_numbered.patch` by the reviewers and checked again in step 7's "Validate every finding's line number" step. Do **not** recompute it with hunk arithmetic. Only fall back to manual resolution when a finding somehow arrived without a validated line:

1. Find the flagged line in `/tmp/pr_full_diff_numbered.patch`; the number printed left of the `|` **is** the post-change file line. (The annotator already did the `<newStart>` + offset counting for you, so there is no arithmetic to redo.)
2. If a finding sits on a deleted line (marked `- |`, no surviving `+`/context line), anchor it to the nearest surviving numbered line in the same hunk and note the relocation in the comment body.
3. Confirm the resolved `path` is repo-relative (matches an entry in `/tmp/pr_changed_files.txt`) and the line is within the file's new length (`git show ${HEAD_SHA}:<file> | wc -l`).

### Handle suggestion blocks (enables "Apply suggestion" / "Commit suggestion" button on GitHub)

Sub-agents emit ` ```suggestion ` blocks directly in their finding output (prefixed with an `<!-- suggestion: line NN -->` or `<!-- suggestion: lines NN-MM -->` HTML comment). Include the finding body **verbatim** in the JSONL — the ` ```suggestion ` block is already in the right format for GitHub and no text transformation is needed.

For each finding that contains a suggestion block:

1. Parse the line range from the HTML comment immediately before the ` ```suggestion ` fence:
   - `<!-- suggestion: line NN -->` → single-line: `suggestion_start_line = NN`, `suggestion_end_line = NN`
   - `<!-- suggestion: lines NN-MM -->` → multi-line: `suggestion_start_line = NN`, `suggestion_end_line = MM`
2. Include those values as `suggestion_start_line` / `suggestion_end_line` in the JSONL entry — the posting loop uses them to set `start_line` in the GitHub API call for multi-line suggestions.
3. Copy the **entire finding body verbatim** (including the HTML comment and the ` ```suggestion ` block) into the JSONL `body` field. **Do not strip or transform it.** GitHub renders the ` ```suggestion ` block as the "Commit suggestion" button automatically.

If a finding has no ` ```suggestion ` block, omit `suggestion_start_line` and `suggestion_end_line`. The body is still copied verbatim.

The reviewers were already instructed (step 6) to return post-change line numbers, but verify here — a wrong line number is the single most common cause of silently dropped inline comments.

Read and follow the instructions in the appropriate provider file — prefer the **plugin scripts** as one Bash call:
- **GitHub** → run `scripts/gh-post-review.sh --verdict "<VERDICT>" --mode "<REVIEW_MODE>" --pr <N>` (see `providers/github.md` → *Posting the final review*). Ensure `/tmp/pr_thread_body.md` and `/tmp/pr_inline_findings.jsonl` exist. Do **not** invent ad-hoc `gh api` loops.
- **Azure DevOps** → run `scripts/ado-post-review.sh --verdict "<VERDICT>" --mode "<REVIEW_MODE>" --pr <N>` (see `providers/azure-devops.md` → *Posting the Review*). Ensure `/tmp/pr_thread_body.md` and `/tmp/pr_inline_findings.jsonl` exist. Do **not** invent a shortened curl script — bare custom thread properties are a common cause of the summary comment never appearing. Never hand-build URLs with `AZURE_DEVOPS_ORG` / `PR_NUMBER` — use `source /tmp/pr_azure.env` and pass `--pr`.
- **Bitbucket or Unknown Platform** → `providers/generic.md`

> **Blocking vs non-blocking on CRITICAL findings:** by **default** a `REQUEST CHANGES` verdict is posted as a *non-blocking* review (GitHub `--comment`, Azure DevOps vote `-5`) so the plugin runs in advisory / shadow mode out of the box. To make `REQUEST CHANGES` *blocking* (GitHub `--request-changes`, Azure DevOps vote `-10`), set `PR_REVIEWER_BLOCK_ON_CRITICAL=true`. Verdict, report body, and inline comments are identical in both modes — only the platform-side review type changes. Provider files contain the exact mapping logic.

### Post-posting self-check (do this before printing the confirmation line)

Determine `EXPECTED_INLINE`: in **initial mode** it is the count of findings in the report with a `path/to/file.ext:NN` reference (sum across Critical Issues, Warnings, Suggestions); in **re-review mode** it is the size of the **New** bucket only (carried-over findings are intentionally not re-posted). Then compare against the inline-thread counter exported by the provider (`INLINE_OK` on Azure DevOps; the count of successful `gh api .../comments` POSTs on GitHub).

- If `INLINE_OK` is `0` and `EXPECTED_INLINE` is `> 0`: posting failed silently. Surface the failure log (`/tmp/pr_inline_failures.log` on Azure DevOps) and treat the run as a partial failure.
- If `INLINE_OK` is much smaller than `EXPECTED_INLINE`: read the failure log and either retry the failed ones or include them in the output diagnostic.

After posting, output a single confirmation line that uses the **actual** inline count, not a hard-coded one. In re-review mode also report the reconciliation outcome. When external replies ran, include that count too:

```
# initial mode
Review posted on PR #<number>: <verdict> — <INLINE_OK>/<EXPECTED_INLINE> inline comments — <EXTERNAL_REPLY_OK> external replies — <URL>

# re-review mode
Re-review posted on PR #<number>: <verdict> — <INLINE_OK>/<EXPECTED_INLINE> new — <RESOLVED_OK> resolved — <carried_over count> still open — <EXTERNAL_REPLY_OK> external replies — <URL>
```

Omit the `external replies` segment when `EXTERNAL_REPLY_OK` is unset or 0 and there was nothing to address. **Never omit the reopened count when `REOPENED_OK > 0`** — append `— ${REOPENED_OK} reopened (regression)` to the re-review line in that case; omit it entirely when zero (a regression signal should stand out, not clutter every ordinary re-review).

If `MARKER_VERIFY_FAILED` (from the posting script's post-POST audit) is non-zero, append a line: `WARN: ${MARKER_VERIFY_FAILED} posted comment(s) failed marker verification — re-review detection for those findings may fail next run.`

If `INLINE_OK < EXPECTED_INLINE`, append a second line:

```
WARN: <EXPECTED_INLINE - INLINE_OK> inline comment(s) failed to post — see /tmp/pr_inline_failures.log
```

If posting is not possible (generic/unknown platform), output:

```
Review complete: <verdict> — report written to pr-review-report.md
```
