---
name: post-strategy
description: Post the test strategy summary to the work item / issue and deliver the HTML report. Usage: /post-strategy [issue-number or work-item-id]
argument-hint: [issue-number or work-item-id]
disable-model-invocation: true
---

Post the test strategy for $ARGUMENTS to the hosting platform.

Use the **orchestrator** agent's posting step. It will:
- Detect the platform from `git remote get-url origin`
- Post a summary comment on the work item / issue with overall risk level and test scenario count
- Ensure the HTML report file (`test-strategy-report.html`) is written to disk
- Apply a label/tag indicating the strategy has been generated

Follow the platform-specific instructions in the appropriate provider file:
- **GitHub** → `providers/github.md`
- **Azure DevOps** → `providers/azure-devops.md`
- **Generic** → `providers/generic.md`
