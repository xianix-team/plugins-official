# Provider: Generic / Plain Text

Use this provider when the git remote is neither GitHub nor Azure DevOps, when the requirement is pasted as plain text, or when API posting is otherwise not possible.

## Behaviour

There is no comment thread, so the conversation happens in a single local file that both the agent and the human edit in turns:

```
requirement-grooming.md
```

Each run reads the file, works out the state from the **Thread** section, appends one round, and rewrites the **Refined description** section. The human answers by editing the file under the latest round and re-running the command.

---

## File Layout

```markdown
# Requirement grooming — <short title>

Source: <repo URL or "plain text input">
Item: <id or short title>
Status: awaiting answers | awaiting split confirmation | ready
Round: 1/3

---

## Refined description

<Markdown version of styles/refined-description-template.md — rewritten every run>

---

## Thread

### Round 1 — agent
<Variant A from styles/round-comment-template.md, footer included>

### Round 1 — answers
<!-- Human: write numbered answers here, e.g. "1. yes", "2. admins only", or "go with defaults" -->

### Round 2 — agent
<Variant B …>

### Round 2 — answers
<!-- Human: … -->
```

## State Detection

- No file → `NEW`.
- Latest `### Round N — answers` block is empty (only the HTML comment) → `AWAITING`; output the waiting status line and stop.
- Latest answers block has content → `ANSWERED`; apply the answers, rewrite *Refined description*, append the next round (or the *Ready to proceed* variant), update `Status:` and `Round:` in the header.

## Output

One status line — see the orchestrator's Step 6 — followed by the file path.

---

## When to Use

- Plain text input (no tracker)
- Jira, Azure Boards without a PAT, self-hosted trackers
- Local / offline runs and CI jobs that only want the file
