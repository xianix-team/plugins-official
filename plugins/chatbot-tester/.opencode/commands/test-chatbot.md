---
description: "Verify AI chatbot behaviour in a web application. Reads widget configuration and Q&A pairs from a chatbot-test block in a GitHub issue or Azure DevOps work item, opens the chatbot via Playwright (headless Chromium), runs seven test categories, judges Q&A accuracy with a batched LLM call, and posts a structured report. Usage: /test-chatbot <url>"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run automated AI chatbot verification for $ARGUMENTS.

## What This Does

Invokes the **orchestrator** agent to:

1. Parse the input URL to determine entry type (GitHub issue, Azure DevOps work item, or direct app URL)
2. Fetch the issue/work item and extract the `chatbot-test` JSON block for widget hints, credentials, and Q&A pairs
3. Open the web application in a headless Chromium browser and locate the chatbot widget
4. Run seven test categories against the chatbot
5. Judge Q&A pair responses with a single batched LLM call
6. Post a structured report as an issue/work item comment, or write `chatbot-test-report.md` for direct URL runs

## Entry Points

| Entry Point | Example | What the agent does |
|---|---|---|
| **GitHub issue URL** | `/test-chatbot https://github.com/owner/repo/issues/42` | Fetches issue body, extracts `chatbot-test` block, runs full test |
| **Azure DevOps work item URL** | `/test-chatbot https://dev.azure.com/org/project/_workitems/edit/1234` | Fetches work item body, extracts `chatbot-test` block, runs full test |
| **Direct app URL** | `/test-chatbot https://staging.example.com` | Lite mode — runs UI and fallback tests only, writes report locally |

## Test Categories

| Category | Full test | Lite mode |
|---|---|---|
| **UI Availability** | Widget loads, trigger button works, input field is interactable | Same |
| **Functional Accuracy** | Q&A pairs from test block — bot answers judged by LLM | Skipped |
| **Fallback Handling** | Gibberish and out-of-scope inputs — bot responds gracefully | Same |
| **Response Latency** | Time from message sent to response complete | Same |
| **Conversation Continuity** | Follow-up question retains context from previous response | Same |
| **Conversation Flow** | Sequential context-dependent Q&A chain from `conversation_flow` block — only runs when defined | Skipped |
| **Empty Input Handling** | Blank message submission handled gracefully | Same |

## Test Case Block

Add this block to a GitHub issue or Azure DevOps work item body. The agent reads it automatically.

````
```chatbot-test
{
  "url": "https://your-app-url.com",
  "widget": {
    "trigger_hint": "description of how to open the chatbot",
    "ready_hint": "description of when the input field is ready",
    "response_done_hint": "description of when the bot has finished responding"
  },
  "credentials": {
    "username": "test@example.com",
    "password_env": "CHATBOT-TEST-PASSWORD"
  },
  "knowledge": [
    {
      "question": "What are your opening hours?",
      "must_contain": ["9am", "5pm", "Monday"]
    }
  ]
}
```
````

`credentials` and `knowledge` are optional. See `docs/setup.md` for the full reference.

## Credentials

The `password_env` field references a secret key stored in Xianix Agentri Studio Secrets. The password value is never written to the test case — only the key name is referenced.

## Verdict Logic

See `docs/verdict-logic.md` for the authoritative verdict computation rules.

## Prerequisites

- Python 3.10+ available (`python3 --version`)
- `playwright` Python package installed (`pip install playwright && playwright install chromium`)
- **GitHub issues:** `gh` CLI installed and authenticated
- **Azure DevOps work items:** `curl` available and `AZURE_DEVOPS_TOKEN` set
- **Login required:** password stored as `CHATBOT-TEST-PASSWORD` in Xianix Agentri Studio Secrets

---

Starting chatbot test now...
