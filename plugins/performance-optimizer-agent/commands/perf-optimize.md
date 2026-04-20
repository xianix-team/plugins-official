---
name: perf-optimize
description: Run a performance bottleneck analysis on a PR or branch. Analysis-first by default — post findings only. Pass --fix-pr to open a separate optimization PR. Works with GitHub, Azure DevOps, Bitbucket, and any git repository. Usage: /perf-optimize [pr-number | branch-name] [--scope <path>] [--target <api|worker|frontend|data>] [--fix-pr]
argument-hint: [pr-number | branch-name] [--scope <path>] [--target <runtime>] [--fix-pr]
---

Run a performance bottleneck analysis for $ARGUMENTS.

## What This Does

This command invokes the **orchestrator** agent which runs a developer-friendly **two-phase** performance review:

1. **Analysis-first** (default) — inspect latency, CPU, memory, and I/O risks in the changed code and post a consolidated report. No source code is modified.
2. **Opt-in fix PR** (only when `--fix-pr` is passed, or the `ai-dlc/pr/perf-optimize-fix` tag is present) — the agent creates a **separate** optimization branch and opens a new PR with focused, low-risk performance improvements. The source PR is left untouched.

The orchestrator coordinates four specialized sub-agents in parallel:

| Analyzer | Focus |
|----------|-------|
| `latency-analyzer` | Slow request paths, expensive synchronous chains, high tail-latency patterns |
| `cpu-analyzer` | Costly loops, repeated heavy computation, inefficient algorithms on critical paths |
| `memory-analyzer` | Excess allocations, retention-prone structures, avoidable object churn |
| `io-query-analyzer` | N+1 queries, repeated remote calls, blocking I/O, missing batching/caching |

## How to Use

```
/perf-optimize                          # Analyze current branch vs main
/perf-optimize 123                      # Analyze PR #123 (GitHub) or PR ID 123 (Azure DevOps)
/perf-optimize feature/cache-refactor   # Analyze the given branch vs main
/perf-optimize --scope src/services     # Restrict analysis to a directory or file pattern
/perf-optimize --target api             # Prioritize API / request-path bottlenecks
/perf-optimize 123 --fix-pr             # Analyze PR #123 and open a separate optimization PR
```

Flags:

- `--scope <path>` — limit analysis to a directory, file, or glob pattern (e.g. `src/api`, `apps/worker/**`)
- `--target <runtime>` — prioritize one of `api`, `worker`, `frontend`, `data` when ranking findings
- `--fix-pr` — after analysis, create a **separate** optimization PR with focused, low-risk changes

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How the report is delivered |
|---|---|---|
| `github.com` | GitHub | GitHub CLI (`gh`) |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`) |
| `bitbucket.org` | Bitbucket | Written to `performance-report.md` (generic fallback) |
| Anything else | Generic | Written to `performance-report.md` |

## Trigger Tags

The Performance Optimizer Agent is **tag-driven** when invoked through Xianix Agent rules:

| Tag | Behavior |
|---|---|
| `ai-dlc/pr/perf-optimize` | Runs analysis-first and posts the report to the PR |
| `ai-dlc/pr/perf-optimize-fix` | After analysis, opens a separate optimization PR |

Applying the fix tag never overwrites or force-pushes to the source PR. It produces a new branch (`perf/optimize-<pr-number>-<timestamp>`) and opens a linked PR against the source PR's base branch.

## Output

- **Analysis-first**: a structured report with ranked bottlenecks, latency/CPU/memory/I/O breakdowns, a quick-wins vs. deeper-follow-up backlog, and validation hints. See `styles/report-template.md` for the full format.
- **Fix PR mode**: the analysis report is posted as usual **and** a separate optimization PR is created with scoped changes, a bottleneck summary, expected impact notes, and a verification checklist.

## Prerequisites

- Must be run inside a git repository
- The current branch must have at least one commit ahead of the base branch
- **GitHub**: `gh` CLI installed and authenticated, or `GITHUB_TOKEN` / `GH_TOKEN` set (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE_DEVOPS_TOKEN` environment variable set (see `docs/platform-setup.md`)
- **Fix PR mode**: `GIT_TOKEN` (GitHub / generic HTTPS) or `AZURE_DEVOPS_TOKEN` (Azure DevOps) must be set so the new optimization branch can be pushed

---

Starting analysis now...
