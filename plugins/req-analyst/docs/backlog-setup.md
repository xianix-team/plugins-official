# Backlog Setup

The `req-analyst` plugin grooms **GitHub Issues**, **Azure DevOps Work Items**, or **plain text** through a short conversation in the item's comment thread. This guide covers what to put in the item, which labels to create, and how to reply.

---

## Item Structure

The plugin works from a title alone, but the fewer gaps in the original, the fewer questions it has to ask.

| You provide | Expect |
|---|---|
| Title only | Round 1 asks about intent, actors, and scope — probably 4–5 questions |
| Title + a paragraph of intent | 2–4 targeted questions |
| Title + intent + constraints / links / draft acceptance criteria | 0–2 questions, often ready on the first pass |

Example of a well-seeded item:

```
Title: Add user profile page
Body:
Users should be able to view and edit their profile (name, email, avatar).
Part of epic #15. Design: [link]. GET /api/users/:id already exists.
Avatar upload: JPG/PNG only.
```

The plugin also reads the repository — `docs/`, `specs/`, `requirements/`, `adr/`, PRDs — so conflicts with existing decisions become questions ("ADR-007 says avatars are read-only; does this supersede it?").

---

## Labels / Tags

| Label / tag | Set by | Meaning |
|---|---|---|
| `ai-dlc/issue/analyze` | Human or another rule | **Trigger.** Start grooming this item. Never removed by the plugin. |
| `needs-clarification` | Plugin | A round of questions is open — reply on the thread |
| `needs-decomposition` | Plugin | Too large — a split is proposed or was created |
| `groomed` | Plugin | **Ready to proceed** — no open decisions; assumptions recorded in the description |

Exactly one of the three readiness signals is present at a time.

**GitHub:** create the labels once (the plugin will also create them if it has permission):

```bash
gh label create ai-dlc/issue/analyze --color 1D76DB --description "Groom this issue with req-analyst"
gh label create groomed              --color 0E8A16 --description "Requirement groomed — ready to proceed"
gh label create needs-clarification  --color FBCA04 --description "req-analyst is waiting on answers"
gh label create needs-decomposition  --color D93F0B --description "Too large — split proposed"
```

**Azure DevOps:** tags are created on first use.

---

## How to Reply

Answer in a comment on the item, addressing the agent. Questions keep their numbers across rounds, so `2.` always means `Q2`.

```
@xianix 1. yes  2. admins only  3. skip for v1
```

| Reply | Effect |
|---|---|
| Numbered answers (`1. …`, `Q2: …`, `#3 — …`) or prose | Folded into the description; next round or ready |
| `@xianix go with defaults` | All proposed defaults accepted → marked `groomed` |
| `@xianix split` / `@xianix keep as one` | Confirm or reject a proposed decomposition |
| `@xianix hold` | Pause — nothing happens until you reply again |
| `@xianix <question>` | Short answer, no state change |
| Edit the description directly | Also picked up — the next run re-checks open questions against it |

You can answer some questions and leave others; the next round only lists what is still open. After **3 rounds** the plugin applies the stated defaults, flags them **(assumed)**, and marks the item ready. Correct an assumption at any time with another `@xianix` comment — the description is updated and the item stays `groomed`.

---

## What the Plugin Changes on the Item

| Where | What |
|---|---|
| Comments | One short comment per turn, ending with a `req-analyst · round N/3 · status: …` footer |
| Description | Rewritten into: Summary · Scope · Requirements · Acceptance criteria · Decisions table · Open questions. The original text is kept verbatim in a collapsed *Original description* block. On Azure DevOps, acceptance criteria go into the *Acceptance Criteria* field when the work item type has one. |
| Labels / tags | One readiness signal swapped per turn |
| Child items | Only when a split is explicitly confirmed with `@xianix split` |

---

## Item Types

Depth scales with the item:

| Type | Detection | Typical round 1 |
|---|---|---|
| **Bug** | Label `bug` / type `Bug` | 0–2 questions — expected vs actual, scope of the fix |
| **Task** | Label `task`, `chore` / type `Task` | 1–3 — done criteria, dependencies |
| **Story** | Label `story`, `feature` / type `User Story`, `PBI` | 2–5 — actors, scope boundary, edge behaviour |
| **Spike** | Label `spike`, `research` | 1–3 — question to answer, time-box, output |

---

## Workflow

1. Create the item with at least a title.
2. Add the `ai-dlc/issue/analyze` label / tag (or run `/requirement-analysis <id>` manually).
3. The plugin posts round 1 and sets `needs-clarification`.
4. Reply with `@xianix …` — the plugin updates the description and posts round 2, or marks it `groomed`.
5. Repeat until `groomed`. Pick up the item from its description; the *Decisions* table is the audit trail.

---

## Platform Support

| Platform | Thread | Description | Signal |
|---|---|---|---|
| **GitHub** | `gh issue view --json comments` / `gh issue comment` | `gh issue edit --body-file` | Labels |
| **Azure DevOps** | Work item comments REST API | PATCH `System.Description` / `AcceptanceCriteria` | Tags |
| **Generic** | `requirement-grooming.md` — you write answers under the latest round | Same file | `Status:` header |
