---
name: judge-responses
description: Phase 3 of chatbot-tester. Makes a single batched LLM call to judge all Q&A pairs from the Functional Accuracy category. Also judges fallback, continuity, and empty input probe responses. Outputs JUDGED_RESULTS with verdict and reasoning added to each item.
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

# Phase 3 — Judge Responses

This skill is invoked by the **orchestrator** agent. It is not a standalone slash command.

## Inputs

| Variable | Source | Description |
|---|---|---|
| `CATEGORY_RESULTS` | Phase 2 | Structured results per test category including verbatim bot responses |
| `KNOWLEDGE` | orchestrator | Parsed contents of the `chatbot-test` block from the GitHub issue or Azure DevOps work item |

## Outputs

`JUDGED_RESULTS` — same structure as `CATEGORY_RESULTS` with `verdict` and `judge_reasoning` added to each Q&A pair and probe result.

---

## Step 1: Judge Q&A Pairs and Conversation Continuity (Single Batched LLM Call)

Extract all Q&A pairs from `CATEGORY_RESULTS.functional_accuracy.qa_pairs` and the continuity probe result from `CATEGORY_RESULTS.conversation_continuity.probe_results[0]`.

**If `CATEGORY_RESULTS.conversation_continuity.status` is `NOT_RUN`**, skip the continuity section entirely — set `verdict: "NOT_RUN"` and `reasoning: "No passing Q&A pair found — probe was not sent."` directly without including it in the LLM call.

Before judging, check each Q&A pair's `actual_response`. If it equals `(response capture failed — no matching bot message element found)`, assign `verdict: "FAIL"` and `reasoning: "Response capture failed — no bot message element matched; cannot evaluate."` directly without including it in the LLM call.

For all remaining pairs, truncate `actual_response` to 500 tokens before including it in the judge prompt.

Make **one single LLM call** with all Q&A pairs, continuity probe (if applicable), and conversation flow steps (if applicable) batched together. Use this prompt structure:

```
You are a strict but fair QA judge evaluating an AI chatbot's responses.

## Q&A Pairs
For each Q&A pair below, return a verdict of PASS, PARTIAL, or FAIL and a one-line reason.

Verdict criteria:
- PASS: the response clearly and correctly addresses the question; contains all required terms in a meaningful context (if provided); and is substantially aligned with the expected answer (if provided)
- PARTIAL: the response is relevant and partially correct but missing one or more required terms, or only partially aligned with the expected answer
- FAIL: the response is incorrect, irrelevant, deflects without answering, or contains none of the required terms

When only "Expected answer" is provided (no required terms): base the verdict purely on semantic alignment with that expected answer.
When both are provided: required terms are the hard gate — a response missing any required term cannot be PASS regardless of semantic alignment.

{for each pair}
---
Index: {n}
Question: {question}
{if expected_answer present: Expected answer (semantic reference): {expected_answer}}
{if must_contain present: Required terms (must appear in a meaningful context): {must_contain joined by ", "}}
Bot response (truncated to 500 tokens): {actual_response_truncated}
---

## Conversation Continuity Probe
(include this section only if continuity probe was run — omit if NOT_RUN)

The follow-up question below was sent immediately after Q&A pair {continuity_anchor_index} in the same conversation, once that pair returned a response containing all required terms. Judge whether the bot's response demonstrates it retained context from that specific exchange.

Anchor Q&A pair (index {continuity_anchor_index}):
  Question: {anchor_question}
  Required terms: {anchor_must_contain}

Follow-up sent: {continuity_probe}
Bot response: {continuity_response_truncated}

Verdict criteria for continuity:
- PASS: response is topically relevant to the follow-up and shows the bot remembered the anchor Q&A exchange
- PARTIAL: response is non-empty and on-topic but generic — could have been given without any prior context
- FAIL: response is empty, asks the user to clarify what they mean, or shows no awareness of the anchor exchange

## Conversation Flow Steps
(include this section only if HAS_CONVERSATION_FLOW=true and flow steps exist — omit otherwise)

The steps below were sent as a sequential conversation in a single session. Each step's question may rely on context established by prior steps. Judge each step that has a response (status NOT_RUN steps are already marked — do not include them here).

Use the same verdict criteria as Q&A Pairs above.

{for each flow step with response}
---
Step: {index}
Name: {name}
Question: {question}
{if expected_answer present: Expected answer (semantic reference): {expected_answer}}
{if must_contain present: Required terms: {must_contain joined by ", "}}
Bot response (truncated to 500 tokens): {actual_response_truncated}
---

Return a JSON object:
{
  "qa_pairs": [
    { "index": n, "verdict": "PASS|PARTIAL|FAIL", "reasoning": "one-line explanation" },
    ...
  ],
  "continuity": { "verdict": "PASS|PARTIAL|FAIL", "reasoning": "one-line explanation" },
  "flow_steps": [
    { "index": n, "verdict": "PASS|PARTIAL|FAIL", "reasoning": "one-line explanation" },
    ...
  ]
}
```

Omit `continuity` key if the continuity probe was NOT_RUN. Omit `flow_steps` key if `HAS_CONVERSATION_FLOW=false`.

Parse the JSON response and attach `verdict` and `judge_reasoning` to each Q&A pair, the continuity probe, and each flow step in `JUDGED_RESULTS`.

**If no Q&A pairs exist** (lite mode), omit the Q&A Pairs section and judge continuity and/or flow steps only.

---

## Step 2: Judge Probe Responses (Deterministic)

For Fallback and Empty Input probes, apply deterministic rules (no LLM call needed). Conversation Continuity is already judged in Step 1.

### Fallback probes (gibberish / out-of-scope)

- **PASSED** if: response is non-empty AND does not contain raw exception text, stack traces, HTTP error codes (500, 404), or empty string
- **FAILED** if: response is empty, contains a stack trace, or contains an unhandled error message
- **BLOCKED** if: no response was captured (timeout or crash)

### Empty Input probe

- **PASSED** if: no crash occurred AND the input field is still interactable after submission
- **FAILED** if: the page crashed, threw a visible error, or the input field became non-interactable

---

## Step 3: Compute Category Verdicts

For each category, compute the category verdict using the Category Verdicts table in `docs/verdict-logic.md`.

---

## Completion

Hand off to `skills/post-test-report/SKILL.md` with `JUDGED_RESULTS`, `TEST_URL`, `ENTRY_TYPE`, `ENTRY_ID`, `PLATFORM`, `LITE_MODE` in scope.
