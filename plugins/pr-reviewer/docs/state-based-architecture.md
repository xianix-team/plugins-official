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

## Flow: Re-Review (No New Commits)

```
1. Author makes small changes without pushing (HEAD_SHA unchanged)

2. Command runs ado-detect-prior.sh
   → /tmp/pr_prior_findings.jsonl contains prior findings
   → /tmp/pr_prior.env: PRIOR_SUMMARY_SHA=abc123...

3. Command decides mode:
   → PRIOR_SUMMARY_SHA (abc123) == HEAD_SHA (abc123)
   → No new commits! But could still have findings changes
   → REVIEW_MODE="rereview" (still checking for changes)
   → RANGE_BASE="BASE_SHA" (review entire PR, not just delta)

4. Command runs review agents
   → Reviews full diff

5. Command reconciliation:
   → Might find same findings or new ones
   → Write state

6. Provider:
   → Skip summary post (same SHA)
   → Post only NEW/FIXED findings
   → Don't duplicate carried-over threads
```

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
grep "pr-reviewer:v2" /tmp/pr_thread_body.md
```

## Summary

This architecture ensures:
- ✅ **No duplicates** — Dedup built into provider logic
- ✅ **Deterministic** — State files, not guesses
- ✅ **Cross-platform** — Same logic for GitHub, Azure, Generic
- ✅ **Testable** — State files make behavior observable
- ✅ **Maintainable** — Single decision point (command), multiple implementations (providers)
