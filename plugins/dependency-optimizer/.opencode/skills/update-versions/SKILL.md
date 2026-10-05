---
name: update-versions
description: "Apply all safe (patch and minor) dependency version updates without running a full optimization. Usage: /update-versions"
compatibility: opencode
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Apply all safe patch and minor dependency version updates.

## Steps

1. Detect the ecosystem and package manager from manifest files:
   ```bash
   find . -maxdepth 2 \( -name "package.json" -o -name "requirements.txt" \
     -o -name "Cargo.toml" -o -name "go.mod" -o -name "pom.xml" \
     -o -name "*.csproj" -o -name "Gemfile" \) | grep -v node_modules
   ```

2. Use the **version-updater** agent, passing it:
   - The list of manifest files
   - The detected ecosystem
   - Instruction: *"List only patch and minor updates (no major bumps). Return the exact commands to apply them for the detected package manager."*

3. Apply the patch and minor updates using the commands returned by the agent:
   - npm: `npm update --save`
   - yarn: `yarn upgrade --pattern "*" --latest` (within declared semver range)
   - pip: `pip install --upgrade <pkg>==<version>`
   - cargo: `cargo update`
   - go: `go get <module>@<version> && go mod tidy`
   - dotnet: `dotnet add package <pkg> --version <version>`
   - bundler: `bundle update <gem>`

4. Run the lockfile update command to sync with the new versions.

5. Create a commit: `chore(deps): update patch and minor dependency versions`

6. Output a table of what was updated (package, old version, new version).

**Does not:**
- Apply major version upgrades (use `/optimize-dependencies` for full analysis with breaking-change review)
- Run vulnerability or license scans
- Open a PR automatically
