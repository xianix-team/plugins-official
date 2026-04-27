---
name: assess-risk
description: Evaluate risk areas for testing — rate changes by impact, complexity, coverage, and data sensitivity. Identify edge cases, regression hotspots, and produce a risk-prioritized testing recommendation. Usage: /assess-risk [issue-number or work-item-id]
argument-hint: [issue-number or work-item-id]
disable-model-invocation: true
---

Assess testing risks for $ARGUMENTS.

Use the **risk-assessor** agent. It will:
- Risk-rate each functional area across impact, complexity, coverage, integration density, and data sensitivity
- Identify critical and high-risk scenarios with business impact
- Surface edge cases and boundary conditions
- Evaluate regression risks from code changes
- Assess data integrity concerns
- Produce a prioritized testing order: must-test → should-test → could-test → smoke-only
