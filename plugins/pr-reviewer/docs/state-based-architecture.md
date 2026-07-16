# PR Reviewer Plugin — State-Based Architecture

## Overview

This document describes the deterministic, state-based architecture that ensures consistent behavior across GitHub, Azure DevOps, and Generic platforms, eliminating duplicate comments and ensuring correct mode detection.

## Core Principle

**Single Source of Truth for Decision State**

Rather than having each script (command, detection, posting) make independent decisions, the command writes canonical decision state to files that all providers read and validate.

```
Step 1-2: Setup & Detect
├─ bash ado-detect-prior.sh (or gh-detect-prior.sh)
│  └─ Writes: /tmp/pr_prior_findings.jsonl, /tmp/pr_prior.env
│
Step 3: Decide Mode (COMMAND ONLY)
├─ Command reads /tmp/pr_prior_findings.jsonl
├─ Determines REVIEW_MODE based on:
│  ├─ IF /tmp/pr_prior_findings.jsonl is empty → REVIEW_MODE="initial"
│  ├─ IF prior findings exist AND PRIOR_SUMMARY_SHA != HEAD_SHA → REVIEW_MODE="rereview"
│  └─ Writes to /tmp/pr_review_state.json
│
Step 7: Post Review (PROVIDER - reads state, doesn't decide)
├─ bash ado-post-review.sh (or github provider)
├─ Reads /tmp/pr_review_state.json (VALIDATION - must exist)
├─ Uses REVIEW_MODE from state, never from env var
├─ Implements unified dedup/reconciliation logic
└─ Posts using platform-appropriate mechanics
```

## State Files

### 1. `/tmp/pr_review_state.json` (Canonical Mode Decision)

**Written by:** `pr-review.md` command in step 3  
**Read by:** All providers at startup  
**Never modified by:** Providers

```json
{
  "mode": "initial" | "rereview",
  "prior_sha": "<PRIOR_SUMMARY_SHA>" or null,
  "head_sha": "<HEAD_SHA>",
  "range_base": "<BASE_SHA or PRIOR_SUMMARY_SHA>",
  "reconcile_enabled": true | false,
  "_version": 1,
  "_comment": "Canonical review state written by command; providers MUST read from this file"
}
```

**When to post each mode:**

| Mode | Summary | Inline Findings | Purpose |
|------|---------|-----------------|---------|
| `initial` | Post new summary | Post all findings | First review of PR |
| `rereview` | Skip (already exists) | Post only NEW findings | Follow-up review after commits |

### 2. `/tmp/pr_reconcile.json` (Finding Buckets)

**Written by:** Step 7 (reconciliation logic) in the command  
**Read by:** Providers in step 8-9 (when posting inline/reconciling)  
**Purpose:** Explicit tracking of which findings are new/carried-over/fixed/reopened

```json
{
  "new": [
    {"file": "...", "line": 42, "fid": "abc123...", "body": "..."},
    ...
  ],
  "carried_over_fids": ["abc123", "def456", ...],
  "fixed": [
    {"fid": "ghi789", "thread_ref": "123", "comment_ref": "456"},
    ...
  ],
  "reopened": [
    {"fid": "jkl012", "thread_ref": "789", "comment_ref": "012"},
    ...
  ],
  "_version": 1
}
```

**Buckets:**
- **`new`**: Findings introduced in this review (post in re-review mode)
- **`carried_over_fids`**: FIDs that exist in both prior and current findings (skip posting, keep thread open)
- **`fixed`**: Prior findings that are now resolved (post reply + resolve thread)
- **`reopened`**: Prior findings marked resolved whose fids reappear in current findings (post reply + reactivate thread)

### 3. `/tmp/pr_prior.env` (Detection Output)

**Written by:** Detection scripts (`ado-detect-prior.sh`, `gh-detect-prior.sh`)  
**Read by:** Command in step 3

```bash
PRIOR_SUMMARY_SHA=abc123...  # SHA the prior review was posted against
PRIOR_SUMMARY_THREAD_ID=456  # Platform-specific thread/review ID
PRIOR_SUMMARY_PUBLISHED=2026-07-15T...  # When it was posted
```

### 4. `/tmp/pr_prior_findings.jsonl` (Prior Plugin Findings)

**Written by:** Detection scripts  
**Read by:** Command in step 3

One JSON object per line:
```json
{"fid": "abc123...", "status": "open|resolved", "thread_ref": "123", "comment_ref": "456"}
```

Only includes findings posted by **this plugin** (identified by marker). Used to determine if prior review exists.

## Flow: Initial Review

```
1. Command runs ado-detect-prior.sh
   → /tmp/pr_prior_findings.jsonl is EMPTY (no prior reviews)
   → /tmp/pr_prior.env: PRIOR_SUMMARY_SHA=""

2. Command decides mode:
   → /tmp/pr_prior_findings.jsonl is empty
   → REVIEW_MODE="initial"
   → Write /tmp/pr_review_state.json with mode="initial"

3. Command runs review agents
   → Generates findings

4. Command reconciliation (step 7):
   → All findings are NEW (no prior findings to compare)
   → Write /tmp/pr_review_reconcile_state.json
      - "new": [all findings]
      - "carried_over_fids": []
      - "fixed": []

5. Command calls provider:
   → bash ado-post-review.sh
   → Export VERDICT

6. Provider (ado-post-review.sh):
   → Read /tmp/pr_review_state.json
   → Confirm mode="initial"
   → Post summary thread with marker (sha=<HEAD_SHA>)
   → Post ALL inline findings
   → Done
```

## Flow: Re-Review (New Commits)

```
1. Author makes changes, pushes new commit (HEAD_SHA changes)

2. Command runs ado-detect-prior.sh
   → /tmp/pr_prior_findings.jsonl contains prior findings (fids from last review)
   → /tmp/pr_prior.env: PRIOR_SUMMARY_SHA=abc123..., PRIOR_SUMMARY_THREAD_ID=789

3. Command decides mode:
   → /tmp/pr_prior_findings.jsonl is NOT empty
   → PRIOR_SUMMARY_SHA (abc123) != HEAD_SHA (def456)
   → REVIEW_MODE="rereview"
   → RANGE_BASE="abc123" (for incremental diff)
   → Write /tmp/pr_review_state.json with mode="rereview"

4. Command runs review agents
   → Reviews full diff (from BASE to HEAD)
   → Generates findings (subset that changed)

5. Command reconciliation (step 7):
   → Compare current findings against prior by FID
   → Buckets:
      - NEW: fids not in prior set
      - CARRIED_OVER: fids in both sets
      - FIXED: fids in prior set but not current (with verification)
   → Write /tmp/pr_review_reconcile_state.json

6. Command calls provider:
   → bash ado-post-review.sh
   → Export VERDICT

7. Provider (ado-post-review.sh):
   → Read /tmp/pr_review_state.json
   → Confirm mode="rereview"
   → Read /tmp/pr_review_reconcile_state.json
   → SKIP summary post (already exists for prior SHA)
   → Resolve FIXED findings (reply + mark resolved)
   → POST only NEW findings (skip carried-over)
   → Reply on addressed external threads
   → Done (no duplicates!)
```

## Flow: Re-Review (No New Commits) — Cost Gate

```
1. PR is re-triggered (comment, re-run, etc.) but HEAD_SHA is unchanged
   since the last review — no commits were pushed in between.

2. Command runs ado-detect-prior.sh
   → /tmp/pr_prior_findings.jsonl contains prior findings
   → /tmp/pr_prior.env: PRIOR_SUMMARY_SHA=abc123...

3. Command decides mode:
   → PRIOR_SUMMARY_SHA (abc123) == HEAD_SHA (abc123)
   → REVIEW_MODE="rereview"

4. Cost gate (commands/pr-review.md, right after mode decision):
   → REVIEW_MODE=rereview AND HEAD_SHA == PRIOR_SUMMARY_SHA
   → PR_REVIEWER_NOOP=true
   → SKIP codebase indexing (step 4), tier selection (step 5), and the
     ENTIRE sub-agent fan-out (step 6) — the diff, codebase, and open
     threads are byte-identical to what the last run already analyzed,
     so nothing downstream could produce a different finding set.
   → Post one lightweight acknowledgement reply (no marker) and stop.

Nothing in steps 5-9 executes. No Haiku/specialist sub-agents are spawned,
no report is compiled, no reconciliation runs — this is the fix for a
same-SHA re-review previously costing the same as a full review, because
step 6 used to run unconditionally against the full diff even when the
mode decision already knew there were zero new commits to look at.
```

**Historical note:** prior to this cost gate, a same-SHA re-review still ran the full sub-agent fan-out over the complete diff (step 6), then relied on step 7's Gate A to force the `fixed` bucket empty and the `new` bucket to typically end up empty too — i.e. it paid for a full analysis just to throw the result away as `carried_over`. The cost gate above intercepts this case *before* any sub-agent is spawned.

## Key Design Decisions

### 1. Why State Files, Not Environment Variables?

**Problem with env vars:**
- Fragile: Can be overridden or lost between shell invocations
- No validation: Providers can't detect if something was actually set
- Easy to misconfigure: Old env vars persist across runs
- Non-deterministic: Defaults in multiple places cause disagreement

**Solution: State files**
- ✅ Persistent across tool calls
- ✅ Validates presence (error if missing)
- ✅ Providers check contents, not guess
- ✅ Deterministic: single calculation, written once, read many times

### 2. Why Carry-Over Detection?

**Problem:** In re-review mode, unresolved findings from prior review keep getting posted as duplicates.

**Solution:** Track which FIDs exist in both sets:
- Read `/tmp/pr_prior_findings.jsonl` (prior FIDs)
- Compare against new findings by FID (not line number, which drifts)
- Skip posting threads for carried-over FIDs
- Keep existing threads open (no duplicate noise)

### 3. Why Marker Validation?

Some Azure DevOps API responses strip custom properties. We:
- Always embed marker in body text (survives property stripping)
- Validate marker was written after posting (catch API failures)
- Extract marker on re-review detection (fallback if properties empty)

### 4. Why Platform-Specific Reconciliation?

**GitHub:** Uses review events (natural dedup at platform level)  
**Azure DevOps:** Uses individual threads (manual dedup needed)  
**Generic:** No API (can't read old markers, only initial mode)

Each provider implements the same logic but calls appropriate APIs.

## Provider Implementation Checklist

### At Startup (All Providers)

- [ ] Load `/tmp/pr_review_state.json` (fail if missing)
- [ ] Validate all required fields present
- [ ] Export state as env vars for use in script
- [ ] Log mode decision

### Summary/Review Event Posting

- [ ] **Initial mode:** POST new summary/review with marker
- [ ] **Re-review mode:** CHECK if summary for HEAD_SHA exists; SKIP if it does
- [ ] Validate marker was actually written (check posted body)

### Inline Findings

- [ ] **Initial mode:** POST all findings
- [ ] **Re-review mode:** 
  - [ ] Read `/tmp/pr_review_reconcile_state.json`
  - [ ] Extract `carried_over_fids`
  - [ ] For each finding: SKIP if fid in carried-over set, ELSE POST

### Reconciliation (Re-Review Only)

- [ ] **Fixed findings:** Reply + resolve thread
- [ ] **Carried-over findings:** Do nothing (already open)
- [ ] **External threads:** Reply if addressed, never resolve

## Testing & Validation

### Unit Tests (Per Provider)

**Initial review:**
```bash
# Setup: /tmp/pr_prior_findings.jsonl is empty
$ bash ado-post-review.sh
# Expect: /tmp/pr_review_state.json mode="initial"
# Expect: Summary posted (new thread)
# Expect: All findings posted (new threads)
# Expect: No carried-over skips
```

**Re-review (with new commits):**
```bash
# Setup: /tmp/pr_review_state.json mode="rereview" + new findings
$ bash ado-post-review.sh
# Expect: Summary skipped (already exists)
# Expect: Only NEW findings posted
# Expect: Carried-over findings skipped
# Expect: Fixed findings resolved
```

**Re-review (no new commits):**
```bash
# Setup: HEAD_SHA == PRIOR_SUMMARY_SHA
$ bash ado-post-review.sh
# Expect: Summary skipped
# Expect: No inline findings posted (all carried-over)
```

### Integration Test (All Platforms)

1. First review on PR #123:
   - Expect 1 summary thread
   - Expect N inline findings
   
2. Push new commit (HEAD changes):
   - Run review again
   - Expect NO new summary (dedup)
   - Expect only new/fixed findings posted
   - Expect carried-over findings NOT re-posted

3. Verify logs show:
   - Mode decision logic
   - Dedup checks and skips
   - Marker validation success
   - Reconciliation counts

## Debugging

Check state files:
```bash
# What mode is active?
jq .mode /tmp/pr_review_state.json

# What findings are in each bucket?
jq '.new | length, .carried_over_fids | length, .fixed | length' \
  /tmp/pr_review_reconcile_state.json

# What was the prior review?
source /tmp/pr_prior.env
echo "Prior SHA: $PRIOR_SUMMARY_SHA"
echo "Prior thread: $PRIOR_SUMMARY_THREAD_ID"

# Did marker write succeed?
grep "pr-reviewer:v1.2" /tmp/pr_thread_body.md
```

## Known Failure Modes and Mitigations

This section documents failure modes discovered in production (Azure DevOps PR #13, July 2026) and their permanent fixes.

### Incident: July 15–16, 2026 (Three Behavioral Episodes in One Session)

Three distinct failure modes appeared in a single `/pr-review` session on a live PR, revealing architectural gaps upstream of the state-file layer.

#### Run A: Fabricated FIDs, Collapsed Newlines, Missing Starting Comment

**Symptoms:**
- Starting comment was not posted (Step 2 skipped)
- Report body had zero embedded newlines (all sections glued together)
- Findings had sequential fake fids (`abc123001`…`abc123016`) instead of 12-hex-char hashes

**Root Causes:**
1. Step 2 (starting comment) had no self-check — a missed tool call went undetected
2. `compute_fid` was prose-instructed per-finding but never validated — model fabricated plausible-looking strings instead of running the hash algorithm
3. Report body was hand-typed into a Bash heredoc (~4000 chars as literal string argument), causing blank lines to collapse during tool-call parameter encoding

**Mitigation:**
- **Self-check after Step 2** (`commands/pr-review.md:207-210`): Explicit verification in conversation history for "Review-in-progress comment posted" or "WARN: skipping" lines.
- **fid validation + self-healing** (`scripts/ado-post-review.sh:444-490`, `providers/github.md:272-296`): Before posting inline findings, validate fid format (`^[0-9a-f]{12}$`). If validation fails and `snippet`/`occurrence_index` are present, recompute fid deterministically and log loud WARN.
- **Mandate `Write` tool for report body** (`commands/pr-review.md:852`, `providers/azure-devops.md:558`): Remove heredoc option. Always use `Write` tool — it passes content as structured parameter, not raw string argument.
- **Newline-density check + best-effort repair** (`scripts/ado-post-review.sh:239-247`): Before posting summary, check if body >500 chars but <1 newline per 200 chars. If true, log WARN and insert `\n\n` before headings/list patterns. Heuristic safety net, not a substitute for the `Write` mandate.

#### Run B: Rogue Marker-Less Posting via Orphan Template

**Symptoms:**
- Starting comment posted normally (293)
- Summary + 15 findings posted in different format (294–309)
- Zero `pr-reviewer` markers anywhere in either thread
- Comments used different style: `**SECURITY:**` bold headers instead of structured finding bodies
- No reconciliation linkage — Run A's findings were not recognized on re-review

**Root Cause:**
`providers/azure-devops.md:159-230` contained a self-contained "Posting pattern (use this exact form for every write call)" section with ready-to-use curl templates for generic comment threads and inline comments. A model independently adopted this template and hand-posted an entire review, completely bypassing markers, reconciliation, and the canonical posting flow.

**Mitigation:**
- **Delete the rogue template entirely** (`providers/azure-devops.md`): Remove lines 159–230 ("Posting pattern", "Generic comment thread", "Inline comment thread"). Every real posting need already has a canonical script or script-embedded path. An orphan template is a liability, not a convenience.
- Every real posting path is now:
  - Command+provider integration (summary via `/pr-review` → provider script)
  - Inline-findings loop in provider script (all findings in one script with dedup checks)
  - Reconciliation (resolve/reopen via provider script)
  - External replies (provider script with reply-only validation)

#### Run C: Silent Re-Review Non-Detection

**Symptoms:**
- Starting comment, summary, and 33 findings posted successfully
- All fids were real 12-hex-char values (from Run A's corrected algorithm)
- Report body again had zero newlines (same heredoc issue as Run A)
- **No re-review detection**: Run A's 16 findings were not recognized as prior — posted as 16 new findings instead of being carried-over

**Root Cause:**
Mode-decision block had no visibility check. If `/tmp/pr_prior.env` was missing (because detect-prior was never run, or Run B's rogue posting never called it), the decision silently fell through to `REVIEW_MODE="initial"` with no way to distinguish "we checked and found nothing" from "we never checked." Result: duplicate summary + findings indistinguishable from an initial review.

**Mitigation:**
- **Mode-decision visibility check** (`commands/pr-review.md:524-529`): After sourcing `/tmp/pr_prior.env`, check if file exists. If reconciliation is enabled but prior.env is missing, log WARN: "/tmp/pr_prior.env missing — detect-prior script was not run (or failed) before this mode decision. Proceeding as REVIEW_MODE=initial, but if a prior review actually exists on this PR, this run WILL post duplicate summary/findings." Doesn't change behavior (still falls through to `initial` per the warn-not-abort policy), but makes the exact failure mode visible in run output.

### Post-Post Marker Verification (Audit Trail)

Even after all fixes above, a final-line-of-defense audit is needed: verify the marker actually made it into the posted thread's response body (Azure properties can strip custom fields on create; GitHub responses may omit body on some error paths).

**Implementation:**
- **Azure inline findings** (`scripts/ado-post-review.sh:531-537`): After successful POST (HTTP 2xx), check response body for marker string. If absent, log ERROR and increment `MARKER_VERIFY_FAILED` counter.
- **Azure summary** (`scripts/ado-post-review.sh:289-296`): Same check after successful summary POST.
- **GitHub inline findings** (`providers/github.md:319-325`): Same check after successful `gh api` comment POST.
- **GitHub summary** — Note: `gh pr review` is a high-level command; detailed response inspection is difficult. Marker verification for summary is best-effort only.
- **Final summary line** (`scripts/ado-post-review.sh:622-625`): If `MARKER_VERIFY_FAILED > 0`, print ERROR line naming count. Per warn-not-abort policy, doesn't exit non-zero, but creates the audit trail that was completely absent during the incident (Run B's rogue posting would have shown this warning 15+ times).

### Summary of Fixes

| Failure | Root Cause | Mitigation | Location |
|---------|-----------|-----------|----------|
| **Fabricated fid** | No validation of `compute_fid` invocation | Validate format + self-heal via recomputation | `ado-post-review.sh:444-490`, `providers/github.md:272-296` |
| **Collapsed newlines** | Hand-typed heredoc parameter | Mandate `Write` tool + newline-density safety net | `commands/pr-review.md:852`, `ado-post-review.sh:239-247` |
| **Missed starting comment** | No self-check after Step 2 | Explicit history verification | `commands/pr-review.md:207-210` |
| **Rogue marker-less posting** | Orphan template in docs | Delete template; all posting via canonical scripts | `providers/azure-devops.md` (lines 159-230 deleted) |
| **Silent mode-decision failure** | No visibility if detection never ran | Warn if prior.env missing but reconciliation enabled | `commands/pr-review.md:524-529` |
| **Marker escape detection** | No POST-response validation | Verify marker in response body; log ERROR + counter | `ado-post-review.sh:531-537, 289-296`, `providers/github.md:319-325`, final summary |

## Summary

This architecture ensures:
- ✅ **No duplicates** — Dedup built into provider logic
- ✅ **Deterministic** — State files, not guesses
- ✅ **Cross-platform** — Same logic for GitHub, Azure, Generic
- ✅ **Testable** — State files make behavior observable
- ✅ **Maintainable** — Single decision point (command), multiple implementations (providers)
- ✅ **Resilient** — Validation at every layer catches upstream failures before they compound
