---
name: write-test-guide
description: Produce the final business-readable test guide from analysis outputs as a logical series of Markdown comment files — Overview & Focus Areas, Risk & Impact, Requirements & Gaps, one comment per non-empty test case category, and a final Coverage Map & QA Sign-off comment. Usage: /write-test-guide [issue-number or work-item-id]
argument-hint: [issue-number or work-item-id]
disable-model-invocation: true
---

Write the test guide for $ARGUMENTS as a Markdown comment series.

Use the **test-guide-writer** agent. It will produce a directory of numbered Markdown files (one per planned comment) plus an `index.json` describing the comment series:

- **Overview & Focus Areas** — work item metadata, headline business risk, "Where Testers Should Focus First", test case count summary, linked PRs, Table of Contents
- **Risk & Impact** — Business Risk Assessment (overall + matrix + What Could Go Wrong), Impacted Areas, Code Changes Overview
- **Requirements & Gaps** — Requirements Coverage, Developer Changes Requiring Clarification, Missing Requirement Coverage, Context Gathered
- **Test Cases** — one comment per non-empty category (🟢 Functional, 🔵 Performance, 🔴 Security, 🟡 Privacy, 🟣 Accessibility, ⚪ Resilience, 🟤 Compatibility), with concrete copy-pasteable test data, business-language steps, expected outcomes, and verification details
- **Coverage Map & QA Sign-off** — requirements → test cases, risks → test cases, out-of-scope, environment & assignment, interactive QA sign-off task list

The series follows the template in `styles/report-template.md` and the conventions in `styles/strategy.md`.

The output directory is `${TMPDIR:-/tmp}/test-strategy-${ENTRY_TYPE}-${ENTRY_ID}/`. The platform provider (GitHub / Azure DevOps / Generic) reads it to post the comments in order.

**No HTML file is produced and nothing is written to the repository working tree.**
