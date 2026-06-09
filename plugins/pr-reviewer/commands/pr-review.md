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

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How review is posted |
|---|---|---|
| `github.com` | GitHub | GitHub CLI (`gh`) — see `providers/github.md` |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`) — see `providers/azure-devops.md` |
| Anything else | Generic | Written to `pr-review-report.md` — see `providers/generic.md` |

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
<!-- pr-reviewer:v1 kind=<finding|summary> fid=<finding-id> sha=<HEAD_SHA> -->
```

- `kind` — `finding` for an inline finding thread, `summary` for the PR-level report comment.
- `fid` — the stable finding id (below). Omit for `kind=summary`.
- `sha` — the `HEAD_SHA` the comment was generated against (lets the next run compute the incremental range).

On **GitHub** the marker is an HTML comment appended to the comment body — it renders invisibly. On **Azure DevOps**, HTML comments are *not* reliably hidden, so the same fields are stored as thread **`properties`** (`pr-reviewer.kind`, `pr-reviewer.fid`, `pr-reviewer.sha`) instead of in the body. The provider files show the exact mechanics.

Only comments carrying this marker are ever reconciled, replied to, or resolved by the plugin. Human review comments are never touched.

### 2. The finding id `fid` (matches a finding across revisions)

`fid` must be **deterministic** and **independent of line number** (lines drift as the author edits), so the same logical issue produces the same id on every run. Compute it from the file path plus a normalised issue signature:

```bash
# fid = first 12 hex of sha1( lowercased repo-relative path + "|" + normalised issue text )
# Normalisation: lowercase, keep [a-z0-9 ], collapse runs of whitespace, trim.
compute_fid() {  # args: <file> <issue-text>
  python3 - "$1" "$2" <<'PY'
import sys, re, hashlib
path = sys.argv[1].strip().lower()
issue = re.sub(r'[^a-z0-9 ]', ' ', sys.argv[2].lower())
issue = re.sub(r'\s+', ' ', issue).strip()
print(hashlib.sha1(f"{path}|{issue}".encode()).hexdigest()[:12])
PY
}
```

Use the **issue summary sentence** (not the code snippet, not the line) as the issue text. The same wording each run keeps the id stable; if the reviewer rephrases an issue slightly between runs it may be treated as new — acceptable, since the worst case is one duplicate rather than a missed regression.

---

# Procedure

When invoked with a PR number, branch name, or no argument (defaults to current branch vs main):

## 1. Detect Platform (do this FIRST, before any other tool call)

Run **only** the following to detect which hosting platform is in use:

```bash
git remote get-url origin
```

From the remote URL, determine the platform:
- Contains `github.com` → **GitHub**
- Contains `dev.azure.com` or `visualstudio.com` → **Azure DevOps**
- Contains `bitbucket.org` → **Bitbucket**
- Anything else → **Generic** (report only, no inline posting)

Store the detected platform — it determines every subsequent CLI/API choice. Do **not** assume the platform from the argument or the repo name; the remote URL is authoritative.

### Platform-exclusive CLI rule (mandatory)

After detection, use **only** the platform-appropriate tool for the rest of the run. Mixing them wastes turns and leaks credentials into logs:

| Platform | Allowed for posting / PR API | Forbidden |
|---|---|---|
| GitHub | `gh`, `git` | `curl` to Azure DevOps, `az` |
| Azure DevOps | `curl` + `AZURE_DEVOPS_TOKEN`, `git` | `gh` (will fail with `gh auth login`), `az login` |
| Bitbucket / Generic | `git` only | `gh`, `curl` to private APIs |

Do **not** probe other CLIs ("just to check"). The hook layer will block obvious mismatches; doing it wrong will block the run.

## 2. Post a "Review in Progress" Comment (must be within the first 3 tool calls)

Immediately after platform detection, post a comment so the PR author knows the review has started. **Do not read any files, do not run `find`/`ls`, do not index the codebase before this step.**

Use the platform-appropriate method:
- **GitHub:** `gh pr comment` — see `providers/github.md`
- **Azure DevOps:** REST API — see `providers/azure-devops.md` (Posting the Starting Comment section)
- **Generic / unknown platform:** Skip — no API available

Resolve the PR number from the argument first; only fall back to a CLI lookup (`gh pr list` on GitHub, `pullrequests?searchCriteria.sourceRefName=...` on Azure DevOps) if it was not provided.

If posting the starting comment fails, output a single warning line and continue — do not stop the review.

## 3. Gather PR Context (do this BEFORE indexing the codebase)

The diff is what matters. Resolve the base/head and pull the diff first — for small PRs (≤10 changed files), this is *all* the context the sub-agents need, and the codebase index in step 4 can be skipped entirely.

### Resolve the base ref (robust to detached HEAD, missing remote-tracking refs, and non-`main` defaults)

> **Important:** detached worktrees created by CI runners (e.g. the Xianix Executor) often have **zero** remote-tracking refs (`refs/remotes/origin/*`). `git show-ref | grep remotes` returns nothing. Resolving `origin/master` will fail. Always fall back to **local** branches and use `git merge-base` for the diff.

```bash
HEAD_SHA=$(git rev-parse HEAD)

# Helper: does a ref exist?
_have_ref() { git show-ref --verify --quiet "$1"; }

# Try origin/HEAD, then origin/{main,master,develop}, then local {main,master,develop},
# then any remote tracking branch, then any local branch other than the current one.
BASE_REF=""
for candidate in \
  "$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" \
  refs/remotes/origin/main refs/remotes/origin/master refs/remotes/origin/develop \
  refs/heads/main refs/heads/master refs/heads/develop; do
  [ -n "$candidate" ] && _have_ref "$candidate" && { BASE_REF="$candidate"; break; }
done

# Last-resort fallbacks
if [ -z "$BASE_REF" ]; then
  # First remote tracking branch that isn't HEAD
  BASE_REF=$(git for-each-ref --format='%(refname)' refs/remotes/origin \
    | grep -v '/HEAD$' | head -1)
fi
if [ -z "$BASE_REF" ]; then
  # First local branch that isn't whatever HEAD points at
  BASE_REF=$(git for-each-ref --format='%(refname)' refs/heads \
    | grep -v -F "$(git symbolic-ref -q HEAD || echo /no/symbolic/ref)" | head -1)
fi

[ -z "$BASE_REF" ] && { echo "ERROR: could not resolve any base ref"; exit 1; }

# Short label (e.g. "master") and a merge-base SHA we can diff against
BASE=$(echo "$BASE_REF" | sed -e 's|^refs/remotes/origin/||' -e 's|^refs/heads/||')
BASE_SHA=$(git merge-base "$BASE_REF" "$HEAD_SHA")

echo "Base: $BASE ($BASE_REF -> $BASE_SHA)"
echo "Head: $HEAD_SHA"
export HEAD_SHA BASE BASE_REF BASE_SHA
```

> On **Azure DevOps**, prefer the PR's real target branch as the base: fetch the PR metadata (see `providers/azure-devops.md` → *Fetching PR Metadata*) and resolve `$PR_TARGET` to a SHA the same way as above, then use that as `BASE_SHA`. The PR object is the source of truth for title/description/target.

Use `${BASE_SHA}` (not `origin/${BASE}`) in every diff command below — it works regardless of whether remote-tracking refs exist.

### Resolve the source branch name (handles detached HEAD)

```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  CURRENT_BRANCH=$(git branch --contains "$HEAD_SHA" \
    | sed 's|^[* ] *||' | grep -v '^(' | head -1)
fi
export CURRENT_BRANCH
```

### Diff and metadata commands (use `BASE_SHA`, not `origin/${BASE}`)

```bash
git log --oneline ${BASE_SHA}..${HEAD_SHA}
git diff --stat ${BASE_SHA}...${HEAD_SHA}
git diff --name-only ${BASE_SHA}...${HEAD_SHA} | tee /tmp/pr_changed_files.txt
git diff ${BASE_SHA}...${HEAD_SHA} > /tmp/pr_full_diff.patch
git log -1 --format="%an <%ae>" ${HEAD_SHA}
git log --format="%s%n%b" ${BASE_SHA}..${HEAD_SHA}

CHANGED_COUNT=$(wc -l < /tmp/pr_changed_files.txt | tr -d ' ')
echo "Changed files: $CHANGED_COUNT"
export CHANGED_COUNT
```

Writing the diff to `/tmp/pr_full_diff.patch` lets you pass it by **path** to sub-agents instead of by value — much smaller prompts when the diff is large.

> **Anti-pattern:** Do NOT `cat <<'DIFF_EOF' ... DIFF_EOF` the diff back to yourself in a subsequent `Bash` call. The diff is already in your conversation history once you ran `git diff`. Echoing it back wastes a turn and tokens; if you need it as a file, you already wrote it to `/tmp/pr_full_diff.patch` above.

Use `git show ${HEAD_SHA}:<filepath>` or the `Read` tool to read the full content of any file that requires deeper analysis beyond the patch.

**Platform CLIs are not used in this diff step.** Use **`gh`** only when posting to GitHub and **`curl`/Azure DevOps REST** only when posting to Azure DevOps (see the provider docs and "Posting the Review" below).

### Detect a prior review and compute the re-review range

This is the one place reading platform PR comments is required, because it determines whether the run is an **initial** review or a **re-review**. Skip entirely on the generic platform (no API) and when `PR_REVIEWER_RECONCILE=false`.

1. List the existing review comments/threads on the PR and keep only those carrying the plugin marker (`<!-- pr-reviewer:v1 ... -->` on GitHub, or the `pr-reviewer.*` thread properties on Azure DevOps). Use the platform helper:
   - **GitHub** → `providers/github.md` → *Detecting a prior review* (GraphQL: review threads with `id`, `isResolved`, body, fid).
   - **Azure DevOps** → `providers/azure-devops.md` → *Detecting a prior review* (`GET .../threads`, filter by `properties["pr-reviewer.fid"]`).

2. Decide the mode:

```bash
# /tmp/pr_prior_findings.jsonl is written by the provider helper: one JSON object per
# prior marked finding thread: {fid, status(open|resolved), thread_ref[, comment_ref]}.
# Matching is by fid alone, so file/line are not needed here.
# PRIOR_SUMMARY_SHA is the sha= from the most recent summary marker, or empty.
if [ "${PR_REVIEWER_RECONCILE:-true}" = "false" ] || [ ! -s /tmp/pr_prior_findings.jsonl ]; then
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
echo "Review mode: $REVIEW_MODE  |  incremental range: ${RANGE_BASE}..${HEAD_SHA}"
export REVIEW_MODE RANGE_BASE
```

3. Capture the **incremental** diff (commits pushed since the last review) in addition to the full PR diff — it is what you skim first in re-review mode and what populates the "changed since last review" line in the delta:

```bash
if [ "$REVIEW_MODE" = "rereview" ] && [ "$RANGE_BASE" != "$BASE_SHA" ]; then
  git log --oneline ${RANGE_BASE}..${HEAD_SHA}
  git diff ${RANGE_BASE}...${HEAD_SHA} > /tmp/pr_incremental_diff.patch
  echo "Incremental diff: $(wc -l < /tmp/pr_incremental_diff.patch) lines since last review"
fi
```

> **Why review the full PR diff, not just the increment?** The full diff (`/tmp/pr_full_diff.patch`) stays the authoritative input to the reviewers so the *current* finding set is always complete — an unresolved finding in a file the latest commits didn't touch must still be detected so it stays open. The incremental diff focuses your attention and drives the delta summary; it does not replace the full scan. Reconciliation (step 7 / posting) compares the current finding set to the prior one **by `fid`**.

## 4. Index the Codebase (skip on small PRs)

```bash
if [ "${CHANGED_COUNT:-0}" -le 10 ]; then
  echo "Small PR ($CHANGED_COUNT files) — skipping codebase index, diff alone is enough context."
else
  # Top-level layout
  ls -1

  # Source tree (depth 3, ignore common noise)
  find . -maxdepth 3 \
    -not -path './.git/*' \
    -not -path './node_modules/*' \
    -not -path './bin/*' \
    -not -path './obj/*' \
    -not -path './.vs/*' \
    | sort

  # Language fingerprint
  find . -not -path './.git/*' -type f \
    | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20

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
# 1. High-risk by file path
HIGH_RISK_FILES=$(grep -iE \
  '(auth|login|signin|session|password|passwd|secret|token|jwt|oauth|crypto|encrypt|decrypt|payment|billing|charge|invoice|checkout|migration|schema|\.sql$|webhook|/api/|/controllers?/|/routes?/|/handlers?/|iam|rbac|permission)' \
  /tmp/pr_changed_files.txt || true)

# 2. High-risk by changed content (added lines only)
HIGH_RISK_DIFF=$(grep -iE '^\+' /tmp/pr_full_diff.patch \
  | grep -iE '(password|secret|api[_-]?key|private[_-]?key|authorize|authenticate|hashpw|bcrypt|jwt|sql|exec\(|eval\(|subprocess|os\.system|pickle\.loads)' \
  || true)

if [ -n "$HIGH_RISK_FILES" ] || [ -n "$HIGH_RISK_DIFF" ]; then
  REVIEW_TIER="specialists"
  echo "High-risk surface detected — escalating to specialist reviewers."
else
  REVIEW_TIER="haiku"
  echo "No high-risk surface — using low-cost Haiku finder path."
fi
export REVIEW_TIER
```

- `REVIEW_TIER=haiku` → go to **step 6A** (two Haiku finders). This is the common case.
- `REVIEW_TIER=specialists` → go to **step 6B** (gated specialist sub-agents).

When genuinely uncertain whether a change is high-risk, prefer **specialists** — a missed vulnerability costs far more than one extra review pass. The heuristic above is intentionally broad for exactly this reason.

## 6. Run the Review (parallel sub-agent calls — MANDATORY)

Run **exactly one** of the two paths below, chosen by `REVIEW_TIER` from step 5. Both paths run **real, parallel, top-level sub-agents** (you are the top-level agent, so `Task` / `Agent` is available here) and both feed the same step 7. The tool is exposed under two equivalent names depending on the Claude Code SDK version (`Task` and/or `Agent`). Use whichever your SDK accepts; if one returns `No such tool available`, immediately retry the same call with the other name. If your SDK requires the plugin prefix, use `pr-reviewer:<name>` instead of the bare name.

**Constraints every sub-agent prompt below must include, verbatim:**

- A reminder: *"Do not re-fetch git data; the diff at /tmp/pr_full_diff.patch is authoritative. Return findings only."*
- A line-number constraint: *"Every `path/to/file.ext:NN` reference must use the POST-CHANGE file line number — the line as it appears in the new version of the file. Derive `NN` from the `@@ -old,+new @@` hunk header's `+new` start plus the offset of the flagged `+` line within that hunk. Never report the diff's own line position or an old-side line number. Findings on deleted (`-`) lines must reference the nearest surviving line."*

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

Then emit **both Agent calls in the same assistant turn** (so they run in parallel). Both **must** set `"model": "claude-haiku-4-5"`. Neither agent may call `Read`, `Bash`, `Grep`, or any other tool — they work only from the two files named in the prompt.

**Agent 1 — Correctness & regressions**

```json
{
  "description": "Correctness & regression finder",
  "model": "claude-haiku-4-5",
  "prompt": "Read /tmp/pr_full_diff.patch then /tmp/pr_context.txt.\n\nFind correctness bugs and behavioural regressions introduced by the diff. Focus on:\n- Logic errors in changed code paths\n- Changed conditions that now allow or block cases they shouldn't\n- Null / empty / zero edge cases on new code paths\n- Removed guards that previously protected against a bad state\n- Interface/contract mismatches between callers and the changed function\n\nFor each finding output exactly:\nFILE: <path>\nLINE: <post-change file line number from the @@ hunk header's +new start plus the offset of the flagged + line within that hunk; never the diff's own line position>\nSEVERITY: CRITICAL | WARNING\nISSUE: <one sentence>\n\nIf you find nothing, output: NONE\nDo not call any tools."
}
```

**Agent 2 — Security & edge cases**

```json
{
  "description": "Security & edge-case finder",
  "model": "claude-haiku-4-5",
  "prompt": "Read /tmp/pr_full_diff.patch then /tmp/pr_context.txt.\n\nFind security issues and missing edge-case handling in the diff. Focus on:\n- Input not validated before use (injection, path traversal)\n- Authentication or authorisation checks removed or weakened\n- Sensitive data written to logs\n- Exception or error paths that swallow failures silently\n- Resource leaks (connections, file handles) on error paths\n- Off-by-one errors or boundary conditions in new loops/ranges\n\nFor each finding output exactly:\nFILE: <path>\nLINE: <post-change file line number from the @@ hunk header's +new start plus the offset of the flagged + line within that hunk; never the diff's own line position>\nSEVERITY: CRITICAL | WARNING | SUGGESTION\nISSUE: <one sentence>\n\nIf you find nothing, output: NONE\nDo not call any tools."
}
```

**Verify and compile (you are the verifier — no extra agents).** For each finding from both agents: (1) confirm the flagged line appears in `/tmp/pr_full_diff.patch` as a `+` line (new code, not pre-existing); (2) discard pre-existing issues, linter/compiler-caught problems, pedantic style, and obvious false positives; (3) merge duplicates and **cap at 8 findings**, ranked CRITICAL → WARNING → SUGGESTION. Then go to step 7.

---

### 6B. Escalated path — gated specialist sub-agents (`REVIEW_TIER=specialists`)

Deeper coverage for high-risk diffs. Run `code-reviewer` **always**; gate the other three by the changed-file mix so you never spawn a reviewer with nothing to do:

| `subagent_type` | Focus | Model tier | Run when the diff contains… | Skip when… |
|---|---|---|---|---|
| `code-reviewer` | Code quality, readability, maintainability | **quality** (cheap) | **always** | never |
| `test-reviewer` | Test coverage and test quality | **quality** (cheap) | source code with behaviour (functions/methods/classes) | the diff is **only** docs, config, or pure formatting/rename |
| `security-reviewer` | Vulnerabilities, secrets, input validation | **risk** (frontier) | source code, auth/authz, input handling, dependencies/lockfiles, IaC, any externally-reachable surface | the diff is **only** docs/markdown/images |
| `performance-reviewer` | Bottlenecks, inefficiencies, resource usage | **risk** (frontier) | DB queries/ORM, loops over collections, I/O, hot paths, large data structures, algorithm changes | the diff is **only** docs/config, or trivial code with no data/IO/loops |

`package.json`/`*.csproj`/lockfile changes are **not** docs — they keep `security-reviewer` in scope (dependency risk). When uncertain whether a reviewer applies, **run it**.

In **one assistant turn**, emit one parallel sub-agent invocation per selected reviewer (between 1 and 4). Each invocation prompt must include, in addition to the two shared constraints above:

- The path `/tmp/pr_full_diff.patch` and the path `/tmp/pr_changed_files.txt`
- `BASE_SHA` and `HEAD_SHA`
- The PR title and description (from the platform metadata fetched in step 2)
- A file-reading constraint: *"When you need full file context, read only the enclosing function/class (±60 lines around each changed hunk). Do not read any file in its entirety if it exceeds 400 lines — use `Bash(sed -n '<start>,<end>p' <file>)` scoped to the changed region instead. Read at most 3 files beyond the diff."*

> **Pass-by-value vs path:** if `DIFF_LINES ≤ 300`, pass the diff **inline** in each prompt (cheaper than each sub-agent re-opening a shared file); if `DIFF_LINES > 300`, pass the path `/tmp/pr_full_diff.patch`.

> **Model selection (mixed-model tiering).** The reviewers split into two model tiers so you don't pay frontier-model rates for the cheaper review dimensions. Set each sub-agent's `model` from its tier (per the table above), resolved with this precedence:
>
> 1. **`PR_REVIEWER_MODEL` (override).** If set, it pins **every** reviewer to that one model — backward-compatible escape hatch, ignores the tiers below.
> 2. Otherwise, per tier:
>    - **quality tier** (`code-reviewer`, `test-reviewer`) → `PR_REVIEWER_QUALITY_MODEL` if set, else `claude-haiku-4-5`. These are pattern/coverage tasks that a small model handles well.
>    - **risk tier** (`security-reviewer`, `performance-reviewer`) → `PR_REVIEWER_RISK_MODEL` if set, else the lead's default/inherited model. Vulnerability and performance reasoning is where frontier accuracy actually pays off — this path was chosen *because* the diff is high-risk.
>
> ```bash
> RISK_MODEL="${PR_REVIEWER_RISK_MODEL:-inherit}"          # frontier / lead's model by default
> QUALITY_MODEL="${PR_REVIEWER_QUALITY_MODEL:-claude-haiku-4-5}"
> if [ -n "${PR_REVIEWER_MODEL:-}" ]; then                 # override: one model for all
>   RISK_MODEL="$PR_REVIEWER_MODEL"; QUALITY_MODEL="$PR_REVIEWER_MODEL"
> fi
> echo "Reviewer models — quality: $QUALITY_MODEL | risk: $RISK_MODEL"
> ```
>
> Emit each reviewer in the same turn with its tier's model in the invocation (`"model": "<quality-or-risk>"`). When the resolved value is the sentinel `inherit`, **omit** the `model` field entirely so the agent's `model: inherit` frontmatter takes over (the lead's model) — do not pass the literal string `inherit` as a model slug. Reviewers in different tiers therefore run on different models within the same parallel turn — that is intended.

Wait for all selected sub-agents to return, then go to step 7.

---

### What NOT to do (anti-patterns — apply to both paths)

These look like progress but are actually you **simulating** sub-agents in your own context. They double cost, double latency, and lose the benefit. **Stop the moment you catch yourself doing any of them:**

- ❌ Spawning a single `orchestrator` / "PR review" sub-agent and asking it to run the reviewers. That sub-agent cannot spawn sub-agents — the fan-out fails and the review degrades to a text summary that never gets posted. Run the agents from here.
- ❌ Running `Bash` with `cat <<'ANALYSIS' ... === CODE QUALITY REVIEW === ... ANALYSIS` — that is **you pretending to be a reviewer**, not invoking it. Delete the heredoc and emit a real agent call instead.
- ❌ A long thinking turn (>20 s) followed by directly compiling the report. That pause is internal reasoning that should have been parallel sub-agent work.
- ❌ Sequential `Task` / `Agent` calls — they MUST be in the same assistant turn so the runtime parallelizes them.
- ❌ Passing a large diff (> 300 lines) inline when `/tmp/pr_full_diff.patch` exists. Pass the path.
- ❌ `cat <<'DIFF_EOF' ... DIFF_EOF` echoing the diff back into the conversation. You already have it. Don't.

### Fallback if sub-agents are genuinely unavailable

If **both** `Task` and `Agent` return `No such tool available` (a stripped-down runtime that exposes neither), do not give up:

1. Perform the review yourself, inline — for the Haiku path do the two finder passes (correctness, security); for the specialist path do one focused pass per selected dimension — using `/tmp/pr_full_diff.patch` as the source of truth.
2. Then **continue to steps 7 and "Posting the Review" exactly as normal** — a degraded analysis path must still post the report and inline comments. Producing a text summary and stopping is a failure.

### Self-check before emitting the report

Before step 7, your conversation history should contain a `Task` (or `Agent`) tool result in the prior turn for the path you ran: **two Haiku finders** (6A) or **one result per selected specialist** (6B). If those results are missing *and* you did not take the documented fallback above, you skipped the review. Go back and do it.

## 7. Compile Final Report

Aggregate all findings into the structured report format defined in `styles/report-template.md`. Read that file and follow its template exactly.

**Guidelines:**
- Reference specific file paths and line numbers for every finding
- Include both the problematic code snippet and a concrete fix example
- Do not flag non-issues — only real problems and genuine improvements
- Consider the PR's stated intent when evaluating trade-offs
- Group related issues together rather than repeating similar findings

### Assign a `fid` to every current finding

For each finding in the compiled report, compute its `fid` with the `compute_fid` helper (see *Comment markers and finding identity*) from its file path and issue summary sentence. This is required in **both** modes — the markers written this run are what the *next* run reconciles against.

### Reconcile against the prior review (re-review mode only)

When `REVIEW_MODE=rereview`, classify by comparing the current finding set to `/tmp/pr_prior_findings.jsonl` **by `fid`**:

| Bucket | Condition | Posting action (see "Posting the Review") |
|---|---|---|
| **Carried-over** | prior `fid` is still in the current finding set | Leave the existing thread open. **Do not post a duplicate.** |
| **Fixed** | prior `fid` (status `open`) is **absent** from the current finding set | Reply "resolved as of `<HEAD_SHA>`" on the existing thread and mark it resolved. |
| **New** | current `fid` not present in the prior set | Post a new inline thread (with marker). |
| **Already-resolved** | prior `fid` whose thread is already resolved | Ignore — no action. |

Write the three actionable buckets to `/tmp/pr_reconcile.json` (`{"fixed":[...], "carried_over":[...], "new":[...]}`, each entry keyed by `fid` with its `thread_ref`/`comment_ref` from the prior file) so the posting step can act on them without recomputing.

Then prepend a **Re-review delta** block to the report body (above the Summary), using the template's re-review section:

```
### Re-review delta
Reviewed N new commit(s) since the last review (`<RANGE_BASE>`..`<HEAD_SHA>`).
- ✅ Fixed: <count> previously-flagged issue(s) resolved
- ⏳ Still open: <count> carried-over issue(s)
- 🆕 New: <count> issue(s) introduced since the last review
```

In **initial mode** skip reconciliation entirely — every finding is "New" and there is no delta block.

### Recompute the verdict from the *currently open* set

The verdict reflects the finding set at `HEAD` after reconciliation — i.e. carried-over + new findings (fixed ones no longer count). A re-review where the author fixed the last blocker should now produce `APPROVE`.

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

```bash
git push origin HEAD
```

### 4. Post a fix summary comment

Post a comment listing:
- Which issues were auto-fixed (with file and line references)
- Which issues still require manual attention

Use the platform-appropriate method from the Posting the Review section below with event `COMMENT`.

---

# Posting the Review

After compiling the report (and applying fixes if in fix mode), post it to the platform detected in Step 1 immediately without waiting for user input. Posting has the sub-steps below; all are mandatory when the platform supports them and the run is incomplete if any are skipped. Sub-step **R** runs only in re-review mode.

| # | Sub-step | GitHub | Azure DevOps | Generic |
|---|---|---|---|---|
| A | Cast the verdict / vote | `gh pr review` flag | `PUT .../reviewers/{id}` with vote | n/a |
| B | Post the full report body (incl. delta) as one PR-level comment, **with the summary marker** | `gh pr review --body` | `POST .../threads` (no `threadContext`) | write to `pr-review-report.md` |
| R | **Re-review only:** reconcile prior findings — resolve **Fixed** threads (with a reply), leave **Carried-over** threads open (no duplicate) | reply + `resolveReviewThread` (GraphQL) | reply + `PATCH .../threads/{id}` `status:fixed` | n/a |
| C | Post **one inline thread per finding** (initial mode: every finding; re-review mode: **only the New bucket**), **each with a finding marker** | `gh api .../pulls/<n>/comments` per finding | `POST .../threads` with `threadContext` per finding | n/a (skip with note) |

**C is not optional** when there are findings to post (initial mode: all findings with `path/to/file.ext:NN`; re-review mode: the New bucket). The whole point of the specialized reviewers is to surface findings inline next to the offending code; collapsing them into the summary thread defeats the plugin's value. If you find yourself about to print "Review posted" without having posted the due inline comments, stop and go back to sub-step C.

**Every comment the plugin posts in B and C must carry its marker** (summary marker on B, finding marker with the finding's `fid` on C — see *Comment markers and finding identity*). A run that posts comments without markers breaks the next re-review (it will re-post everything as duplicates). The provider files show exactly where the marker goes for each call.

### Sub-step R — reconcile prior findings (re-review mode only)

Skip in initial mode and on the generic platform. Drive this from `/tmp/pr_reconcile.json` (built in step 7):

- **Fixed** (`fixed[]`): for each, post a short reply on the existing thread — e.g. `✅ Resolved as of \`<HEAD_SHA>\`` — then mark the thread resolved/fixed. Use the platform mechanics in the provider file's *Reconciling prior findings* section.
- **Carried-over** (`carried_over[]`): take **no** action. The thread is already open; do not reply on every run (avoid notification spam) and never re-post the finding as a new thread.

Track a counter (`RESOLVED_OK` / `RESOLVED_FAIL`) the same way inline posting does, and include resolved-count in the final confirmation line.

### Resolve every finding to a post-change file line (do this before sub-step C)

Both GitHub (`gh api .../comments --field line=NN --field side=RIGHT`) and Azure DevOps (`threadContext.rightFileStart.line`) anchor inline comments to the line number **in the new (post-change) version of the file** — not the line's position within the diff. Mis-anchored comments either land on the wrong line or are rejected (GitHub `422`, Azure DevOps `400`).

For each finding before serializing it:

1. Open `/tmp/pr_full_diff.patch` and find the hunk containing the finding. Hunk headers look like `@@ -<oldStart>,<oldLen> +<newStart>,<newLen> @@`.
2. The finding's file line = `<newStart>` + (count of context ` ` and added `+` lines that precede the flagged line within that hunk). Deleted (`-`) lines do **not** advance the new-side counter.
3. If a finding sits on a deleted line (no surviving `+`/context line), anchor it to the nearest surviving line in the same hunk and note the relocation in the comment body.
4. Confirm the resolved `path` is repo-relative (matches an entry in `/tmp/pr_changed_files.txt`) and the line is within the file's new length.

The reviewers were already instructed (step 6) to return post-change line numbers, but verify here — a wrong line number is the single most common cause of silently dropped inline comments.

Read and follow the instructions in the appropriate provider file:
- **GitHub** → `providers/github.md`
- **Azure DevOps** → `providers/azure-devops.md` (sub-step C is the loop in **§4 — MANDATORY**, not the one-off example)
- **Bitbucket or Unknown Platform** → `providers/generic.md`

> **Blocking vs non-blocking on CRITICAL findings:** by **default** a `REQUEST CHANGES` verdict is posted as a *non-blocking* review (GitHub `--comment`, Azure DevOps vote `-5`) so the plugin runs in advisory / shadow mode out of the box. To make `REQUEST CHANGES` *blocking* (GitHub `--request-changes`, Azure DevOps vote `-10`), set `PR_REVIEWER_BLOCK_ON_CRITICAL=true`. Verdict, report body, and inline comments are identical in both modes — only the platform-side review type changes. Provider files contain the exact mapping logic.

### Post-posting self-check (do this before printing the confirmation line)

Determine `EXPECTED_INLINE`: in **initial mode** it is the count of findings in the report with a `path/to/file.ext:NN` reference (sum across Critical Issues, Warnings, Suggestions); in **re-review mode** it is the size of the **New** bucket only (carried-over findings are intentionally not re-posted). Then compare against the inline-thread counter exported by the provider (`INLINE_OK` on Azure DevOps; the count of successful `gh api .../comments` POSTs on GitHub).

- If `INLINE_OK` is `0` and `EXPECTED_INLINE` is `> 0`: posting failed silently. Surface the failure log (`/tmp/pr_inline_failures.log` on Azure DevOps) and treat the run as a partial failure.
- If `INLINE_OK` is much smaller than `EXPECTED_INLINE`: read the failure log and either retry the failed ones or include them in the output diagnostic.

After posting, output a single confirmation line that uses the **actual** inline count, not a hard-coded one. In re-review mode also report the reconciliation outcome:

```
# initial mode
Review posted on PR #<number>: <verdict> — <INLINE_OK>/<EXPECTED_INLINE> inline comments — <URL>

# re-review mode
Re-review posted on PR #<number>: <verdict> — <INLINE_OK>/<EXPECTED_INLINE> new — <RESOLVED_OK> resolved — <carried_over count> still open — <URL>
```

If `INLINE_OK < EXPECTED_INLINE`, append a second line:

```
WARN: <EXPECTED_INLINE - INLINE_OK> inline comment(s) failed to post — see /tmp/pr_inline_failures.log
```

If posting is not possible (generic/unknown platform), output:

```
Review complete: <verdict> — report written to pr-review-report.md
```
