#!/usr/bin/env python3
"""reconcile.py — deterministic reconciliation of current findings against prior findings,
plus a deterministic verdict. Implements the bucket rules from commands/pr-review.md §7
("Reconcile against the prior review") verbatim, and the report-template.md verdict mapping
table made fully mechanical (any open CRITICAL -> REQUEST CHANGES; else any open WARNING ->
NEEDS DISCUSSION; else any SUGGESTION -> APPROVE WITH SUGGESTIONS; else APPROVE).

Inputs:
    /tmp/pr_review_state.json     (from gather-context.sh)
    /tmp/pr_findings.json         (written by the LLM after verifying sub-agent findings —
                                    a JSON list of {file, line, severity, category, fid, body})
    /tmp/pr_prior_findings.jsonl  (from gather-context.sh's prior-review detection;
                                    one JSON object per prior marked finding thread:
                                    {fid, status(open|resolved), thread_ref[, comment_ref], file,
                                     severity, category})

Output:
    /tmp/pr_reconcile.json:
    {
      "verdict": "APPROVE" | "APPROVE WITH SUGGESTIONS" | "REQUEST CHANGES" | "NEEDS DISCUSSION",
      "fixed": [...],                  # prior findings to reply-and-resolve
      "carried_over": [...],           # prior findings still open, no action
      "unreviewed_carried_over": [...],# prior findings not re-reviewed this push, no action
      "new": [...],                    # current findings to post as new inline threads
      "counts": {"fixed": N, "carried_over": N, "unreviewed_carried_over": N, "new": N}
    }

In initial mode (no prior review), every current finding is "new" and there is no delta —
this script still runs (fixed/carried_over/unreviewed_carried_over are simply empty), so the
caller never has to special-case initial vs. rereview when reading the output.

Fixed vs. carried-over — verified, not inferred. A prior finding whose fid the current
sub-agent pass didn't reproduce used to be declared "fixed" purely because it went missing
from a fresh, independently-sampled LLM scan — with no check that the code actually changed.
Since the finder agents are stochastic and re-scan from scratch on every non-push-triggered
run, running the exact same review twice against the exact same commit could (and did, in
production) surface a different subset of findings each time, so a finding the second pass
simply failed to re-notice got silently marked "fixed" and closed, even with zero commits in
between. Fixed now requires two things: (1) HEAD actually advanced past the commit the prior
review was posted against, and (2) the finding's exact anchored line — recomputed as a fid
directly from the file on disk via compute-fid.py's fids_for_file, not reported by an LLM —
is no longer reproducible at HEAD. Absent evidence of either, the finding stays carried_over.
"""
import json
import importlib.util
import os

_spec = importlib.util.spec_from_file_location(
    "compute_fid", os.path.join(os.path.dirname(os.path.abspath(__file__)), "compute-fid.py")
)
_compute_fid_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_compute_fid_module)
fids_for_file = _compute_fid_module.fids_for_file

STATE_FILE = "/tmp/pr_review_state.json"
FINDINGS_FILE = "/tmp/pr_findings.json"
PRIOR_FINDINGS_FILE = "/tmp/pr_prior_findings.jsonl"
OUTPUT_FILE = "/tmp/pr_reconcile.json"


def load_jsonl(path):
    items = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    items.append(json.loads(line))
    except FileNotFoundError:
        pass
    return items


def compute_verdict(open_findings):
    severities = {f.get("severity", "").lower() for f in open_findings}
    if "critical" in severities:
        return "REQUEST CHANGES"
    if "warning" in severities:
        return "NEEDS DISCUSSION"
    if "suggestion" in severities:
        return "APPROVE WITH SUGGESTIONS"
    return "APPROVE"


def load_changed_files(path):
    if not path:
        return None  # unresolvable: caller must not use this as a filter
    try:
        with open(path) as f:
            return {line.strip() for line in f if line.strip()}
    except FileNotFoundError:
        return None


def verify_actually_fixed(prior, head_sha, prior_summary_sha, changed_files):
    """A disappeared prior finding is only "fixed" when there's deterministic evidence its
    exact flagged line is gone — never just because this run's LLM scan failed to re-notice
    it. See the module docstring for why "absent from a fresh scan" isn't proof of anything.
    """
    # Gate A: HEAD must have actually advanced since the review that raised this finding.
    # If it hasn't, no commit could possibly have fixed anything.
    if not head_sha or head_sha == prior_summary_sha:
        return False

    prior_file = prior.get("file", "")
    # Fast path: if we know which files changed since the prior review and this one isn't
    # among them, its flagged line can't have moved either.
    if prior_file and changed_files is not None and prior_file not in changed_files:
        return False

    # Gate B: recompute fids for every line currently on disk at the flagged file and check
    # whether this finding's fid is still reproducible. Still there -> the finder just missed
    # it this pass, not fixed. Gone (or file deleted/moved) -> genuinely fixed.
    if not prior_file:
        return False  # no file to verify against — don't guess "fixed"
    category = prior.get("category") or None
    return prior["fid"] not in fids_for_file(prior_file, category)


def main():
    with open(STATE_FILE) as f:
        state = json.load(f)

    try:
        with open(FINDINGS_FILE) as f:
            current_findings = json.load(f)
    except FileNotFoundError:
        current_findings = []

    prior_findings = load_jsonl(PRIOR_FINDINGS_FILE)

    current_fids = {f["fid"] for f in current_findings if f.get("fid")}
    prior_by_fid = {f["fid"]: f for f in prior_findings if f.get("fid")}

    push_update_mode = bool(state.get("push_update_mode"))
    head_sha = state.get("head_sha", "")
    prior_summary_sha = state.get("prior_summary_sha", "")
    incremental_files = load_changed_files(state.get("incremental_changed_files"))

    fixed, carried_over, unreviewed_carried_over = [], [], []

    for fid, prior in prior_by_fid.items():
        if prior.get("status") == "resolved":
            continue  # already-resolved: ignore, no action
        if fid in current_fids:
            carried_over.append(prior)  # still flagged: leave open, don't duplicate
            continue
        # Open prior finding, not present in current findings. In push-update mode the
        # finder agents only looked at the incremental (this-push) diff, so a finding whose
        # file wasn't touched by this push was never in scope to re-surface at all — that's
        # "not reviewed", a different thing from "reviewed and looks fixed".
        prior_file = prior.get("file", "")
        if push_update_mode and incremental_files is not None:
            was_in_scope = (prior_file in incremental_files) or not prior_file
            if not was_in_scope:
                unreviewed_carried_over.append(prior)
                continue
        # In scope this pass but the finder didn't re-flag it — verify before trusting that.
        if verify_actually_fixed(prior, head_sha, prior_summary_sha, incremental_files):
            fixed.append(prior)
        else:
            carried_over.append(prior)

    new = [f for f in current_findings if f.get("fid") not in prior_by_fid]

    # Verdict reflects the finding set at HEAD after reconciliation: carried-over + new
    # (fixed findings no longer count; unreviewed carried-over findings are still open).
    # carried_over/unreviewed_carried_over prior entries may or may not have a matching
    # current finding (a Gate A/B-verified carried-over one usually won't, since it dropped
    # out of this run's fresh scan) — prefer the current finding's severity when there is
    # one, otherwise fall back to the prior finding's own persisted severity, and only then
    # to "warning" as a conservative default for pre-severity-persistence threads.
    severity_lookup = {f["fid"]: f.get("severity", "") for f in current_findings if f.get("fid")}
    normalized_open = list(current_findings)
    for p in carried_over + unreviewed_carried_over:
        if p["fid"] in current_fids:
            continue  # already included via current_findings above
        severity = severity_lookup.get(p["fid"]) or p.get("severity") or "warning"
        normalized_open.append({"severity": severity})

    verdict = compute_verdict(normalized_open)

    result = {
        "verdict": verdict,
        "fixed": fixed,
        "carried_over": carried_over,
        "unreviewed_carried_over": unreviewed_carried_over,
        "new": new,
        "counts": {
            "fixed": len(fixed),
            "carried_over": len(carried_over),
            "unreviewed_carried_over": len(unreviewed_carried_over),
            "new": len(new),
        },
    }

    with open(OUTPUT_FILE, "w") as f:
        json.dump(result, f, indent=2)

    summary = dict(result["counts"])
    summary["verdict"] = verdict
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
