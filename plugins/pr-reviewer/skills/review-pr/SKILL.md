---
name: review-pr
description: Trigger a comprehensive PR review. Runs code quality, security, test coverage, and performance analysis. Usage: /review-pr [PR number or branch name]
argument-hint: [pr-number or branch-name]
disable-model-invocation: true
---

Perform a comprehensive review of the pull request $ARGUMENTS.

This skill is a thin alias for the `/pr-review` command. Run the full procedure documented in `commands/pr-review.md` **yourself, in the top-level context** — do not delegate it to an `orchestrator` sub-agent. A sub-agent cannot spawn the four reviewer sub-agents, so the parallel review only works when you run it directly. The procedure will:

1. Detect the hosting platform from `git remote get-url origin` first (hard gate — do not open the GitHub provider or call `gh` until this completes). If the executor injected `PLATFORM=azuredevops`, normalize it to canonical `azure` and still verify against the remote; never default to GitHub.
2. Post a "review in progress" comment
3. Check out the PR head itself when a PR number was given (the runner leaves the workspace on the default branch and knows nothing about PRs — the synthetic `refs/pull/<n>/head` / `refs/pull/<n>/merge` refs are how you get at the PR's commits), resolve the PR's **real target branch** from the platform metadata and **`git fetch` its current remote tip** before diffing (never diff against a possibly-stale local copy of the target — that inflates the review with commits already merged), then gather PR context using git (diffs, commits, changed files), **detect whether the plugin already reviewed this PR**, and load **all open inline review threads** for awareness/dedup. If a prior plugin review exists, the run switches to re-review mode: it reconciles prior findings (resolving the ones now fixed, leaving carried-over ones open without duplicating them), focuses on commits pushed since the last review, and posts a re-review delta. Independently, open external threads that look addressed get a reply (never resolved). Set `PR_REVIEWER_RECONCILE=false` to force a stateless full review that also skips external-thread awareness.
4. Index the codebase structure (skipped on small PRs)
5. Choose the review tier (step 5 of `commands/pr-review.md`), then launch the applicable specialist sub-agents **in parallel** with `subagent_type` set (`code-reviewer` always; `security-reviewer`, `test-reviewer`, and `performance-reviewer` gated by change type — see step 6B gating table):
   - **code-reviewer** — Code quality, readability, naming, duplication, error handling (`model: haiku`)
   - **security-reviewer** — OWASP vulnerabilities, secrets, injection, auth issues (omit `model`)
   - **test-reviewer** — Test coverage, edge cases, test quality (`model: haiku`)
   - **performance-reviewer** — N+1 queries, algorithmic complexity, memory issues (omit `model`)
6. Compile all findings into a structured report (see `styles/report-template.md`)
7. Post the review to the detected platform automatically

If invoked with `--fix`: apply fixes to CRITICAL and WARNING issues, commit, and push before posting.

If a branch name is provided (e.g., `/review-pr feature/my-feature`), compare that branch against the remote's default branch (freshly fetched — see step 3 of `commands/pr-review.md`).

If no argument is given, review the **current branch** against the remote's default branch (freshly fetched).

**Optional — blocking mode:** by **default** the review is posted as a *non-blocking* review even when CRITICAL issues are found (GitHub `--comment` / Azure DevOps vote `-5`), so it never gates merges out of the box. Set `PR_REVIEWER_BLOCK_ON_CRITICAL=true` in the environment to upgrade `REQUEST CHANGES` to a blocking review (GitHub `--request-changes` / Azure DevOps vote `-10`), which prevents merge under standard branch protection rules. The verdict label and report body remain unchanged. See `docs/platform-setup.md`.
