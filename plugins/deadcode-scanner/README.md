# deadcode-scanner

Dead code detection for JS/TS repositories using [Knip](https://knip.dev) — finds unused files, exports, types, enum members, and dependencies, then reports them or removes them via a **draft PR** that never touches your working tree.

## What It Finds

| Finding | Severity | Auto-fixable |
|---|---|---|
| Unused / unlisted / unresolved dependencies | MEDIUM | deps: yes · unlisted/unresolved: guide-only |
| Entirely-unused files | LOW | only with `--include-files` |
| Duplicate exports | LOW | guide-only |
| Unused exports | INFO | yes |
| Unused types / enum members | INFO | yes |

Dead code is a maintenance concern, not a vulnerability — severities cap at MEDIUM and the report tone is factual, not alarmist.

## Usage

```bash
# Report-only scan (nothing in your repo is modified)
/deadcode

# Scan a specific path / stricter production analysis
/deadcode ./packages/web-app --production

# Preview what --fix would remove (no git operations)
/deadcode --fix-dry-run

# Open a draft PR removing unused exports, types, and dependencies
/deadcode --fix

# Also delete entirely-unused files (destructive — review carefully)
/deadcode --fix --include-files
```

## How `--fix` Works (and Why It's Safe)

1. A **throwaway git worktree** is created from `origin/<default-branch>` — your current branch and uncommitted work are never touched.
2. Dependencies are installed in the worktree (Knip needs the real module graph).
3. `knip --fix --fix-type exports,types,dependencies` runs **inside the worktree**.
4. The removals are committed on `deadcode-fix/<timestamp>`, pushed, and opened as a **draft PR**.
5. The worktree is deleted. You review the PR, run CI, and merge — or close it.

Only one `deadcode-fix/*` PR is open at a time. File deletion (`--allow-remove-files`) is gated behind `--include-files`.

## Output

```
deadcode-reports/
├── <timestamp>/                  # run history (append-only)
│   ├── deadcode-report.html
│   ├── deadcode-report.md
│   ├── deadcode-report.json
│   └── deadcode-evidence/        # raw knip output
└── latest/                       # stable mirror of the newest run
```

Each run computes a delta vs the prior one: new / resolved / persisting findings.

## Suppression — `.deadcode-ignore`

Some "dead" code is intentional (public API surface, framework conventions Knip doesn't know). Add finding IDs or `*` globs to `.deadcode-ignore` in the repo root:

```
# Public API — consumed by external packages
DEAD-EXPORT-src/index.ts#createClient
DEAD-DEP-@types/*
```

Suppressed findings move to a collapsed audit section of the report.

## Configuration

If your repo has a `knip.json`, `knip.ts`, or a `"knip"` key in `package.json`, it is **respected automatically** — the scanner never overrides it. Pass `--config <path>` only to use an explicit alternative.

## Prerequisites

- **Node.js 18+** (Knip runs via `npx --yes knip`; no global install needed)
- Installed `node_modules` recommended — without it the scan runs but is marked `partial` (degraded module resolution)
- For `--fix`: a git repo with an `origin` remote; `gh` (GitHub) or `az` (Azure DevOps) CLI to auto-open the PR (falls back to a pushed branch + compare URL)

## Scope & Limitations

- **JS/TS ecosystems only.** On a repo without `package.json` the scan completes cleanly with `skipped` status. Monorepos/workspaces are handled natively by Knip.
- **False positives exist** — dynamic imports, reflection, and unknown framework magic are invisible to static analysis. That's why nothing is ever auto-applied: report by default, draft PR on request, human always merges.

## Architecture

| Agent | Role |
|---|---|
| `orchestrator` | Input validation, run-history setup, phase coordination |
| `knip-detector` | Runs Knip, normalizes output into the canonical findings schema |
| `report-writer` | Suppression, delta, HTML/MD/JSON reports |
| `fix-writer` | Worktree + `knip --fix` + draft PR (only with `--fix`) |

## Related

- [/pentest](../pentest-agent/README.md) — web-application penetration testing
- [/infra-scan](../infra-scanner/README.md) — IaC, SBOM, and network scanning
