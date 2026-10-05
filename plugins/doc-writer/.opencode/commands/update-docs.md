---
description: Update the codebase documentation to match the changes introduced by a pull request. Analyses the PR's modified source files, locates the relevant docs (READMEs, /docs trees, inline reference docs, changelogs, OpenAPI specs, etc.), edits or creates the entries that need to be in sync with the new code, and opens a separate **companion documentation PR** whose target branch is the original PR's head — so the doc changes can be reviewed and merged into the feature branch independently. Works with GitHub, Azure DevOps, and any git repository.
---
> **OpenCode runtime note:** Claude `Task` / `Agent` tool orchestration is not available. Invoke specialist agents with the OpenCode `task` tool and `subagent_type` set to the agent name (or `@agent-name`). Use `CLAUDE_PLUGIN_ROOT` for scripts (the executor sets it to this plugin root).

Update the documentation in the codebase to match the source changes in pull request $ARGUMENTS.

## You run this yourself — do NOT delegate to a sub-agent

**Critical execution rule (read first).** You, the top-level agent, perform every step below **yourself**, directly, using your own `Bash`, `Read`, `Write`, `Edit`, `Grep`, and `Glob` tools. There is no background "orchestrator" agent that runs on your behalf. Nothing happens unless you run it.

- Do **not** spawn a separate sub-agent and ask *it* to do the work. Do it in this context.
- Do **not** describe the flow in the future tense ("the agent will now analyse the PR…") and then stop. Narrating the steps is **not** the same as executing them.
- Do **not** report success, or that work is "in progress", until you have actually reached the **Completion criteria** at the bottom of this file — i.e. you have pushed the docs branch and opened (or confirmed) the companion docs PR, or you have genuinely confirmed that no documentation changes are required.
- Reading these instructions is not sufficient. Every step that shows a command must actually be run.

Execute all steps autonomously and in order. Do not ask for confirmation, clarification, or approval at any point. If a step fails irrecoverably, output a single error line describing what failed and stop — do not ask what to do next.

## Hard constraints

- **Source code is read-only.** Never modify source files, tests, build configuration, lockfiles, dependency manifests, or generated artefacts. The only exception is inline reference doc comments (JSDoc/TSDoc, docstrings, Rustdoc, GoDoc, XML doc comments) **inside source files that the PR itself already touched** — and only when those comments describe the symbol whose signature or behaviour changed.
- **Only edit files inside the documentation surfaces** enumerated in Step 4. If you are unsure whether a file is documentation, prefer **not** to edit it and surface the question in the summary instead.
- **Every doc edit must trace back to a specific change in the PR diff.** Never reflow paragraphs, re-order sections, or "improve" documentation for unchanged code.
- **Match existing conventions** — heading levels, table style, code-block language tags, link style, CHANGELOG format.
- **Never commit onto the original PR's own branch.** Every doc change ships on a separate `docs/pr-<n>-sync` branch, delivered as a companion documentation PR targeted at the original PR's head branch.

---

## Step 0: Index the Codebase

Build a quick structural picture of the repository:

```bash
# Top-level layout
ls -1

# Source tree (depth 3, ignore common noise)
find . -maxdepth 3 \
  -not -path './.git/*' \
  -not -path './node_modules/*' \
  -not -path './bin/*' \
  -not -path './obj/*' \
  -not -path './.vs/*' \
  -not -path './dist/*' \
  -not -path './build/*' \
  | sort

# Language fingerprint
find . -not -path './.git/*' -type f \
  | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20

# Entry points / build manifests
ls *.sln *.csproj package.json go.mod Cargo.toml pom.xml build.gradle \
   pyproject.toml setup.py requirements.txt CMakeLists.txt mix.exs Gemfile 2>/dev/null || true
```

Store a short mental model of the language stack and overall project structure.

---

## Step 1: Detect Platform

```bash
git remote get-url origin
```

From the remote URL determine the platform:

- Contains `github.com` → **GitHub**
- Contains `dev.azure.com` or `visualstudio.com` → **Azure DevOps**
- Anything else → **Generic** (no API available — write local report)

Store the detected platform — it determines every subsequent API call.

---

## Step 2: Resolve PR Number and Check PR State

### 2a. Normalise the argument into a bare PR number

The argument (`$ARGUMENTS`) may arrive from an upstream automation in several shapes — a bare number, a web PR URL, or even a REST API URL (e.g. `#https://api.github.com/repos/owner/repo/pulls/5`). Extract the trailing integer before doing anything else:

```bash
RAW_ARG="$ARGUMENTS"

# Strip everything except the final run of digits. Handles:
#   5
#   #5
#   https://github.com/owner/repo/pull/5
#   #https://api.github.com/repos/owner/repo/pulls/5
PR_NUMBER=$(printf '%s' "$RAW_ARG" | grep -oE '[0-9]+' | tail -1)
```

If `PR_NUMBER` is empty **and** no argument was given, resolve it from the current branch using the platform-appropriate method:

- **GitHub:** see `providers/github.md` — Resolving the PR Number section
- **Azure DevOps:** see `providers/azure-devops.md` — Resolving the PR Number section
- **Generic:** treat the current branch (`HEAD` vs `origin/<default>`) as the PR; no remote PR object exists

If `PR_NUMBER` is still empty after this, output a single error line (`ERROR: could not resolve a PR number from "<arg>" or the current branch`) and stop.

### 2b. Check whether the PR is open or already merged

- **GitHub:**
  ```bash
  gh pr view "${PR_NUMBER}" --json state,mergedAt,headRefName,baseRefName,mergeCommit,url
  ```
- **Azure DevOps:** fetch PR details per `providers/azure-devops.md` and inspect the `status` field.

Store `PR_NUMBER`, `PR_STATE`, `PR_HEAD_BRANCH`, `PR_BASE_BRANCH`, and `PR_URL`. If the PR is already merged, follow the **Merged PR Flow** at the end of this document instead of the open-PR push flow.

---

## Step 3: Post a "Documentation Update in Progress" Comment

Before doing any analysis, post an immediate comment on the original PR so the author knows the process has started and that a companion docs PR will be opened when finished:

- **GitHub:** see `providers/github.md` — Posting the "Documentation Update in Progress" comment section
- **Azure DevOps:** see `providers/azure-devops.md` — Posting the Starting Comment section
- **Generic:** skip — no API available

If posting the starting comment fails, output a single warning line and continue. **Do not stop.**

---

## Step 4: Check Out a Docs Branch Cut from the PR Head

### 4a. Fetch the PR head and cut a fresh docs branch

You **never** commit directly onto the PR's own branch. Instead, cut a new branch off the tip of the PR's head and use that as the working branch for every documentation edit. A separate PR is opened later that targets the original PR's head branch, so the documentation changes can be reviewed and merged into the feature branch.

For the open-PR flow:

```bash
git fetch origin "${PR_HEAD_BRANCH}"

# Branch name for the documentation PR. Use a short, deterministic name so re-runs
# on the same PR check out the same branch (no duplicate branches per re-run).
DOCS_BRANCH="docs/pr-${PR_NUMBER}-sync"

# If the branch already exists locally, reset it to the latest PR head;
# otherwise create it from the PR head.
if git show-ref --verify --quiet "refs/heads/${DOCS_BRANCH}"; then
  git checkout "${DOCS_BRANCH}"
  git reset --hard "origin/${PR_HEAD_BRANCH}"
else
  git checkout -b "${DOCS_BRANCH}" "origin/${PR_HEAD_BRANCH}"
fi
```

Record both `PR_HEAD_BRANCH` (the original feature branch — this is the **target** of the docs PR) and `DOCS_BRANCH` (the working branch holding the documentation commit).

If the fetch or checkout fails, output a single error line and stop.

### 4b. Inventory the documentation tree

Build a list of all documentation surfaces in the repository — these are the **only** files you are allowed to edit. Capture:

```bash
# Markdown docs at any depth
find . -type f \( -name '*.md' -o -name '*.mdx' -o -name '*.rst' -o -name '*.adoc' -o -name '*.txt' \) \
  -not -path './.git/*' \
  -not -path './node_modules/*' \
  -not -path './vendor/*' \
  -not -path './dist/*' \
  -not -path './build/*' \
  | sort

# OpenAPI / Swagger / AsyncAPI
find . -type f \( -iname 'openapi.*' -o -iname 'swagger.*' -o -iname 'asyncapi.*' \) \
  -not -path './node_modules/*' | sort

# Config samples referenced by docs
ls -1 .env.example sample.config.* example.config.* 2>/dev/null || true

# CHANGELOG and release-notes-like files
ls -1 CHANGELOG* CHANGES* HISTORY* RELEASE* 2>/dev/null || true
```

Group the inventory by category:

| Category | Examples |
|---|---|
| **Top-level docs** | `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md` |
| **Documentation tree** | Everything under `docs/`, `doc/`, `documentation/`, `wiki/` |
| **Per-package READMEs** | `*/README.md` inside `packages/`, `plugins/`, `apps/`, `modules/`, `services/` |
| **API reference** | `openapi.yaml`, `swagger.json`, `*.api.md`, `docs/api/**` |
| **ADRs / RFCs** | `docs/adr/**`, `docs/decisions/**`, `docs/rfcs/**` |
| **Inline reference docs** | JSDoc / TSDoc, Python docstrings, GoDoc, Rustdoc, XML doc comments **inside source files** — *editing these does count as editing source; only adjust them when the surrounding source file is already in the PR diff* |
| **Plugin / marketplace manifests** | `package.json` `description` field, `.claude-plugin/plugin.json` `description`, marketplace manifests |

Persist this inventory — every doc edit you make must land in one of these files (with the inline-reference exception noted above).

### 4c. Detect conventions

Note the documentation conventions used in the repo so your edits match the existing style:

- Heading levels and ordering
- Whether tables, bullet lists, or prose are preferred
- Whether code blocks specify a language tag
- Whether examples use shell, code, or pseudo-code
- Whether docs use absolute or relative links between pages
- The `CHANGELOG.md` format (Keep a Changelog, semver headings, "Unreleased" section, etc.)

You will mirror these conventions in every edit.

---

## Step 5: Fetch the PR Diff and Classify Changed Files

### 5a. Fetch the PR diff

Use the platform-appropriate method to get the **unified diff** of the PR:

- **GitHub:** see `providers/github.md` — Fetching the PR Diff section (uses `gh pr diff`)
- **Azure DevOps:** see `providers/azure-devops.md` — Fetching the PR Diff section (uses `git diff origin/${BASE}...origin/${HEAD}` plus iterations API as a fallback)
- **Generic:**
  ```bash
  BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)
  git diff origin/${BASE}...HEAD
  git diff --name-status origin/${BASE}...HEAD
  ```

Also collect:

- The PR title and description (for context — sometimes a description hints at what docs should change)
- Commit messages
- The list of changed files with their status (`A`, `M`, `D`, `R`)

### 5b. Classify every changed file

For each file in the PR diff, assign exactly one category:

| Category | Patterns / Heuristic | Doc-implication |
|---|---|---|
| **Source — public surface** | Exports a function, class, type, route, CLI command, env var, configuration key, schema, or migration that is consumed outside the file | High — almost always implies a doc update |
| **Source — internal only** | Private/non-exported helpers, internal modules, no external consumer | Low — only update docs if behaviour visible elsewhere changed |
| **Configuration / schema** | `*.json`, `*.yaml`, `*.yml`, `*.toml`, `*.env.example`, infra-as-code files | Medium — update config docs when keys, defaults, or required-ness change |
| **Build / dependency** | `package.json` (deps only), `package-lock.json`, lockfiles, `Dockerfile`, CI files | Low — only update install/setup docs when **prerequisites or invocation** change |
| **Tests** | `*.test.*`, `*_test.*`, `*Tests.*`, `*Spec.*`, files under `tests/`, `__tests__/` | None — never imply doc changes |
| **Documentation already in the PR** | Any file matching the inventory in Step 4 that the PR author already touched | Read it to understand the author's intent; do not undo their changes; fill in gaps the author missed |
| **Generated** | Files under `dist/`, `build/`, `generated/`, files containing a `@generated` marker | None |
| **Other** | Anything that does not fit above | Inspect manually before deciding |

For each **source / configuration** change, also record:

- The **public symbols added, renamed, removed, or whose signature changed**
- The **CLI commands or sub-commands added, renamed, or removed**
- The **environment variables or config keys added, renamed, or removed**
- The **routes / endpoints added or modified**
- Any **behavioural change** described in the commit message that does not map to a symbol-level change (e.g. "now retries 3 times on 5xx")

If the diff is large, prefer reading the **changed files at the new revision** plus the diff hunks — do not re-derive the full file behaviour from the diff alone.

---

## Step 6: Map Each Change to Documentation Entries

For each change identified in Step 5b, find the documentation entries that describe it **today**. Use `Grep` and `Glob` against the inventory from Step 4.

Build a worklist of `(change, doc_entry, disposition)` tuples. The disposition is one of:

| Disposition | When to assign | Action |
|---|---|---|
| **Update** | An existing doc entry describes the symbol/feature/route/config, and the PR changes its signature, behaviour, default, or example | Edit the entry to reflect the new state |
| **Add** | The PR adds a new public surface (exported symbol, CLI command, env var, route, page, feature) that has **no** existing doc entry, **and** the documentation tree has a natural home for it (e.g. an API index, a CLI reference, a CHANGELOG, a feature guide) | Create or extend the appropriate doc file with a new entry |
| **Remove** | The PR removes a public surface that **is** documented today | Delete the entry, or replace it with a deprecation note if the docs use one |
| **Rename** | The PR renames an exported symbol, CLI command, env var, route, or page | Update every reference in the doc tree (use `Grep -r`); add a "renamed from" note where the repo's conventions call for it |
| **No-op** | The change is purely internal, refactor, formatting, test-only, build-only, or dependency bump with no user-visible effect | Record the rationale; produce no edit |

Also produce a **CHANGELOG entry** when the repository has a `CHANGELOG.md` (or equivalent) **and** the PR introduces a user-visible change (Added / Changed / Deprecated / Removed / Fixed / Security). Place it under the `Unreleased` heading using the repo's existing convention.

If you cannot find a natural home for a new doc entry, prefer **not** to invent a new file. Instead, surface the gap in the summary comment under "Documentation gaps — please review."

---

## Step 7: Apply the Documentation Changes

Apply edits in the following order so each later step sees the previous one:

1. **Removes** first — delete obsolete sections so later updates do not re-reference them.
2. **Renames** next — sweep the doc tree and replace old names with new ones.
3. **Updates** — edit drifted sections.
4. **Adds** — create new entries.
5. **CHANGELOG** — last, so the changelog can describe the final shape.

For every edit:

- Use `Read` to load the full target file before modifying it.
- Prefer `Edit` for partial updates of existing files; reserve `Write` for new files or full rewrites of files you have just created.
- Preserve front-matter, table-of-contents anchors, and existing IDs.
- Update **code samples** in the docs when the code they demonstrate has changed signature or behaviour. If a code sample now references a removed symbol, fix it.
- Update **links** to renamed files. If a link target no longer exists, either update it or remove the broken link.
- Keep edits minimal — do not reflow paragraphs, re-order sections, or "tidy" unrelated content.

After all edits, run a sanity sweep:

```bash
# Markdown link sanity — relative links pointing at files that no longer exist
git diff --name-only HEAD       # files you just touched

# Look for now-broken references to removed/renamed symbols
# (use the names you collected in Step 5b)
grep -rn "<OLD-NAME>" --include='*.md' --include='*.mdx' --include='*.rst' . || true
```

If any sweep turns up a stale reference you missed, fix it before committing.

---

## Step 8: Commit and Push the Docs Branch

If your worklist resulted in **no edits at all** (every change was a No-op), skip to Step 10 and report "no documentation updates required" — do not create an empty commit and do not open a docs PR.

Otherwise commit on the `DOCS_BRANCH` you created in Step 4a:

```bash
# Confirm you are on the docs branch, not the PR's own head
CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "${CURRENT}" != "${DOCS_BRANCH}" ]; then
  echo "ERROR: expected to be on ${DOCS_BRANCH}, actually on ${CURRENT}"
  exit 1
fi

# Stage every doc file you edited or created
git add <doc-file-1> <doc-file-2> ...

# One commit for all doc updates
git commit -m "docs: sync documentation with PR #${PR_NUMBER}

Synchronises documentation with the source changes in #${PR_NUMBER}:
<bullet list — one short line per disposition group>
- Updated: <N> entries
- Added:   <N> entries
- Removed: <N> entries
- Renamed: <N> references
- CHANGELOG entry under [Unreleased]"
```

Then push the docs branch. **Authenticate the push inline** — the runtime injects a token via `GITHUB_TOKEN` (GitHub / generic) or `AZURE_DEVOPS_TOKEN` (Azure DevOps). Pass it directly on the `git push` invocation with `-c url.<...>.insteadOf`, so authentication does not depend on any ambient git config:

```bash
# GitHub / generic remotes
git -c "url.https://x-access-token:${GITHUB_TOKEN}@github.com/.insteadOf=https://github.com/" \
    push -u origin "${DOCS_BRANCH}"
```

For Azure DevOps remotes, use the provider-specific push in `providers/azure-devops.md` (it injects `AZURE_DEVOPS_TOKEN` for both `dev.azure.com` and `visualstudio.com`). If `GITHUB_TOKEN` (or `AZURE_DEVOPS_TOKEN`) is unset, the `validate-prerequisites.sh` hook blocks the push with a clear message — surface that message and stop.

If the commit or push fails, output a single error line and stop — do not ask what to do.

> **Why a separate branch?** The original PR's branch may be protected, under active review, owned by a fork, or fast-moving. By keeping documentation in its own branch and its own PR (targeted at the feature branch), the doc updates can be reviewed independently and merged when the author is ready, without rewriting or interleaving commits on the active feature branch.

---

## Step 9: Open the Documentation PR Targeting the Original PR's Branch

Open a new pull request whose **head** is `DOCS_BRANCH` and whose **target / base** is the original PR's feature branch (`PR_HEAD_BRANCH`). This makes the docs PR a candidate to be merged *into* the feature branch — once merged, the documentation changes become part of the original PR's commit history before it lands in `main`.

Use the platform-appropriate method:

- **GitHub:** see `providers/github.md` — Opening the Documentation PR section (uses `gh pr create --base "${PR_HEAD_BRANCH}" --head "${DOCS_BRANCH}"`)
- **Azure DevOps:** see `providers/azure-devops.md` — Creating the Documentation PR section (REST `POST .../pullrequests` with `sourceRefName=refs/heads/${DOCS_BRANCH}` and `targetRefName=refs/heads/${PR_HEAD_BRANCH}`)
- **Generic:** no remote PR can be created — leave the branch pushed (if a remote is available) and record the manual merge instructions in `doc-update-report.md`

PR metadata to use:

| Field | Value |
|---|---|
| Title | `docs: sync documentation with PR #${PR_NUMBER}` |
| Body | Use the same content as the summary comment from Step 10. Prepend a single line: `Documentation companion for #${PR_NUMBER}. Merge this PR into the \`${PR_HEAD_BRANCH}\` branch before merging the original PR.` |
| Base / target branch | `${PR_HEAD_BRANCH}` (the original PR's feature branch) |
| Head / source branch | `${DOCS_BRANCH}` |
| Labels (if supported) | `documentation` |

Store the resulting PR number and URL as `DOCS_PR_NUMBER` and `DOCS_PR_URL` — both are referenced in the summary comment posted in Step 10.

### Re-runs on the same original PR

If `DOCS_PR_NUMBER` already exists for `PR_NUMBER` (a previous run of this plugin opened one):

- Re-use the existing docs PR instead of opening a new one.
- The push in Step 8 will update the existing PR with the new commit.
- Update the docs-PR description with the latest summary content if the platform allows it (`gh pr edit ${DOCS_PR_NUMBER} --body ...` on GitHub).

Detect this by listing open PRs whose head branch is `DOCS_BRANCH`:

- **GitHub:** `gh pr list --head "${DOCS_BRANCH}" --json number,url --jq '.[0]'`
- **Azure DevOps:** see `providers/azure-devops.md` — Detecting an Existing Docs PR section

---

## Step 10: Post Documentation Summary Comment on the Original PR

Post the compiled summary on the **original PR** (`PR_NUMBER`) so reviewers see it in context. The comment must include a link to the new docs PR (`DOCS_PR_URL`) so the author knows exactly what to merge.

Use the template in `styles/report-template.md`. Read that file and follow its structure exactly.

- **GitHub / Azure DevOps:** post as a new comment on the original PR (`PR_NUMBER`), not the docs PR
- **Generic:** write to `doc-update-report.md` at the repository root

---

## Completion criteria (do not report success until these hold)

Only after the applicable branch below is satisfied may you emit a final result line. If a criterion is not met, you have not finished — keep working or emit the error line and stop.

**When documentation changes were applied:**

1. The doc commit exists on `DOCS_BRANCH` and the branch was pushed to `origin` (verify: `git log -1 --oneline` on `DOCS_BRANCH`, and the push command exited 0).
2. The companion docs PR actually exists. Verify it, do not assume:
   ```bash
   gh pr list --head "${DOCS_BRANCH}" --state open --json number,url --jq '.[0]'   # GitHub
   ```
   (Azure DevOps: confirm `DOCS_PR_ID` was returned by the create/detect call.)
3. The summary comment was posted on the original PR (or, in generic mode, `doc-update-report.md` was written).

Then output exactly one confirmation line:

```
Documentation PR opened: #<DOCS_PR_NUMBER> → ${PR_HEAD_BRANCH} (companion for PR #<number>): <N> updated, <N> added, <N> removed, <N> renamed — <DOCS_PR_URL>
```

Generic mode (no remote PR API):

```
Documentation branch pushed: ${DOCS_BRANCH} (merge into ${PR_HEAD_BRANCH}) — <N> updated, <N> added, <N> removed, <N> renamed — report written to doc-update-report.md
```

**When no documentation changes were required** (every change was a No-op — no commit, no docs PR opened): post the shorter "no-op" summary variant, then output:

```
No documentation updates required on PR #<number> — all changes are internal/refactor/test-only.
```

---

## Merged PR Flow

The default flow (Steps 4–10) opens a docs PR that targets the **original PR's head branch**. When the original PR is already merged, that head branch is typically deleted or has diverged — so the docs PR must instead target the original PR's **base branch** (e.g. `main`).

Substitute the following for Steps 4a and 9:

### 4a (merged): Cut the docs branch from the merge commit

1. **Identify the merge commit** from the platform metadata fetched in Step 2 (`mergeCommit.oid` on GitHub, `lastMergeCommit.commitId` on Azure DevOps). Fall back to `git log --oneline | head -5` if the API field is empty.

2. **Cut the docs branch from the merge commit:**
   ```bash
   MERGE_SHA=<merge commit SHA>
   DOCS_BRANCH="docs/pr-${PR_NUMBER}-followup"
   git fetch origin
   git checkout -b "${DOCS_BRANCH}" "${MERGE_SHA}"
   ```

3. **Apply all documentation edits** using the same Step 4b–Step 7 logic.

4. **Commit and push** (authenticate the push inline as in Step 8):
   ```bash
   git add <doc files>
   git commit -m "docs: sync documentation with merged PR #${PR_NUMBER}"
   git -c "url.https://x-access-token:${GITHUB_TOKEN}@github.com/.insteadOf=https://github.com/" \
       push -u origin "${DOCS_BRANCH}"
   ```

### 9 (merged): Open the follow-up docs PR targeting the base branch

Because the original PR is closed, the docs PR cannot target it — target `PR_BASE_BRANCH` (the original PR's base, e.g. `main`) instead.

- **GitHub:**
  ```bash
  gh pr create \
    --title "docs: sync documentation with merged PR #${PR_NUMBER}" \
    --body "Follow-up to #${PR_NUMBER}. Brings the project documentation in line with the source changes that were merged in that PR." \
    --base "${PR_BASE_BRANCH}" \
    --head "${DOCS_BRANCH}"
  ```
- **Azure DevOps:** see `providers/azure-devops.md` — Creating the Documentation PR section, with `targetRefName=refs/heads/${PR_BASE_BRANCH}`.
- **Generic:** write the manual merge instructions to `doc-update-report.md`.

Then proceed to Step 10 — post a summary comment on the **original (merged) PR** if the platform allows comments on merged PRs (GitHub does; Azure DevOps does), referencing the new follow-up docs PR.
