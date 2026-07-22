---
name: post-review
description: Post the current PR review findings as comments on a pull request. Requires a PR number. Usage: /post-review [pr-number]
argument-hint: [pr-number]
disable-model-invocation: true
---

Post the PR review findings as review comments on PR #$ARGUMENTS.

Do not ask for confirmation at any point. Execute all steps autonomously and proceed immediately from one step to the next.

**Always pass inputs as CLI flags** (`--pr`, `--verdict`, `--mode`) on the same Bash call — never rely on `export` from a prior Bash call (shell state does not persist between tool calls).

## Steps

1. **Check permissions**

   Discover the PR number from `$ARGUMENTS`, then run `scripts/check-permissions.sh --pr <number>` as one Bash call (it detects the platform from `origin` and normalizes executor aliases such as `azuredevops` → `azure`). **Stop** if it exits non-zero — do not post. Then `source /tmp/pr_permissions.env`.

2. **Verify PR exists and is open**

   Run `scripts/verify-pr.sh --pr <number>` as one Bash call. **Stop** if it exits non-zero (missing / merged / completed / abandoned). Then `source /tmp/pr_verify.env`.

   On Azure DevOps, if `/tmp/pr_azure.env` is missing, run `scripts/ado-start-comment.sh --pr <number>` first (or let `verify-pr.sh` / `lib-azure-remote.sh` parse the remote).

3. **Format the review**

   Map the verdict to the platform event type. The exact GitHub flag / Azure DevOps vote for `REQUEST CHANGES` depends on `PR_REVIEWER_BLOCK_ON_CRITICAL` (default **non-blocking** — see the provider files, which are authoritative):

   | Plugin verdict | GitHub event | Azure DevOps vote |
   |---|---|---|
   | `APPROVE` | `APPROVE` | `10` |
   | `APPROVE WITH SUGGESTIONS` | `APPROVE` | `5` |
   | `REQUEST CHANGES` | `COMMENT` (default) / `REQUEST_CHANGES` if `PR_REVIEWER_BLOCK_ON_CRITICAL=true` | `-5` (default) / `-10` if `PR_REVIEWER_BLOCK_ON_CRITICAL=true` |
   | `NEEDS DISCUSSION` | `COMMENT` | `-5` |

   Ensure findings are ready for posting:
   - `scripts/assign-fids.sh` — fill any missing `fid` values
   - `scripts/validate-findings.sh` — re-anchor / drop bad line numbers
   - Unless `PR_REVIEWER_RECONCILE=false`, run `scripts/detect-review-mode.sh --pr <number>` then `scripts/reconcile-prior-findings.sh` (fid buckets + line±5 dedup). External-thread "addressed vs still_open" judgment stays with you — write `/tmp/pr_external_reconcile.json` when you classify them.

4. **Post the review**

   Post via the platform script as **one** `Bash` call (pass `--verdict` and `--mode` as flags; ensure `/tmp/pr_thread_body.md` and `/tmp/pr_inline_findings.jsonl` exist). The script casts the verdict/vote, posts the summary with marker, reconciles prior/external threads (sub-steps R and E), and posts one inline thread per finding:

   - **GitHub** → `scripts/gh-post-review.sh --verdict "…" --mode "…" --pr <number>` (see `providers/github.md`)
   - **Azure DevOps** → `scripts/ado-post-review.sh --verdict "…" --mode "…" --pr <number>` (see `providers/azure-devops.md`)
   - **Generic / unknown** → `providers/generic.md`

5. **Output result**

   On completion, output a single summary line:

   **GitHub:**
   ```
   Posted review on PR #<number>: <verdict> — <N> inline comments — <EXTERNAL_REPLY_OK> external replies — <review URL>
   ```

   **Azure DevOps:**
   ```
   Posted review on PR #<number>: <verdict> — <N> inline comments — <EXTERNAL_REPLY_OK> external replies — ${API_BASE}/_git/<repo>/pullrequest/<number>
   ```

   **Generic:**
   ```
   Review complete: <verdict> — report written to pr-review-report.md
   ```

   If any step fails, output the error and stop — do not retry or ask for input.

> **Note:** GitHub posting requires the **`gh` CLI** installed and authenticated. Azure DevOps posting uses `curl` with the `AZURE_DEVOPS_TOKEN` environment variable (PAT with Pull Request Threads Read & Write scope; dashed `AZURE-DEVOPS-TOKEN` is auto-discovered via `resolve_token`). See `docs/platform-setup.md` for setup instructions. On Azure DevOps, follow `providers/azure-devops.md` exactly — including thread `properties` so Markdown in PR comments renders (this differs from Work Item comments, which use `?format=markdown` on a different API).
