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

## What This Does

| Reviewer | Focus |
|----------|-------|
| `code-reviewer` | Readability, naming, duplication, error handling, design patterns |
| `security-reviewer` | OWASP Top 10, secrets, injection, auth/authz vulnerabilities |
| `test-reviewer` | Coverage gaps, test quality, edge cases, missing regression tests |
| `performance-reviewer` | N+1 queries, O(n²) loops, memory leaks, blocking I/O |

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

**Platform CLIs are not used in this step.** Use **`gh`** only when posting to GitHub and **`curl`/Azure DevOps REST** only when posting to Azure DevOps (see the provider docs and "Posting the Review" below).

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

## 5. Understand the Change

Before launching sub-agents:
- Identify the type of change (feature, bugfix, refactor, config, docs)
- Note which languages/frameworks are involved
- Identify critical or high-risk files (auth, payments, database migrations, public APIs)
- Estimate scope (small/medium/large)

### Select which reviewers to run (cost gate — do not run all four blindly)

Running all four reviewers on a docs-only or config-only PR is pure waste. Use the changed-file mix in `/tmp/pr_changed_files.txt` to decide which of the four sub-agents to spawn in step 6. Always run `code-reviewer`; gate the other three:

| Reviewer | Run when the diff contains… | Skip when… |
|---|---|---|
| `code-reviewer` | **always** | never |
| `security-reviewer` | source code, auth/authz, input handling, dependencies/lockfiles, IaC, or any externally-reachable surface | the diff is **only** docs/markdown/images |
| `test-reviewer` | source code with behaviour (functions/methods/classes) | the diff is **only** docs, config, or pure formatting/rename — i.e. nothing whose behaviour a test would assert |
| `performance-reviewer` | DB queries/ORM, loops over collections, I/O, hot paths, large data structures, or algorithm changes | the diff is **only** docs/config, or trivial code with no data/IO/loops |

Rules:
- A file counts as "docs" only if it is markdown/text/images with no code fences that ship as code. `package.json`/`*.csproj`/lockfile changes are **not** docs — they keep `security-reviewer` in scope (dependency risk).
- When uncertain whether a reviewer applies, **run it** — a skipped reviewer that should have run is worse than one wasted pass. The table is for clear-cut cases (e.g. a README typo PR), not borderline ones.
- Record the chosen set; step 6 spawns exactly those reviewers (between 1 and 4). If only `code-reviewer` qualifies, spawn just that one — that is expected and correct for trivial PRs.

## 6. Orchestrate Specialized Reviews (parallel sub-agent calls — MANDATORY)

This step is the entire point of the review. Skipping it is a P0 bug. **You run this yourself** — you are the top-level agent, so the `Task` / `Agent` tool is available to you here.

### What to do

In **one assistant turn**, emit **one parallel sub-agent invocation per reviewer selected in step 5** (between 1 and 4). The tool is exposed under two equivalent names depending on the Claude Code SDK version (`Task` and/or `Agent`). Use whichever your SDK accepts; if one returns `No such tool available`, immediately retry the same call with the other name in the next turn.

| `subagent_type` | Focus | Spawn? |
|---|---|---|
| `code-reviewer` | Code quality, readability, maintainability | always |
| `security-reviewer` | Vulnerabilities, secrets, input validation | per step 5 gate |
| `test-reviewer` | Test coverage and test quality | per step 5 gate |
| `performance-reviewer` | Bottlenecks, inefficiencies, resource usage | per step 5 gate |

> If your SDK requires the plugin prefix for sub-agent names, use `pr-reviewer:code-reviewer` (etc.) instead of the bare name.

> **Mandatory ≠ all four.** "MANDATORY" means the selected reviewers must run as **real, parallel, top-level sub-agents** — not that you must always run four. Running 1–3 because step 5 gated the rest is correct and expected; **simulating** any reviewer in your own context (see anti-patterns below) is the P0 bug, regardless of count.

Each invocation prompt must include, verbatim:

- The path `/tmp/pr_full_diff.patch` (the full diff written in step 3) and the path `/tmp/pr_changed_files.txt`
- `BASE_SHA` and `HEAD_SHA`
- The PR title and description (from the platform metadata fetched in step 2)
- A reminder: *"Do not re-fetch git data; the diff at /tmp/pr_full_diff.patch is authoritative. Return findings only."*
- A file-reading constraint: *"When you need full file context, read only the enclosing function/class (±60 lines around each changed hunk). Do not read any file in its entirety if it exceeds 400 lines — use `Bash(sed -n '<start>,<end>p' <file>)` scoped to the changed region instead. Read at most 3 files beyond the diff."*
- A line-number constraint: *"Every `path/to/file.ext:NN` reference must use the POST-CHANGE file line number — the line as it appears in the new version of the file. Derive `NN` from the `@@ -old,+new @@` hunk header's `+new` start plus the offset of the flagged `+` line within that hunk. Never report the diff's own line position or an old-side line number. Findings on deleted (`-`) lines must reference the nearest surviving line."*

> **Cost guard (mandatory):** Before emitting the sub-agent calls, check the diff size:
> ```bash
> DIFF_LINES=$(wc -l < /tmp/pr_full_diff.patch)
> echo "Diff size: $DIFF_LINES lines"
> ```
> - If `DIFF_LINES ≤ 300`: this is a small PR. Pass the diff **inline** in each sub-agent prompt (not by path) — it is small enough that inline context is cheaper than sub-agents opening and re-reading a shared file.
> - If `DIFF_LINES > 300`: pass by path (`/tmp/pr_full_diff.patch`) as normal.

> **Model selection (cost tiering):** the reviewer agents declare `model: inherit`, so by default they run on the lead's model. Pass an explicit `model` in each sub-agent call to control cost; respect the `PR_REVIEWER_MODEL` environment variable when it is set, otherwise tier by diff size:
> - `PR_REVIEWER_MODEL` set → use that model for every reviewer.
> - else `DIFF_LINES ≤ 300` (small PR) → use a fast, low-cost model (e.g. `claude-haiku-4-5`) for all reviewers.
> - else `DIFF_LINES > 300` or any high-risk file (auth, payments, crypto, DB migrations, public API) is in scope → use the lead's default/inherited model for accuracy.
> A single explicit model applies to all selected reviewers in the same turn — do not run different tiers in one fan-out.

Wait for all selected sub-agents to return, then proceed to step 7.

### What NOT to do (anti-patterns observed in production)

These look like progress but are actually you **simulating** sub-agents in your own context. They double cost, double latency, and lose the specialization benefit. **Stop the moment you catch yourself doing any of them:**

- ❌ Spawning a single `orchestrator` / "PR review" sub-agent and asking it to run the reviewers. That sub-agent cannot spawn sub-agents — the fan-out will fail and the review will degrade to a text summary that never gets posted. Run the selected reviewers from here.
- ❌ Running `Bash` with `cat <<'ANALYSIS' ... === CODE QUALITY REVIEW === ... ANALYSIS` — that is **you pretending to be the code-reviewer**, not invoking it. If you find yourself writing the heredoc text, delete it and emit a sub-agent call instead.
- ❌ A long thinking turn (>20 s) followed by directly compiling the report. That long pause is internal reasoning that should have been parallel sub-agent work.
- ❌ Sequential `Task` / `Agent` calls — each one waits for the previous to finish. They MUST be in the same assistant turn so the runtime parallelizes them.
- ❌ Passing the full diff inline in the sub-agent prompt when `/tmp/pr_full_diff.patch` exists *and the diff is large* (> 300 lines). Pass the path; the sub-agent will `Read` it.
- ❌ `cat <<'DIFF_EOF' ... DIFF_EOF` echoing the diff back into the conversation. You already have it. Don't.

### Fallback if sub-agents are genuinely unavailable

If **both** `Task` and `Agent` return `No such tool available` (a stripped-down runtime that exposes neither), do not give up on the review:

1. Perform the **selected** review dimensions yourself, inline, one focused pass each (the step-5 set among code quality, security, tests, performance), using `/tmp/pr_full_diff.patch` as the source of truth.
2. Then **continue to steps 7 and "Posting the Review" exactly as normal** — a degraded analysis path must still post the report and inline comments. Producing a text summary and stopping is a failure.

### Self-check before emitting the report

Before step 7, your conversation history should contain one `Task` (or `Agent`) tool result in the prior turn for **each reviewer selected in step 5** (`code-reviewer` plus whichever of `security-reviewer` / `test-reviewer` / `performance-reviewer` the gate kept). If a selected reviewer has no result *and* you did not take the documented fallback path above, you skipped it. Go back and do it. (A reviewer that step 5 deliberately skipped should have no result — that is correct.)

## 7. Compile Final Report

Aggregate all findings into the structured report format defined in `styles/report-template.md`. Read that file and follow its template exactly.

**Guidelines:**
- Reference specific file paths and line numbers for every finding
- Include both the problematic code snippet and a concrete fix example
- Do not flag non-issues — only real problems and genuine improvements
- Consider the PR's stated intent when evaluating trade-offs
- Group related issues together rather than repeating similar findings

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

After compiling the report (and applying fixes if in fix mode), post it to the platform detected in Step 1 immediately without waiting for user input. Posting has **three** sub-steps that are all mandatory when the platform supports them — the run is incomplete if any are skipped.

| # | Sub-step | GitHub | Azure DevOps | Generic |
|---|---|---|---|---|
| A | Cast the verdict / vote | `gh pr review` flag | `PUT .../reviewers/{id}` with vote | n/a |
| B | Post the full report body as one PR-level comment | `gh pr review --body` | `POST .../threads` (no `threadContext`) | write to `pr-review-report.md` |
| C | Post **one inline thread per finding** with a file path and line number | `gh api .../pulls/<n>/comments` per finding | `POST .../threads` with `threadContext` per finding | n/a (skip with note) |

**C is not optional** when the report contains Critical Issues, Warnings, or Suggestions with `path/to/file.ext:NN` references. The whole point of the four specialized reviewers is to surface findings inline next to the offending code; collapsing them into the summary thread defeats the plugin's value. If you find yourself about to print "Review posted" without having posted inline comments, stop and go back to sub-step C.

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

Count the findings in the compiled report that have a `path/to/file.ext:NN` reference (sum across Critical Issues, Warnings, Suggestions) — call this `EXPECTED_INLINE`. Then compare against the inline-thread counter exported by the provider (`INLINE_OK` on Azure DevOps; the count of successful `gh api .../comments` POSTs on GitHub).

- If `INLINE_OK` is `0` and `EXPECTED_INLINE` is `> 0`: posting failed silently. Surface the failure log (`/tmp/pr_inline_failures.log` on Azure DevOps) and treat the run as a partial failure.
- If `INLINE_OK` is much smaller than `EXPECTED_INLINE`: read the failure log and either retry the failed ones or include them in the output diagnostic.

After posting, output a single confirmation line that uses the **actual** inline count, not a hard-coded one:

```
Review posted on PR #<number>: <verdict> — <INLINE_OK>/<EXPECTED_INLINE> inline comments — <URL>
```

If `INLINE_OK < EXPECTED_INLINE`, append a second line:

```
WARN: <EXPECTED_INLINE - INLINE_OK> inline comment(s) failed to post — see /tmp/pr_inline_failures.log
```

If posting is not possible (generic/unknown platform), output:

```
Review complete: <verdict> — report written to pr-review-report.md
```
