# Dead Code Scan Report

**Repository:** {{repo}}
**Scanned at:** {{scan_timestamp}}
**Detector:** knip ({{detector_status.status}}{{#if detector_status.reason}} — {{detector_status.reason}}{{/if}})

## Summary

| Severity | Count |
|---|---|
| 🟡 Medium | {{summary.medium}} |
| 🔵 Low | {{summary.low}} |
| ⚪ Info | {{summary.info}} |
| **Total** | **{{summary.total}}** |

| Category | Count |
|---|---|
| Unused dependencies | {{by_category.dependency}} |
| Unused files | {{by_category.file}} |
| Duplicate exports | {{by_category.duplicate}} |
| Unlisted / unresolved imports | {{by_category.unlisted_unresolved}} |
| Unused exports | {{by_category.export}} |
| Unused types / enum members | {{by_category.type}} |

## Delta vs Prior Run

{{#if delta.has_prior}}
- **+{{delta.new_count}} new** findings since last run
- **-{{delta.resolved_count}} resolved** since last run
- **·{{delta.persisting_count}} persisting** findings
{{else}}
No prior run to compare against.
{{/if}}

## Findings

Grouped by category, ordered Medium → Info. Each finding includes a clickable location, description, and remediation.

{{#each categories}}
### {{category_label}}

{{#each findings}}
#### [{{severity}}] {{title}}

- **ID:** `{{id}}`
- **Location:** [{{location}}]({{handler_file}}#L{{handler_line}})
- **Description:** {{description}}
- **Remediation:** {{remediation}}
{{#if fix.command}}- **Fix command:** `{{fix.command}}`{{/if}}
{{/each}}
{{/each}}

## Suppressed Findings

{{#if suppressed}}
Findings matched by `.deadcode-ignore` rules. Excluded from the active count above; listed here for audit purposes.

{{#each suppressed}}
- [{{severity}}] {{title}} (`{{id}}`)
{{/each}}
{{else}}
None.
{{/if}}

## How to Act on This

- **Intentional keepers** (public API, framework magic): add the finding ID to `.deadcode-ignore`.
- **Genuine dead code:** run `/deadcode --fix` to open a draft PR removing everything Knip can fix safely, or apply the per-finding fix commands manually.
- **Always** run the project's build and tests after removal — static analysis cannot see dynamic imports or reflection.
