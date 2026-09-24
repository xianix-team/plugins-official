# infra-scanner

Authorized infrastructure security scanning plugin. Companion to [pentest-agent](../pentest-agent/README.md) — covers the infrastructure surface (IaC, SBOM, network ports/TLS) that pentest-agent v3.0+ deliberately leaves out so it can focus on web-application pentesting.

## What It Does

| Category | Tools Used | What It Checks |
|---|---|---|
| IaC Security | `hadolint`, `tfsec`, `checkov`, `kubesec` | Dockerfile, Terraform, Kubernetes, GitHub Actions misconfigurations |
| SBOM Generation | `trivy`, `syft` | CycloneDX Software Bill of Materials for supply-chain compliance |
| Network Scanning | `nmap`, `openssl` | Open ports, service versions, TLS certificate validity and expiry |

## Quick Start

```bash
# Full infra scan with network probe
/infra-scan https://staging.myapp.com --authorized

# Code-only scan (no network probe — no URL needed)
/infra-scan --authorized

# Preview the auto-fix diff for the top finding (no git operations)
/infra-scan --authorized --fix-dry-run

# Open a draft PR for the single top mechanically-fixable finding
/infra-scan --authorized --fix
```

The `--authorized` flag is **required**.

## Output

| File | Description |
|---|---|
| `infra-report.html` | Styled HTML with severity grid |
| `infra-report.md` | Plain Markdown |
| `infra-report.json` | Machine-readable canonical output |
| `infra-sbom.json` | CycloneDX SBOM (if trivy or syft is installed) |
| `infra-evidence/` | Raw tool outputs (nmap XML, trivy JSON, hadolint JSON, etc.) |

## Architecture

```
orchestrator
├── Phase 0: Authorization gate + setup
├── Phase 1 (parallel):
│   ├── iac-scanner       Dockerfile, Terraform, k8s, GHA misconfigs
│   ├── sbom-generator    CycloneDX SBOM via trivy/syft
│   └── network-scanner   nmap + TLS check (only when target URL given)
├── Phase 2:
│   └── report-writer     Merges JSON, applies suppression, synthesizes fix objects, writes reports
└── Phase 3 (only with --fix):
    └── fix-writer        Opens a draft PR for the top mechanically-fixable finding on a
                          worktree off origin/<default-branch>. Working tree never touched.
```

## Auto-fix via PR (`--fix`)

**Nothing is ever automatically applied to your code.** `--fix` opens a draft Pull Request with a single proposed change; you review and merge it via your normal workflow.

What it does, in order:

1. **Pick** the single highest-priority mechanically-fixable finding (severity → category preference).
2. **Skip** it if an `infra-fix/<finding-id>` PR is already open (so re-runs don't spam PRs).
3. **Create an isolated `git worktree`** off `origin/<default-branch>` — your current branch and uncommitted work are never touched.
4. **Apply** the one fix inside the worktree.
5. **Commit** on a new branch `infra-fix/<finding-id>`.
6. **Push** the branch.
7. **Open a draft PR** via `gh pr create --draft` (GitHub) or `az repos pr create --draft true` (Azure DevOps).
8. **Clean up** the worktree (the branch is kept for the PR).
9. **Append** a "Fix PR Opened" section to `infra-report.md`.

Re-run `/infra-scan --authorized --fix` after merging the PR to address the next finding.

### Which findings get a PR

Only safe, template-computable changes — everything else stays as report guidance:

| Fixable | Change |
|---|---|
| `IAC-TF-UNENCRYPTED` | `encrypted = false` → `true` |
| `IAC-K8S-PRIVILEGED` | `privileged: true` → `false` |
| `IAC-K8S-HOST-NETWORK` | `hostNetwork: true` → `false` |
| `IAC-K8S-HOST-PID` | `hostPID: true` → `false` |
| `IAC-GHA-UNPINNED-ACTION` / `IAC-GHA-MUTABLE-ACTION` | pin `uses:` to a commit SHA (via `gh api`) |

Open ingress, public DB, hardcoded creds, secret-in-ENV, `curl \| bash`, `latest`-tag, ADD-url, and workflow-injection findings are **never** auto-fixed — they require human judgment.

### Edge cases

- **`--fix-dry-run`** — prints the proposed diff and performs **zero git operations** (no branch, commit, push, or PR). Preview before committing to `--fix`.
- **`branch-pushed-no-pr`** — branch pushed but `gh`/`az` is unavailable or unauthenticated; a compare URL is printed instead.
- **`branch-only`** — push failed; the local branch with the commit is preserved and manual-push instructions are printed.
- **drift → `skipped`** — the file changed on `origin/<default-branch>` since the scan; no PR is opened.
- **`all-top-findings-pr-open`** — every fixable finding already has an open `infra-fix` PR; merge or close them first.

## Suppressing Findings (`.infra-ignore`)

```
# Exact ID
IAC-DOCKER-LATEST-TAG

# Wildcard
IAC-GHA-*
```

## Prerequisites

### Required (only when scanning a network target)

- `nmap` 7.80+

### Optional

- `hadolint`, `tfsec`, `checkov`, `kubesec`, `trivy`, `syft` — install whichever match the IaC types in your repo

## Related

For **web application** penetration testing — OWASP Top 10 probes, SAST, secrets detection, dependency CVEs, and source-code recon that drives the URL probing — install [pentest-agent](../pentest-agent/README.md). The two plugins are designed to be used together when you need both infra and web coverage.

## License

MIT — Copyright (c) Xianix
