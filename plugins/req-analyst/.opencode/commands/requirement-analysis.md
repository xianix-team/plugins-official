---
description: "Groom a backlog item through a short conversation in its comment thread. Each run reads the thread, works out where the conversation stands, and takes one step — ask up to 5 clarifying questions, fold the answers into the description, or mark the item ready to proceed. Works with GitHub Issues, Azure DevOps Work Items, or plain text. Usage: /requirement-analysis [issue-number or work-item-id]"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Take the next grooming step on backlog item $ARGUMENTS.

## What This Does

This command invokes the **orchestrator** agent, which runs **one turn** of a grooming conversation:

1. **Read the thread** — the item, every comment, and the current description.
2. **Determine the state** from the plugin's own previous comments and any human replies after them.
3. **Take one action:**

| State | Action |
|---|---|
| No previous round | Analyse the item (repo docs, `context-analyst`, `gap-risk-analyst`), then post **round 1**: 2–3 sentences of understanding and up to 5 numbered questions, each with a proposed default. Label `needs-clarification`. |
| Humans replied with `@xianix` | Fold the answers into the **description** (requirements, acceptance criteria, decisions table), then either post the next round with what is still open, or mark the item **ready** (`groomed`). |
| Waiting, no new replies | Do nothing. |
| Item already ready, human asks for a change | Update the description, post a one-line *Updated* comment. |
| Item is too large | Propose a split; create linked child items only if the human confirms. |

4. **Stop.** The next run — usually triggered by the human's reply — takes the next step.

The conversation is capped at **3 rounds**. After that, remaining questions are resolved with their stated defaults, flagged as assumptions in the description, and the item is marked ready.

## How Humans Reply

Comment on the issue / work item, addressing the agent and answering by number:

```
@xianix 1. yes  2. admins only  3. skip for v1
```

or accept the proposed defaults:

```
@xianix go with defaults
```

Prose answers work too; the agent maps them to the open questions. Editing the description directly also counts — the next run re-checks open questions against it.

## What Changes on the Item

- **Comments:** one short round comment per turn, ending with a `req-analyst · round N/3 · status: …` footer that the next run uses to detect state.
- **Description:** rewritten into a concise structured form — summary, scope, requirements, acceptance criteria, decisions table (who decided what, linked to the comment), open questions. The author's original text is preserved verbatim in a collapsed *Original description* block.
- **Labels / tags:** exactly one of `needs-clarification`, `needs-decomposition`, `groomed` at a time. `groomed` means ready to proceed.

## Platform Support

Auto-detected from `git remote get-url origin`:

| Remote contains | Platform | Thread | Description edit |
|---|---|---|---|
| `github.com` | GitHub | `gh issue view --json comments`, `gh issue comment` | `gh issue edit --body-file` |
| `dev.azure.com` / `visualstudio.com` | Azure DevOps | Work item comments REST API | PATCH `System.Description` (+ `AcceptanceCriteria` when the type has it) |
| Anything else | Generic | `requirement-grooming.md` — human edits the answers block | Same file |

## Output

One status line, e.g.

```
Round 1 posted on #42: 4 open questions — awaiting answers
Applied 3 answers on #42; round 2 posted: 1 still open
Ready to proceed: #42 marked groomed — 2 assumptions recorded
```

## Prerequisites

- **GitHub:** `gh` CLI authenticated with `repo` scope (edits the body and labels)
- **Azure DevOps:** `AZURE-DEVOPS-TOKEN` with `Work Items (Read & Write)`
- **Generic:** nothing

---

Reading the thread now...
