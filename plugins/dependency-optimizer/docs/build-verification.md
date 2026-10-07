# Build Verification

Every automated fix this plugin applies (patch/minor version bumps, unused-package
removal) must be verified to **at least compile/build** before it is committed. This
doc defines the check to run per ecosystem, and the pass/fail contract that
`agents/orchestrator.md`, `skills/update-versions/SKILL.md`, and
`skills/fix-vulnerabilities/SKILL.md` all follow.

This is a **compile/build check only** — it is not a test run. Running the project's
test suite is out of scope: tests can be slow, flaky, or require services this plugin
has no access to, which would make the gate unreliable. "At least compiles" is the bar.

---

## When to run this

After all safe fixes for the run have been applied to the working tree (version bumps,
unused-package removal), and **before** `git add` / `git commit` / `git push`.

Run the check **once**, for the whole batch of changes — not per package. If it fails,
the whole batch is reverted (see Failure below); this plugin does not bisect which
individual package broke the build.

---

## Ecosystem → Verification Command

| Ecosystem | Package manager | Primary check | Fallback (when no build/type step exists) |
|---|---|---|---|
| Node.js | npm | If `package.json` has a `"build"` script: `npm run build` | Else: `npm ci` (or `npm install` if no lockfile) must exit 0. If `tsconfig.json` exists, also run `npx tsc --noEmit` |
| Node.js | yarn | If `package.json` has a `"build"` script: `yarn build` | Else: `yarn install --check-files` must exit 0. If `tsconfig.json` exists, also run `npx tsc --noEmit` |
| Node.js | pnpm | If `package.json` has a `"build"` script: `pnpm build` | Else: `pnpm install` must exit 0. If `tsconfig.json` exists, also run `npx tsc --noEmit` |
| Python | pip / poetry / pipenv | `python -m compileall -q .` (run after the ecosystem's install command has succeeded, so newly-pinned versions are actually installed) | — |
| Rust | cargo | `cargo check --locked` | — |
| Go | go modules | `go build ./...` | — |
| Java | maven | `mvn -q -DskipTests compile` | — |
| Java/Kotlin | gradle | `./gradlew compileJava compileTestJava -q` (or `./gradlew compileKotlin -q` if Kotlin) | If no wrapper: `gradle compileJava -q` |
| .NET | dotnet | `dotnet build --nologo -v quiet` | — |
| Ruby | bundler | `bundle check` (or `bundle install` if `check` is unavailable) followed by: `find . -name '*.rb' -not -path './vendor/*' -not -path './.git/*' \| xargs -n1 ruby -c > /dev/null` | — |

Use the ecosystem/package-manager already detected in the orchestrator's Step 3 —
do not re-detect it.

---

## Pass / Fail Contract

Every caller of this doc must write the result to `/tmp/dep_build_verify_status`.

### On success

```bash
echo "PASSED" > /tmp/dep_build_verify_status
echo "command: <exact command that was run>" >> /tmp/dep_build_verify_status
```

Proceed to commit as normal.

### On failure

```bash
echo "FAILED" > /tmp/dep_build_verify_status
echo "command: <exact command that was run>" >> /tmp/dep_build_verify_status
echo "--- output (tail) ---" >> /tmp/dep_build_verify_status
tail -40 /tmp/dep_build_verify_output.log >> /tmp/dep_build_verify_status
```

Then:

1. **Revert the working tree**: `git checkout -- .` (safe — at this point the branch
   only carries the uncommitted fix diff; nothing has been committed yet).
2. **Do not commit, push, or open a PR for this fix.**
3. Treat the batch as if no safe automated fix existed for this run:
   - Orchestrator: downgrade Health Status to `MANUAL INTERVENTION` (even if
     sub-agents reported `FIXES AVAILABLE`), move the affected items into the
     report's **Critical Issues Requiring Attention** section, and continue to the
     normal `MANUAL INTERVENTION` report-posting path (comment, not PR).
   - `/update-versions` and `/fix-vulnerabilities`: skip the commit step and output a
     failure line instead of the success table (see each skill file for the exact
     format).
