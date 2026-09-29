# Refined Description Template

This is the **issue / work item description** the orchestrator writes in Step 4. It is rewritten from scratch on every turn from the accumulated decisions, so it always reflects the current state of the conversation.

Rules:

- Keep the whole managed section under **~60 lines**. If a section would be empty, omit it.
- On the **first edit only**, move the author's existing body verbatim into the collapsed `Original description` block at the bottom. Never edit that block again.
- Anything derived from a default rather than a human answer is marked **(assumed)** inline and has `Assumed:` in the Decisions table.
- Keep question ids (`Qn`) identical to the ones used in the comments.
- Every decision row links to the comment it came from where the platform supports it.
- Do not include analysis, personas essays, competitor notes, or journey maps here. If a piece of context genuinely changes the requirement, it becomes a requirement line or a decision — nothing else.

---

## Markdown version (GitHub, generic)

```markdown
<!-- req-analyst: managed section — humans may edit; the agent rewrites it as decisions land in the thread -->

## Summary
**As a** <persona> **I want** <capability> **so that** <outcome>.

<Optional: 1–2 sentences of context that changes scope — e.g. relation to an existing PRD / ADR.>

## Scope
- **In:** <bullet(s)>
- **Out:** <bullet(s)> *(assumed)*

## Requirements
- R1 — <testable statement>
- R2 — <testable statement>
- R3 — <testable statement> *(assumed — see Q4)*

## Acceptance criteria
- **Given** <precondition> **when** <action> **then** <outcome>
- **Given** … **when** … **then** …
- **Given** <edge / failure case> **when** … **then** <safe behaviour>

## Decisions
| # | Question | Decision | Source |
|---|---|---|---|
| Q1 | <short question> | <decision> | @alice — [comment](<url>) |
| Q2 | <short question> | <decision> | @alice — [comment](<url>) |
| Q4 | <short question> | **Assumed:** <default> | default, round 3 |

## Open questions
- **Q3** — <question> · *Default: <…>*

<details><summary>Original description</summary>

<the author's original body, verbatim>

</details>
```

Omit `## Open questions` when nothing is open. Omit `## Decisions` only on a first pass with no questions and no assumptions.

**Decomposed parent (after a confirmed split):** replace *Requirements* / *Acceptance criteria* with:

```markdown
## Split into
- #<n> — <child title>
- #<n> — <child title>

Each child is groomed in its own thread.
```

---

## HTML version (Azure DevOps `System.Description`)

Azure DevOps stores the description as HTML. Emit the same structure with plain HTML tags. Keep it simple — headings, paragraphs, lists, one table.

```html
<p><em>req-analyst managed section — humans may edit; the agent rewrites it as decisions land in the discussion.</em></p>

<h2>Summary</h2>
<p><strong>As a</strong> &lt;persona&gt; <strong>I want</strong> &lt;capability&gt; <strong>so that</strong> &lt;outcome&gt;.</p>

<h2>Scope</h2>
<ul>
  <li><strong>In:</strong> …</li>
  <li><strong>Out:</strong> … <em>(assumed)</em></li>
</ul>

<h2>Requirements</h2>
<ul>
  <li>R1 — …</li>
  <li>R2 — … <em>(assumed — see Q4)</em></li>
</ul>

<h2>Decisions</h2>
<table>
  <tr><th>#</th><th>Question</th><th>Decision</th><th>Source</th></tr>
  <tr><td>Q1</td><td>…</td><td>…</td><td>Alice, discussion 12 Mar</td></tr>
  <tr><td>Q4</td><td>…</td><td><strong>Assumed:</strong> …</td><td>default, round 3</td></tr>
</table>

<h2>Open questions</h2>
<ul>
  <li><strong>Q3</strong> — … <em>Default: …</em></li>
</ul>

<h2>Original description</h2>
<blockquote>…the author's original description HTML, unchanged…</blockquote>
```

If the work item type exposes `Microsoft.VSTS.Common.AcceptanceCriteria` (User Story, Product Backlog Item), write the acceptance criteria into that field as an HTML `<ul>` of Given/When/Then lines and leave them out of the description. Otherwise add an `<h2>Acceptance criteria</h2>` list to the description.
