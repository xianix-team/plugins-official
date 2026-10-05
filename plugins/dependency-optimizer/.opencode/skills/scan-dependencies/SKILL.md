---
name: scan-dependencies
description: "Run a full dependency analysis and produce a report without applying any fixes or opening a PR. Usage: /scan-dependencies"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Run a full dependency scan and output a report — read-only, no changes applied.

## Steps

1. Detect the ecosystem and package manager from manifest files:
   ```bash
   find . -maxdepth 2 \( -name "package.json" -o -name "requirements.txt" \
     -o -name "Cargo.toml" -o -name "go.mod" -o -name "pom.xml" \
     -o -name "*.csproj" -o -name "Gemfile" \) | grep -v node_modules
   ```

2. Write manifest paths to `/tmp/dep_manifests.txt` and ecosystem info to `/tmp/dep_scan_env.sh`.

3. Run all four specialized analyses **in parallel** (one sub-agent invocation per analysis):
   - **vulnerability-scanner** — CVEs, deprecated packages, supply-chain flags
   - **version-updater** — outdated packages, patch/minor/major classification
   - **bloat-analyzer** — unused dependencies, duplicate transitives, bundle size
   - **license-auditor** — copyleft detection, unknown licenses, policy violations

4. Compile findings into the report format defined in `styles/dependency-template.md`.

5. Determine the Health Status:
   - `SECURE` — no issues found
   - `FIXES AVAILABLE` — safe updates or removals exist
   - `MANUAL INTERVENTION` — critical CVEs, major breaks, or license violations

6. Write the report to `dependency-scan-report.md` in the project root.

7. Output the health status and a brief summary to the console.

**Does not:**
- Apply any fixes
- Create a branch or commit
- Open a PR

Use `/optimize-dependencies` to run the same analysis with automated fixes and a PR.
