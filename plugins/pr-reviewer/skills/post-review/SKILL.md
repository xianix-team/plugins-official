---
name: post-review
description: Post the current PR review findings as comments on a pull request. Requires a PR number. Usage: /post-review [pr-number]
argument-hint: [pr-number]
disable-model-invocation: true
---

Post the PR review findings as review comments on PR #$ARGUMENTS.

Do not ask for confirmation at any point. Execute all steps autonomously and proceed immediately from one step to the next.

## Steps

1. **Detect Platform**

   Run:
   ```bash
   git remote get-url origin
   ```

   Determine the platform from the remote (**authoritative** — do not assume GitHub from the PR number or mention prompt):
   - Contains `github.com` → **GitHub** (`PLATFORM=github`)
   - Contains `dev.azure.com` or `visualstudio.com` → **Azure DevOps** (`PLATFORM=azure`)
   - Anything else → **Generic**

   If the environment already has `PLATFORM=azuredevops` (Xianix Executor standard) or `azure-devops` / `ado`, treat that as Azure DevOps and confirm against the remote. Canonical script value is always `azure`, never leave the raw `azuredevops` string in place for later `== "azure"` checks.
2. **Verify PR exists**

   Use the platform-appropriate method to confirm the PR exists and retrieve its current state:

   **GitHub:**
   ```bash
   gh pr view <pr-number> --json state,title,headRefName
   ```
   If the PR does not exist or is already merged/closed, stop and output a single error line.

   **Azure DevOps:**
   ```bash
   # Run Step 2 starting-comment script first if /tmp/pr_azure.env is missing.
   source /tmp/pr_azure.env
   PR_ID="${PR_ID:-${PR_NUMBER}}"
   curl -sS -u ":${AZURE_DEVOPS_TOKEN}" \
     "${API_BASE}/_apis/git/repositories/${AZURE_REPO}/pullrequests/${PR_ID}?api-version=7.1"
   ```
   `API_BASE`, `AZURE_REPO`, and `PR_ID` come from `/tmp/pr_azure.env` (written in Step 2). Do **not** use `AZURE_DEVOPS_ORG`, `AZURE_DEVOPS_PROJECT`, or `PR_NUMBER` in REST paths.

   If the PR does not exist or is already completed/abandoned, stop and output a single error line — do not ask the user what to do.

3. **Format the review**

   Map the verdict to the platform event type. The exact GitHub flag / Azure DevOps vote for `REQUEST CHANGES` depends on `PR_REVIEWER_BLOCK_ON_CRITICAL` (default **non-blocking** — see the provider files, which are authoritative):

   | Plugin verdict | GitHub event | Azure DevOps vote |
   |---|---|---|
   | `APPROVE` | `APPROVE` | `10` |
   | `APPROVE WITH SUGGESTIONS` | `APPROVE` | `5` |
   | `REQUEST CHANGES` | `COMMENT` (default) / `REQUEST_CHANGES` if `PR_REVIEWER_BLOCK_ON_CRITICAL=true` | `-5` (default) / `-10` if `PR_REVIEWER_BLOCK_ON_CRITICAL=true` |
   | `NEEDS DISCUSSION` | `COMMENT` | `-5` |

4. **Post the review** (sub-steps, all mandatory when supported by the platform)

   First, unless `PR_REVIEWER_RECONCILE=false`, run the provider **detect-prior script** as one Bash call (`scripts/gh-detect-prior.sh` or `scripts/ado-detect-prior.sh` — see provider *Detecting a prior review*). Do **not** invent a shortened `curl`/`THREADS_JSON` dump. That writes `/tmp/pr_prior_findings.jsonl`, `/tmp/pr_open_threads.jsonl`, and `/tmp/pr_prior.env`. If marked prior findings exist, this is a **re-review**: reconcile them (resolve the ones now fixed, leave carried-over ones open, post only genuinely new findings). Also validate open **external** threads against `HEAD`, write `/tmp/pr_external_reconcile.json`, and **dedup** findings that overlap existing open threads before posting. See *Comment markers and finding identity*, *Reconcile against existing open review threads*, and *Reconciling prior findings* in `commands/pr-review.md` and the provider files.

   1. Cast the verdict / vote (GitHub review flag, Azure DevOps reviewer PUT — see provider).
   2. Post the full report body (with the re-review delta / existing-threads blocks when applicable) as one PR-level comment, **carrying the summary marker**.
   3. **(Re-review only) Reconcile prior plugin findings** — reply on + resolve the threads whose findings are now fixed; do not re-post carried-over findings.
   4. **Reply on addressed external threads** (sub-step E) — for each entry in `/tmp/pr_external_reconcile.json` → `addressed[]`, post a reply only; **never resolve** those threads.
   5. **Post one inline thread per finding** that has a `path/to/file.ext:NN` reference (initial mode: every surviving finding after dedup; re-review mode: only the New bucket after dedup), **each carrying its finding marker**. This is mandatory — skipping it collapses every finding into the summary thread and defeats the purpose of the review.

   Follow the instructions in the appropriate provider file:

   - **GitHub** → `providers/github.md`
   - **Azure DevOps** → run `scripts/ado-post-review.sh` via `providers/azure-devops.md` → *Posting the Review* (one `Bash` call; set `VERDICT` first; includes sub-steps R and E). Do not invent a shortened curl script.
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

> **Note:** GitHub posting requires the **`gh` CLI** installed and authenticated. Azure DevOps posting uses `curl` with the `AZURE_DEVOPS_TOKEN` environment variable (PAT with Pull Request Threads Read & Write scope). See `docs/platform-setup.md` for setup instructions. On Azure DevOps, follow `providers/azure-devops.md` exactly — including thread `properties` so Markdown in PR comments renders (this differs from Work Item comments, which use `?format=markdown` on a different API).
