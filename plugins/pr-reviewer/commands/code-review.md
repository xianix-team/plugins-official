---
name: code-review
description: Focused PR code review optimised for cost. Prioritises correctness bugs, behavioural regressions, and security issues. Usage: /code-review
---

`2 haiku finders → self-verify → ≤8 findings`

Review the current branch for **correctness bugs, behavioural regressions, and security issues**. Do not make code changes. Do not post to any platform.

---

## Step 1 — Gather the diff (single Bash call)

```bash
HEAD_SHA=$(git rev-parse HEAD)

# Resolve base ref — works in detached-HEAD worktrees (no remote-tracking refs)
BASE_REF=""
for candidate in \
  "$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" \
  refs/remotes/origin/main refs/remotes/origin/master refs/remotes/origin/develop \
  refs/heads/main refs/heads/master refs/heads/develop; do
  [ -n "$candidate" ] && git show-ref --verify --quiet "$candidate" 2>/dev/null \
    && { BASE_REF="$candidate"; break; }
done
[ -z "$BASE_REF" ] && BASE_REF=$(git for-each-ref --format='%(refname)' refs/remotes/origin \
  | grep -v '/HEAD$' | head -1)
[ -z "$BASE_REF" ] && BASE_REF=$(git for-each-ref --format='%(refname)' refs/heads \
  | grep -v -F "$(git symbolic-ref -q HEAD || echo /no/ref)" | head -1)
[ -z "$BASE_REF" ] && { echo "ERROR: could not resolve base ref"; exit 1; }

BASE_SHA=$(git merge-base "$BASE_REF" "$HEAD_SHA")
git diff "${BASE_SHA}...${HEAD_SHA}" > /tmp/cr_diff.patch
echo "Diff written: $(wc -l < /tmp/cr_diff.patch) lines"
git diff --stat "${BASE_SHA}...${HEAD_SHA}"
git diff --name-only "${BASE_SHA}...${HEAD_SHA}" | tee /tmp/cr_changed_files.txt
git log --oneline "${BASE_SHA}..${HEAD_SHA}"
```

## Step 2 — Pre-load context (at most 3 Read calls, strict size cap)

From `/tmp/cr_changed_files.txt` pick the **top 3 highest-risk files** (business logic, auth, data-access first; skip pure test files and generated files unless they ARE the only changed files).

For each chosen file:
- If the file is **≤ 400 lines**, read it in full with the `Read` tool.
- If the file is **> 400 lines**, extract only the changed functions using the diff line numbers:

```bash
# Replace FILE and START/END with actual values from the diff hunk headers
grep -n "^@@" /tmp/cr_diff.patch | head -20   # find hunk positions
# Then read ±60 lines around each changed hunk
sed -n '<start>,<end>p' <file>
```

Concatenate all extracted snippets into `/tmp/cr_context.txt` (filepath header before each snippet).

**Do not read more than 3 files. Do not read any file in its entirety if it exceeds 400 lines.**

## Step 3 — Two parallel Haiku finder agents

Emit **both Agent calls in the same assistant turn** (so they run in parallel).  
Both agents **must** include `"model": "claude-haiku-4-5"` in the call.  
Neither agent may call `Read`, `Bash`, `Grep`, or any other tool — they work only from the files listed below.

**Agent 1 — Correctness & regressions**

```json
{
  "description": "Correctness & regression finder",
  "model": "claude-haiku-4-5",
  "prompt": "Read /tmp/cr_diff.patch then /tmp/cr_context.txt.\n\nFind correctness bugs and behavioural regressions introduced by the diff. Focus on:\n- Logic errors in changed code paths\n- Changed conditions that now allow or block cases they shouldn't\n- Null / empty / zero edge cases on new code paths\n- Removed guards that previously protected against a bad state\n- Interface/contract mismatches between callers and the changed function\n\nFor each finding output exactly:\nFILE: <path>\nLINE: <post-change file line number — the line as it appears in the NEW version of the file. Compute it from the @@ hunk header: new-side start (the number after the comma-less '+') plus the offset of the flagged '+' line within that hunk. Never report the diff's own line position.>\nSEVERITY: CRITICAL | WARNING\nISSUE: <one sentence>\n\nIf you find nothing, output: NONE\nDo not call any tools."
}
```

**Agent 2 — Security & edge cases**

```json
{
  "description": "Security & edge-case finder",
  "model": "claude-haiku-4-5",
  "prompt": "Read /tmp/cr_diff.patch then /tmp/cr_context.txt.\n\nFind security issues and missing edge-case handling in the diff. Focus on:\n- Input not validated before use (injection, path traversal)\n- Authentication or authorisation checks removed or weakened\n- Sensitive data written to logs\n- Exception or error paths that swallow failures silently\n- Resource leaks (connections, file handles) on error paths\n- Off-by-one errors or boundary conditions in new loops/ranges\n\nFor each finding output exactly:\nFILE: <path>\nLINE: <post-change file line number — the line as it appears in the NEW version of the file. Compute it from the @@ hunk header's new-side start plus the offset of the flagged '+' line within that hunk. Never report the diff's own line position.>\nSEVERITY: CRITICAL | WARNING | SUGGESTION\nISSUE: <one sentence>\n\nIf you find nothing, output: NONE\nDo not call any tools."
}
```

## Step 4 — Verify and compile (no additional agents)

You are the verifier. For each finding from both agents:

1. Confirm the flagged line appears in `/tmp/cr_diff.patch` as a `+` line (new code, not pre-existing).
2. Discard: pre-existing issues, linter/compiler-caught problems, pedantic style, obvious false positives.
3. Merge duplicates. Cap at **8 total findings**, ranked CRITICAL → WARNING → SUGGESTION.

## Step 5 — Output

```
## Code Review

### Critical Issues
- `path/to/file.ext:NN` — [description]
  **Fix:** [concrete fix in the same language]

### Warnings
- `path/to/file.ext:NN` — [description]
  **Fix:** [suggestion]

### Suggestions
- `path/to/file.ext:NN` — [improvement]

### Positive Observations
[One specific thing done well in the diff]
```

If there are no findings in a section, write "None."
