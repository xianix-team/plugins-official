---
name: pr-group-review
description: Review a GROUP of related pull requests (one feature split across several repositories, linked to one labelled work item) in one run — each PR gets its normal review plus cross-repo findings and a shared group summary. Usage: /pr-group-review --work-item <owner/repo#N | Azure DevOps work item URL> | --pr <N> [--force] | <PR URL | repo#n | repo@branch …>
argument-hint: --work-item <ref> | --pr <n> [--force] | <pr-url | repo#n | repo@branch ...>
---

Run a unified review of the pull-request group for $ARGUMENTS.

## You are the review lead — run this yourself

Same rule as `/pr-review`: **you**, the top-level agent, run every step and spawn the reviewer sub-agents directly. Never delegate the procedure to an orchestrator sub-agent — sub-agents cannot spawn sub-agents, so the parallel review would silently not happen.

Execute every step autonomously and in order, without asking for confirmation. If a step fails, output one error line and stop — except where a step says "warn and continue".

**How this differs from `/pr-review`.** Each member PR is reviewed exactly like `/pr-review` would (same finders, same posting, same re-review reconciliation), but:
- the group is found from the **work item**: its label (Azure DevOps: tag) `ai-dlc/pr/group-review` turns group review on, and every open PR linked to it is a member;
- this command fetches the other members' repositories itself, and posts a note once on each member PR saying it is reviewed with the group (a push to any open PR starts this command, which stops at once for PRs that are not in a labelled group);
- a **lock** stored with the work item makes sure only one group review runs at a time;
- every member has its **own state directory** `/tmp/prg/<slug>/` instead of `/tmp/pr_*`;
- one extra reviewer, `cross-repo-reviewer`, looks only at defects *between* the PRs;
- every member's summary ends with the same **group section**.

Never run the single-PR scripts (`pr-setup.sh`, `gh-post-review.sh`, …) yourself during a group review, and never read or write `/tmp/pr_*` — use the `group-*.sh` scripts below.

**Arguments.** `--work-item <ref>` (the label was added to that work item, or its PR links changed), `--pr <N>` (a PR in the current repository was opened or pushed, or someone asked for a group review on it), `--force` (review every member, even unchanged ones). PR URLs / `repo#n` / `repo@branch` without `--work-item`/`--pr` are a **local run**: skip D1–D3, D5 and every lock call; start at G1 with those members.

**The lock.** Once D2 says `LOCK=acquired`, this run owns the group. If you stop for **any** reason after that — a failed step included — run `group-lock.sh release` before stopping, so the next push is not blocked. If any lock call prints `LOCK=lost`, another run took the group over (this one was too slow): stop at once without posting and without releasing.

---

## G0. Resolve plugin scripts

```bash
# shellcheck disable=SC1091
[ -f /tmp/pr_plugin.env ] && source /tmp/pr_plugin.env
resolve_pr_script() {
  local name="$1" cand
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/${name}" ]; then
    echo "${CLAUDE_PLUGIN_ROOT}/scripts/${name}"; return 0
  fi
  for cand in \
    ${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/plugins/cache/*/pr-reviewer/*/scripts/$name} \
    ${HOME:+$HOME/.claude/plugins/cache/*/pr-reviewer/*/scripts/$name} \
    /workspace/repo/xianix-claude-config/plugins/cache/*/pr-reviewer/*/scripts/"$name" \
    /workspace/*/xianix-claude-config/plugins/cache/*/pr-reviewer/*/scripts/"$name"
  do
    [ -f "$cand" ] || continue
    echo "$cand"; return 0
  done
  find ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT"} ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR/plugins"} \
    ${HOME:+"$HOME/.claude/plugins"} /workspace/repo/xianix-claude-config/plugins \
    -path "*/pr-reviewer/scripts/${name}" 2>/dev/null | sort -V | tail -1
}
S=$(resolve_pr_script group-discover.sh)
[ -n "${S:-}" ] && [ -f "$S" ] || { echo "ERROR: scripts/group-discover.sh not found — stop the review" >&2; exit 1; }
ROOT="$(cd "$(dirname "$S")/.." && pwd)"
{
  printf 'export CLAUDE_PLUGIN_ROOT=%q\n' "$ROOT"
  printf 'export PRG_WS=%q\n' "${PRG_WS:-/tmp/prg-ws}"
  [ -n "${GITHUB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ] && printf 'export GH_TOKEN=%q\n' "$GITHUB_TOKEN"
} > /tmp/prg_plugin.env
echo "CLAUDE_PLUGIN_ROOT=$ROOT"
```

If the scripts cannot be resolved, **stop**. Do not hand-roll replacements.

## D1. Discover the group (one Bash call)

Pass `--work-item …` / `--pr …` / `--force` exactly as given in `$ARGUMENTS`:

```bash
source /tmp/prg_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/group-discover.sh" <arguments from $ARGUMENTS>
```

The script reads the work item, its label and the linked PRs, waits for the quiet period when `PR_GROUP_SETTLE_SECONDS` is set (it sleeps; this is expected), and posts the group note on members that do not have it yet. Read its `STATUS=` line (and, with `--pr`, its `TRIGGER_MEMBER=` line):

| STATUS | What to do |
|---|---|
| `group` | Continue with D2 — unless `TRIGGER_MEMBER=false`: then print `Group review: PR #<n> is not a member of the group of <WORK_ITEM> — nothing to do` and stop. |
| `not-labelled` | Print `Group review: <WORK_ITEM> does not have the group-review label — nothing to do` and stop. |
| `too-small` | Print `Group review: <WORK_ITEM> has fewer than 2 open PRs — nothing to do` and stop. |
| `no-work-item` | Print `Group review: PR #<n> is not linked to a labelled work item — nothing to do` and stop. |

None of these stop cases is a failure.

## D2. Take the lock

```bash
source /tmp/prg_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/group-lock.sh" acquire
```

- `LOCK=acquired …` → continue.
- `LOCK=busy HOLDER=<id>` → another run is reviewing this group; when it finishes it checks for new commits and reviews them too. Print `Group review: already running (<id>) — this push will be included` and stop. Do **not** release (you do not own the lock).

## D3. Check out the members

```bash
source /tmp/prg_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/group-checkout.sh"
```

Members that cannot be fetched are left out (warn and continue). Exit 1 means none could be checked out: release the lock and stop.

## G1. Set up every member (one Bash call)

Set `PR_REVIEWER_GROUP_FORCE=true` when `FORCE=true` in `$PRG_WS/run.env` (it follows `--force`, and is reset for a second pass). For a local run, pass the members from `$ARGUMENTS` as separate arguments instead.

```bash
source /tmp/prg_plugin.env
PR_REVIEWER_GROUP_FORCE=<true|false> bash "$CLAUDE_PLUGIN_ROOT/scripts/group-setup.sh"
```

Per member this runs, in that member's checkout with `PR_STATE_DIR=/tmp/prg/<slug>`: permissions check → `pr-setup.sh` (checks out the PR head) → `detect-review-mode.sh` → `review-tier.sh` → "review in progress" comment (mentioning the group). The comment is posted only on members that will be reviewed: a member with no new commits since its last review gets none, unless forced. Full output per member is in `/tmp/prg/<slug>/setup.log`; the script prints one line per member.

- Members marked `✗ excluded` are not reviewed (no access, closed/merged, no changes). Continue with the rest.
- If the script exits non-zero, no member could be set up: output its error, release the lock and stop.
- If `CHANGED_COUNT=0` and the run is not forced, nothing changed since the last review: go straight to **D5** (it records this and frees the lock).
- `BUDGET_MODE=lean` means the run's budget is thin for this many PRs: in G4 use the `haiku` tier for **every** member, with a single finder each.
- `/tmp/prg/group_state.json` now lists every member (`slug`, `dir`, `state_dir`, `pr_number`, `review_mode`, `review_tier`, `diff_lines`, `unchanged_since_last_review`). Read it once.

## G2. Build the contract index

```bash
source /tmp/prg_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/group-contract-index.sh"
```

Writes `/tmp/prg/contracts.md`. Do not paste it back to yourself; the cross-repo reviewer reads it.

## G3. Understand the feature

Read, without re-fetching anything:
- the work item title/description from `$PRG_WS/discovery.json` (`work-item.title`, `work-item.body`);
- each active member's `PR_TITLE` / `PR_BODY` from `/tmp/prg/<slug>/pr_state.env`.

Write a 3–6 line **feature intent** summary. It goes into the cross-repo reviewer's prompt.

## G4. Run all reviewers in ONE assistant turn (parallel)

First keep the lock alive (reviews take a while) and make sure the group is still on:

```bash
source /tmp/prg_plugin.env; bash "$CLAUDE_PLUGIN_ROOT/scripts/group-lock.sh" heartbeat
```

`LOCK=disabled` means the label was removed from the work item meanwhile: release the lock, print `Group review: stopped — the group-review label was removed` and stop. `LOCK=lost`: stop (see **The lock**).

Then emit **all** of the following sub-agent calls in the same turn:

**a) Per-member reviews.** For each active member whose `unchanged_since_last_review` is `false` (or all members when forced), run exactly what `/pr-review` step 6 runs for that member's `review_tier` (all `haiku` in lean mode):
- `haiku` → the two Haiku finders of step **6A**;
- `specialists` → the gated specialists of step **6B** (`select-reviewers.sh` / `resolve-models.sh` run with `PR_STATE_DIR=/tmp/prg/<slug>` from the member's `dir`).

Read `"$CLAUDE_PLUGIN_ROOT/commands/pr-review.md"` steps 6A/6B once and reuse those prompts verbatim, with two substitutions: every `/tmp/pr_<name>` becomes `/tmp/prg/<slug>/pr_<name>`, and the 6A pre-load context file is `/tmp/prg/<slug>/pr_context.txt` (built from that member's files only, read from that member's `dir`). Start each prompt with `MEMBER: <slug> — repository at <dir>`.

With more than 4 members, or in lean mode, give each `haiku`-tier member a **single** finder that covers both focus lists instead of two.

**b) Cross-repo review** — only when at least 2 members are active and at least one of them changed: one call with `subagent_type: "cross-repo-reviewer"` (prefix `pr-reviewer:` if your SDK requires it), no `model` field. Prompt:

```
Group: /tmp/prg/group_state.json   Contract index: /tmp/prg/contracts.md
Numbered diffs: /tmp/prg/<slug>/pr_full_diff_numbered.patch for each member: <slug list>
Feature intent:
<your G3 summary>
Return findings in your required block format, then the MERGE_ORDER line.
```

When `TOTAL_DIFF_LINES` in `/tmp/prg/group_state.env` exceeds `${PR_GROUP_MAX_DIFF_LINES:-6000}`, add: *"The group is large: work from contracts.md and read diffs only for the specific hunks it points to."*

The tool may be exposed as `Task` or `Agent`; if one returns `No such tool available`, retry the same calls with the other name.

## G5. Verify and merge findings

Self-verify as `/pr-review` does (keep real, well-evidenced findings; drop speculation; cap per-member findings at 8; cap cross-repo findings at 8). For each cross-repo finding, check that `LINE` really is a numbered line in that member's patch.

Write **one** file, `/tmp/prg/findings.jsonl` — one JSON object per finding:

```json
{"member": "<slug>", "file": "<path>", "line": 42, "severity": "CRITICAL", "body": "<finding body in the /pr-review format, incl. **Fix:** and any suggestion block>"}
{"member": "<slug>", "file": "<path>", "line": 7, "severity": "WARNING", "category": "contract-drift", "related": "<other-slug>:<path>:<line>", "body": "<issue + fix>"}
```

`category` and `related` only on cross-repo findings. Keep `suggestion_start_line` / `suggestion_end_line` exactly as `/pr-review` would.

Then route them:

```bash
source /tmp/prg_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/group-route-findings.sh"
```

Any `DROPPED` line means you used a wrong member slug — fix `/tmp/prg/findings.jsonl` and re-run.

## G6. Write each member's report, verdict, and the group notes

For each active member that will be posted (changed, forced, or with findings routed to it):
1. Write `/tmp/prg/<slug>/pr_thread_body.md` — that member's report following `styles/report-template.md`, covering its own findings **and** the cross-repo findings anchored on it. Do not add the group table; the post script appends it.
2. Write `/tmp/prg/<slug>/verdict` — one of `APPROVE`, `REQUEST CHANGES`, `NEEDS DISCUSSION`, from that member's open findings (own + cross-repo anchored on it), using the same rules as `/pr-review`.
3. Optional, as in `/pr-review` step 7: `/tmp/prg/<slug>/pr_external_reconcile.json` for addressed external threads on that PR.

Write `/tmp/prg/group_notes.md` once, following `styles/group-report-template.md`: the cross-repo findings list (all members) and the **advisory** suggested merge order from the reviewer's `MERGE_ORDER` line. Merge order is advice only — it never changes a verdict.

## G7. Post (one Bash call)

```bash
source /tmp/prg_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/group-lock.sh" heartbeat
```

Same rules as in G4: `LOCK=disabled` → release, print the stopped line and stop **without posting**; `LOCK=lost` → stop. Otherwise post:

```bash
source /tmp/prg_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/group-post.sh"
```

Per member, in its checkout and state dir: `validate-findings.sh` → `assign-fids.sh` → `reconcile-prior-findings.sh` → `gh-post-review.sh` / `ado-post-review.sh` (generic: `pr-review-report.md` in the member's folder), with the shared group section appended to the body. A member with no new commits and no new findings is skipped (its previous review stands) unless forced.

## D5. Next pass, or done

```bash
source /tmp/prg_plugin.env
bash "$CLAUDE_PLUGIN_ROOT/scripts/group-lock.sh" next
```

It records the commit each member was reviewed at, then reads the group again:

| Output | What to do |
|---|---|
| `NEXT=done …` | Nothing new (or the label is gone). The lock is released. Go to G8. |
| `NEXT=again PASS=<n> CHANGED=<list>` | A member got new commits, or a PR was linked, while this review ran — and there is time for another pass. You still hold the lock. Print the per-member lines of the pass you just finished, then go back to **D3** and run D3 → G7 → D5 again. Do not repeat D1/D2. |
| `NEXT=handed-off ON=<pr>` | New commits arrived but this container is out of time or passes. The lock is released and a follow-up comment on that PR starts a fresh run. Go to G8. |

Skip D5 for a local run.

## G8. Report

Print the post script's per-member confirmation lines and its final `Group review: …` line verbatim (for every pass), then the `NEXT=` line. If any member shows `POST FAILED`, add one line pointing to `/tmp/prg/<slug>/post.err`. Do not print anything else.
