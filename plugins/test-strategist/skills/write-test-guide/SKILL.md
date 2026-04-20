---
name: write-test-guide
description: Produce the final business-readable HTML test guide from analysis outputs — prioritized test scenarios, preconditions, expected results, exploratory testing charters, and regression checklist. Usage: /write-test-guide [issue-number or work-item-id]
argument-hint: [issue-number or work-item-id]
disable-model-invocation: true
---

Write the HTML test guide for $ARGUMENTS.

Use the **test-guide-writer** agent. It will produce a self-contained HTML report with:
- Requirements traceability matrix
- Risk-prioritized test scenarios with steps and expected results
- Edge cases and boundary conditions
- Regression checklist
- Exploratory testing charters
- Environment and test data requirements

The report follows the template in `styles/report-template.md` and is written to `test-strategy-report.html`.
