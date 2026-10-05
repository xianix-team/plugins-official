---
description: "Alias for /test-web-app. Verify web app behaviour for a GitHub PR/Issue or Azure DevOps PR/Bug using the Webwright workflow (Python/Playwright, headless Chromium). Usage: /web-app-test [pr <n> | issue <n> | wi <id>] [--env <name>] [--url <url>] [--role <role>] [--interactive]"
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run automated web app behaviour verification for $ARGUMENTS.

Read and follow `commands/test-web-app.md` exactly — treat this as a direct invocation of `/test-web-app $ARGUMENTS`.
