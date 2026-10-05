---
name: fix-vulnerabilities
description: "Scan for known CVEs and security advisories only, and apply safe patches immediately. Usage: /fix-vulnerabilities"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run a targeted vulnerability-only scan and apply safe patches.

## Steps

1. Detect the ecosystem from manifest files in the current directory:
   ```bash
   find . -maxdepth 2 -name "package.json" -o -name "requirements.txt" \
     -o -name "Cargo.toml" -o -name "go.mod" -o -name "pom.xml" \
     -o -name "*.csproj" -o -name "Gemfile" | grep -v node_modules
   ```

2. Use the **vulnerability-scanner** agent, passing it:
   - The list of manifest files
   - The detected ecosystem
   - Instruction: *"Return only CVE findings with severity CRITICAL and HIGH, and the safe patch commands for each. Do not include version drift or license findings."*

3. For each CRITICAL and HIGH finding with a safe patch:
   - Apply the patch using the ecosystem-native update command
   - Verify the updated version resolves the CVE

4. Create a commit with the message: `fix(security): patch critical and high CVEs`

5. Output a summary of patched CVEs with before/after versions.

**Does not:**
- Run version drift or bloat analysis
- Open a PR automatically (use `/optimize-dependencies` for the full flow)
- Apply major version upgrades
