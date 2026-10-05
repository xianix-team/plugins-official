---
description: "Discover or bootstrap architecture-constraint docs, open a docs PR when needed, then evaluate a changeset scope (PR, branch, or merged-PR window) against those constraints and report the few most important improvements. Works with GitHub, Azure DevOps, and any git repository. Usage: /arch-fitness [scope] [--issue <n> | --workitem <id>] [--docs-only | --evaluate-only]"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run an architecture fitness evaluation for $ARGUMENTS.

## What This Does

1. **Capture inputs** — parse CLI args and, when attached to a task, the issue / work-item body config block.
2. **Detect platform** — read `git remote get-url origin` → GitHub / Azure DevOps / Generic.
3. **Discover architecture docs** — scan the repo for constraint-bearing architecture material.
4. **Bootstrap or refresh docs** — if none exist, draft a `docs/architecture/` set; if stale, update them. Drafted constraints are marked `status: proposed`.
5. **Open a docs PR** (when docs were created or updated) against the default branch.
6. **Assemble the changeset scope** — a single PR diff, a branch diff, or PRs merged in a date window.
7. **Evaluate fitness** against the constraint set (merged docs, or freshly drafted ones flagged as pending ratification).
8. **Report the top 3–5 improvements** via task comment, chat text, or an instructed output format.

Docs bootstrap and fitness evaluation run in the **same invocation**. Evaluation uses drafted docs immediately; the report marks them as pending human ratification when a docs PR was opened.

## How to Use

```
/arch-fitness                                          # current branch vs default (or last 30d merged PRs on default)
/arch-fitness 42                                       # evaluate PR #42
/arch-fitness --pr 42                                  # same
/arch-fitness feature/payments                         # evaluate a branch against the default branch
/arch-fitness "prs merged during last 3 months"        # date-window multi-PR scope
/arch-fitness --since 2026-04-16                       # merged PRs since a date
/arch-fitness --issue 123                              # attach to GitHub issue #123; parse body config
/arch-fitness --workitem 4567                          # attach to Azure DevOps work item #4567
/arch-fitness --docs-only                              # discover/bootstrap/update docs + open PR; skip evaluation
/arch-fitness --evaluate-only --pr 42                  # evaluate against existing docs only; skip docs PR
```

### Supported flags

| Flag | Accepts | Purpose |
|---|---|---|
| `--pr <n>` | positive integer | Evaluate a specific pull request |
| `--since <date>` | ISO date `YYYY-MM-DD` or relative phrase | Evaluate PRs merged since that date |
| `--issue <n>` | positive integer | GitHub only — attach run to an issue; parse body config; post comment |
| `--workitem <id>` | positive integer | Azure DevOps only — attach run to a work item; parse description; post comment |
| `--docs-only` | flag | Stop after docs bootstrap/update + docs PR |
| `--evaluate-only` | flag | Skip docs bootstrap/update; evaluate against existing constraints only |
| `--max-findings <n>` | positive integer (default 5) | Cap on reported improvements |
| `--focus <paths>` | comma-separated paths | Restrict evaluation to these areas |
| `--skip <paths>` | comma-separated paths | Exclude these areas from evaluation |

CLI flags override values parsed from the task body. Silently ignore unknown flags with a one-line `notice: ignoring unknown flag '<flag>'`.

### Scope resolution (priority order)

1. Explicit PR number (`42` or `--pr 42`) → single-PR diff.
2. Branch name → diff against the default branch.
3. Date window phrase (`"prs merged during last 3 months"`, `--since YYYY-MM-DD`) → merged PRs in that window.
4. No scope given:
   - If the current branch is **not** the default branch → current branch vs default.
   - If on the default branch **and** chat invocation → ask the user for scope (or suggest last 30 days).
   - If on the default branch **and** task invocation → default to last 30 days of merged PRs.

## Task Body Config Block

When invoked via a GitHub Issue or Azure DevOps Work Item (label/tag `ai-dlc/arch/fitness`), the body may contain:

```
ARCH FITNESS — START
Scope: prs merged during last 3 months
Focus areas: src/payments, src/api
Skip areas: src/legacy
Max findings: 5
Output: comment
Docs mode: auto
ARCH FITNESS — END
```

| Key | Values | Default |
|---|---|---|
| `Scope` | PR number, branch name, or date-window phrase | see scope resolution above |
| `Focus areas` | comma-separated paths | none |
| `Skip areas` | comma-separated paths | none |
| `Max findings` | integer 1–10 | 5 |
| `Output` | `comment` \| `file <path>` \| `json` | `comment` when attached to a task; chat text otherwise |
| `Docs mode` | `auto` \| `docs-only` \| `evaluate-only` | `auto` |

All keys optional. CLI flags override body values.

## Pipeline

```
/arch-fitness [scope] [--issue N | --workitem ID]
    │
    ├── Step 0: Detect platform (GitHub / Azure DevOps / Generic)
    ├── Step 1: Capture inputs (args + task body)
    ├── Step 2: Post "Architecture fitness in progress" comment (task mode only)
    │
    ├── Phase A–C (unless --evaluate-only):
    │     └── arch-doc-curator
    │           ├── Discover architecture docs
    │           ├── Bootstrap or update docs/architecture/
    │           └── Open docs PR (arch/docs-*) when changes exist
    │
    ├── Phase D (unless --docs-only):
    │     ├── Assemble changeset scope (see providers/)
    │     └── fitness-evaluator — evaluate constraints vs changeset; rank top findings
    │
    └── Route output (comment / chat / file / json) using styles/fitness-report.md
```

## Platform Support

| Remote URL | Platform | Docs PR | Fitness output |
|---|---|---|---|
| `github.com` | GitHub | `gh pr create` | `gh issue comment` (task) or chat text |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST `POST .../pullrequests` | work-item comment (task) or chat text |
| Anything else | Generic | push branch + report file | write `arch-fitness-report.md` |

Follow the matching file under `providers/`.

## Agents

| Agent | Role |
|---|---|
| `arch-doc-curator` | Discover, bootstrap, or update `docs/architecture/` and open the docs PR |
| `fitness-evaluator` | Evaluate the changeset against constraints; select top findings |

## Focused Skills

| Skill | When |
|---|---|
| `/arch-docs` | Docs discovery / bootstrap / update + docs PR only |
| `/arch-evaluate` | Evaluate against existing docs only (no docs PR) |

## Prerequisites

- Must be run inside a git repository
- **GitHub:** `gh` CLI installed and authenticated, or `GITHUB-TOKEN` / `GH_TOKEN` set (see `docs/platform-setup.md`)
- **Azure DevOps:** `AZURE-DEVOPS-TOKEN` environment variable set
- **Generic:** nothing required beyond git; output is a local report file

## Output

Render the report from `styles/fitness-report.md`:

- Verdict: `FIT` / `DRIFTING` / `AT RISK`
- Docs PR link (if one was opened) and ratification status
- Top findings table (capped by `Max findings`)
- Per-finding detail with constraint ID, evidence, why it matters, remediation
- Evaluated-scope summary

Routing:

| Mode | Destination |
|---|---|
| Task (`--issue` / `--workitem` / rule payload) and `Output: comment` | Comment on the issue / work item + label/tag `arch-fitness-complete` |
| Chat (no task attachment) | Print the report as the response |
| `Output: file <path>` | Write the report to that path |
| `Output: json` | Emit a JSON findings array (plus docs PR URL if any) |
| Generic remote | Always write `arch-fitness-report.md` in the repository root |

---

Starting architecture fitness analysis now...
