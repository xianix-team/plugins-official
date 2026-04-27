---
name: analyze-performance
description: Run a whole-codebase performance analysis against the default branch and write the compiled report to performance-report.md without opening a pull request. Use this skill for local diagnostics, dry runs, or CI jobs that only need the report artifact. Usage /analyze-performance [--scope <path>] [--target <api|worker|frontend|data>]
argument-hint: [--scope <path>] [--target <runtime>]
disable-model-invocation: true
---

Run a **report-only** performance analysis of $ARGUMENTS.

This is the read-only variant of `/perf-optimize`. It runs the full analyzer pipeline but stops **before** applying any edits, pushing any branch, or opening any pull request. The compiled report is written to `performance-report.md` in the repository root.

Use the **orchestrator** agent to drive the full analysis flow. The orchestrator will:

1. Index the codebase structure and detect the language / framework stack
2. Detect the hosting platform from `git remote get-url origin`
3. Fetch the repository's default branch at its latest commit
4. Compute the scoped file set from `--scope` (or default to the whole codebase)
5. Classify scoped files by runtime criticality (request path, data layer, compute-heavy, frontend render, cold)
6. Launch the four performance analyzers in parallel via the `Agent` tool:
   - **latency-analyzer** — slow request paths, sync chains, tail-latency patterns
   - **cpu-analyzer** — costly loops, heavy recompute, inefficient algorithms
   - **memory-analyzer** — excess allocations, retention-prone structures, object churn
   - **io-query-analyzer** — N+1, chatty calls, blocking I/O, missing batching/caching
7. Rank findings by `impact × confidence`, with hot-path and `--target` tie-breakers
8. Compile the output into the structured format in `styles/report-template.md`
9. Write the full report to `performance-report.md` in the repository root

This skill **never** creates a branch, never pushes, and never opens a PR — use `/perf-optimize` (or `/create-perf-pr`) to open the fix PR once you have reviewed the report.

If `--scope <path>` is provided, restrict analysis to that directory / file / comma-separated glob list. If `--target <runtime>` is provided, bias ranking toward that runtime profile. If no argument is given, scan the whole codebase against the default branch.
