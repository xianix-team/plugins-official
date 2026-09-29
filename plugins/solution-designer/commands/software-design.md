---
name: software-design
description: Produce a software design for a groomed backlog item that conforms to the repository's accepted architecture. Opens a design PR with docs/design/<id>-<slug>.md (plus proposed ADRs where the design needs an architecture change) and posts a short comment with the decisions needed. Follow-up @xianix replies revise the design. Works with GitHub Issues, Azure DevOps Work Items, or plain text. Usage: /software-design [issue-number | work-item-id]
argument-hint: [issue-number | work-item-id] [--force]
---

Take the next design step on backlog item $ARGUMENTS.

## What This Does

Invokes the **orchestrator** agent for **one turn**:

1. **Read** the item, its description (including the `req-analyst` refined requirement), and the comment thread.
2. **Gate** — the item must be groomed (`groomed` label/tag, or `req-analyst` status *ready*). If not, it posts a short note and stops. `--force` or a `@xianix design anyway` reply overrides.
3. **Understand the architecture** — `architecture-analyst` reads `docs/architecture/` (constraints and ADRs maintained by `arch-fitness`), other ADR folders and architecture docs, and surveys the code the requirement touches.
4. **Design** — `solution-designer` writes the design doc within that architecture: components with real paths, interfaces, data, key flows, cross-cutting concerns, traceability to every requirement / AC, and an implementation plan. Any needed deviation becomes a **proposed ADR**, never a silent one.
5. **Review** — `design-reviewer` checks conformance, traceability, and grounding; one fix pass.
6. **Deliver** — commit to `design/<id>-<slug>`, open or update the design PR, post one short comment, set the design label.

## States

| State | Action |
|---|---|
| Not groomed | Post *Not ready for design yet*; stop |
| New | Full design → PR → comment (`design-needs-decision` or `design-proposed`) |
| Humans replied `@xianix …` | Apply decisions / feedback → revise doc on the same branch → comment |
| Requirement edited after the design | Re-design against the new requirement, summarise changes |
| Design PR merged, or `@xianix approve` | `design-approved` |
| Waiting | Nothing |

## How Humans Reply

```
@xianix 1. event  2. no partial cancel
@xianix go with defaults
@xianix use the existing NotificationService instead of a new queue
@xianix approve
```

Or review the design PR directly — merging it accepts the design.

## Output

```
Design proposed on #42: <PR url> — conformance PASS — 0 open decisions
Design needs decision on #42: <PR url> — 2 open decisions, 1 proposed ADR
```

## Prerequisites

- **GitHub:** `gh` authenticated; Contents, Issues, Pull requests: Read & Write
- **Azure DevOps:** `AZURE-DEVOPS-TOKEN` with Work Items and Code: Read & Write
- git `user.name` / `user.email` configured

---

Reading the item now...
