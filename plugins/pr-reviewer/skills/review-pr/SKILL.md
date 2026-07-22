---
name: review-pr
description: Trigger a comprehensive PR review. Runs code quality, security, test coverage, and performance analysis. Usage: /review-pr [PR number or branch name]
argument-hint: [pr-number or branch-name]
disable-model-invocation: true
---

Perform a comprehensive review of the pull request $ARGUMENTS.

This skill is a thin alias for the `/pr-review` command. Run the full procedure documented in `commands/pr-review.md` **yourself, in the top-level context** — do not delegate it to an `orchestrator` sub-agent. A sub-agent cannot spawn the four reviewer sub-agents, so the parallel review only works when you run it directly. Prefer the plugin scripts for all deterministic steps. **Always pass inputs as CLI flags** (`--pr`, `--branch`, `--verdict`, `--mode`, `--fix`) on the same Bash call — never rely on `export` from a prior Bash call (shell state does not persist). The procedure will:

1. Detect the hosting platform from `git remote get-url origin` first (hard gate — do not open the GitHub provider or call `gh` until this completes). If the executor injected `PLATFORM=azuredevops`, normalize it to canonical `azure` and still verify against the remote; never default to GitHub.
2. Run `scripts/check-permissions.sh --pr <N>` (hard gate — stop if auth/scopes fail). Then post a "review in progress" comment via `scripts/gh-start-comment.sh --pr <N>` / `scripts/ado-start-comment.sh --pr <N>`.
3. Run `scripts/pr-setup.sh --pr <N>` (or `--branch <name>`) to check out the PR head, resolve the real target branch, and gather diffs. Then `scripts/detect-review-mode.sh --pr <N>` for prior-review / open-thread awareness.
4. Run `scripts/index-codebase.sh` (skipped automatically on small PRs).
5. Run `scripts/review-tier.sh`, then (when escalated) `scripts/select-reviewers.sh` + `scripts/resolve-models.sh`. Launch the applicable specialist sub-agents **in parallel** with `subagent_type` set:
   - **code-reviewer** — always (`model` from `QUALITY_SLUG`, usually `haiku`)
   - **security-reviewer** / **test-reviewer** / **performance-reviewer** — gated by `RUN_*` flags from `select-reviewers.sh`
6. Compile findings into the report template. Before posting run `scripts/assign-fids.sh`, `scripts/validate-findings.sh`, and `scripts/reconcile-prior-findings.sh` (fid buckets + dedup). External-thread addressed/still_open judgment stays with you.
7. Post via `scripts/gh-post-review.sh --verdict "…" --mode "…" --pr <N>` / `scripts/ado-post-review.sh --verdict "…" --mode "…" --pr <N>`.

If invoked with `--fix`: apply fixes to CRITICAL and WARNING issues, commit, then push with `scripts/push-fixes.sh` before posting.

If a branch name is provided (e.g., `/review-pr feature/my-feature`), compare that branch against the remote's default branch (freshly fetched — see step 3 of `commands/pr-review.md`).

If no argument is given, review the **current branch** against the remote's default branch (freshly fetched).

**Optional — blocking mode:** by **default** the review is posted as a *non-blocking* review even when CRITICAL issues are found (GitHub `--comment` / Azure DevOps vote `-5`), so it never gates merges out of the box. Set `PR_REVIEWER_BLOCK_ON_CRITICAL=true` in the environment (or pass `--block-on-critical` to the post script) to upgrade `REQUEST CHANGES` to a blocking review (GitHub `--request-changes` / Azure DevOps vote `-10`), which prevents merge under standard branch protection rules. The verdict label and report body remain unchanged. See `docs/platform-setup.md`.
