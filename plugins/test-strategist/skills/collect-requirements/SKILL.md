---
name: collect-requirements
description: Consolidate all requirements from a work item — acceptance criteria, child items, comments, and referenced documentation — into a structured requirements map. Usage: /collect-requirements [issue-number or work-item-id]
argument-hint: [issue-number or work-item-id]
disable-model-invocation: true
---

Collect and consolidate all requirements for $ARGUMENTS.

Use the **requirement-collector** agent. It will extract testable requirements from:
- The work item title, description, and acceptance criteria
- Child work items / sub-tasks
- Comments and discussion threads
- Referenced documentation and specs
- Non-functional requirements implied by the feature area

The output is a structured requirements map with traceability, gap analysis, and scope boundaries.
