# Round Comment Templates

Every comment the plugin posts follows one of these variants. The orchestrator posts **exactly one** per invocation.

Hard limits:

- Max **5** questions per round. Max **2** newly-surfaced questions in a follow-up round.
- Each question: one bold line + ≤1 sentence of why + a `Default:`. No sub-bullets.
- No findings tables, no lens sections, no restating the issue back at the author.
- The **footer line is mandatory and must keep its exact shape** — the next run parses it to determine state:

  ```
  `req-analyst` · round <N>/3 · status: **<awaiting answers | awaiting split confirmation | ready>** · open: <M>
  ```

Question ids (`Q1`, `Q2`, …) are assigned once and never renumbered. A re-phrased question keeps its id.

---

## Variant A — Round 1

```markdown
## Requirement analysis — round 1 of 3

**What I understand:** <2–3 sentences: who this is for, what they need, what "done" looks like. Include the one Fit-note finding if it changes scope — e.g. "This overlaps with `docs/prd/billing.md` §3, which already specifies X.">

**Decisions I need before this is ready:**

1. **Q1 — <one-line question>** — <why it matters, ≤1 sentence>. *Default: <what I will assume if unanswered>.*
2. **Q2 — <one-line question>** — <why>. *Default: <…>.*
3. **Q3 — …**

**How to reply:** comment `@xianix` with numbered answers, e.g. `@xianix 1. yes 2. admins only 3. skip for v1` — or `@xianix go with defaults`.

<details><summary>Analyst notes (optional)</summary>

- **Intent:** …
- **Journey:** …
- **Personas:** …
- **Domain:** …
- **Fit:** …

</details>

---
`req-analyst` · round 1/3 · status: **awaiting answers** · open: 3
```

Omit the `<details>` block on Azure DevOps.

---

## Variant B — Follow-up round (2 or 3)

```markdown
## Requirement analysis — round 2 of 3

**Applied to the description:**
- Q1 → <decision in ≤10 words> (@alice)
- Q3 → <decision> (@alice)

**Still open:**

2. **Q2 — <question, possibly narrowed based on the answers>** — <why>. *Default: <…>.*
4. **Q4 — <new question surfaced by the answer to Q1>** — <why>. *Default: <…>.*

Reply with `@xianix` + numbered answers, or `@xianix go with defaults`. After round 3 I will go with the defaults and mark this ready.

---
`req-analyst` · round 2/3 · status: **awaiting answers** · open: 2
```

---

## Variant C — Ready to proceed

```markdown
## Ready to proceed

The description now reflects the decisions from this thread: <one sentence stating the requirement as agreed>.

**Assumptions I made** (flagged in the description — correct any of them with an `@xianix` comment):
- Q4 → assumed <default> (no answer by round 3)
- Q5 → assumed <default> (not asked; low impact)

Labelled `groomed`.

---
`req-analyst` · round 2/3 · status: **ready** · open: 0
```

Omit the *Assumptions* block entirely if there are none. Use the round number of the last question round (or `1/3` when the item was ready on the first pass).

---

## Variant D — Decomposition proposal

```markdown
## This looks like more than one item

<1–2 sentences on why: distinct user goals / domains / more than ~8 critical decisions.>

**Proposed split:**

1. **<Child title>** — <one line: who / what / why>
2. **<Child title>** — <…>
3. **<Child title>** — <…>

Reply `@xianix split` to create these as linked items (each will get its own grooming round), or reply with edits to the split, or `@xianix keep as one` to groom it as a single item.

---
`req-analyst` · round 1/3 · status: **awaiting split confirmation** · open: 0
```

---

## Variant E — Updated (change request on a READY item)

```markdown
## Updated

- <what changed in the description, one line per change> (@bob)

Still `groomed`.

---
`req-analyst` · round 3/3 · status: **ready** · open: 0
```

---

## Variant F — Reply to a question

No heading. ≤3 sentences answering the question. Then the footer with the **same** round and status as the previous agent comment, so the state does not advance.

```markdown
By Q3 I mean whether a user who already has an active subscription should see the upgrade banner at all, or only after it lapses. The default keeps it hidden while active.

---
`req-analyst` · round 1/3 · status: **awaiting answers** · open: 3
```
