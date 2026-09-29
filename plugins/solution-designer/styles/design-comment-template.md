# Design Comment Templates

One comment per run. The pictures live in the design doc (they render in the PR). The comment is a **table plus the decisions** — no approach paragraph, no pasted diagram.

Footer, exact shape, every comment:

```
`solution-designer` · r<N> · status: **<needs decision | proposed | approved | blocked>** · open: <M>
```

`D1`, `D2`, … are assigned once and never renumbered. Max 4 open decisions. Each is one line: question, then `Default:`.

---

## Needs decision

```markdown
## Design r1 — your decision

| | |
|---|---|
| **PR** | <url> |
| **Doc** | `docs/design/<id>-<slug>.md` — shape + flow diagrams |
| **Architecture** | complies · or **1 deviation → ADR-0012** |

| What changes | Where |
|---|---|
| `POST /orders/{id}/cancel` | `src/api/orders/routes.ts` |
| Cancellation policy **new** | `src/domain/orders/cancellation.ts` |
| `OrderCancelled` event | Payments (existing) |

1. **D1 — Refund sync or by event?** *Default: event (ADR-0007).*
2. **D2 — Partial cancel?** *Default: no.*

`@xianix 1. event 2. no` · `@xianix go with defaults`

---
`solution-designer` · r1 · status: **needs decision** · open: 2
```

The *What changes* table is the Shape table with only changed and new rows. Cap it at 6 rows; the doc has the rest.

## Proposed

```markdown
## Design r2 — ready for review

| | |
|---|---|
| **PR** | <url> |
| **Architecture** | complies · ADR-0012 proposed |
| **Applied** | D1 → event (@alice) · D2 → no (default) |

Merge the PR, or `@xianix approve`. `@xianix <feedback>` to revise.

---
`solution-designer` · r2 · status: **proposed** · open: 0
```

Drop the *Applied* row on r1.

## Revised

Same as Needs decision or Proposed. Heading `## Design r<N> — revised`. Add one row:

| **Changed** | D1 → event (@alice) · AC3 failure path |

Requirement edited since the design: `| **Changed** | requirement updated — <what moved in the design> |`

## Approved

```markdown
## Design approved

| | |
|---|---|
| **By** | PR merged by @bob |
| **Doc** | `docs/design/<id>-<slug>.md` |
| **Still open** | ADR-0012 needs ratification |

---
`solution-designer` · r<N> · status: **approved** · open: 0
```

Drop *Still open* when there is no proposed ADR.

## Not groomed

```markdown
## Not ready for design

No `groomed` label and no finished grooming. Add `ai-dlc/issue/analyze`, or `@xianix design anyway`.

---
`solution-designer` · r0 · status: **blocked** · open: 0
```

## Question back

One or two lines, no heading. Footer repeats the previous revision and status, so the round does not advance.

## Blocked on the requirement

```markdown
## Design blocked

| Conflict | R2 wants real-time stock · AC4 allows 5-minute staleness |
| Unblock | Resolve it on the requirement — I'll redesign when the description changes |

---
`solution-designer` · r<N> · status: **blocked** · open: 1
```

Azure DevOps: post the same Markdown with `format=markdown`. Do not put Mermaid in the comment — work-item discussions do not render it. The diagrams are in the doc.
