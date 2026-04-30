---
name: requirement-analysis
description: Surround a backlog item with the context a senior analyst would bring to a refinement session — fit with existing requirements, domain knowledge, competitive insight, user journeys, persona impact, usability and adoption considerations, and open questions. Works with GitHub Issues, Azure DevOps Work Items, or plain text. Usage: /requirement-analysis [issue-number or work-item-id]
argument-hint: [issue-number | work-item-id]
---

Elaborate the backlog item $ARGUMENTS — act as a thinking partner, not a gatekeeper.

## What This Does

This command invokes the **orchestrator** agent. It fetches the item, indexes the repository for product/requirements documents (PRDs, specs, RFCs, ADRs, feature briefs, user stories), reasons about how the new ask fits the existing product context, then runs four analysts in parallel followed by a Gap & Risk pass.

**Phase 1 — Context lenses (parallel):**

| Analyst | Lens |
|---------|------|
| `intent-analyst` | The "why" behind the ask — underlying user need, success definition, current workaround |
| `domain-analyst` | Domain knowledge, terminology, regulations, and how comparable products / competitors approach the same problem |
| `journey-mapper` | End-to-end user workflow this change participates in — upstream triggers, downstream consequences, **usability touchpoints and friction risks** |
| `persona-analyst` | Affected personas, where their goals diverge, and **adoption considerations** (onboarding, migration, change management, success signals) |

**Phase 2 — Gap & Risk:**

| Analyst | Lens |
|---------|------|
| `gap-risk-analyst` | Open questions, assumptions worth validating, acceptance criteria worth tightening — framed as **prompts for the team**, not blockers |

The orchestrator also reasons explicitly about **fit with existing requirements** — overlaps, dependencies, contradictions, and gaps at the **product/requirements level** (not the code level).

## How to Use

```
/requirement-analysis 42          # Elaborate GitHub issue #42 or Azure DevOps work item #42
```

## Platform Support

The plugin auto-detects the hosting platform from your git remote URL:

| Remote URL contains | Platform | How items are fetched | How elaboration is delivered |
|---|---|---|---|
| `github.com` | GitHub | `gh` CLI | Ordered comments via `gh` CLI |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | REST API (`curl`) | Ordered comments via REST |
| Anything else | Generic / plain text | User-provided | Written to `requirement-elaboration-report.md` |

## How It Posts

Each lens is posted as a **separate comment** on the issue/work item, preserving the original description. The thread looks like:

1. **Elaboration Summary** — a short overview, the readiness signal, and the key takeaways
2. **Fit with Existing Requirements** — overlaps, dependencies, contradictions, gaps with PRDs/specs/ADRs/feature briefs already in the repo
3. **Intent & User Context** — the underlying need, situational context, decision points
4. **User Journey** — upstream triggers, downstream consequences, usability touchpoints, friction risks
5. **Personas & Adoption** — affected user types, where goals diverge, onboarding/migration/change-management considerations
6. **Domain & Competitive Context** — concepts, terminology, regulations, how comparable products solve this
7. **Open Questions & Gaps** — assumptions to validate, ACs worth tightening — as prompts for the next refinement

Sections that yield no real findings are **skipped**, not filled with "None identified."

## Readiness Signal (Hint, Not a Gate)

A lightweight label/tag is also applied as a triage hint — but the real value is in the elaboration itself. The team decides what to do next.

| Signal | What it means |
|---|---|
| `GROOMED` | Intent is clear and the elaboration didn't surface critical open questions |
| `NEEDS CLARIFICATION` | Worth a short conversation before development picks it up |
| `NEEDS DECOMPOSITION` | Likely too large — the elaboration suggests how it might split |

## After the Elaboration

The agent outputs:

```
Elaboration posted on issue #<number>: <signal> — <N> comments — <N> open questions
```

## Prerequisites

- **GitHub**: `gh` CLI installed and authenticated (see `docs/platform-config.md`)
- **Azure DevOps**: `AZURE-DEVOPS-TOKEN` environment variable set (see `docs/platform-config.md`)
- **Plain text / unknown platform**: nothing — the report is written to a local file

---

Starting elaboration now...
