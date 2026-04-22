---
name: perf-optimize
description: Run a whole-codebase performance bottleneck analysis against the repository's default branch and open a single pull request containing focused low-risk optimizations and the embedded performance report. Issue-driven on GitHub (label an issue with ai-dlc/perf/optimize) and Azure DevOps (tag a work item with ai-dlc/perf/optimize). Usage: /perf-optimize [--scope <path>] [--target <api|worker|frontend|data>]
argument-hint: [--scope <path>] [--target <runtime>]
---

Run a whole-codebase performance bottleneck review for $ARGUMENTS.

## What This Does

This command invokes the **orchestrator** agent which runs a whole-codebase performance review against the repository's **default branch**:

1. **Detect platform** — reads `git remote` to identify GitHub or Azure DevOps.
2. **Fetch the default branch** at its latest commit — this is the analysis baseline.
3. **Parse scope hints** from the trigger issue / work item body (`Scope:` and `Target:` on their own lines).
4. **Analyze bottlenecks** across the scoped paths using four specialized sub-agents in parallel:

   | Analyzer | Focus |
   |----------|-------|
   | `latency-analyzer` | Slow request paths, expensive synchronous chains, high tail-latency patterns |
   | `cpu-analyzer` | Costly loops, repeated heavy computation, inefficient algorithms on critical paths |
   | `memory-analyzer` | Excess allocations, retention-prone structures, avoidable object churn |
   | `io-query-analyzer` | N+1 queries, repeated remote calls, blocking I/O, missing batching/caching |

5. **Rank findings** by `impact × confidence` with hot-path and `--target` tie-breakers.
6. **Apply only the Quick-win subset** via the `perf-pr-author` sub-agent, one commit per finding.
7. **Open a single pull request** against the default branch with the full performance report embedded in the body, linked back to the originating issue / work item.

## How to Use

```
/perf-optimize                          # Whole-codebase scan on the default branch
/perf-optimize --scope src/services     # Restrict analysis to a directory or file pattern
/perf-optimize --target api             # Prioritize API / request-path bottlenecks
/perf-optimize --scope src/api --target api   # Combine both
```

Flags:

- `--scope <path>` — limit analysis to a directory, file, or comma-separated list / glob pattern (e.g. `src/api`, `apps/worker/**`, `src/services,src/workers`)
- `--target <runtime>` — prioritize one of `api`, `worker`, `frontend`, `data` when ranking findings

When invoked via a Xianix Agent rule, the execute prompt provides the scope / target hints parsed from the issue or work item body; locally these flags override or supplement any hints.

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How the PR is created |
|---|---|---|
| `github.com` | GitHub | `gh` CLI (issues + PRs) |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`, work items + PRs) |

Other git hosts are not currently supported for the issue-driven flow. For local runs against any remote, the command still compiles a performance report and applies Quick-wins to a new branch, but PR creation is a no-op until you open one manually on the host.

## Trigger Label

The Performance Optimizer is **label-driven** when invoked through Xianix Agent rules. A **single** label / tag drives the full analyze-and-fix flow:

| Trigger | Platform | Behavior |
|---|---|---|
| `ai-dlc/perf/optimize` on an issue | GitHub | Run the whole-codebase review and open a PR from `perf/issue-{number}-<slug>` that references `Closes #{number}` |
| `ai-dlc/perf/optimize` on a work item | Azure DevOps | Run the whole-codebase review and open a PR from `perf/workitem-{id}-<slug>` that references work item `#{id}` |

The command never pushes to the repository's default branch. All edits go on the new `perf/issue-*` / `perf/workitem-*` branch.

## Output

- A single pull request against the default branch with:
  - title `perf: <issue title>`
  - body containing the structured performance report (see `styles/report-template.md`)
  - one commit per applied Quick-win finding, prefixed `perf:`
  - `Closes #{issue-number}` (GitHub) or a work-item reference (Azure DevOps)
- A link-back comment on the originating issue / work item pointing at the new PR.

## Prerequisites

- Must be run inside a git repository
- The repository must have a detectable default branch
- **GitHub**: `gh` CLI installed and authenticated, or `GITHUB_TOKEN` set (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE_DEVOPS_TOKEN` environment variable set (see `docs/platform-setup.md`)

---

Starting analysis now...
