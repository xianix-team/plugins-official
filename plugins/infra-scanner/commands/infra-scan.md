---
name: infra-scan
description: Run an authorized infrastructure security scan. Covers Infrastructure-as-Code misconfigurations (Dockerfile, Terraform, Kubernetes, GitHub Actions), SBOM generation, and optional network port + TLS scanning when a target URL is supplied. Produces infra-report.html, infra-report.md, and infra-report.json locally. Usage: /infra-scan [target-url] --authorized [options]
argument-hint: [target-url] --authorized [--fix | --fix-dry-run]
---

Run an infrastructure security scan against the current repository and (optionally) `$ARGUMENTS`.

## IMPORTANT — Authorization Required

The `--authorized` flag confirms you have permission to scan. Without it the command refuses to run. If a `target-url` is provided, you also confirm permission to network-probe that host.

## What This Does

This command invokes the **orchestrator** agent which coordinates:

| Agent | Focus |
|---|---|
| `iac-scanner` | Dockerfiles, Terraform, Kubernetes manifests, GitHub Actions workflows |
| `sbom-generator` | CycloneDX Software Bill of Materials via trivy or syft |
| `network-scanner` | Open ports, service fingerprinting, TLS certificate validity (only runs when a `target-url` is supplied) |

The **report-writer** then compiles findings into structured reports.

## Usage Examples

```bash
# Full infra scan with network probe
/infra-scan https://staging.myapp.com --authorized

# Code-only scan (no network probe)
/infra-scan --authorized

# Preview the auto-fix diff for the top finding (no git operations)
/infra-scan --authorized --fix-dry-run

# Open a draft PR for the single top mechanically-fixable finding
/infra-scan --authorized --fix
```

## Flags

| Flag | Effect |
|---|---|
| `--authorized` | **Required.** Confirms you have permission to scan. Without it the command refuses to run. |
| `--fix` | **Open a draft PR** with the single most important mechanically-fixable finding. Creates an isolated `git worktree` off `origin/<default-branch>`, applies the fix on a new branch `infra-fix/<finding-id>`, commits, pushes, and opens a draft PR via `gh` (GitHub) or `az repos pr create` (Azure DevOps). **Never modifies your working tree.** Limited to safe mechanical categories: Terraform/Kubernetes config-flag swaps (`encrypted`, `privileged`, `hostNetwork`, `hostPID`) and GitHub Action SHA-pinning. Re-run after merging the PR to open the next one. Open ingress, public DB, hardcoded creds, secret-in-ENV, curl\|bash, `latest`-tag, and workflow-injection findings never get a PR — they stay as report guidance. |
| `--fix-dry-run` | Print the proposed diff for the single top finding. **No git operations at all** — no branch, no commit, no push, no PR. Use this first to preview the change before letting `--fix` open the PR. |

## Output

- `infra-report.html` — styled HTML report
- `infra-report.md` — Markdown report
- `infra-report.json` — canonical JSON
- `infra-sbom.json` — CycloneDX SBOM (if generator succeeded)
- `infra-evidence/` — raw tool outputs (nmap XML, trivy JSON, hadolint JSON, etc.)

## Prerequisites

### Required

| Tool | Min Version | Notes |
|---|---|---|
| `nmap` | 7.80+ | Only required when scanning a target URL |

### Optional (plugin degrades gracefully if absent)

| Tool | Purpose |
|---|---|
| `hadolint` | Dockerfile linting |
| `tfsec` | Terraform scanning |
| `checkov` | Terraform/k8s scanning |
| `kubesec` | Kubernetes manifest risk scoring |
| `trivy` | SBOM + container config |
| `syft` | SBOM generation (fallback) |

## Related

For web-application penetration testing (OWASP web probes, SAST, secrets, dependency CVEs), see [/pentest](../pentest-agent/commands/pentest.md).

---

Starting infrastructure scan now...
