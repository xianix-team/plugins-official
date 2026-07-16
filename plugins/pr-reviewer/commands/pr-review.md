---
name: pr-review
description: Run a full PR review. Analyzes code quality, security, tests, and performance. Works with GitHub, Azure DevOps, Bitbucket, and any git repository. Usage: /pr-review [PR number, PR URL, branch name, or leave blank for current branch]
argument-hint: [pr-number | pr-url | branch-name]
---

Run a comprehensive pull request review for $ARGUMENTS.

## You are the review lead — run this yourself, do NOT delegate to an orchestrator sub-agent

**Critical execution rule (read first).** You, the top-level agent, perform the orchestration described below directly. The specialized reviews (`code-reviewer`, and whichever of `security-reviewer`, `test-reviewer`, `performance-reviewer` apply per the step 5 gate) are run by spawning those sub-agents **from here, in the main context**.

Do **not** spawn a separate `orchestrator` / "PR review" sub-agent and ask *it* to run the reviewers. A sub-agent cannot spawn further sub-agents — in the Claude Agent SDK that fails with `No such tool available: Task. Task is not available inside subagents`, the parallel review silently degrades, and the report never gets posted. The fan-out in **Step 6** only works when it is emitted from the top-level agent, which is you.

Execute every step below autonomously and in order. Do not ask for confirmation, clarification, or approval at any point. If a step fails, output a single error line describing what failed and stop — except where a step explicitly says "warn and continue".

**Fix mode vs report mode:** if the invocation includes a `--fix` flag or the instruction explicitly says to fix issues, apply fixes and push (see *Applying Fixes*). Otherwise, compile and post the review report only.

**Re-review awareness (first review vs. follow-up review).** Before reviewing, the command checks whether *this plugin* has already reviewed the PR (it stamps every comment it posts with a hidden marker — see *Comment markers* below). If a prior review is found, the run switches to **re-review mode**: it reconciles old findings against the current head (resolving the ones the author fixed, leaving the unresolved ones open without re-posting duplicates), focuses on the commits pushed since the last review, and posts a short re-review delta instead of a brand-new wall of comments. The first review of a PR always runs in **initial mode**. This is automatic; no flag is required. Set `PR_REVIEWER_RECONCILE=false` to force a full, stateless review that ignores prior findings.

**This only works if the correct PR is identified in the first place.** Resolve `$ARGUMENTS` into `PR_NUMBER`/`BRANCH_ARG` (used in step 1's setup script) before doing anything else, since getting the *wrong* PR silently produces the wrong review mode too (a fresh PR with no markers of its own looks like `initial` even if you meant to re-review something else). Accept, in order:

1. **A PR URL** — e.g. `https://github.com/acme/widgets/pull/123` or `https://dev.azure.com/org/project/_git/repo/pullrequest/456`. This is the shape pasted when triggering a re-review from an Agent Studio chat message — extract the PR number from the URL itself into `PR_NUMBER`; the owner/repo/org/project always come from this workspace's own git remote (step 1's platform detection), never from the pasted URL, so a URL for a different fork can't redirect the review elsewhere.
2. **A bare PR number** → `PR_NUMBER`.
3. **A branch name** → `BRANCH_ARG`.
4. **Nothing** — a PR-comment-triggered run, where the executor should already have the right ref checked out; leave both unset so step 1 resolves from the currently checked-out branch.

Note which of these resolved it (`chat-url` | `chat-number` | `explicit-branch` | `current-branch`) and mention it in your final digest — useful for confirming *why* a given PR was picked when debugging a report that landed somewhere unexpected.

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
<!-- pr-reviewer:v1.2 kind=<finding|summary> fid=<finding-id> sha=<HEAD_SHA> -->
```

- `kind` — `finding` for an inline finding thread, `summary` for the PR-level report comment.
- `fid` — the stable finding id (below). Omit for `kind=summary`.
- `sha` — the `HEAD_SHA` the comment was generated against (lets the next run compute the incremental range).

On **GitHub** the marker is an HTML comment appended to the comment body — it renders invisibly. On **Azure DevOps**, HTML comments are *not* reliably hidden, so the same fields are stored as thread **`properties`** (`pr-reviewer.kind`, `pr-reviewer.fid`, `pr-reviewer.sha`) instead of in the body. The provider files show the exact mechanics.

**Version history:** `v1` markers (from prior plugin runs) will no longer be recognized as plugin-owned findings after this upgrade. PRs with open `v1`-marked threads will run one full initial-mode pass on their next review, fully re-scanning and re-posting all findings. This is a one-time cost; subsequent re-reviews on those PRs will behave normally with `v2` markers. This version bump is necessary to fix a flaw in the `v1` formula (see below).

**Plugin-owned threads** (carrying this marker) are the only ones the plugin may **resolve**. On re-review, fixed plugin findings get a reply and the thread is marked resolved — same as before.

**External threads** (humans, other bots, unmarked comments) are never resolved by this plugin. When an open external thread looks addressed at `HEAD`, the plugin may **reply** that it appears fixed and leave the thread open for the original author. Still-open external threads are left untouched (no reply every run — avoid notification spam). All open inline threads — plugin and external — are used for awareness and dedup so the plugin does not re-post the same finding.

### 2. The finding id `fid` (matches a finding across revisions)

`fid` must be **deterministic** and **independent of line number** (lines drift as the author edits) — and, critically, independent of anything an LLM has to reproduce identically across separate runs. Compute it from three inputs, none of which is free text you write: the file path, the literal source line the finding is anchored to (read directly off disk, never typed by you or the sub-agent), and an occurrence index to disambiguate identical lines:

```bash
# fid = first 12 hex of sha1( lowercased repo-relative path + "|" + normalised on-disk snippet + "|" + occurrence_index )
# Normalisation: lowercase, keep [a-z0-9 ], collapse runs of whitespace, trim.
# occurrence_index: 1-based rank among all findings in THIS RUN that share (path, normalized snippet),
#   ordered by ascending post-change line number. Deterministically breaks ties when multiple identical
#   lines are flagged in the same file (e.g., two empty catch blocks).
compute_fid() {  # args: <file> <on-disk-snippet-text> <occurrence-index>
  python3 - "$1" "$2" "$3" <<'PY'
import sys, re, hashlib
path = sys.argv[1].strip().lower()
snippet = re.sub(r'[^a-z0-9 ]', ' ', sys.argv[2].lower())
snippet = re.sub(r'\s+', ' ', snippet).strip()
occurrence = sys.argv[3].strip()
print(hashlib.sha1(f"{path}|{snippet}|{occurrence}".encode()).hexdigest()[:12])
PY
}
```

To get the snippet: after resolving the finding to its post-change file/line (see "Validate every finding's line number" below), read that exact line's literal text off disk — `git show ${HEAD_SHA}:<file> | sed -n "${NN}p"` — and pass it as `<on-disk-snippet-text>`. To compute `occurrence_index`: after gathering all current findings, group them by `(file, normalized_snippet)`, sort each group by post-change line number ascending, and assign a 1-based rank within each group. **Never** use the reviewer's free-text issue sentence as fid input.

Why this design: an earlier version hashed `file + issue summary sentence`, but that sentence is regenerated by an LLM sub-agent on every run — if a re-review's finder phrased the same bug even slightly differently, the fid changed and the finding was reposted as a duplicate instead of recognized as carried-over. The `v1` formula then added `category` to handle same-line collisions, but category is equally unstable — the same underlying bug can be independently tagged by different agents (or the same agent on different runs) under different concern categories, invalidating the fid without any code change. The `v2` formula drops category and instead uses structural identity (`path|snippet`) to anchor the fid, plus an occurrence index (mechanical, deterministic) to disambiguate when identical code patterns are flagged multiple times in the same file. This makes fids stable as long as the flagged snippet itself doesn't change, regardless of how many times that pattern appears or how any sub-agent describes it in prose.

---

# Procedure

When invoked with a PR number, branch name, or no argument (defaults to current branch vs main):

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

### Clear stale state files before this run

Immediately after platform detection, clean up any leftover state from a prior run that may have failed or run against a different PR in a reused container/session:

```bash
rm -f /tmp/pr_review_state.json /tmp/pr_reconcile.json /tmp/pr_external_reconcile.json \
      /tmp/pr_prior_findings.jsonl /tmp/pr_open_threads.jsonl /tmp/pr_inline_findings.jsonl \
      /tmp/pr_thread_body.md /tmp/pr_review_summary.md /tmp/pr_findings.jsonl
```

This prevents a prior run's state (with a different HEAD_SHA or even a different PR) from leaking into this run's reconciliation logic.

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

## 2. Post a "Review in Progress" Comment (must be within the first 3 tool calls)

Immediately after platform detection, post a comment so the PR author knows the review has started. **Do not read any files, do not run `find`/`ls`, do not index the codebase before this step.**

Use the platform-appropriate method — each provider's starting-comment block is **self-contained** (run it as one `Bash` call; do not invent a shortened version):
- **GitHub:** `gh pr comment` — see `providers/github.md` → *Posting the "review in progress" comment*
- **Azure DevOps:** run the **entire** script in `providers/azure-devops.md` → *Posting the Starting Comment* (it parses the remote, resolves `PR_ID`, posts the thread, and writes `/tmp/pr_azure.env`). Set `PR_NUMBER` from the numeric argument first when one was provided.
- **Generic / unknown platform:** Skip — no API available

Resolve the PR number from the argument first; only fall back to a CLI lookup (`gh pr list` on GitHub, or the branch lookup inside the Azure starting-comment script) if it was not provided.

If posting the starting comment fails, output a single warning line and continue — do not stop the review.

### Self-check before continuing to Step 3

Your conversation history should contain either:
- A successful tool output containing `Review-in-progress comment posted on PR #<n>` (starting comment was posted), or
- An explicit `WARN: ... skipping review-in-progress comment` line (starting comment was intentionally skipped on a platform that doesn't support it, like generic git).

If neither appears in your conversation history, you skipped Step 2. Go back and run the starting-comment script now for your platform before proceeding to Step 3.

## 3. Gather PR Context (do this BEFORE indexing the codebase)

The diff is what matters. Resolve the base/head and pull the diff first — for small PRs (≤10 changed files), this is *all* the context the sub-agents need, and the codebase index in step 4 can be skipped entirely.

### Run the setup script (ONE bash call — mandatory)

> **Shell state does not persist between tool calls.** Each `Bash` invocation starts a fresh shell — variables like `HEAD_SHA` from a prior call are **gone**. This script resolves checkout, base/head SHAs, diffs, and the numbered patch in one shot, then writes everything to `/tmp/pr_state.env`. In any later bash block that needs these values, run `source /tmp/pr_state.env` first. Never assume a variable from a prior tool call still exists.

> **Xianix Executor / CI worktrees:** the runner checks out the repo's **default branch** only — it knows nothing about PRs. When a PR number is provided, this script is a **hard gate**. You must see `Checked out PR #<n> at <sha>` (or branch checkout) in the output before proceeding. If `HEAD_SHA` does not match the platform's `headRefOid`, the script exits with an error.

Set `PR_NUMBER` (numeric argument, if any) and `BRANCH_ARG` (branch name argument, if any) before running. You may leave `PLATFORM` unset — the script always resolves it from `origin` and normalizes executor aliases such as `azuredevops`. Canonical values inside the script are only `github`, `azure`, or `generic`. Then execute this **entire** script as a single `Bash` call:

```bash
set -euo pipefail

# --- 0. Resolve PLATFORM from origin (authoritative). Never default to github. ---
# Xianix Executor injects PLATFORM=azuredevops; normalize aliases, then prefer origin.
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
[ -n "$REMOTE_URL" ] || { echo "ERROR: no git remote 'origin' — cannot detect platform"; exit 1; }
case "$REMOTE_URL" in
  *github.com*) DETECTED=github ;;
  *dev.azure.com*|*visualstudio.com*) DETECTED=azure ;;
  *) DETECTED=generic ;;
esac
# Strip case/hyphen/underscore so azuredevops, azure-devops, azure_devops, ADO → azure
PLATFORM_HINT_RAW="${PLATFORM:-}"
case "$(printf '%s' "$PLATFORM_HINT_RAW" | tr '[:upper:]' '[:lower:]' | tr -d '_-')" in
  azuredevops|ado|azure) PLATFORM_HINT=azure ;;
  github|gh) PLATFORM_HINT=github ;;
  bitbucket|generic) PLATFORM_HINT=generic ;;
  "") PLATFORM_HINT="" ;;
  *) PLATFORM_HINT="$PLATFORM_HINT_RAW" ;;
esac
if [ -n "$PLATFORM_HINT" ] && [ "$PLATFORM_HINT" != "$DETECTED" ]; then
  echo "WARN: PLATFORM hint '${PLATFORM_HINT_RAW}' (normalized=${PLATFORM_HINT}) disagrees with origin (${DETECTED}) — using origin" >&2
fi
PLATFORM="$DETECTED"
export PLATFORM
echo "PLATFORM=${PLATFORM} (from origin; env hint was '${PLATFORM_HINT_RAW:-unset}')"
CHECKED_OUT=""

# --- 1. Checkout the revision under review ---
if [ -n "${PR_NUMBER:-}" ]; then
  case "$PLATFORM" in
    azure*) CANDIDATE_REFS="refs/pull/${PR_NUMBER}/merge refs/pull/${PR_NUMBER}/head" ;;
    *)      CANDIDATE_REFS="refs/pull/${PR_NUMBER}/head refs/pull/${PR_NUMBER}/merge" ;;
  esac
  for ref in $CANDIDATE_REFS; do
    if git fetch origin "$ref" 2>/dev/null; then
      git checkout --detach FETCH_HEAD
      CHECKED_OUT="$ref"
      break
    fi
  done
  if [ -z "$CHECKED_OUT" ]; then
    echo "WARN: no synthetic PR ref found — resolving source branch via platform API"
    case "$PLATFORM" in
      azure*)
        if [ -f /tmp/pr_azure.env ]; then
          # shellcheck disable=SC1091
          source /tmp/pr_azure.env
        fi
        if [ -z "${API_BASE:-}" ] || [ -z "${AZURE_REPO:-}" ]; then
          REMOTE=$(git remote get-url origin)
          if echo "$REMOTE" | grep -qE '(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)'; then
            V3_PATH=$(echo "$REMOTE" | sed -E 's|^ssh://||; s|^[^@]+@||; s|^[^:/]+[:/]+||')
            REMOTE="https://dev.azure.com/$(echo "$V3_PATH" | cut -d/ -f2)/$(echo "$V3_PATH" | cut -d/ -f3)/_git/$(echo "$V3_PATH" | cut -d/ -f4)"
          fi
          REMOTE_CLEAN=$(echo "$REMOTE" | sed -E 's|https?://[^@]+@|https://|; s|\.git$||')
          AZURE_HOST=$(echo "$REMOTE_CLEAN" | awk -F/ '{print $3}')
          PATH_PARTS=$(echo "$REMOTE_CLEAN" | awk -F/ '{for (i=4; i<=NF; i++) print $i}')
          GIT_LINE=$(echo "$PATH_PARTS" | grep -nx '_git' | head -1 | cut -d: -f1 || true)
          [ -n "$GIT_LINE" ] || { echo "ERROR: not an Azure DevOps git URL"; exit 1; }
          AZURE_PROJECT=$(echo "$PATH_PARTS" | sed -n "$((GIT_LINE - 1))p")
          AZURE_REPO=$(echo    "$PATH_PARTS" | sed -n "$((GIT_LINE + 1))p")
          if [ "$AZURE_HOST" = "dev.azure.com" ]; then
            AZURE_ORG=$(echo "$PATH_PARTS" | sed -n '1p'); PREFIX_START=2
            HOST_AND_ORG_PATH="https://dev.azure.com/${AZURE_ORG}"
          else
            AZURE_ORG=$(echo "$AZURE_HOST" | cut -d'.' -f1); PREFIX_START=1
            HOST_AND_ORG_PATH="https://${AZURE_HOST}"
          fi
          PROJECT_LINE=$((GIT_LINE - 1))
          if [ "$PROJECT_LINE" -gt "$PREFIX_START" ]; then
            AZURE_COLLECTION=$(echo "$PATH_PARTS" | sed -n "${PREFIX_START},$((PROJECT_LINE - 1))p" | tr '\n' '/' | sed 's|/$||')
            API_BASE="${HOST_AND_ORG_PATH}/${AZURE_COLLECTION}/${AZURE_PROJECT}"
          else
            API_BASE="${HOST_AND_ORG_PATH}/${AZURE_PROJECT}"
          fi
        fi
        PR_ID="${PR_ID:-${PR_NUMBER:-}}"
        if [ -z "$PR_ID" ] || [ -z "${API_BASE:-}" ] || [ -z "${AZURE_REPO:-}" ]; then
          echo "ERROR: Azure checkout fallback needs PR_NUMBER and a parsed API_BASE/AZURE_REPO"
          exit 1
        fi
        SRC=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
          "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1" \
          | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sourceRefName','').replace('refs/heads/',''))")
        [ -n "$SRC" ] || { echo "ERROR: could not resolve Azure PR source branch for PR #${PR_ID}"; exit 1; }
        git fetch origin "refs/heads/${SRC}"
        git checkout --detach FETCH_HEAD
        CHECKED_OUT="refs/heads/${SRC}"
        ;;
      *)
        SRC=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')
        git fetch origin "refs/heads/${SRC}"
        git checkout --detach FETCH_HEAD
        CHECKED_OUT="refs/heads/${SRC}"
        ;;
    esac
  fi
  echo "Checked out PR #${PR_NUMBER} via ${CHECKED_OUT} at $(git rev-parse HEAD)"
elif [ -n "${BRANCH_ARG:-}" ]; then
  git fetch origin "$BRANCH_ARG"
  git checkout --detach FETCH_HEAD
  CHECKED_OUT="refs/heads/${BRANCH_ARG}"
  echo "Checked out branch ${BRANCH_ARG} at $(git rev-parse HEAD)"
fi

# --- 2. Resolve target branch name ---
if [ -n "${PR_NUMBER:-}" ]; then
  case "$PLATFORM" in
    azure*)
      if [ -f /tmp/pr_azure.env ]; then
        # shellcheck disable=SC1091
        source /tmp/pr_azure.env
      fi
      if [ -z "${API_BASE:-}" ] || [ -z "${AZURE_REPO:-}" ]; then
        echo "WARN: /tmp/pr_azure.env incomplete — re-parsing remote for Azure metadata"
        REMOTE=$(git remote get-url origin)
        if echo "$REMOTE" | grep -qE '(ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)'; then
          V3_PATH=$(echo "$REMOTE" | sed -E 's|^ssh://||; s|^[^@]+@||; s|^[^:/]+[:/]+||')
          REMOTE="https://dev.azure.com/$(echo "$V3_PATH" | cut -d/ -f2)/$(echo "$V3_PATH" | cut -d/ -f3)/_git/$(echo "$V3_PATH" | cut -d/ -f4)"
        fi
        REMOTE_CLEAN=$(echo "$REMOTE" | sed -E 's|https?://[^@]+@|https://|; s|\.git$||')
        AZURE_HOST=$(echo "$REMOTE_CLEAN" | awk -F/ '{print $3}')
        PATH_PARTS=$(echo "$REMOTE_CLEAN" | awk -F/ '{for (i=4; i<=NF; i++) print $i}')
        GIT_LINE=$(echo "$PATH_PARTS" | grep -nx '_git' | head -1 | cut -d: -f1 || true)
        [ -n "$GIT_LINE" ] || { echo "ERROR: not an Azure DevOps git URL"; exit 1; }
        AZURE_PROJECT=$(echo "$PATH_PARTS" | sed -n "$((GIT_LINE - 1))p")
        AZURE_REPO=$(echo    "$PATH_PARTS" | sed -n "$((GIT_LINE + 1))p")
        if [ "$AZURE_HOST" = "dev.azure.com" ]; then
          AZURE_ORG=$(echo "$PATH_PARTS" | sed -n '1p'); PREFIX_START=2
          HOST_AND_ORG_PATH="https://dev.azure.com/${AZURE_ORG}"
        else
          AZURE_ORG=$(echo "$AZURE_HOST" | cut -d'.' -f1); PREFIX_START=1
          HOST_AND_ORG_PATH="https://${AZURE_HOST}"
        fi
        PROJECT_LINE=$((GIT_LINE - 1))
        if [ "$PROJECT_LINE" -gt "$PREFIX_START" ]; then
          AZURE_COLLECTION=$(echo "$PATH_PARTS" | sed -n "${PREFIX_START},$((PROJECT_LINE - 1))p" | tr '\n' '/' | sed 's|/$||')
          API_BASE="${HOST_AND_ORG_PATH}/${AZURE_COLLECTION}/${AZURE_PROJECT}"
        else
          API_BASE="${HOST_AND_ORG_PATH}/${AZURE_PROJECT}"
        fi
      fi
      PR_ID="${PR_ID:-${PR_NUMBER}}"
      if [ -z "$PR_ID" ] || [ -z "${API_BASE:-}" ] || [ -z "${AZURE_REPO:-}" ]; then
        echo "ERROR: Azure metadata needs PR_NUMBER and a parsed API_BASE/AZURE_REPO"
        exit 1
      fi
      PR_JSON=$(curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
        "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1")
      BASE=$(echo "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('targetRefName','').replace('refs/heads/',''))")
      PR_HEAD_BRANCH=$(echo "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sourceRefName','').replace('refs/heads/',''))")
      EXPECTED_HEAD=$(echo "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('lastMergeSourceCommit',{}).get('commitId',''))")
      PR_TITLE=$(echo "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('title',''))")
      PR_BODY=$(echo "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('description','') or '')")
      PR_AUTHOR=$(echo "$PR_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('createdBy',{}).get('displayName',''))")
      ;;
    *)
      PR_METADATA=$(gh pr view "$PR_NUMBER" --json baseRefName,headRefName,headRefOid,title,body,author)
      BASE=$(echo "$PR_METADATA" | jq -r '.baseRefName')
      PR_HEAD_BRANCH=$(echo "$PR_METADATA" | jq -r '.headRefName')
      PR_TITLE=$(echo "$PR_METADATA" | jq -r '.title')
      PR_BODY=$(echo "$PR_METADATA" | jq -r '.body // ""')
      PR_AUTHOR=$(echo "$PR_METADATA" | jq -r '.author.login')
      EXPECTED_HEAD=$(echo "$PR_METADATA" | jq -r '.headRefOid')
      ;;
  esac
else
  BASE=$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/","",$2); print $2}')
  : "${BASE:=main}"
  PR_TITLE=""
  PR_BODY=""
  PR_AUTHOR=""
  EXPECTED_HEAD=""
fi

# --- 3. Resolve HEAD_SHA and fetch fresh base tip ---
if [ "${CHECKED_OUT:-}" = "refs/pull/${PR_NUMBER:-}/merge" ]; then
  HEAD_SHA=$(git rev-parse HEAD^2)
else
  HEAD_SHA=$(git rev-parse HEAD)
fi

if [ -n "${PR_NUMBER:-}" ] && [ -n "${EXPECTED_HEAD:-}" ] && [ "$HEAD_SHA" != "$EXPECTED_HEAD" ]; then
  echo "ERROR: checked-out HEAD ($HEAD_SHA) does not match PR headRefOid ($EXPECTED_HEAD) — checkout failed"
  exit 1
fi

if git fetch origin "refs/heads/${BASE}" 2>/dev/null; then
  BASE_TIP=$(git rev-parse FETCH_HEAD)
else
  echo "WARN: could not fetch origin/${BASE} — falling back to local refs, base may be stale"
  BASE_TIP=""
  for candidate in "refs/remotes/origin/${BASE}" "refs/heads/${BASE}"; do
    git show-ref --verify --quiet "$candidate" && { BASE_TIP=$(git rev-parse "$candidate"); break; }
  done
fi
[ -n "$BASE_TIP" ] || { echo "ERROR: could not resolve base branch '${BASE}'"; exit 1; }

BASE_SHA=$(git merge-base "$BASE_TIP" "$HEAD_SHA")
echo "Base: $BASE (tip $BASE_TIP -> merge-base $BASE_SHA)"
echo "Head: $HEAD_SHA"

# --- 4. Sanity check commit count (GitHub only; skip azure/generic) ---
# Compare against canonical PLATFORM=github only — never treat azuredevops as GitHub.
if [ -n "${PR_NUMBER:-}" ] && [ "$PLATFORM" = "github" ]; then
  GIT_COMMIT_COUNT=$(git rev-list --count "${BASE_SHA}..${HEAD_SHA}")
  GH_COMMIT_COUNT=$(gh pr view "$PR_NUMBER" --json commits --jq '.commits | length')
  echo "Git commit count: $GIT_COMMIT_COUNT"
  echo "GitHub commit count: $GH_COMMIT_COUNT"
  if [ "$GIT_COMMIT_COUNT" -gt "$GH_COMMIT_COUNT" ]; then
    echo "ERROR: git reports more commits than GitHub — base is stale; re-fetch origin/${BASE} and retry"
    exit 1
  fi
  echo "✓ Commit count OK (git=$GIT_COMMIT_COUNT, github=$GH_COMMIT_COUNT)"
fi

# --- 5. Generate diffs and metadata ---
git log --oneline "${BASE_SHA}..${HEAD_SHA}"
git diff --stat "${BASE_SHA}"..."${HEAD_SHA}"
git diff --name-only "${BASE_SHA}"..."${HEAD_SHA}" | tee /tmp/pr_changed_files.txt
git diff "${BASE_SHA}"..."${HEAD_SHA}" > /tmp/pr_full_diff.patch
git log -1 --format="%an <%ae>" "${HEAD_SHA}"
git log --format="%s%n%b" "${BASE_SHA}..${HEAD_SHA}"

CHANGED_COUNT=$(wc -l < /tmp/pr_changed_files.txt | tr -d ' ')
echo "Changed files: $CHANGED_COUNT"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  CURRENT_BRANCH=$(git branch --contains "$HEAD_SHA" \
    | sed 's|^[* ] *||' | grep -v '^(' | head -1 || true)
fi

# --- 6. Annotate diff with post-change line numbers ---
awk '
  /^@@/ {
    s = substr($0, index($0, "+") + 1); newln = s + 0
    print "      | " $0; next
  }
  /^(diff |index |--- |\+\+\+ |new file|deleted file|similarity|rename |Binary )/ {
    print "      | " $0; next
  }
  /^\+/ { printf "%5d |+%s\n", newln, substr($0, 2); newln++; next }
  /^ /  { printf "%5d | %s\n", newln, substr($0, 2); newln++; next }
  /^-/  { printf "    - |-%s\n", substr($0, 2); next }
  { print "      | " $0 }
' /tmp/pr_full_diff.patch > /tmp/pr_full_diff_numbered.patch
echo "Annotated diff written: $(wc -l < /tmp/pr_full_diff_numbered.patch) lines"

# --- 7. Persist state for later tool calls ---
# Use printf %q so titles/bodies with spaces, quotes, or newlines survive `source`.
{
  echo "PLATFORM=$PLATFORM"
  echo "HEAD_SHA=$HEAD_SHA"
  echo "BASE_SHA=$BASE_SHA"
  echo "BASE=$BASE"
  echo "BASE_TIP=$BASE_TIP"
  echo "CHANGED_COUNT=$CHANGED_COUNT"
  echo "CHECKED_OUT=$CHECKED_OUT"
  printf 'PR_NUMBER=%q\n' "${PR_NUMBER:-}"
  printf 'CURRENT_BRANCH=%q\n' "${CURRENT_BRANCH:-}"
  printf 'PR_TITLE=%q\n' "${PR_TITLE:-}"
  printf 'PR_BODY=%q\n' "${PR_BODY:-}"
  printf 'PR_AUTHOR=%q\n' "${PR_AUTHOR:-}"
  printf 'PR_HEAD_BRANCH=%q\n' "${PR_HEAD_BRANCH:-}"
} > /tmp/pr_state.env
echo "State written to /tmp/pr_state.env"
```

> On **Azure DevOps** the `/merge` ref points at the PR's *merge commit*; its second parent (`HEAD^2`) is the real PR head. The script sets `HEAD_SHA` accordingly when `CHECKED_OUT=refs/pull/<n>/merge`.

Writing the diff to `/tmp/pr_full_diff.patch` lets you pass it by **path** to sub-agents instead of by value — much smaller prompts when the diff is large.

Each kept line in `/tmp/pr_full_diff_numbered.patch` looks like `  147 |+    var x = ParseSubject(dn);` — the number left of the `|` is the exact line to cite. Reviewers must **copy** this number, never recompute it.

> **Anti-pattern:** Do NOT `cat <<'DIFF_EOF' ... DIFF_EOF` the diff back to yourself in a subsequent `Bash` call. The diff is already in your conversation history once you ran the setup script. Echoing it back wastes a turn and tokens.

Use `git show ${HEAD_SHA}:<filepath>` or the `Read` tool to read the full content of any file that requires deeper analysis beyond the patch. Always `source /tmp/pr_state.env` first so `HEAD_SHA` is defined.

**Platform CLIs are not used in this diff step.** Use **`gh`** only when posting to GitHub and **`curl`/Azure DevOps REST** only when posting to Azure DevOps (see the provider docs and "Posting the Review" below).

### Detect a prior review and compute the re-review range

This is the one place reading platform PR comments is required, because it determines whether the run is an **initial** review or a **re-review**, and it loads open inline threads for awareness/dedup. Skip entirely on the generic platform (no API) and when `PR_REVIEWER_RECONCILE=false` (stateless mode also skips external-thread awareness).

1. Unless `PR_REVIEWER_RECONCILE=false` (or platform is generic), list the existing review comments/threads on the PR. **Run the platform script as one Bash call** — do **not** invent a shortened `curl`/`gh` dump (Azure agents inventing `THREADS_JSON=$(curl …)` then `json.load` is a common crash on 401 HTML).

   The script writes:
   - `/tmp/pr_prior_findings.jsonl` — only threads carrying the plugin marker (`<!-- pr-reviewer:v1.2 ... -->` on GitHub, or the `pr-reviewer.*` thread properties on Azure DevOps). Drives `REVIEW_MODE`.
   - `/tmp/pr_open_threads.jsonl` — **every open inline thread** (humans, bots, this plugin), one JSON object per line: `{file, line, body, author, is_plugin, thread_ref[, comment_ref]}`. Used for reviewer awareness, dedup, and external-thread validation.
   - `/tmp/pr_prior.env` — `PRIOR_SUMMARY_SHA` (shell state does not persist; always `source` this file afterward).

   | Platform | Script (one Bash call) |
   |---|---|
   | **GitHub** | `scripts/gh-detect-prior.sh` (see `providers/github.md` → *Detecting a prior review*) |
   | **Azure DevOps** | `scripts/ado-detect-prior.sh` (see `providers/azure-devops.md` → *Detecting a prior review*) |

   Resolve the script via `CLAUDE_PLUGIN_ROOT` the same way as `ado-post-review.sh`. If the script exits non-zero (missing token, HTTP 401, non-JSON body), **fix auth / env and re-run the script** — do not hand-roll a replacement curl.

2. Decide the mode:

```bash
source /tmp/pr_state.env
# shellcheck disable=SC1091
[ -f /tmp/pr_prior.env ] && source /tmp/pr_prior.env

# Mode-decision visibility: warn if detection never ran (missing prior.env)
# This distinguishes "we checked and found nothing" from "we never checked"
: "${PR_REVIEWER_RECONCILE:=true}"
if [ "$PR_REVIEWER_RECONCILE" != "false" ] && [ ! -f /tmp/pr_prior.env ]; then
  echo "WARN: /tmp/pr_prior.env missing — provider's detect-prior script was not run (or failed) before this mode decision. Proceeding as REVIEW_MODE=initial, but if a prior review actually exists on this PR, this run WILL post duplicate summary/findings. Re-run detection now if unsure." >&2
fi

# /tmp/pr_prior_findings.jsonl is written by the provider script: one JSON object per
# prior marked finding thread: {fid, status(open|resolved), thread_ref[, comment_ref]}.
# Matching is by fid alone, so file/line are not needed here.
# /tmp/pr_open_threads.jsonl is written by the same script (may be empty).
# Touch an empty file if the helper skipped writing it so later steps can test -s safely.
if [ "$PR_REVIEWER_RECONCILE" = "false" ]; then
  : > /tmp/pr_prior_findings.jsonl
  : > /tmp/pr_open_threads.jsonl
  : > /tmp/pr_prior.env
fi
[ -f /tmp/pr_open_threads.jsonl ] || : > /tmp/pr_open_threads.jsonl
# PRIOR_SUMMARY_SHA is the sha= from the most recent summary marker, or empty.
if [ "$PR_REVIEWER_RECONCILE" = "false" ] || [ ! -s /tmp/pr_prior_findings.jsonl ]; then
  REVIEW_MODE="initial"
  RANGE_BASE="$BASE_SHA"
else
  REVIEW_MODE="rereview"
  # New commits since the last review; fall back to BASE_SHA if the recorded sha is gone.
  if [ -n "${PRIOR_SUMMARY_SHA:-}" ] && git cat-file -e "${PRIOR_SUMMARY_SHA}^{commit}" 2>/dev/null; then
    RANGE_BASE="$PRIOR_SUMMARY_SHA"
  else
    RANGE_BASE="$BASE_SHA"
  fi
fi
OPEN_THREAD_COUNT=$(wc -l < /tmp/pr_open_threads.jsonl | tr -d ' ')
echo "Review mode: $REVIEW_MODE  |  incremental range: ${RANGE_BASE}..${HEAD_SHA}  |  open threads: ${OPEN_THREAD_COUNT}"
export REVIEW_MODE RANGE_BASE

# --- Write canonical review state (read by all providers) ---
# This ensures providers don't have to guess or make independent decisions
python3 - "$REVIEW_MODE" "${PRIOR_SUMMARY_SHA:-}" "$HEAD_SHA" "$RANGE_BASE" \
  "$([ "$PR_REVIEWER_RECONCILE" = "false" ] && echo false || echo true)" <<'PYTHON'
import json, sys, pathlib
mode, prior_sha, head_sha, range_base, reconcile = sys.argv[1:6]
state = {
    "mode": mode,
    "prior_sha": prior_sha or None,
    "head_sha": head_sha,
    "range_base": range_base,
    "reconcile_enabled": reconcile.lower() in ("true", "1", "yes"),
}
pathlib.Path("/tmp/pr_review_state.json").write_text(json.dumps(state, indent=2))
PYTHON
```

3. Capture the **incremental** diff (commits pushed since the last review) in addition to the full PR diff — it is what you skim first in re-review mode and what populates the "changed since last review" line in the delta:

```bash
source /tmp/pr_state.env
if [ "$REVIEW_MODE" = "rereview" ] && [ "$RANGE_BASE" != "$BASE_SHA" ]; then
  git log --oneline ${RANGE_BASE}..${HEAD_SHA}
  git diff ${RANGE_BASE}...${HEAD_SHA} > /tmp/pr_incremental_diff.patch
  echo "Incremental diff: $(wc -l < /tmp/pr_incremental_diff.patch) lines since last review"
fi
```

> **Why review the full PR diff, not just the increment?** The full diff (`/tmp/pr_full_diff.patch`) stays the authoritative input to the reviewers so the *current* finding set is always complete — an unresolved finding in a file the latest commits didn't touch must still be detected so it stays open. The incremental diff focuses your attention and drives the delta summary; it does not replace the full scan. Reconciliation (step 7 / posting) compares the current finding set to the prior one **by `fid`**, and also validates open external threads against `HEAD`.

### Cost gate: skip re-analysis entirely when HEAD hasn't moved (mandatory)

The mode decision above already has everything needed to recognize a **true no-op re-review**: `REVIEW_MODE=rereview` and `HEAD_SHA` identical to `PRIOR_SUMMARY_SHA`. When both hold, the diff, the codebase, and every open thread are byte-identical to what the last run already analyzed — nothing downstream can produce a different result. **Steps 4, 5, and 6 (codebase indexing, tier selection, and the sub-agent fan-out) are the expensive part of a review**, and running them here only re-derives a finding set that step 7's Gate A is guaranteed to fully discard as `carried_over`. That is pure wasted spend — do not run them.

```bash
source /tmp/pr_state.env
[ -f /tmp/pr_prior.env ] && source /tmp/pr_prior.env
if [ "$REVIEW_MODE" = "rereview" ] && [ -n "${PRIOR_SUMMARY_SHA:-}" ] && [ "$HEAD_SHA" = "$PRIOR_SUMMARY_SHA" ]; then
  echo "NO-OP: HEAD ($HEAD_SHA) unchanged since the last review — skipping codebase indexing, tier selection, and sub-agent review."
  export PR_REVIEWER_NOOP=true
else
  export PR_REVIEWER_NOOP=false
fi
```

**If `PR_REVIEWER_NOOP=true`:** do not proceed to step 4. No sub-agents, no report compilation, no reconciliation. Post one short acknowledgement reply and stop:

- **GitHub** — a plain issue comment, same mechanism as the starting comment (`providers/github.md` → *Posting the "review in progress" comment*):
  ```bash
  gh pr comment "$PR_NUMBER" --body "No new commits since the last review (\`${HEAD_SHA:0:7}\`) — nothing to re-analyze. Push a commit to trigger a fresh review."
  ```
- **Azure DevOps** — reply on the prior summary thread (`PRIOR_SUMMARY_THREAD_ID` from `/tmp/pr_prior.env`), using the same POST-to-`.../threads/{id}/comments` shape as *Replying on addressed external threads* in `providers/azure-devops.md`, with body `No new commits since the last review (\`${HEAD_SHA:0:7}\`) — nothing to re-analyze. Push a commit to trigger a fresh review.`
- **Generic** — no API; the `echo` above is the only output. Just stop.

Do **not** stamp this acknowledgement with the `pr-reviewer:v1.2 kind=summary` marker — it isn't a review and must never be mistaken for one by the next run's prior-summary lookup (which already resolves correctly to the existing summary at this same SHA).

Then output the final confirmation line and end the run:

```text
No-op re-review on PR #<number>: HEAD unchanged at <sha> since the last review — skipped re-analysis.
```

**If `PR_REVIEWER_NOOP=false`** (initial mode, or re-review with new commits): continue to step 4 as normal.

## 4. Index the Codebase (skip on small PRs)

Every line these commands print lands in your context and is paid for on every subsequent turn — keep the index small. The caps below are mandatory, not decorative.

```bash
source /tmp/pr_state.env
if [ "${CHANGED_COUNT:-0}" -le 10 ]; then
  echo "Small PR ($CHANGED_COUNT files) — skipping codebase index, diff alone is enough context."
else
  # Top-level layout
  ls -1

  # Source tree (depth 3, ignore common noise, HARD CAP at 200 lines)
  find . -maxdepth 3 \
    -name .git -prune -o \
    -name node_modules -prune -o \
    -name bin -prune -o \
    -name obj -prune -o \
    -name .vs -prune -o \
    -name dist -prune -o \
    -name build -prune -o \
    -print | sort | head -200

  # Language fingerprint (changed files only — the repo-wide walk is wasted tokens)
  sed 's/.*\.//' /tmp/pr_changed_files.txt | sort | uniq -c | sort -rn | head -10

  # Entry points / build manifests
  ls *.sln *.csproj package.json go.mod Cargo.toml pom.xml build.gradle \
     pyproject.toml setup.py requirements.txt CMakeLists.txt 2>/dev/null || true
fi
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
source /tmp/pr_state.env
RISK_PATH_RE='(auth|login|signin|session|password|passwd|secret|token|jwt|oauth|crypto|encrypt|decrypt|payment|billing|charge|invoice|checkout|migration|schema|\.sql$|webhook|/api/|/controllers?/|/routes?/|/handlers?/|iam|rbac|permission)'
RISK_CONTENT_RE='(password|secret|api[_-]?key|private[_-]?key|authorize|authenticate|hashpw|bcrypt|jwt|sql|exec\(|eval\(|subprocess|os\.system|pickle\.loads)'

REVIEW_TIER="haiku"
# 1. High-risk by file path — docs/images can never be a high-risk surface,
#    so exclude them before matching (a filename like docs/token-guide.md must
#    not escalate the whole run to the expensive specialist path).
if grep -ivE '\.(md|markdown|rst|txt|png|jpg|jpeg|gif|svg)$' /tmp/pr_changed_files.txt \
   | grep -qiE "$RISK_PATH_RE"; then
  REVIEW_TIER="specialists"
# 2. High-risk by changed content. '^\+[^+]' matches added lines ONLY — a bare
#    '^\+' also matches '+++ b/<path>' file headers, which escalates PRs whose
#    filenames merely contain words like "token" or "sql".
elif grep -E '^\+[^+]' /tmp/pr_full_diff.patch | grep -qiE "$RISK_CONTENT_RE"; then
  REVIEW_TIER="specialists"
fi

if [ "$REVIEW_TIER" = "specialists" ]; then
  echo "High-risk surface detected — escalating to specialist reviewers."
else
  echo "No high-risk surface — using low-cost Haiku finder path."
fi
export REVIEW_TIER
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
CATEGORY: correctness | security | performance | test-coverage | maintainability — pick whichever actually describes the issue, not just "whatever this agent usually finds"
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

**Verify and compile (you are the verifier — no extra agents).** For each finding from both agents: (1) confirm the flagged line appears in `/tmp/pr_full_diff_numbered.patch` as a `+` line (new code, not pre-existing) and that the reported `LINE` matches the number printed in that line's margin — **if the line number is missing, does not match the margin, or exceeds the file's length, correct it to the margin number of the flagged code before keeping the finding** (this is the guard against out-of-range citations like `:466` on a 322-line file); (2) discard pre-existing issues, linter/compiler-caught problems, pedantic style, and obvious false positives; (3) **group findings from both agents by `(file, post-change line)`.** Where two or more findings land on the same location — the two finders can independently flag the same line under different categories/severities — merge them into **one** finding: keep the single most specific `CATEGORY`, the highest severity among the duplicates, and fold any distinct detail from the merged `ISSUE` text into one body. Do not post the same location twice under different categories or severities. Then **cap at 8 findings**, ranked CRITICAL → WARNING → SUGGESTION; (4) **preserve the `SUGGESTION_START_LINE` / `SUGGESTION_END_LINE` / `SUGGESTION_CODE` fields verbatim** — they will be extracted in the "Extract suggestion annotations" step before posting and are what enables the GitHub "Commit suggestion" button. Then go to step 7.

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

In **one assistant turn**, emit one parallel sub-agent invocation per selected reviewer (between 1 and 4). Each invocation prompt must include, in addition to the two shared constraints above:

- The path `/tmp/pr_full_diff_numbered.patch` (the line-number-annotated diff — the authoritative source for `NN`) and the path `/tmp/pr_changed_files.txt`
- `BASE_SHA` and `HEAD_SHA`
- The PR title and description (from the platform metadata fetched in step 2)
- A file-reading constraint: *"When you need full file context, read only the enclosing function/class (±60 lines around each changed hunk). Do not read any file in its entirety if it exceeds 400 lines — use `Bash(sed -n '<start>,<end>p' <file>)` scoped to the changed region instead. Read at most 3 files beyond the diff."*

> **Pass-by-value vs path:** if `DIFF_LINES ≤ 300`, paste the contents of `/tmp/pr_full_diff_numbered.patch` **inline** in each prompt (cheaper than each sub-agent re-opening a shared file) — inline the *numbered* diff, not the raw one, so the line numbers travel with it; if `DIFF_LINES > 300`, pass the path `/tmp/pr_full_diff_numbered.patch`.

> **Model selection (mixed-model tiering).** The reviewers split into two model tiers so you don't pay frontier-model rates for the cheaper review dimensions. Set each sub-agent's `model` from its tier (per the table above), resolved with this precedence:
>
> 1. **`PR_REVIEWER_MODEL` (override).** If set, it pins **every** reviewer to that one model — backward-compatible escape hatch, ignores the tiers below.
> 2. Otherwise, per tier:
>    - **quality tier** (`code-reviewer`, `test-reviewer`) → `PR_REVIEWER_QUALITY_MODEL` if set, else `haiku`. These are pattern/coverage tasks that a small model handles well.
>    - **risk tier** (`security-reviewer`, `performance-reviewer`) → `PR_REVIEWER_RISK_MODEL` if set, else inherit (omit `model`). Vulnerability and performance reasoning is where frontier accuracy actually pays off — this path was chosen *because* the diff is high-risk.
>
> ```bash
> source /tmp/pr_state.env
> map_model_slug() {
>   case "$1" in
>     inherit|"") echo "" ;;
>     sonnet|opus|haiku|fable) echo "$1" ;;
>     *haiku*) echo "haiku" ;;
>     *sonnet*) echo "sonnet" ;;
>     *opus*) echo "opus" ;;
>     *) echo "haiku" ;;
>   esac
> }
> RISK_MODEL="${PR_REVIEWER_RISK_MODEL:-inherit}"
> QUALITY_MODEL="${PR_REVIEWER_QUALITY_MODEL:-haiku}"
> if [ -n "${PR_REVIEWER_MODEL:-}" ]; then
>   RISK_MODEL="$PR_REVIEWER_MODEL"; QUALITY_MODEL="$PR_REVIEWER_MODEL"
> fi
> QUALITY_SLUG=$(map_model_slug "$QUALITY_MODEL")
> RISK_SLUG=$(map_model_slug "$RISK_MODEL")
> echo "Reviewer models — quality: ${QUALITY_SLUG:-inherit} | risk: ${RISK_SLUG:-inherit}"
> ```
>
> Emit each reviewer in the **same assistant turn** with `subagent_type` set. Pass `"model": "<slug>"` only when the mapped slug is non-empty (`haiku` for quality tier; omit entirely for risk tier when `RISK_SLUG` is empty). **Never** pass `claude-haiku-4-5`, `inherit`, or any other string — those cause `InputValidationError`.
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
> For `security-reviewer` and `performance-reviewer`, omit `"model"` so they inherit the lead's model. Launch all selected reviewers in one turn — never sequentially.

Wait for all selected sub-agents to return, then go to step 7. **Do not** run `sed`/`git show`/`Read` on changed files yourself while waiting — that is simulating the reviewers (see anti-patterns below).

**Verify and compile (you are the verifier here too).** Each selected reviewer's output already carries a `[CATEGORY: ...]` tag per finding (see the agent definitions' output formats), chosen from the same closed enum independently of that agent's own specialty — e.g. `test-reviewer` may legitimately tag a finding `security`. This means the same line can be flagged more than once, by different specialists, under different categories and severities. Before writing `/tmp/pr_inline_findings.jsonl` (step 7): group all findings from all sub-agents that ran this pass by `(file, post-change line)`. Where two or more land on the same location, merge them into **one** finding: keep the single most specific category, the highest severity among the duplicates, and fold any distinct detail from the merged bodies into one. Do not post the same location twice under different categories or severities.

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

**Before posting (all platforms):** write the compiled report markdown to `/tmp/pr_thread_body.md` **using the `Write` tool**. Do not use a Bash heredoc. Also serialize every finding to post as one JSON object per line in `/tmp/pr_inline_findings.jsonl` (fields: `file`, `line`, `body`, `fid`, `snippet`, `occurrence_index`). Do **not** use alternate names like `pr_review_summary.md` or `pr_findings.jsonl` — the Azure posting script only auto-corrects those as a fallback.

**Guidelines:**
- Reference specific file paths and line numbers for every finding
- Include both the problematic code snippet and a concrete fix example
- Do not flag non-issues — only real problems and genuine improvements
- Tag findings that exist in the base branch (not introduced by this PR) as **pre-existing** — they may warrant a WARNING but must not alone drive a `REQUEST CHANGES` verdict
- Consider the PR's stated intent when evaluating trade-offs
- Group related issues together rather than repeating similar findings

### Validate every finding's line number against the file (MANDATORY — do this before writing the report)

This is the guard that keeps the **summary body** honest. Inline comments get a second chance to be corrected (GitHub `422`, Azure DevOps `400`, and the "Resolve every finding to a post-change file line" step), but the summary embeds the reviewer's `file:NN` text as-is — so an over-shot number like `:466` on a 322-line file sails straight into the report unless you check it here. Do the check **once**, and use the result for **both** the summary and the inline JSONL so they never disagree.

For each finding:

1. Compute the file's new-side length: `LINES=$(git show ${HEAD_SHA}:<file> | wc -l)`.
2. If `NN > LINES`, or the code at `<file>:NN` (`git show ${HEAD_SHA}:<file> | sed -n "${NN}p"`) does not contain the snippet the finding describes, the number is wrong. Re-anchor it: find the flagged line in `/tmp/pr_full_diff_numbered.patch` and use the number printed in its margin. If the finding is genuinely unlocatable in the new file (e.g. it only described deleted code), drop it rather than cite a fabricated line.
3. Carry the corrected `NN` into the report body **and** the inline JSONL — the summary line reference and the inline comment for the same finding must be identical.

A finding whose line cannot be validated to a real, in-range line in the changed file must not appear in the report with a made-up number.

### Assign a `fid` to every current finding

For each finding in the compiled report, compute its `fid` with the `compute_fid` helper (see *Comment markers and finding identity*) from its file path, the literal on-disk text of the flagged line (already read during line-number validation above — reuse it, don't re-fetch), and an occurrence index (1-based rank among all current findings with the same file and normalized snippet, ordered by line number). This is required in **both** modes — the marker written this run (`fid=` only, per the existing marker format) is what the *next* run reconciles against by fid equality; no other field needs to round-trip through the marker for this to work, since a future run recomputes its own current-state fid from file+snippet+occurrence the same way and simply compares the two hashes.

### Reconcile against the prior review (re-review mode only)

## 8. Execute the Posting Step (Immediately after compiling the report)

**Mandatory:** Post the review to the platform immediately. Do not wait for user input or confirmations. All findings are lost if posting is skipped.

### Load review state and execute platform-appropriate posting

```bash
# Load state written in step 3
source /tmp/pr_state.env 2>/dev/null || { echo "ERROR: /tmp/pr_state.env missing"; exit 1; }
source /tmp/pr_review_state.json >/dev/null 2>&1 || true  # optional: for inspection
export VERDICT  # Must be set before posting (from step 7)

# Verify prerequisites
[ -f /tmp/pr_thread_body.md ] || { echo "ERROR: /tmp/pr_thread_body.md missing"; exit 1; }
[ -f /tmp/pr_inline_findings.jsonl ] || { echo "ERROR: /tmp/pr_inline_findings.jsonl missing"; exit 1; }

# Execute platform-specific posting script
case "$PLATFORM" in
  azure)
    # Azure DevOps: source pr_azure.env for API endpoints, then run posting script
    source /tmp/pr_azure.env 2>/dev/null || { echo "ERROR: /tmp/pr_azure.env missing (did you run Step 2?)"; exit 1; }
    bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/ado-post-review.sh"
    ;;
  github)
    # GitHub: use provider script from providers/github.md
    bash "${CLAUDE_PLUGIN_ROOT:-.}/providers/github.md"
    ;;
  *)
    echo "Platform '$PLATFORM' not yet supported for automated posting" >&2
    exit 1
    ;;
esac
```

If posting fails:
- Check `/tmp/pr_inline_failures.log` for which findings failed to post
- Verify `VERDICT` was exported from Step 7
- Confirm Azure token (`AZURE_DEVOPS_TOKEN`) or GitHub token is valid
- Re-run the posting script once auth/env is corrected

---

### Reconcile against the prior review (re-review mode only)

**Precedence rule:** First check whether each prior finding's `fid` is present in the current finding set, **before** checking resolved-status. This ensures a bug that was manually marked resolved but still reproduces gets surfaced as `reopened`, not silently skipped.

When `REVIEW_MODE=rereview`, classify by comparing the current finding set to `/tmp/pr_prior_findings.jsonl` **by `fid`**:

| Bucket | Condition | Posting action (see "Posting the Review") |
|---|---|---|
| **Carried-over** | prior `fid` (status `open`) is still in the current finding set | Leave the existing thread open. **Do not post a duplicate.** |
| **Reopened** | prior `fid` (status `resolved`) is still in the current finding set | Reply "This finding still reproduces as of `<HEAD_SHA>` despite being marked resolved" on the existing thread and reactivate it. |
| **Fixed** | prior `fid` (status `open`) is **absent** from the current finding set **and** passes both gates below | Reply "resolved as of `<HEAD_SHA>`" on the existing thread and mark it resolved. |
| **New** | current `fid` not present in the prior set | Post a new inline thread (with marker). |
| **Already-resolved** | prior `fid` (status `resolved`), absent from current set | Ignore — no action. |

**`fixed` requires verified evidence, not just absence.** A prior finding whose `fid` doesn't reappear in this run's current finding set is **not** automatically `fixed` — the finder sub-agents are stochastic and re-scan from scratch on every non-push-triggered run, so a re-review of the exact same commit can (and did, in a reported production case) surface a different subset of findings each pass. Only bucket a disappeared finding as `fixed` when **both** gates hold:

- **Gate A — HEAD actually advanced.** `HEAD_SHA` must have moved past the sha the prior finding's marker was posted against. Nothing can be fixed if HEAD hasn't changed since the finding was raised. **MANDATORY MECHANICAL CHECK (before writing `/tmp/pr_reconcile.json`):** If `RANGE_BASE == PRIOR_SUMMARY_SHA` (same-commit re-run), the `fixed` bucket MUST be empty — move any fid that appears to have disappeared into `carried_over` instead. Do not rely on LLM judgment here; this is stochastic scan variance, not a real fix.
- **Gate B — the flagged line is genuinely gone.** Recompute the fid directly from the file on disk at `HEAD_SHA` for the prior finding's `(file, snippet)` — read the current line(s) around where it was last anchored and recompute `compute_fid` against each — and confirm none of them reproduce the prior fid.

Anything that fails either gate stays `carried_over`, and its severity still feeds the verdict even though it has no matching current finding this pass.

**Spot-check the `fixed` bucket before trusting it — you, not a mechanical check.** Gate B above proves only that one exact literal line is gone from the file; it cannot distinguish "genuinely fixed" from "same bug, line text shifted" (an unrelated rename, a reformat, a line split elsewhere in the same commit). Since `fixed` is normally small (a handful of entries at most), for **each** entry you are about to bucket as `fixed`: re-read the current version of that finding's `file` (you likely already have it open from this pass) and confirm the underlying bug pattern the original finding described is actually gone — not just reworded, renamed, or moved a few lines. If the pattern is still present, move that entry to `carried_over` instead and keep its severity in the open set. Only entries that survive this check may be reported as fixed or trigger a reply-and-resolve in the posting step.

Write the four actionable buckets to `/tmp/pr_reconcile.json` (`{"fixed":[...], "carried_over":[...], "reopened":[...], "new":[...]}`, each entry keyed by `fid` with its `thread_ref`/`comment_ref` from the prior file) so the posting step can act on them without recomputing.

Then prepend a **Re-review delta** block to the report body (above the Summary), using the template's re-review section:

```
### Re-review delta
Reviewed N new commit(s) since the last review (`<RANGE_BASE>`..`<HEAD_SHA>`).
- ✅ Fixed: <count> previously-flagged issue(s) resolved
- ⏳ Still open: <count> carried-over issue(s)
- 🆕 New: <count> issue(s) introduced since the last review
```

In **initial mode** skip plugin-fid reconciliation entirely — every finding starts as "New" and there is no re-review delta block. External-thread validation (next section) still runs in both modes.

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

The run executes in a temporary Docker container with no stored git credentials, and the `PreToolUse` hook cannot export variables into your shell (it only validates that the token exists). Carry the token **inline on the push command itself** via env-scoped git config:

```bash
REMOTE_URL=$(git remote get-url origin)
REMOTE_HOST=$(echo "$REMOTE_URL" | sed -E 's|^[a-z+]+://||; s|^[^@/]+@||; s|[:/].*$||')
case "$REMOTE_URL" in
  *dev.azure.com*|*visualstudio.com*) PUSH_TOKEN="${AZURE_DEVOPS_TOKEN}" ;;
  *)                                  PUSH_TOKEN="${GITHUB_TOKEN}" ;;
esac

GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0="url.https://x-access-token:${PUSH_TOKEN}@${REMOTE_HOST}/.insteadOf" \
GIT_CONFIG_VALUE_0="https://${REMOTE_HOST}/" \
git push origin HEAD
```

The `GIT_CONFIG_*` prefix scopes the credential to this single command — nothing is written to disk or `~/.gitconfig`, and nothing needs to persist in the throwaway container.

### 4. Post a fix summary comment

Post a comment listing:
- Which issues were auto-fixed (with file and line references)
- Which issues still require manual attention

Use the platform-appropriate method from the Posting the Review section below with event `COMMENT`.

---

# Posting the Review

After compiling the report (and applying fixes if in fix mode), post it to the platform detected in Step 1 immediately without waiting for user input. Posting has the sub-steps below; all are mandatory when the platform supports them and the run is incomplete if any are skipped. Sub-step **R** runs only in re-review mode. Sub-step **E** runs whenever `/tmp/pr_external_reconcile.json` has an non-empty `addressed` list.

| # | Sub-step | GitHub | Azure DevOps | Generic |
|---|---|---|---|---|
| A | Cast the verdict / vote | `gh pr review` flag | `PUT .../reviewers/{id}` with vote | n/a |
| B | Post the full report body (incl. delta) as one PR-level comment, **with the summary marker** | `gh pr review --body` | `POST .../threads` (no `threadContext`) | write to `pr-review-report.md` |
| R | **Re-review only:** reconcile prior **plugin** findings — resolve **Fixed** threads (with a reply), leave **Carried-over** threads open (no duplicate) | reply + `resolveReviewThread` (GraphQL) | reply + `PATCH .../threads/{id}` `status:fixed` | n/a |
| E | Reply on **addressed external** open threads (reply only — **never resolve**) | reply via `.../comments/{id}/replies` | reply via `POST .../threads/{id}/comments` | n/a |
| C | Post **one inline thread per finding** (initial mode: every surviving finding; re-review mode: **only the New bucket** after dedup), **each with a finding marker** | `gh api .../pulls/<n>/comments` per finding | `POST .../threads` with `threadContext` per finding | n/a (skip with note) |

**C is not optional** when there are findings to post (initial mode: all findings with `path/to/file.ext:NN` after dedup; re-review mode: the New bucket after dedup). The whole point of the specialized reviewers is to surface findings inline next to the offending code; collapsing them into the summary thread defeats the plugin's value. If you find yourself about to print "Review posted" without having posted the due inline comments, stop and go back to sub-step C.

**Every comment the plugin posts in B and C must carry its marker** (summary marker on B, finding marker with the finding's `fid` on C — see *Comment markers and finding identity*). A run that posts comments without markers breaks the next re-review (it will re-post everything as duplicates). The provider files show exactly where the marker goes for each call.

### Sub-step R — reconcile prior findings (re-review mode only)

Skip in initial mode and on the generic platform. Drive this from `/tmp/pr_reconcile.json` (built in step 7):

- **Fixed** (`fixed[]`): for each, post a short reply on the existing thread — e.g. `✅ Resolved as of \`<HEAD_SHA>\`` — then mark the thread resolved/fixed. Use the platform mechanics in the provider file's *Reconciling prior findings* section.
- **Carried-over** (`carried_over[]`): take **no** action. The thread is already open; do not reply on every run (avoid notification spam) and never re-post the finding as a new thread.

Track a counter (`RESOLVED_OK` / `RESOLVED_FAIL`) the same way inline posting does, and include resolved-count in the final confirmation line.

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

Read and follow the instructions in the appropriate provider file:
- **GitHub** → `providers/github.md`
- **Azure DevOps** → run `scripts/ado-post-review.sh` (see `providers/azure-devops.md` → *Posting the Review*). Set `VERDICT`, ensure `/tmp/pr_thread_body.md` and `/tmp/pr_inline_findings.jsonl` exist, then execute as **one** `Bash` call. Do **not** invent a shortened curl script — bare custom thread properties are a common cause of the summary comment never appearing. Never hand-build URLs with `AZURE_DEVOPS_ORG` / `PR_NUMBER` — use `source /tmp/pr_azure.env` and `PR_ID`. (Note: `REVIEW_MODE` is now read from `/tmp/pr_review_state.json` written in step 3, not passed as env var.)
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

Omit the `external replies` segment when `EXTERNAL_REPLY_OK` is unset or 0 and there was nothing to address.

If `INLINE_OK < EXPECTED_INLINE`, append a second line:

```
WARN: <EXPECTED_INLINE - INLINE_OK> inline comment(s) failed to post — see /tmp/pr_inline_failures.log
```

If posting is not possible (generic/unknown platform), output:

```
Review complete: <verdict> — report written to pr-review-report.md
```
