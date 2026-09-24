---
name: deadcode
description: "Detect dead code (unused files, exports, types, and dependencies) in a JS/TS repository using Knip. Produces deadcode-report.html, deadcode-report.md, and deadcode-report.json locally with run history and delta tracking. Optional --fix opens a draft PR that safely removes the dead code via an isolated git worktree — your working tree is never touched. Usage: /deadcode [path] [--fix | --fix-dry-run] [options]"
argument-hint: "[path] [--fix | --fix-dry-run] [--include-files] [--production] [--config <path>] [--output-dir <path>] [--publish github]"
---

Detect dead code in the repository at `$ARGUMENTS` (defaults to the current directory).

## What This Does

This command invokes the **orchestrator** agent which coordinates:

| Agent | Focus |
|---|---|
| `knip-detector` | Runs [Knip](https://knip.dev) to find unused files, exports, types, enum members, duplicate exports, and unused/unlisted dependencies |
| `report-writer` | Compiles findings into HTML/Markdown/JSON reports with `.deadcode-ignore` suppression and delta vs the prior run |
| `fix-writer` | (only with `--fix` / `--fix-dry-run`) Opens a **draft PR** removing dead code via an isolated git worktree |

## Report-Only by Default

Without `--fix`, nothing in your repository is modified — the scan is read-only analysis plus report files written under `deadcode-reports/`.

With `--fix`, dead code is removed by running `knip --fix` **inside a throwaway git worktree** based on `origin/<default-branch>`. The change is committed on a new branch (`deadcode-fix/<timestamp>`), pushed, and opened as a **draft PR** for human review. Your current branch and uncommitted work are never touched.

## Usage Examples

```bash
# Report-only scan of the current repo
/deadcode

# Scan a specific path
/deadcode ./packages/web-app

# Production mode (stricter: ignores devDependencies and test entry points)
/deadcode --production

# Preview what --fix would remove, without any git operations
/deadcode --fix-dry-run

# Open a draft PR removing unused exports, types, and dependencies
/deadcode --fix

# Also allow deletion of entirely-unused files (destructive — off by default)
/deadcode --fix --include-files

# Keep run history in a custom location
/deadcode --output-dir ../reports/deadcode
```

## Flags

| Flag | Effect |
|---|---|
| `--fix` | Run Knip's safe auto-fix in a worktree and open a draft PR. Default fix scope: `exports,types,dependencies` (non-destructive). |
| `--fix-dry-run` | Print the diff `--fix` would produce. No branch, no push, no PR. |
| `--include-files` | Extends `--fix` to delete entirely-unused files (`--allow-remove-files`). Destructive — review the PR carefully. |
| `--production` | Pass `--production` to Knip (stricter analysis for shippable code). |
| `--config <path>` | Explicit Knip config. If the repo already has `knip.json`/`knip.ts`/a `"knip"` key in `package.json`, it is respected automatically — never overridden unless you pass this flag. |
| `--output-dir <path>` | Root folder for run history (default: `./deadcode-reports`). |
| `--publish github` | Post a non-sensitive summary as a GitHub issue via `gh`. |

## Output

```
deadcode-reports/
├── <timestamp>/                  # this run (history, never overwritten)
│   ├── deadcode-report.html
│   ├── deadcode-report.md
│   ├── deadcode-report.json
│   └── deadcode-evidence/        # raw knip JSON output
└── latest/                       # stable mirror of the newest run
```

## Suppression

Add finding IDs (or `*` glob patterns) to a `.deadcode-ignore` file in the repo root, one per line. Matched findings move to the report's suppressed section:

```
# Kept for the public API even though nothing imports it internally
DEAD-EXPORT-src/index.ts#legacyHelper
DEAD-DEP-@types/*
```

## Prerequisites

### Required

| Tool | Notes |
|---|---|
| Node.js 18+ | Knip runs via `npx --yes knip` — no global install needed |

### Recommended

- Run `npm install` (or pnpm/yarn) first — Knip needs installed `node_modules` to resolve the dependency graph accurately. The scan still runs without it but is marked `partial`.

## Scope

Knip analyzes JS/TS ecosystems only. On a repository with no `package.json`, the scan completes cleanly with a `skipped` status. Knip handles monorepos/workspaces natively.

## A Note on False Positives

Static analysis cannot see dynamic imports, reflection, or framework conventions Knip doesn't know about. That is why nothing is ever auto-applied: findings are report-only, `--fix` always goes through a draft PR that a human reviews, and `.deadcode-ignore` silences confirmed keepers.

---

Starting dead code scan now...
