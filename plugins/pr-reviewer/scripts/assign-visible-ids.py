#!/usr/bin/env python3
"""Keep C/W/S finding labels stable across PR re-reviews."""

import json
import os
import re
from pathlib import Path


def load_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


prior_path = Path(os.environ.get("PRIOR", "/tmp/pr_prior_findings.jsonl"))
findings_path = Path(os.environ.get("FINDINGS", "/tmp/pr_inline_findings.jsonl"))
reconcile_path = Path(os.environ.get("RECONCILE", "/tmp/pr_reconcile.json"))
output_path = Path(os.environ.get("VISIBLE_IDS", "/tmp/pr_visible_ids.json"))

prior = load_jsonl(prior_path)
findings = load_jsonl(findings_path)
reconcile = json.loads(reconcile_path.read_text())
labels = {}
owners = {}
next_number = {"C": 1, "W": 1, "S": 1}

for finding in prior:
    fid = finding.get("fid")
    label = finding.get("visible_id")
    if not fid or not label:
        continue
    if not re.fullmatch(r"[CWS][1-9]\d*", label):
        raise ValueError(f"Invalid prior visible ID: {label}")
    if fid in labels and labels[fid] != label:
        raise ValueError(f"Conflicting visible IDs for fid {fid}")
    if label in owners and owners[label] != fid:
        raise ValueError(f"Visible ID {label} belongs to two findings")
    labels[fid] = label
    owners[label] = fid
    prefix = label[0]
    next_number[prefix] = max(next_number[prefix], int(label[1:]) + 1)

prefixes = {"CRITICAL": "C", "WARNING": "W", "SUGGESTION": "S"}
for finding in findings:
    fid = finding.get("fid")
    if not fid:
        raise ValueError("Assign finding fids before visible IDs")
    label = labels.get(fid)
    if not label:
        severity = str(finding.get("severity") or "").upper()
        if not severity:
            match = re.search(r"\b(CRITICAL|WARNING|SUGGESTION)\b", finding.get("body", ""))
            if match:
                severity = match.group(1)
        prefix = prefixes.get(severity)
        if not prefix:
            raise ValueError(f"Missing severity for finding {fid}")
        label = f"{prefix}{next_number[prefix]}"
        next_number[prefix] += 1
        labels[fid] = label
    finding["visible_id"] = label
    body = finding.get("body") or finding.get("comment") or ""
    body = re.sub(r"^\s*(?:\*\*)?[CWS]\d+(?:\*\*)?(?=\s|[—:-]|$)\s*[—:-]?\s*", "", body, count=1)
    finding["body"] = f"**{label}** {body.lstrip()}"

for bucket in ("fixed", "carried_over", "reopened", "new"):
    for finding in reconcile.get(bucket, []):
        finding["visible_id"] = labels.get(finding.get("fid"))

findings_path.write_text("".join(json.dumps(finding, ensure_ascii=False) + "\n" for finding in findings))
reconcile_path.write_text(json.dumps(reconcile, indent=2) + "\n")
output_path.write_text(json.dumps(labels, indent=2, sort_keys=True) + "\n")
print(f"Visible IDs: {len(findings)} new inline finding(s), {len(labels)} known label(s)")
print(f"Wrote {output_path}")
