---
description: "Run a whole-codebase performance bottleneck analysis against the repository's default branch and open a single pull request containing focused low-risk optimizations and the embedded performance report. Issue-driven on GitHub (label an issue with ai-dlc/perf/optimize), Azure DevOps (tag a work item with ai-dlc/perf/optimize), or on a recurring schedule (--schedule, no issue/work item; scans incrementally between periodic full scans). Usage: /perf-optimize [--scope <path>] [--target <api|worker|frontend|data>] [--schedule] [--full-scan-day <SUN..SAT>]"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run a whole-codebase performance bottleneck review for $ARGUMENTS.

## What This Does

This command invokes the **orchestrator** agent which runs a whole-codebase performance review against the repository's **default branch**:

1. **Detect platform** — reads `git remote` to identify GitHub or Azure DevOps.
2. **Fetch the default branch** at its latest commit — this is the analysis baseline.
3. **Parse scope hints** from the trigger issue / work item body (`Scope:` and `Target:` on their own lines) — skipped for `--schedule` runs, which have no body to parse.
4. **Analyze bottlenecks** across the scoped paths using four specialized sub-agents in parallel:

   | Analyzer | Focus |
   |----------|-------|
   | `latency-analyzer` | Slow request paths, expensive synchronous chains, high tail-latency patterns |
   | `cpu-analyzer` | Costly loops, repeated heavy computation, inefficient algorithms on critical paths |
   | `memory-analyzer` | Excess allocations, retention-prone structures, avoidable object churn |
   | `io-query-analyzer` | N+1 queries, repeated remote calls, blocking I/O, missing batching/caching |

5. **Rank findings** by `impact × confidence` with hot-path and `--target` tie-breakers.
6. **Apply Quick-wins** via the `perf-pr-author` sub-agent, one commit per finding — the **full** Quick-wins subset for issue/work-item runs, or **exactly one** fix for `--schedule` runs (the highest-impact item among the trivially-safe, high-confidence, small-diff candidates).
7. **Open a single pull request** against the default branch. Issue/work-item runs embed the full performance report and link back to the originating issue / work item; `--schedule` runs ship a **single change with a slim body**, traced only by baseline commit — see `docs/triggers-schedule.md`.

## How to Use

```
/perf-optimize                          # Whole-codebase scan on the default branch
/perf-optimize --scope src/services     # Restrict analysis to a directory or file pattern
/perf-optimize --target api             # Prioritize API / request-path bottlenecks
/perf-optimize --scope src/api --target api   # Combine both
/perf-optimize --issue 123              # Attach the run to GitHub issue #123
/perf-optimize --workitem 4567          # Attach the run to Azure DevOps work item #4567
/perf-optimize --schedule               # Scheduled (cron) run — no issue/work item, still opens a PR
/perf-optimize --schedule --scope src/api --target api   # Scheduled run scoped to a directory/runtime
/perf-optimize --schedule --full-scan-day MON            # Scheduled run with Monday (UTC) as the weekly full-scan day
```

### Supported flags

All flags are optional. When invoked via a Xianix Agent rule, the execute prompt supplies `--issue` / `--workitem` / `--schedule` (and, for `--issue` / `--workitem`, parses `Scope:` / `Target:` hints from the issue or work item body); local `--scope` / `--target` flags override those hints.

| Flag | Accepts | Purpose |
|---|---|---|
| `--scope <path>` | path, glob, or comma-separated list (`src/api`, `apps/worker/**`, `src/services,src/workers`) | Limit analysis to specific directories or files. Overrides any `Scope:` hint in the issue / work item body. |
| `--target <runtime>` | `api` \| `worker` \| `frontend` \| `data` | Prioritize one runtime profile when ranking findings. Overrides any `Target:` hint. |
| `--issue <number>` | positive integer | GitHub only. Attach this run to an existing issue: use its title / body for scope parsing, name the branch `perf/issue-<number>-<slug>`, reference `Closes #<number>` in the PR. |
| `--workitem <id>` | positive integer | Azure DevOps only. Attach this run to an existing work item: use its title / description for scope parsing, name the branch `perf/workitem-<id>-<slug>`, reference the work item in the PR. |
| `--schedule` | (no value) | Marks the run as coming from a cron `schedule` rule set instead of an issue/work-item webhook — see `docs/triggers-schedule.md`. Opens a PR with **exactly one** fix — the highest-impact item among the trivially-safe candidates — and a **slim body** (no embedded full report), on branch `perf/scheduled-<date>-<sha>`. Scans **incrementally** by default: only files changed since the last scheduled scan (recovered from prior `perf/scheduled-*` PRs) plus their direct callers, falling back to a full scan on the first run, on the weekly full-scan day, or when the prior baseline can't be recovered; skips outright if nothing changed. Skips the starting comment, issue-body scope parsing, and link-back comment since there is no issue/work item. Mutually exclusive with `--issue` / `--workitem`. |
| `--full-scan-day <day>` | `SUN`–`SAT` (three-letter, case-insensitive) | Scheduled runs only. The UTC day-of-week on which a scheduled run performs the periodic **full** codebase scan instead of an incremental one. Default: `SUN`. Ignored with a one-line notice on non-schedule runs. |

### Flags the orchestrator does NOT accept

The following flags are sometimes seen in other perf tooling. They are **not** part of this plugin's contract — do not pass them:

- `--repo` — the repository is always auto-detected from `git remote get-url origin`. Passing it is redundant and is silently ignored.
- `--branch-prefix` — the branch name is a pure function of the trigger (`perf/issue-<number>-<slug>`, `perf/workitem-<id>-<slug>`, or `perf/scheduled-<date>-<sha>`). Prefixes are not configurable; this keeps branch names predictable for cleanup automation.
- `--dry-run` / `--no-pr` — use the `/analyze-performance` skill instead if you only want the report written to `performance-report.md` without opening a PR.

If a rule's `execute-prompt` passes an unknown flag, the orchestrator ignores it and prints a one-line notice (`notice: ignoring unknown flag '<flag>'`) rather than failing the run.

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How the PR is created |
|---|---|---|
| `github.com` | GitHub | `gh` CLI (issues + PRs) |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`, work items + PRs) |

Other git hosts are not currently supported for the issue-driven or scheduled flow. For local runs against any remote, the command still compiles a performance report and applies Quick-wins to a new branch, but PR creation is a no-op until you open one manually on the host.

## Prerequisites

- Must be run inside a git repository
- The repository must have a detectable default branch
- **GitHub**: `gh` CLI installed and authenticated, or `GITHUB-TOKEN` set (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE-DEVOPS-TOKEN` environment variable set (see `docs/platform-setup.md`)

---

## Trigger Label / Schedule

The Performance Optimizer runs from three kinds of Xianix Agent rule: two **label/tag-driven** webhook triggers, and one **cron-driven** schedule trigger with no label at all:

| Trigger | Platform / Rule type | Behavior |
|---|---|---|
| `ai-dlc/perf/optimize` on an issue | GitHub webhook | Run the whole-codebase review and open a PR from `perf/issue-{number}-<slug>` that references `Closes #{number}` |
| `ai-dlc/perf/optimize` on a work item | Azure DevOps webhook | Run the whole-codebase review and open a PR from `perf/workitem-{id}-<slug>` that references work item `#{id}` |
| Cron tick (no label, no payload) | `schedule` rule set — either platform | Run an **incremental** review (files changed since the last scheduled scan + direct callers; full codebase on the first run and the weekly `--full-scan-day`) and open a **single-change, slim** PR from `perf/scheduled-<date>-<sha>` that references the baseline commit and scan window — see `docs/triggers-schedule.md`. Applies exactly one fix (highest-impact of the trivially-safe candidates); skipped entirely if a prior scheduled PR is still open (idempotency guard, orchestrator Step 1a) or if nothing changed since the last scan (Step 1b). |

The command never pushes to the repository's default branch. All edits go on a new `perf/issue-*`, `perf/workitem-*`, or `perf/scheduled-*` branch.

## Output

- A single pull request against the default branch with:
  - title `perf: <issue title>` (issue/work-item runs) or `perf: scheduled optimization scan (<date>)` (`--schedule` runs)
  - **body** — the full structured performance report (issue/work-item runs, see `styles/report-template.md`), or a **slim single-change body** (`--schedule` runs: one-change rationale + before/after + short checklist)
  - **commits** — one per applied Quick-win (issue/work-item runs), or **exactly one** commit (`--schedule` runs)
  - **traceability** — `Closes #{issue-number}` (GitHub), a work-item reference (Azure DevOps), or `Trigger: Scheduled run @ <baseline-sha>` (`--schedule`)
- A link-back comment on the originating issue / work item pointing at the new PR — **not applicable** for `--schedule` runs, which have no issue/work item to comment on.

---

Starting analysis now...
