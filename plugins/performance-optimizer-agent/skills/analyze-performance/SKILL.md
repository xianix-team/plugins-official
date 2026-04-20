---
name: analyze-performance
description: Run an analysis-first performance bottleneck review on a PR or branch. Identifies latency, CPU, memory, and I/O issues and posts a consolidated report. No source code is modified. Usage: /analyze-performance [pr-number | branch-name] [--scope <path>] [--target <api|worker|frontend|data>]
argument-hint: [pr-number | branch-name]
disable-model-invocation: true
---

Run an analysis-first performance review of $ARGUMENTS.

Use the **orchestrator** agent to drive the full analysis flow. The orchestrator will:

1. Index the codebase structure and detect the language / framework stack
2. Detect the hosting platform from `git remote get-url origin`
3. Gather PR context via git (diffs, commits, changed files)
4. Classify changed files by runtime criticality (request path, data layer, compute-heavy, frontend render, cold)
5. Launch the four performance analyzers in parallel via the `Agent` tool:
   - **latency-analyzer** — slow request paths, sync chains, tail-latency patterns
   - **cpu-analyzer** — costly loops, heavy recompute, inefficient algorithms
   - **memory-analyzer** — excess allocations, retention-prone structures, object churn
   - **io-query-analyzer** — N+1, chatty calls, blocking I/O, missing batching/caching
6. Rank findings by `impact × confidence`, with hot-path and `--target` tie-breakers
7. Compile the output into the structured format in `styles/report-template.md`
8. Post the report to the detected platform (GitHub / Azure DevOps) or write `performance-report.md` on generic hosts

This skill is **analysis-first only** — it never creates a fix PR. To generate a separate optimization PR, use the `create-fix-pr` skill, pass `--fix-pr` to `/perf-optimize`, or apply the `ai-dlc/pr/perf-optimize-fix` label on the source PR.

If `--scope <path>` is provided, restrict analysis to that directory / file / glob. If `--target <runtime>` is provided, bias ranking toward that runtime profile. If a branch name is provided (e.g. `feature/cache-refactor`), compare that branch against the default base. If no argument is given, review the current branch against the default base.
