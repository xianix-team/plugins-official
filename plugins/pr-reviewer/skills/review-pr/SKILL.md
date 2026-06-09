---
name: review-pr
description: Trigger a comprehensive PR review. Runs code quality, security, test coverage, and performance analysis. Usage: /review-pr [PR number or branch name]
argument-hint: [pr-number or branch-name]
disable-model-invocation: true
---

Perform a comprehensive review of the pull request $ARGUMENTS.

This skill is a thin alias for the `/pr-review` command. Run the full procedure documented in `commands/pr-review.md` **yourself, in the top-level context** — do not delegate it to an `orchestrator` sub-agent. A sub-agent cannot spawn the four reviewer sub-agents, so the parallel review only works when you run it directly. The procedure will:

1. Detect the hosting platform from `git remote get-url origin`
2. Post a "review in progress" comment
3. Gather PR context using git (diffs, commits, changed files)
4. Index the codebase structure (skipped on small PRs)
5. Launch the relevant specialized sub-agent reviews in parallel (spawned by you, the top-level agent). `code-reviewer` always runs; the other three are gated by the change type (docs-only / config-only PRs skip the reviewers that don't apply — see step 5 of `commands/pr-review.md`):
   - **code-reviewer** — Code quality, readability, naming, duplication, error handling
   - **security-reviewer** — OWASP vulnerabilities, secrets, injection, auth issues
   - **test-reviewer** — Test coverage, edge cases, test quality
   - **performance-reviewer** — N+1 queries, algorithmic complexity, memory issues
6. Compile all findings into a structured report (see `styles/report-template.md`)
7. Post the review to the detected platform automatically

If invoked with `--fix`: apply fixes to CRITICAL and WARNING issues, commit, and push before posting.

If a branch name is provided (e.g., `/review-pr feature/my-feature`), compare that branch against `main`.

If no argument is given, review the **current branch** against `main`.

**Optional — blocking mode:** by **default** the review is posted as a *non-blocking* review even when CRITICAL issues are found (GitHub `--comment` / Azure DevOps vote `-5`), so it never gates merges out of the box. Set `PR_REVIEWER_BLOCK_ON_CRITICAL=true` in the environment to upgrade `REQUEST CHANGES` to a blocking review (GitHub `--request-changes` / Azure DevOps vote `-10`), which prevents merge under standard branch protection rules. The verdict label and report body remain unchanged. See `docs/platform-setup.md`.
