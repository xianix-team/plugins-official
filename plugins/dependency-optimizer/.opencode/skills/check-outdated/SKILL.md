---
name: check-outdated
description: "Show all outdated dependencies with current vs latest versions. Read-only report — no changes applied. Usage: /check-outdated"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Show a read-only report of all outdated dependencies for the current project.

## Steps

1. Detect the ecosystem and package manager from manifest files:
   ```bash
   find . -maxdepth 2 \( -name "package.json" -o -name "requirements.txt" \
     -o -name "Cargo.toml" -o -name "go.mod" -o -name "pom.xml" \
     -o -name "*.csproj" -o -name "Gemfile" \) | grep -v node_modules
   ```

2. Run the ecosystem-native outdated check:
   - npm: `npm outdated`
   - yarn: `yarn outdated`
   - pip: `pip list --outdated`
   - cargo: `cargo outdated` (if installed)
   - go: `go list -m -u all`
   - dotnet: `dotnet list package --outdated`
   - bundler: `bundle outdated`

3. Classify each outdated package as:
   - `patch` — bug fix only, low risk
   - `minor` — new features, backwards compatible
   - `major` — potential breaking changes

4. Output a formatted table:

   | Package | Current | Latest | Type | Risk |
   |---------|---------|--------|------|------|
   | `express` | `4.17.1` | `4.18.2` | patch | Low |
   | `webpack` | `4.46.0` | `5.88.2` | major | High |

5. For any major version bumps, note the link to the migration guide if known.

**Does not:**
- Apply any changes
- Run vulnerability or license scans
- Create a branch or PR

Use `/update-versions` to apply safe updates, or `/optimize-dependencies` for the full automated optimization flow.
