---
description: "Run a full project dependency audit and optimization. Analyzes outdated packages, security vulnerabilities, license compliance, and bundle size impact. Usage: /dependency-optimizer"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run a comprehensive dependency optimization for the project in $ARGUMENTS.

## Hand-off Rules (read first)

When invoking the `orchestrator` sub-agent, **do not assume a package manager or ecosystem**. Let the orchestrator detect the ecosystem from the project's root files (e.g., `package.json`, `requirements.txt`, `Cargo.toml`, `go.mod`).

- ❌ Bad: *"Optimize dependencies for the **npm** project"* — this primes the orchestrator with the wrong ecosystem if the project uses yarn, pnpm, or a monorepo with multiple managers.
- ✅ Good: *"Optimize dependencies for the project. Detect the package manager and ecosystem from the lockfiles before doing anything else."*

The orchestrator's first action is always to scan for manifest and lockfiles — do not pre-empt it.

## What This Does

This command invokes the **orchestrator** agent, which coordinates four specialized reviewers in parallel:

| Reviewer | Focus |
|----------|-------|
| `vulnerability-scanner` | CVE checks, OWASP advisories, deprecated packages, supply-chain risk |
| `version-updater` | SemVer drift, patch/minor/major classification, breaking-change risk |
| `bloat-analyzer` | Bundle size, unused dependencies, duplicate transitive packages |
| `license-auditor` | Copyleft detection (GPL/AGPL), license compatibility, corporate policy |

## How to Use

```
/dependency-optimizer              # Scan and optimize the project in the current directory
/dependency-optimizer path/to/sub  # Scan a specific sub-project or workspace
```

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How the report is posted |
|---|---|---|
| `github.com` | GitHub | GitHub CLI (`gh`) — PR opened for fixes, comment for reports |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`) — PR or thread posted |
| Anything else | Generic | Written to `dependency-optimization-report.md` |

## Output and Health Status

The optimization produces a structured report with one of three health statuses:

| Status | Meaning | Action taken |
|---|---|---|
| `SECURE` | No CVEs, no drift, no bloat, clean licenses | Report posted as comment only |
| `FIXES AVAILABLE` | Safe updates exist and were auto-applied | New branch + PR opened automatically |
| `MANUAL INTERVENTION` | Critical CVEs, major version breaks, or license violations | Report posted with manual steps |

See `styles/dependency-template.md` for the full report format.

## Available Skills

| Skill | Description |
|-------|-------------|
| `/optimize-dependencies` | Full optimization — analysis + auto-fix PR (same as this command via skill) |
| `/scan-dependencies` | Full analysis report only — no changes applied |
| `/fix-vulnerabilities` | Patch CRITICAL and HIGH CVEs only |
| `/update-versions` | Apply safe patch/minor version updates only |
| `/check-outdated` | Read-only view of all outdated packages |
| `/audit-licenses` | License compliance report only |

## Prerequisites

- Must be run inside a git repository
- **GitHub**: `gh` CLI installed and authenticated (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE-DEVOPS-TOKEN` environment variable set (see `docs/platform-setup.md`)
- **Push / PR creation**: `GITHUB-TOKEN` (GitHub) or `AZURE-DEVOPS-TOKEN` (Azure DevOps) required for `git push`

---

Starting dependency optimization now...
