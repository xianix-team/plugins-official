---
name: apply-answers
description: "Fold the humans' answers from a backlog item's comment thread into its description without running a fresh analysis. Reads the last round of questions and the replies after it, updates requirements / acceptance criteria / decisions in the description, and posts the next round or marks the item ready. Usage: /apply-answers [issue-number or work-item-id]"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Apply the answers in the thread of item #$ARGUMENTS to its description.

Do not ask for confirmation. Execute all steps autonomously.

## Steps

1. **Detect platform** — `git remote get-url origin` → GitHub / Azure DevOps / Generic.

2. **Fetch the item and the full thread** — see `providers/<platform>.md`. Sort comments chronologically.

3. **Locate the last round** — the most recent comment with the footer `` `req-analyst` · round N/3 · status: … ``. If there is none, stop and output `No open round on #<id> — run /requirement-analysis first`. If its status is `ready`, treat any later `@xianix` comment as a change request.

4. **Collect answers** — human comments after that round that mention `@xianix`, contain numbered answers (`1.`, `Q2:`, `#3 —`), or plainly answer an open question. Check for the special intents first: *go with defaults*, *not ready / hold*, *split*, or a question back to the agent.

5. **Map answers to questions** — by id first, by content second. Ambiguous → best reading plus a narrowed re-ask under the same `Qn`. Record author and comment link for each decision. Add at most 2 new CRITICAL questions surfaced by the answers.

6. **Rewrite the description** per `styles/refined-description-template.md` (Markdown on GitHub / generic, HTML on Azure DevOps). Preserve the *Original description* block verbatim.

7. **Post one comment** per `styles/round-comment-template.md`:
   - questions remain and round < 3 → Variant B (next round), label `needs-clarification`
   - none remain, or round 3 exhausted, or "go with defaults" → Variant C (ready), label `groomed`
   - change on a ready item → Variant E (updated), keep `groomed`

8. **Swap the readiness label / tag** so exactly one is present. Never touch `ai-dlc/issue/analyze`.

9. **Output** one status line:

   ```
   Applied <K> answers on #<id>; round <N> posted: <M> still open
   Ready to proceed: #<id> marked groomed — <A> assumptions recorded
   ```

> GitHub requires `gh` CLI authenticated with `repo` scope. Azure DevOps requires `AZURE-DEVOPS-TOKEN` with Work Items Read & Write. See `docs/platform-config.md`.
