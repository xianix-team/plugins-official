# Group notes template (`/tmp/prg/group_notes.md`)

The review lead writes this file once per group run. `scripts/group-post.sh` places it under the group table that it generates, and appends the result to **every** member's summary — so write it for a reader looking at any one of the PRs.

Use exactly these sections, in this order. Omit a section only when it has nothing in it.

```markdown
### Cross-repo findings
- 🔴 **contract-drift** — orders-api `src/Orders/OrderDto.cs:42` ↔ web `src/api/orders.ts:118`: `totalAmount` renamed to `total`, web still reads `totalAmount`. Fix in web.
- 🟡 **ordering-hazard** — orders-api `Startup.cs:88` needs the `orders.total` column from db-schema `migrations/0042_total.sql:3`.

### Suggested merge order (advisory)
db-schema → orders-api → web — the migration adds the column orders-api reads.
```

Rules:
- One bullet per cross-repo finding: severity icon (🔴 CRITICAL, 🟡 WARNING, 🔵 SUGGESTION), **category**, `member path:line` ↔ `member path:line`, one sentence, which member should change.
- When there are no cross-repo findings, write `### Cross-repo findings` followed by `- None found.`
- The merge order is **advice only**. Never phrase it as a requirement, and never let it change a verdict. Write `Any order.` when the reviewer returned `MERGE_ORDER: any`.
- Do not repeat per-PR findings here; each PR's own report carries them.
