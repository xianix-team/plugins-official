---
name: pr-review
description: Run a full PR review. Analyzes code quality, security, tests, and performance. Works with GitHub, Azure DevOps, Bitbucket, and any git repository.
argument-hint: [pr-number | pr-url | branch-name]
---

Run a comprehensive pull request review for $ARGUMENTS.

## You are the review lead — run this yourself, do NOT delegate to an orchestrator sub-agent

**Critical execution rule (read first).** You, the top-level agent, perform the orchestration described below directly. The specialized reviews (`code-reviewer`, and whichever of `security-reviewer`, `test-reviewer`, `performance-reviewer` apply per the tier gate) are run by spawning those sub-agents **from here, in the main context**.

Do **not** spawn a separate `orchestrator` / "PR review" sub-agent and ask *it* to run the reviewers. A sub-agent cannot spawn further sub-agents — in the Claude Agent SDK that fails with `No such tool available: Task. Task is not available inside subagents`, the parallel review silently degrades, and the report never gets posted. The fan-out only works when it is emitted from the top-level agent, which is you.

Execute every step below autonomously and in order. Do not ask for confirmation, clarification, or approval at any point. If a step fails, output a single error line describing what failed and stop — except where a step explicitly says "warn and continue".

**Deterministic plumbing, LLM judgment.** Platform detection, PR metadata, base/head resolution, diffing, prior-review detection, the review-mode/tier decisions, diff-line-to-file-line resolution, finding-id hashing, reconciliation bucketing, and posting mechanics are **all handled by committed scripts** in `${CLAUDE_PLUGIN_ROOT}/scripts/` — not re-implemented by you each run. This exists because re-typing this plumbing as bash across many separate `Bash` tool calls used to silently break: under harnesses whose `Bash` tool doesn't persist shell state across calls, variables computed in one call evaporated by the next, and the plugin once silently ran a full review on a PR it had already reviewed because the prior-review-detection API call hit an empty `API_BASE`. The scripts read/write a single state file (`/tmp/pr_review_state.json`) instead of shell variables, so this class of failure is now structurally impossible. **Always invoke scripts as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/<name>"`, never `./scripts/<name>`** (sidesteps exec-bit issues). Your job is the part scripts can't do: understanding the diff, finding real bugs, and writing the report prose.

**Fix mode vs report mode:** if the invocation includes a `--fix` flag or the instruction explicitly says to fix issues, apply fixes and push (see *Applying Fixes*). Otherwise, compile and post the review report only.

**Re-review awareness (first review vs. follow-up review).** `gather-context.sh` (step 1 below) detects whether *this plugin* has already reviewed the PR (via its own comment markers — see *Comment markers* below) and returns `review_mode: "rereview" | "initial"` in the state file — driven entirely by whether a prior summary marker was found (`prior_summary_sha`), never by how this run was triggered. In re-review mode: prior findings are reconciled (resolving the ones the author fixed, leaving unresolved ones open without re-posting duplicates), the review focuses on commits pushed since the last review, and a re-review delta is posted instead of a brand-new wall of comments. This is automatic. Set `PR_REVIEWER_RECONCILE=false` to force a full, stateless review that ignores prior findings.

**This only works if the correct PR is identified in the first place.** `gather-context.sh` resolves the target PR from `$ARGUMENTS` before it ever looks at prior-review markers, so getting the *wrong* PR silently produces the wrong mode too (a fresh PR with no markers of its own looks like `initial` even if you meant to re-review something else). It accepts, in order:

1. **A PR URL** — e.g. `https://github.com/acme/widgets/pull/123` or `https://dev.azure.com/org/project/_git/repo/pullrequest/456`. This is the shape pasted when triggering a re-review from an Agent Studio chat message — the PR number is extracted from the URL itself; the owner/repo/org/project always come from this workspace's own git remote, never from the pasted URL, so a URL for a different fork can't redirect the review elsewhere.
2. **A bare PR number.**
3. **A branch name** — looked up as the head/source branch of its open PR.
4. **Nothing** — a PR-comment-triggered run, where the executor should already have the right ref checked out; resolved from the currently checked-out branch.

Whichever of these resolved it is recorded as `trigger_source` in the state file (`chat-url` | `chat-number` | `explicit-branch` | `current-branch`) and printed in the digest — useful for confirming *why* a given PR was picked when debugging a report that landed somewhere unexpected. On both GitHub and Azure DevOps, once the PR is resolved the script also makes sure the workspace is actually checked out to that PR's head branch (not whatever branch a reused workspace happened to have last) before computing any diff — a workspace pinned to a stale branch was the historical cause of "reviewed the wrong PR" reports even when the PR number itself was resolved correctly. It also refreshes the local copy of the PR's target/base branch (e.g. `main`) from `origin` before resolving the base SHA, so a long-lived/reused workspace can't silently diff against a stale base.

## What This Does

This command runs a **cost-tiered** review and posts the results back to the PR. `gather-context.sh` chooses the tier from the diff automatically:

- **Default — low-cost path:** two parallel Haiku finder agents scan the diff for correctness/regression bugs and security/edge-case issues; you then self-verify and keep the strongest findings (capped at 8). This is the path for ordinary PRs and keeps token cost low.
- **Escalated — full specialist path:** when the diff touches a **high-risk surface** (auth/authz, payments/billing, crypto, DB migrations/schema, or public APIs), the dedicated specialized reviewers run instead for deeper coverage, on **mixed model tiers** so frontier-model spend goes only where it pays off:

| Reviewer | Focus | Model tier |
|----------|-------|------------|
| `code-reviewer` | Readability, naming, duplication, error handling, design patterns | quality (cheap, e.g. Haiku) |
| `test-reviewer` | Coverage gaps, test quality, edge cases, missing regression tests | quality (cheap, e.g. Haiku) |
| `security-reviewer` | OWASP Top 10, secrets, injection, auth/authz vulnerabilities | risk (frontier / lead's model) |
| `performance-reviewer` | N+1 queries, O(n²) loops, memory leaks, blocking I/O | risk (frontier / lead's model) |

Either way the outcome is identical downstream: a verdict, a summary comment, and **one inline comment per finding** posted to the detected platform.

## Platform Support

Auto-detected by `gather-context.sh` from the git remote URL:

| Remote URL contains | Platform | How review is posted |
|---|---|---|
| `github.com` | GitHub | `gh` CLI — see `providers/github.md` |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`) — see `providers/azure-devops.md` |
| Anything else | Generic | Written to `pr-review-report.md` — see `providers/generic.md` |

## Prerequisites

- Must be run inside a git repository with `bash` and `python3` (stdlib only, no extra packages) available
- The branch under review must have at least one commit ahead of the base branch
- **GitHub**: `gh` CLI installed and authenticated (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE_DEVOPS_TOKEN` environment variable set (see `docs/platform-setup.md`)
- **Fix mode**: `GITHUB_TOKEN` (GitHub) or `AZURE_DEVOPS_TOKEN` (Azure DevOps) must be set for `git push`

---

# Comment markers and finding identity (read before posting)

Re-review depends on the plugin being able to recognise its **own** previous comments and match each old finding to the current code. Two pieces of metadata make this possible, written on **every** comment the plugin posts (initial *and* re-review).

### 1. The marker (identifies a comment as ours)

`<!-- pr-reviewer:v1 kind=<finding|summary> fid=<finding-id> sha=<HEAD_SHA> -->` — on **GitHub** this is an HTML comment appended to the body (renders invisibly); on **Azure DevOps** the same fields are thread `properties` (`pr-reviewer.kind`/`pr-reviewer.fid`/`pr-reviewer.sha`) since HTML comments aren't reliably hidden there. `post-review.sh` stamps every comment it posts — you never write this yourself.

### 2. The finding id `fid` (matches a finding across revisions)

`fid` must be **deterministic** and **independent of line number** — and, critically, independent of anything an LLM has to reproduce identically across separate runs. It is computed from three inputs, none of which is free text you write: the file path, a fixed-enum `CATEGORY` (see the sub-agent output format below — the sub-agent picks one of `correctness | security | performance | test-coverage | maintainability`, a closed vocabulary, not prose), and the literal source line the finding is anchored to, read directly off disk (never typed by you or the sub-agent).

To compute it:
1. Resolve the finding's file/line with `resolve-line.py` (see step 6) — you already do this.
2. `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/extract-snippet.py" "<file>" "<post-change line>"` — prints the exact flagged line's literal text from the file on disk.
3. `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/compute-fid.py" "<file>" "<category>" "<snippet from step 2>"` — always call the script, never hand-compute it.

Why not the free-text issue sentence: an earlier design hashed `file + issue summary sentence`, but that sentence is regenerated by an LLM sub-agent on every run — if a re-review's finder phrased the same bug even slightly differently, the fid changed and the finding was reposted as a duplicate instead of recognized as carried-over. Anchoring to the literal on-disk line instead means the fid is stable as long as the flagged line itself doesn't change, regardless of how any sub-agent describes it in prose.

---

# Procedure

## 1. Gather PR context (one script call — replaces platform detection, PR metadata, base/head resolution, diffing, prior-review detection, and the mode/tier decisions)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gather-context.sh" $ARGUMENTS
```

Pass `--push-update` as an additional argument when the trigger context indicates this is a follow-up push to an existing PR (the executor sets this) — it forces re-review mode and scopes the tier decision to the incremental diff only, per the script's own logic.

Read the digest this prints, then read `/tmp/pr_review_state.json` for anything you need by name (`platform`, `pr_id`/`pr_number`, `review_mode`, `review_tier`, `review_diff_file`, `changed_count`, `pr_title`, `pr_description`, etc.). **Do not recompute any of these values yourself** — that's exactly the failure mode this script exists to eliminate.

If the script exits non-zero, output its stderr as a single error line and stop — these are genuinely unrecoverable (can't resolve the platform, the base ref, or the PR number). If it prints a `WARN:` about prior-review detection failing, that's not fatal — the run continues in `initial` mode with the failure visible; do not treat it as "confirmed no prior review."

If `changed_count` is `0`, there's nothing to review — skip to posting a short "no changes to review" note and stop.

## 2. Post a "Review in Progress" Comment

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-start-comment.sh"
```

Reads everything it needs from the state file written in step 1. Non-fatal by design — if it warns, continue.

## 3. Index the Codebase (skip on small PRs)

```bash
if [ "$(python3 -c "import json; print(json.load(open('/tmp/pr_review_state.json'))['changed_count'])")" -le 10 ]; then
  echo "Small PR — skipping codebase index, diff alone is enough context."
else
  ls -1
  find . -maxdepth 3 -not -path './.git/*' -not -path './node_modules/*' -not -path './bin/*' -not -path './obj/*' -not -path './.vs/*' | sort
  find . -not -path './.git/*' -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20
  ls *.sln *.csproj package.json go.mod Cargo.toml pom.xml build.gradle pyproject.toml setup.py requirements.txt CMakeLists.txt 2>/dev/null || true
fi
```

If indexing was performed, use `Read` on key config/manifest files and `Grep` to locate the main entry point, base classes, or shared utilities referenced by the changed files. Otherwise skip directly to step 4.

## 4. Understand the Change

Before launching any agents, from `/tmp/pr_review_state.json` and the diff at `review_diff_file`:

- Identify the type of change (feature, bugfix, refactor, config, docs)
- Note which languages/frameworks are involved
- Estimate scope (small/medium/large)

The review **tier** (`review_tier`: `"haiku"` or `"specialists"`) was already decided by `gather-context.sh` from the same high-risk-surface heuristic this step used to re-run — read it from the state file, don't recompute it. `"haiku"` → go to step 5A. `"specialists"` → go to step 5B.

## 5. Run the Review (parallel sub-agent calls — MANDATORY)

Run **exactly one** of the two paths below, per `review_tier` from the state file. Both paths run **real, parallel, top-level sub-agents** (you are the top-level agent, so `Task`/`Agent` is available here) and both feed step 6. Use whichever of `Task`/`Agent` your SDK accepts; if one returns `No such tool available`, retry with the other name. If your SDK requires the plugin prefix, use `pr-reviewer:<name>` instead of the bare name.

**Constraints every sub-agent prompt below must include, verbatim:**

- *"Do not re-fetch git data; the diff at `$REVIEW_DIFF_FILE` is authoritative. Return findings only."* (`REVIEW_DIFF_FILE` = `review_diff_file` from the state file — in push-update mode this is already the incremental diff, in all other modes the full PR diff; the script already resolved which one.)
- When `push_update_mode` is `true` in the state file, also include: *"This is a focused push review. Only the commits pushed since the last review are in scope — review only the diff you were given, not the full PR history."*
- **The line-number contract:** *"For each finding, report `LINE:` as the line number **within the diff file you were given** (count from line 1 of that file) — not a file line number, not hunk-relative math. Just: which line of the file I handed you is this on."* A separate deterministic step resolves that to the real post-change file line — sub-agents must **not** attempt hunk-header arithmetic themselves. (This replaces the old contract where agents computed the post-change file line directly — that was the single most common cause of dropped/misplaced inline comments; agents already have the diff file open, so "which line of this file" is trivial and unambiguous, whereas hunk math was not.)

> **Diff size (used by both paths):** read `diff_lines` and `review_diff_file` from the state file. If `diff_lines <= 300`, pass the diff **inline** in each sub-agent prompt (cheaper than each re-opening a shared file); otherwise pass the path `$REVIEW_DIFF_FILE`.

---

### 5A. Default path — two parallel Haiku finders (`review_tier == "haiku"`)

**Pre-load context (at most 3 `Read` calls, strict size cap).** From `/tmp/pr_changed_files.txt` pick the **top 3 highest-risk files** (business logic, data access first; skip pure test/generated files unless they are the only changes). For each:

- If the file is **≤ 400 lines**, read it in full.
- If **> 400 lines**, extract only the changed regions: `grep -n '^@@' $REVIEW_DIFF_FILE` to find hunk positions, then `sed -n '<start>,<end>p' <file>` for ±60 lines around each hunk.

Concatenate the snippets into `/tmp/pr_context.txt` (a filepath header before each). **Never read any file in its entirety if it exceeds 400 lines; never read more than 3 files.**

Then emit **both Agent calls in the same assistant turn** (so they run in parallel). Both **must** set `"model": "haiku"` — use the short slug, not a dated model id. Neither agent may call `Read`, `Bash`, `Grep`, or any other tool — they work only from the two files named in the prompt.

**Agent 1 — Correctness & regressions**

```json
{
  "description": "Correctness & regression finder",
  "model": "haiku",
  "prompt": "Read $REVIEW_DIFF_FILE then /tmp/pr_context.txt.\n\n[If push_update_mode=true, prepend: 'This is a focused push review — only review the commits pushed since the last review. Do not flag issues from earlier commits in the PR.']\n\nFind correctness bugs and behavioural regressions introduced by the diff. Focus on:\n- Logic errors in changed code paths\n- Changed conditions that now allow or block cases they shouldn't\n- Null / empty / zero edge cases on new code paths\n- Removed guards that previously protected against a bad state\n- Interface/contract mismatches between callers and the changed function\n\nFor each finding output exactly:\nFILE: <path>\nLINE: <the line number within $REVIEW_DIFF_FILE itself that you are flagging — count from line 1 of that file, do not compute a file line number>\nSEVERITY: CRITICAL | WARNING\nCATEGORY: correctness | security | performance | test-coverage | maintainability — pick whichever actually describes the issue (most of your findings will be 'correctness')\nISSUE: <one sentence>\n\nIf you find nothing, output: NONE\nDo not call any tools."
}
```

**Agent 2 — Security & edge cases**

```json
{
  "description": "Security & edge-case finder",
  "model": "haiku",
  "prompt": "Read $REVIEW_DIFF_FILE then /tmp/pr_context.txt.\n\n[If push_update_mode=true, prepend: 'This is a focused push review — only review the commits pushed since the last review. Do not flag issues from earlier commits in the PR.']\n\nFind security issues and missing edge-case handling in the diff. Focus on:\n- Input not validated before use (injection, path traversal)\n- Authentication or authorisation checks removed or weakened\n- Sensitive data written to logs\n- Exception or error paths that swallow failures silently\n- Resource leaks (connections, file handles) on error paths\n- Off-by-one errors or boundary conditions in new loops/ranges\n\nFor each finding output exactly:\nFILE: <path>\nLINE: <the line number within $REVIEW_DIFF_FILE itself that you are flagging — count from line 1 of that file, do not compute a file line number>\nSEVERITY: CRITICAL | WARNING | SUGGESTION\nCATEGORY: correctness | security | performance | test-coverage | maintainability — pick whichever actually describes the issue (this agent covers both 'security' issues and general 'correctness' edge cases, e.g. an off-by-one is correctness even though this agent found it)\nISSUE: <one sentence>\n\nIf you find nothing, output: NONE\nDo not call any tools."
}
```

**Verify and compile (you are the verifier — no extra agents).** For each finding from both agents: (1) confirm the flagged diff-line is a `+` line in `$REVIEW_DIFF_FILE` (new code, not pre-existing); (2) discard pre-existing issues, linter/compiler-caught problems, pedantic style, and obvious false positives; (3) merge duplicates and **cap at 8 findings**, ranked CRITICAL → WARNING → SUGGESTION. Then go to step 6.

---

### 5B. Escalated path — gated specialist sub-agents (`review_tier == "specialists"`)

Run `code-reviewer` **always**; gate the other three by the changed-file mix so you never spawn a reviewer with nothing to do:

| `subagent_type` | Focus | Model tier | Run when the diff contains… | Skip when… |
|---|---|---|---|---|
| `code-reviewer` | Code quality, readability, maintainability | **quality** (cheap) | **always** | never |
| `test-reviewer` | Test coverage and test quality | **quality** (cheap) | source code with behaviour (functions/methods/classes) | the diff is **only** docs, config, or pure formatting/rename |
| `security-reviewer` | Vulnerabilities, secrets, input validation | **risk** (frontier) | source code, auth/authz, input handling, dependencies/lockfiles, IaC, any externally-reachable surface | the diff is **only** docs/markdown/images |
| `performance-reviewer` | Bottlenecks, inefficiencies, resource usage | **risk** (frontier) | DB queries/ORM, loops over collections, I/O, hot paths, large data structures, algorithm changes | the diff is **only** docs/config, or trivial code with no data/IO/loops |

`package.json`/`*.csproj`/lockfile changes are **not** docs — they keep `security-reviewer` in scope. When uncertain whether a reviewer applies, **run it**.

In **one assistant turn**, emit one parallel sub-agent invocation per selected reviewer (1–4). Each prompt must include, in addition to the shared constraints above:

- `$REVIEW_DIFF_FILE` and `/tmp/pr_changed_files.txt`
- `base_sha` and `head_sha` from the state file
- `pr_title` and `pr_description` from the state file
- *"When you need full file context, read only the enclosing function/class (±60 lines around each changed hunk). Do not read any file in its entirety if it exceeds 400 lines — use `Bash(sed -n '<start>,<end>p' <file>)` scoped to the changed region instead. Read at most 3 files beyond the diff."*

> **Model selection (mixed-model tiering).** Precedence: `PR_REVIEWER_MODEL` (if set, pins **every** reviewer, ignoring tiers) > per-tier: quality tier (`code-reviewer`, `test-reviewer`) → `PR_REVIEWER_QUALITY_MODEL` or `haiku`; risk tier (`security-reviewer`, `performance-reviewer`) → `PR_REVIEWER_RISK_MODEL` or the lead's inherited model. Use short slugs (`sonnet`/`opus`/`haiku`/`fable`). When the resolved value is the sentinel `inherit`, **omit** the `model` field entirely rather than passing the literal string `inherit`.

Wait for all selected sub-agents to return, then go to step 6.

---

### What NOT to do (anti-patterns — apply to both paths)

- ❌ Spawning a single `orchestrator` / "PR review" sub-agent and asking it to run the reviewers — it can't spawn sub-agents, the fan-out fails.
- ❌ Running `Bash` with a heredoc that prints a fake "=== CODE QUALITY REVIEW ===" analysis — that's you pretending to be a reviewer. Emit a real agent call.
- ❌ A long thinking turn followed by directly compiling the report — that pause should have been parallel sub-agent work.
- ❌ Sequential `Task`/`Agent` calls — they MUST be in the same assistant turn so the runtime parallelizes them.
- ❌ Passing a large diff (> 300 lines) inline when the diff file exists on disk. Pass the path.
- ❌ Re-deriving `platform`/`api_base`/`pr_id`/`base_sha`/`head_sha` with fresh `git`/`curl` commands anywhere in this procedure — they're already in `/tmp/pr_review_state.json`, written once by step 1.

### Fallback if sub-agents are genuinely unavailable

If **both** `Task` and `Agent` return `No such tool available`: perform the review yourself, inline — for the Haiku path do the two finder passes; for the specialist path do one focused pass per selected dimension — using `$REVIEW_DIFF_FILE` as the source of truth. Then **continue to steps 6–7 exactly as normal** — a degraded analysis path must still post the report and inline comments.

### Self-check before step 6

Your conversation history should contain a `Task`/`Agent` tool result in the prior turn for the path you ran. If missing and you didn't take the fallback above, you skipped the review — go back and do it.

## 6. Compile Findings and Reconcile

**Resolve each finding's post-change file line — deterministically, not by hand:**

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-line.py" "$REVIEW_DIFF_FILE" <diff-line-from-the-sub-agent>
# prints: <file>:<post-change-line>
```

**Compute each finding's `fid` — deterministically, not by hand:**

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/extract-snippet.py" "<file>" "<post-change line from resolve-line.py>"
# prints: <the literal flagged line's source text>

python3 "${CLAUDE_PLUGIN_ROOT}/scripts/compute-fid.py" "<file>" "<category from the sub-agent's CATEGORY field>" "<snippet from extract-snippet.py>"
```

Write the compiled, verified findings (post-`resolve-line.py` file/line, post-`compute-fid.py` fid) to `/tmp/pr_findings.json` as a JSON list, each entry: `{"file": ..., "line": ..., "severity": "critical"|"warning"|"suggestion", "category": "<the same CATEGORY value passed to compute-fid.py>", "fid": ..., "body": "<markdown body, e.g. '**[CRITICAL]** ...'>"}`. `category` is persisted on the posted comment's marker (`post-review.sh` does this) so a *later* re-review's reconciliation can recompute this exact finding's fid against HEAD without needing an LLM to reproduce it — see reconcile.py's fixed/carried-over verification below.

**Reconcile against the prior review and compute the verdict — deterministically:**

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/reconcile.py"
```

Reads `/tmp/pr_findings.json`, `/tmp/pr_review_state.json`, and `/tmp/pr_prior_findings.jsonl`; writes `/tmp/pr_reconcile.json` with `fixed`/`carried_over`/`unreviewed_carried_over`/`new` buckets and a `verdict` (`APPROVE` | `APPROVE WITH SUGGESTIONS` | `REQUEST CHANGES` | `NEEDS DISCUSSION`) computed from the open-finding severities. **Use this verdict as-is — do not invent your own verdict string or override it.** In initial mode every finding lands in `new` and the other buckets are empty; this script still runs unconditionally.

**`fixed` requires verified evidence, not just absence.** A prior finding whose `fid` doesn't reappear in this run's `current_findings` is **not** automatically `fixed` — the finder sub-agents are stochastic and re-scan from scratch on every non-push-triggered run, so a re-review of the exact same commit can (and did, in a reported production case) surface a different subset of findings each pass. `reconcile.py` only buckets a disappeared finding as `fixed` when **both** hold: (1) `head_sha` in the state file has actually advanced past `prior_summary_sha` — nothing can be fixed if HEAD hasn't moved since the finding was raised — and (2) the finding's exact flagged line, recomputed as a fid directly from the file on disk (`compute-fid.py`'s `fids_for_file`, not reported by an LLM), is no longer reproducible at HEAD. Anything that fails either check stays `carried_over`, and its severity still feeds the verdict even though it has no matching current finding this pass.

**Write the report body** (`/tmp/pr_report_body.md`) following `styles/report-template.md`'s structure exactly:

- Reference specific file paths and line numbers (from `/tmp/pr_findings.json`, already resolved) for every finding
- Include both the problematic code snippet and a concrete fix example
- Do not flag non-issues — only real problems and genuine improvements
- Consider the PR's stated intent (from `pr_title`/`pr_description` in the state file) when evaluating trade-offs
- Group related issues together rather than repeating similar findings
- Use the **verdict from `/tmp/pr_reconcile.json`**, not your own judgment
- In re-review mode, prepend the Re-review delta block using the counts from `/tmp/pr_reconcile.json`'s `counts` object (`fixed`, `carried_over`, `new`, and `unreviewed_carried_over` when non-zero) — do not tally these yourself
- In initial mode, omit the delta block entirely

## Applying Fixes (Fix Mode Only)

Only enter this section when running in fix mode (invocation includes `--fix` or explicit fix instruction). Otherwise skip directly to step 7.

1. Use `Write` or `Bash` to edit the affected files (only CRITICAL and WARNING issues — never auto-fix suggestions). Use `git show HEAD:<filepath>` or `Read` to read current content first.
2. Commit: `git add <file> && git commit -m "fix: <short description>"` — one commit per logical fix.
3. Push: `git push origin HEAD`.
4. The fix summary is included automatically when you post the review in step 7 — write it into the report body.

## 7. Post the Review

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-review.sh" /tmp/pr_report_body.md
```

This handles everything platform-specific: mapping the verdict to a vote/review event (respecting `PR_REVIEWER_BLOCK_ON_CRITICAL` — see below), posting the summary with its marker, reconciling `fixed` threads (reply + resolve), posting one inline thread per finding in `/tmp/pr_reconcile.json`'s `new` bucket with its marker, and printing the final confirmation line using its own counters. **Do not print your own confirmation line with self-tallied numbers — echo what the script printed.**

> **Blocking vs non-blocking on CRITICAL findings:** by **default** `post-review.sh` posts a `REQUEST CHANGES` verdict as *non-blocking* (GitHub `--comment`, Azure DevOps vote `-5`) — advisory / shadow mode out of the box. Set `PR_REVIEWER_BLOCK_ON_CRITICAL=true` to make it blocking (GitHub `--request-changes`, Azure DevOps vote `-10`). Verdict, report body, and inline comments are identical either way — only the platform action changes.

If posting is not possible (generic/unknown platform), `post-review.sh` writes `pr-review-report.md` and prints `Review complete: <verdict> — report written to pr-review-report.md` itself.
