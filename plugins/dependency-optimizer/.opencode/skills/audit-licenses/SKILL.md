---
name: audit-licenses
description: "Run a license compliance audit on all project dependencies. Flags copyleft, unknown, and policy-violating licenses. Usage: /audit-licenses"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run a focused license compliance audit on all project dependencies.

## Steps

1. Detect the ecosystem from manifest files:
   ```bash
   find . -maxdepth 2 \( -name "package.json" -o -name "requirements.txt" \
     -o -name "Cargo.toml" -o -name "go.mod" -o -name "pom.xml" \
     -o -name "*.csproj" -o -name "Gemfile" \) | grep -v node_modules
   ```

2. Use the **license-auditor** agent, passing it:
   - The list of manifest files
   - The detected ecosystem
   - Instruction: *"Audit all dependency licenses. Flag copyleft (GPL, AGPL, LGPL), unknown, and commercially restricted licenses. Return a full license distribution table and a verdict."*

3. Output the license audit findings directly. This is a report-only operation — no fixes are applied automatically.

4. For any CRITICAL findings (GPL, AGPL violations), include the recommended alternative packages or isolation strategies.

**Use this when:**
- Preparing for a commercial product release or open-source publication
- Responding to a legal/compliance review request
- Onboarding a new dependency that needs license verification

**Does not:**
- Run vulnerability or version analysis
- Apply any fixes
- Open a PR
