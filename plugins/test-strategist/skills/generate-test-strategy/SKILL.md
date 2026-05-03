---
name: generate-test-strategy
description: Trigger a full test strategy generation. Gathers requirements, code changes, and risk assessment, then produces a business-readable test guide as a logical series of Markdown comments posted on the PR / issue / work item discussion. Usage: /generate-test-strategy [issue-number or work-item-id]
argument-hint: [issue-number or work-item-id]
disable-model-invocation: true
---

Generate a comprehensive test strategy for $ARGUMENTS.

Use the **orchestrator** agent to run the full test strategy pipeline. The orchestrator will:

1. Detect the hosting platform from `git remote get-url origin`.
2. Fetch the work item / issue with all metadata, child items, comments, and linked PRs.
3. Gather code changes from all linked pull requests.
4. Index the repository for documentation and existing test coverage.
5. Launch three specialized sub-agents in parallel:
   - **requirement-collector** — consolidates all testable requirements
   - **change-analyst** — maps code changes to functional areas and integration points
   - **risk-assessor** — risk-rates each area and identifies edge cases
6. Launch the **test-guide-writer** to produce the **comment series** — one Markdown file per planned comment, plus an `index.json` describing the series. Output goes to `${TMPDIR:-/tmp}/test-strategy-${ENTRY_TYPE}-${ENTRY_ID}/`.
7. Hand off to the platform provider (GitHub / Azure DevOps / Generic) to post each comment in order, capture URLs, and back-fill the Table of Contents in Comment 1.

If no argument is given, analyze the **current branch** context.

**No HTML file is produced and nothing is written to the repository working tree.**
