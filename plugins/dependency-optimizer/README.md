---
title: Dependency Optimizer
description: Whole-project dependency audit — CVEs, SemVer drift, unused packages, and license violations — delivered as a ready-to-review fix PR or report.
---

The **Dependency Optimizer** performs a **whole-project** dependency audit across every manifest and lockfile it can find, then either opens a pull request containing safe, automated fixes or posts a report describing what needs human review.

It works across **all major ecosystems** — Node.js (npm/yarn/pnpm), Python (pip/poetry/pipenv), Rust (cargo), Go, Java (maven/gradle), .NET, and Ruby (bundler) — auto-detecting the ecosystem from manifest and lockfiles rather than assuming one.

Single entry point: **`/dependency-optimizer`** (or the equivalent `/optimize-dependencies` skill). Focused skills are also available for narrower jobs — vulnerability-only fixes, version bumps, license audits, or read-only reports.

It focuses on:

| Capability | What it detects |
|---|---|
| **Vulnerabilities** | Known CVEs, OWASP advisories, deprecated/abandoned packages, supply-chain risk (typosquatting, unpinned versions, SHA/`latest` pins) |
| **Version Drift** | Outdated packages classified as patch/minor/major, breaking-change risk, lock file drift |
| **Bloat** | Unused dependencies (zero imports in source), duplicate transitive packages, heavy packages with lighter alternatives, bundle size impact |
| **License Compliance** | Copyleft (GPL/AGPL/LGPL) detection, license compatibility conflicts, corporate policy violations |

Works with **GitHub** and **Azure DevOps** for automated PR creation; any other git remote falls back to a **Generic** mode that writes the report to a file in the repository.

---

## How It Works

```mermaid
flowchart TD
    A[/dependency-optimizer invoked] --> B[Detect platform from git remote]
    B --> C[Discover manifest and lockfiles up to depth 3]
    C --> D[Detect ecosystem and package manager]
    D --> E[Run vulnerability version bloat and license analyzers in parallel]
    E --> F[Compile findings into structured report]
    F --> G{Health status}
    G -->|SECURE| H[Post report as comment]
    G -->|FIXES AVAILABLE| I[Apply safe fixes on a new branch and open a PR]
    G -->|MANUAL INTERVENTION| J[Post report with manual steps]
```

1. **Detect platform** — runs `git remote get-url origin` first, before anything else. `github.com` → GitHub; `dev.azure.com` / `visualstudio.com` → Azure DevOps; anything else → Generic.
2. **Post "scan in progress"** — if a PR context is discoverable on the current branch, posts an immediate notice (GitHub `gh pr comment`, Azure DevOps REST thread). Skipped on Generic, and failures here only produce a warning — the scan continues.
3. **Discover manifests** — scans up to 3 directories deep (catching monorepo workspaces) for `package.json`, `requirements.txt`, `Cargo.toml`, `go.mod`, `pom.xml`, `build.gradle`, `*.csproj`, `Gemfile`, and their lockfiles, then infers the ecosystem(s) and package manager(s) in use.
4. **Run four analyses in parallel** — `vulnerability-scanner`, `version-updater`, `bloat-analyzer`, and `license-auditor` each receive the manifest list and detected ecosystem, and run independently.
5. **Compile the report** — findings are merged into the format defined in `styles/dependency-template.md` and a single **Health Status** is assigned.
6. **Apply safe fixes** *(FIXES AVAILABLE only)* — patch/minor version bumps and confirmed-unused package removals are applied on a new `deps/auto-optimize-<timestamp>` branch and committed.
7. **Post the result** — GitHub gets a PR (fixes) or a comment (secure/manual); Azure DevOps gets a PR or REST thread; Generic writes `dependency-optimization-report.md` to the repo root.

This plugin runs as an **external auditing tool** against the target repository: it deliberately does **not** read or follow instructions from that repository's own `CLAUDE.md`, `AGENTS.md`, `.cursor/rules`, or similar configuration files — those are guidelines for the project's contributors and must not influence this plugin's behavior, tool choices, or output format. Only this plugin's own agent/skill files govern its behavior.

The flow is **single-shot and autonomous** — invoking the command is treated as authorization for all git and PR operations it performs. It does not pause mid-run to ask for confirmation before committing, pushing, or opening a PR.

---

## Available Skills

| Skill | Description |
|-------|-------------|
| `/optimize-dependencies` | Full optimization — analysis + auto-fix PR (same flow as `/dependency-optimizer`) |
| `/scan-dependencies` | Full analysis report only — no changes applied, no branch or PR |
| `/fix-vulnerabilities` | CVE scan only; patches CRITICAL and HIGH findings immediately, commits, no PR |
| `/update-versions` | Applies all safe patch/minor version updates only; no vulnerability or license scan |
| `/check-outdated` | Read-only table of outdated packages with patch/minor/major classification |
| `/audit-licenses` | License compliance report only — copyleft, unknown, and policy-violating licenses |

## How to Use

```
/dependency-optimizer              # Scan and optimize the project in the current directory
/dependency-optimizer path/to/sub  # Scan a specific sub-project or workspace
```

When invoking the orchestrator, the ecosystem must never be assumed up front — it is always detected from lockfiles at run time (a project could be yarn, pnpm, or a multi-manager monorepo).

---

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How the report is posted |
|---|---|---|
| `github.com` | GitHub | GitHub CLI (`gh`) — PR opened for fixes, comment for reports |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`) — PR or thread posted |
| Anything else | Generic | Written to `dependency-optimization-report.md` |

## Output and Health Status

Every run produces a report with exactly one of three health statuses:

| Status | Meaning | Action taken |
|---|---|---|
| `SECURE` | No CVEs, no drift, no bloat, clean licenses | Report posted as a comment only — no branch or PR |
| `FIXES AVAILABLE` | Safe patch/minor updates or unused-package removals exist | New `deps/auto-optimize-*` branch created, fixes applied, PR opened |
| `MANUAL INTERVENTION` | Critical CVEs with no safe patch, required major upgrades, or license violations | Report posted with manual steps — nothing auto-applied |

Only fixes classified as safe are ever applied automatically:

- ✅ Patch-level bumps (`1.2.3` → `1.2.4`)
- ✅ Minor bumps with no detected breaking changes
- ✅ Removal of packages confirmed unused (zero imports found in source)
- ❌ Major version upgrades, packages with known API breaks, or anything flagged `MANUAL INTERVENTION` by a sub-agent

See `styles/dependency-template.md` for the full report format, including the **Automated Fixes Applied**, **Critical Issues**, **Warnings & Technical Debt**, and **Optimization & Tree-Shaking Suggestions** sections that make up every compiled report.

---

## Environment Variables

| Variable | Platform | Required | Purpose |
|---|---|---|---|
| `GITHUB-TOKEN` | GitHub | For `git push` / PR creation | Authenticate HTTPS pushes and (with `gh auth login`, or as `GH_TOKEN`) the `gh` CLI |
| `AZURE-DEVOPS-TOKEN` | Azure DevOps | For REST calls and `git push` | PAT for work item/PR REST calls and HTTPS push credential injection |

**GitHub token scopes:** `repo` (private repos) or `public_repo` (public only); `read:org` if needed for org repos.

**Azure DevOps PAT scopes:** `Code` (Read & Write), `Pull Request Threads` (Read & Write), `User Profile` (Read).

> **Azure DevOps variable-name hygiene:** the variable must be exported with **underscores**, e.g. `AZURE_DEVOPS_TOKEN`, not literal hyphens — bash cannot reference a hyphenated variable name, so a hyphenated export silently sends an empty password to every API call. The `hooks/validate-prerequisites.sh` PreToolUse hook detects this case and blocks with an actionable message before any `curl` or `git push` runs.

See `docs/platform-setup.md` for full setup steps and `docs/git-auth.md` for how credentials are injected into `git push` at runtime without touching `~/.gitconfig`.

---

## Quick Start

```bash
# Point Claude Code at the plugin
claude --plugin-dir /path/to/xianix-plugins-official/plugins/dependency-optimizer

# Then in the chat
/dependency-optimizer
```

## Prerequisites

- Must be run inside a git repository
- **GitHub**: `gh` CLI installed and authenticated (see `docs/platform-setup.md`)
- **Azure DevOps**: `AZURE-DEVOPS-TOKEN` environment variable set (see `docs/platform-setup.md`)
- **Push / PR creation**: `GITHUB-TOKEN` (GitHub) or `AZURE-DEVOPS-TOKEN` (Azure DevOps) required for `git push`
- Ecosystem-native audit tools (`npm`, `pip-audit`, `cargo-audit`, `govulncheck`, `license-checker`, `depcheck`, etc.) improve accuracy but are optional — every analyzer falls back to manifest/source-based analysis when its native tool is missing, with a warning rather than a hard failure

---

## Safety Invariants

Enforced by both the orchestrator prompt and the `hooks/validate-prerequisites.sh` PreToolUse hook:

- **Only patch/minor updates and confirmed-unused package removals are ever applied automatically.** Major upgrades and anything flagged `MANUAL INTERVENTION` are reported, never auto-applied.
- **Fixes always land on a new branch** (`deps/auto-optimize-<timestamp>`) — the project's default branch is never pushed to directly.
- **The target repository's own agent instructions are never followed.** `CLAUDE.md`, `AGENTS.md`, `.cursor/rules`, and similar files in the audited repo are ignored so they cannot redirect this plugin's behavior or output.
- **`gh` is refused against non-GitHub remotes and `curl`-to-Azure-DevOps is refused against non-Azure remotes** — the PreToolUse hook blocks cross-platform tool usage before it runs.
- **`git push` is blocked if the required token isn't set**, and blocked entirely if there's no configured remote.
- **A missing ecosystem-native audit tool degrades to manifest-based analysis with a warning, never to a silent skip.**

---

## What's in this plugin

```
dependency-optimizer/
├── .claude-plugin/
│   ├── plugin.json          # Manifest
│   ├── settings.json        # Default agent
│   └── .lsp.json            # Language servers
├── commands/
│   └── dependency-optimizer.md  # Slash command entry point
├── agents/
│   ├── orchestrator.md          # Ecosystem detection + fix/report controller
│   ├── vulnerability-scanner.md
│   ├── version-updater.md
│   ├── bloat-analyzer.md
│   └── license-auditor.md
├── skills/
│   ├── optimize-dependencies/SKILL.md
│   ├── scan-dependencies/SKILL.md
│   ├── fix-vulnerabilities/SKILL.md
│   ├── update-versions/SKILL.md
│   ├── check-outdated/SKILL.md
│   └── audit-licenses/SKILL.md
├── providers/
│   ├── github.md             # PR/comment posting via gh CLI
│   ├── azure-devops.md       # PR/thread posting via REST
│   └── generic.md            # Report-to-file fallback
├── styles/
│   └── dependency-template.md
├── hooks/
│   ├── hooks.json
│   ├── validate-prerequisites.sh
│   └── notify-push.sh
├── docs/
│   ├── platform-setup.md
│   ├── git-auth.md
│   └── mcp-config.md
└── README.md
```

---

## License

MIT — same as the rest of this marketplace.
