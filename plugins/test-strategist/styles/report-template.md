# HTML Impact Analysis & Test Strategy Report Template

This template defines the 12-section structure for the HTML report produced by the `test-guide-writer` agent. Follow this template exactly when generating the report.

The report is written for **QA engineers, product owners, and non-technical stakeholders**. Test cases describe _what_ to verify and _why it matters_ — not which line of code changed.

---

## Report Sections Overview

| # | Section | Purpose |
|---|---|---|
| 1 | **Summary** | Work item title, type, severity/priority, developer, tester, iteration, and all linked PRs |
| 2 | **Context Gathered** | Everything the agent discovered: linked PRs, child work items, changesets, and referenced documentation |
| 3 | **Code Changes Overview** | Per-PR cards with file counts, branch information, and links — without raw diffs |
| 4 | **Requirements Coverage** | Each repro step (Bug) or acceptance criterion (PBI/Feature) mapped to the code changes that address it |
| 5 | **Developer Changes Requiring Clarification** | Code changes not explained by any stated requirement — categorised and flagged for discussion with the developer before testing begins |
| 6 | **Missing Requirement Coverage** | Requirements or acceptance criteria with no corresponding code change found |
| 7 | **Business Risk Assessment** | What could go wrong, who is affected, and how severe — written for non-technical readers |
| 8 | **Test Cases** | All test scenarios across seven categories |
| 9 | **Coverage Map** | Matrix showing which requirements and risks each test case covers, and what is explicitly out of scope |
| 10 | **Impacted Areas** | Direct and indirect impact on user workflows, integrations, and data — with High / Medium / Low ratings |
| 11 | **Environment & Assignment** | Area path, iteration, assigned developer, assigned tester |
| 12 | **QA Sign-off** | Interactive checklist for the tester to confirm completion |

---

## Test Case Categories

Test cases are grouped by category with color-coded badges:

| Badge | Category | When generated |
|---|---|---|
| 🟢 `tc-functional` | **Functional** | Always |
| 🔵 `tc-performance` | **Performance** | When the change touches a service, query, or data pipeline with realistic performance exposure |
| 🔴 `tc-security` | **Security** | When the change touches authentication, data input, API surfaces, or permission logic |
| 🟡 `tc-privacy` | **Privacy & PII** | When the change handles personal, financial, or health data |
| 🟣 `tc-accessibility` | **Accessibility & Usability** | When the change touches any user interface |
| ⚪ `tc-resilience` | **Resilience** | When the change touches a service call, queue, or external dependency |
| 🟤 `tc-compatibility` | **Compatibility** | When the change touches a UI, a public API, an integration point, or a contract shared with other systems |

Categories with no realistic surface must be **skipped entirely** — do not include empty sections.

---

## HTML Structure

The report must be a **self-contained HTML document** with inline CSS. No external dependencies.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Impact Analysis — #[work-item-id] [title]</title>
  <style>
    /* ── Reset & Base ── */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, sans-serif;
      line-height: 1.6; color: #1a1a2e; background: #fff;
      max-width: 1100px; margin: 0 auto; padding: 2rem;
    }
    @media print {
      body { max-width: 100%; padding: 1rem; font-size: 11pt; }
      .no-print { display: none; }
      details[open] summary { page-break-after: avoid; }
    }

    /* ── Typography ── */
    h1 { font-size: 1.8rem; border-bottom: 3px solid #0f3460; padding-bottom: 0.5rem; margin-bottom: 1rem; }
    h2 { font-size: 1.4rem; color: #0f3460; margin-top: 2rem; margin-bottom: 0.75rem; border-bottom: 1px solid #e0e0e0; padding-bottom: 0.3rem; }
    h3 { font-size: 1.15rem; color: #16213e; margin-top: 1.5rem; margin-bottom: 0.5rem; }
    h4 { font-size: 1rem; color: #333; margin-top: 1rem; margin-bottom: 0.3rem; }
    p, li { margin-bottom: 0.5rem; }

    /* ── Header ── */
    .report-header { background: #0f3460; color: #fff; padding: 1.5rem 2rem; border-radius: 8px; margin-bottom: 2rem; }
    .report-header h1 { color: #fff; border-bottom-color: rgba(255,255,255,0.3); }
    .report-meta { display: flex; flex-wrap: wrap; gap: 1.5rem; margin-top: 1rem; font-size: 0.9rem; opacity: 0.9; }
    .report-meta span { white-space: nowrap; }

    /* ── Risk Badges ── */
    .risk-critical { background: #dc3545; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.85rem; }
    .risk-high     { background: #fd7e14; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.85rem; }
    .risk-medium   { background: #ffc107; color: #1a1a2e; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.85rem; }
    .risk-low      { background: #28a745; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.85rem; }

    /* ── Test Category Badges ── */
    .tc-functional     { background: #28a745; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }
    .tc-performance    { background: #007bff; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }
    .tc-security       { background: #dc3545; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }
    .tc-privacy        { background: #ffc107; color: #1a1a2e; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }
    .tc-accessibility  { background: #6f42c1; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }
    .tc-resilience     { background: #6c757d; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }
    .tc-compatibility  { background: #795548; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }

    /* ── Clarification Badge ── */
    .badge-clarification { background: #e83e8c; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }

    /* ── Tables ── */
    table { width: 100%; border-collapse: collapse; margin: 1rem 0; font-size: 0.9rem; }
    th { background: #0f3460; color: #fff; text-align: left; padding: 0.6rem 0.8rem; }
    td { padding: 0.6rem 0.8rem; border-bottom: 1px solid #e0e0e0; vertical-align: top; }
    tr:nth-child(even) { background: #f8f9fa; }
    tr:hover { background: #e8f0fe; }

    /* ── Scenario Cards ── */
    .scenario { border: 1px solid #e0e0e0; border-radius: 8px; margin: 1rem 0; overflow: hidden; }
    .scenario-header { padding: 0.8rem 1rem; display: flex; align-items: center; gap: 0.8rem; border-bottom: 1px solid #e0e0e0; background: #f8f9fa; }
    .scenario-id { font-weight: 700; font-family: monospace; min-width: 60px; }
    .scenario-title { flex: 1; font-weight: 600; }
    .scenario-body { padding: 1rem; }
    .scenario-body dt { font-weight: 600; color: #0f3460; margin-top: 0.8rem; }
    .scenario-body dd { margin-left: 1rem; }
    .scenario-body ol { margin-left: 1.5rem; }
    .scenario-body ol li { margin-bottom: 0.3rem; }

    /* ── PR Cards ── */
    .pr-card { border: 1px solid #e0e0e0; border-radius: 8px; padding: 1rem; margin: 0.8rem 0; background: #f8f9fa; }
    .pr-card h4 { margin-top: 0; }

    /* ── Clarification Cards ── */
    .clarification-card { border-left: 4px solid #e83e8c; background: #fef0f5; padding: 1rem; margin: 0.8rem 0; border-radius: 0 6px 6px 0; }

    /* ── Summary Box ── */
    .summary-box { background: #f0f4ff; border: 1px solid #b8d0ff; border-radius: 8px; padding: 1.2rem; margin: 1rem 0; }

    /* ── Warning Box ── */
    .warning-box { background: #fff3cd; border: 1px solid #ffc107; border-radius: 8px; padding: 1.2rem; margin: 1rem 0; }

    /* ── TOC ── */
    .toc { background: #f8f9fa; border: 1px solid #e0e0e0; border-radius: 8px; padding: 1rem 1.5rem; margin: 1rem 0; }
    .toc a { text-decoration: none; color: #0f3460; }
    .toc a:hover { text-decoration: underline; }
    .toc ol { margin-left: 1.2rem; }
    .toc li { margin-bottom: 0.3rem; }

    /* ── Details/Accordion ── */
    details { margin: 0.5rem 0; }
    summary { cursor: pointer; font-weight: 600; padding: 0.3rem 0; }
    summary:hover { color: #0f3460; }

    /* ── Sign-off Checklist ── */
    .signoff-item { padding: 0.5rem 0; border-bottom: 1px solid #eee; }
    .signoff-item label { cursor: pointer; display: flex; align-items: center; gap: 0.5rem; }
    .signoff-item input[type="checkbox"] { width: 18px; height: 18px; accent-color: #0f3460; }
  </style>
</head>
<body>

<!-- ═══════════════════════════════════════════════
     SECTION 1: SUMMARY
     ═══════════════════════════════════════════════ -->
<div class="report-header">
  <h1>🧪 Impact Analysis — #[work-item-id] [title]</h1>
  <div class="report-meta">
    <span>📅 Generated: [ISO 8601 timestamp]</span>
    <span>🏷️ Type: [Bug / PBI / Feature / Issue]</span>
    <span>⚠️ Severity: [severity]</span>
    <span>📊 Priority: [priority]</span>
    <span>👨‍💻 Developer: [assigned developer]</span>
    <span>🧪 Tester: [assigned tester]</span>
    <span>📦 Iteration: [iteration path / milestone]</span>
    <span>⚠️ Overall Risk: <span class="risk-[level]">[RISK LEVEL]</span></span>
  </div>
</div>

<div class="summary-box">
  <p>[2-3 sentences: what was built, the overall risk posture, and the testing recommendation]</p>
  <p><strong>Test Cases:</strong> [total] (🟢 [n] Functional | 🔵 [n] Performance | 🔴 [n] Security | 🟡 [n] Privacy | 🟣 [n] Accessibility | ⚪ [n] Resilience | 🟤 [n] Compatibility)</p>
  <p><strong>Linked PRs:</strong> [list of PR numbers with titles]</p>
</div>

<!-- ═══════════════════════════════════════════════
     TABLE OF CONTENTS
     ═══════════════════════════════════════════════ -->
<nav class="toc no-print">
  <h2>Contents</h2>
  <ol>
    <li><a href="#context">Context Gathered</a></li>
    <li><a href="#code-changes">Code Changes Overview</a></li>
    <li><a href="#req-coverage">Requirements Coverage</a></li>
    <li><a href="#clarification">Developer Changes Requiring Clarification</a></li>
    <li><a href="#missing-coverage">Missing Requirement Coverage</a></li>
    <li><a href="#risk">Business Risk Assessment</a></li>
    <li><a href="#test-cases">Test Cases</a></li>
    <li><a href="#coverage-map">Coverage Map</a></li>
    <li><a href="#impacted-areas">Impacted Areas</a></li>
    <li><a href="#environment">Environment &amp; Assignment</a></li>
    <li><a href="#signoff">QA Sign-off</a></li>
  </ol>
</nav>

<!-- ═══════════════════════════════════════════════
     SECTION 2: CONTEXT GATHERED
     ═══════════════════════════════════════════════ -->
<section id="context">
  <h2>📂 Context Gathered</h2>
  <p>Everything the agent discovered while building this report:</p>

  <h3>Linked Pull Requests</h3>
  <table>
    <thead>
      <tr><th>PR</th><th>Title</th><th>State</th><th>Branch</th><th>Files</th></tr>
    </thead>
    <tbody>
      <tr><td>#[pr-number]</td><td>[PR title]</td><td>[Open/Merged/Closed]</td><td>[branch-name]</td><td>[file count]</td></tr>
    </tbody>
  </table>

  <h3>Child Work Items</h3>
  <table>
    <thead>
      <tr><th>ID</th><th>Title</th><th>Type</th><th>State</th></tr>
    </thead>
    <tbody>
      <tr><td>#[id]</td><td>[title]</td><td>[type]</td><td>[state]</td></tr>
    </tbody>
  </table>

  <!-- Include if changesets are found -->
  <h3>Changesets</h3>
  <table>
    <thead>
      <tr><th>ID</th><th>Comment</th><th>Author</th><th>Date</th></tr>
    </thead>
    <tbody>
      <tr><td>[id]</td><td>[comment]</td><td>[author]</td><td>[date]</td></tr>
    </tbody>
  </table>

  <h3>Referenced Documentation</h3>
  <ul>
    <li>[path/to/doc.md] — [brief description of relevance]</li>
  </ul>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 3: CODE CHANGES OVERVIEW
     ═══════════════════════════════════════════════ -->
<section id="code-changes">
  <h2>🔄 Code Changes Overview</h2>

  <!-- One card per PR — no raw diffs, just summaries -->
  <div class="pr-card">
    <h4>PR #[number] — [title]</h4>
    <p><strong>Branch:</strong> [source] → [target] | <strong>Files:</strong> [count] | <strong>+[additions]/-[deletions]</strong></p>
    <table>
      <thead>
        <tr><th>File</th><th>Change Type</th><th>Area</th><th>Risk</th></tr>
      </thead>
      <tbody>
        <tr><td><code>[path/to/file]</code></td><td>[Added/Modified/Deleted]</td><td>[Functional area]</td><td><span class="risk-[level]">[Risk]</span></td></tr>
      </tbody>
    </table>
  </div>
  <!-- Repeat for each PR -->
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 4: REQUIREMENTS COVERAGE
     ═══════════════════════════════════════════════ -->
<section id="req-coverage">
  <h2>✅ Requirements Coverage</h2>
  <p>Each requirement (acceptance criterion or repro step) mapped to the code changes that address it.</p>

  <table>
    <thead>
      <tr><th>ID</th><th>Requirement</th><th>Addressed By</th><th>Evidence</th><th>Status</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>AC1 / RS1</td>
        <td>[Requirement text]</td>
        <td>[File(s) + change description]</td>
        <td>[Why this change satisfies the requirement]</td>
        <td><span class="risk-low">Covered</span></td>
      </tr>
      <!-- Repeat for each requirement -->
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 5: DEVELOPER CHANGES REQUIRING CLARIFICATION
     ═══════════════════════════════════════════════ -->
<section id="clarification">
  <h2>⚠️ Developer Changes Requiring Clarification</h2>

  <div class="warning-box">
    <p><strong>[count] code changes</strong> cannot be mapped to any stated requirement. These must be discussed with the developer before testing begins — do not guess scope.</p>
  </div>

  <div class="clarification-card">
    <h4><span class="badge-clarification">[Category emoji] [Category]</span> — [Change title]</h4>
    <dl>
      <dt>Change</dt>
      <dd>[Plain-language description of what the code does differently]</dd>
      <dt>Location</dt>
      <dd>[File and functional area affected]</dd>
      <dt>Hypothesis</dt>
      <dd>[What the agent believes the intent is, if it can be inferred]</dd>
      <dt>Status</dt>
      <dd><strong>Needs Clarification</strong> — must be resolved before this area is tested</dd>
    </dl>
  </div>
  <!-- Repeat for each flagged change -->
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 6: MISSING REQUIREMENT COVERAGE
     ═══════════════════════════════════════════════ -->
<section id="missing-coverage">
  <h2>🔍 Missing Requirement Coverage</h2>
  <p>Requirements or acceptance criteria with no corresponding code change found.</p>

  <table>
    <thead>
      <tr><th>ID</th><th>Requirement</th><th>Why It Appears Uncovered</th><th>Severity</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>AC3</td>
        <td>[Requirement text]</td>
        <td>[No code change found that addresses this / May be covered elsewhere / Not yet implemented]</td>
        <td><span class="risk-[level]">[Severity]</span></td>
      </tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 7: BUSINESS RISK ASSESSMENT
     ═══════════════════════════════════════════════ -->
<section id="risk">
  <h2>⚠️ Business Risk Assessment</h2>

  <div class="summary-box">
    <p><strong>Overall Risk:</strong> <span class="risk-[level]">[RISK LEVEL]</span></p>
    <p>[2-3 sentence risk summary in non-technical language — what could break, who is affected, how severe]</p>
  </div>

  <h3>Risk Matrix</h3>
  <table>
    <thead>
      <tr><th>Area</th><th>Risk</th><th>Impact</th><th>Who Is Affected</th><th>Primary Driver</th></tr>
    </thead>
    <tbody>
      <tr><td>[Area]</td><td><span class="risk-[level]">[Level]</span></td><td>[Business impact if broken]</td><td>[Users / roles affected]</td><td>[Main reason]</td></tr>
    </tbody>
  </table>

  <h3>What Could Go Wrong</h3>
  <table>
    <thead>
      <tr><th>#</th><th>Scenario</th><th>Risk</th><th>Who Is Affected</th><th>How Severe</th></tr>
    </thead>
    <tbody>
      <tr><td>1</td><td>[Business-language scenario]</td><td><span class="risk-[level]">[Risk]</span></td><td>[Users affected]</td><td>[Severity description]</td></tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 8: TEST CASES
     ═══════════════════════════════════════════════ -->
<section id="test-cases">
  <h2>🧪 Test Cases</h2>

  <!-- ── Functional ── -->
  <h3>🟢 Functional Test Cases</h3>

  <div class="scenario">
    <div class="scenario-header">
      <span class="scenario-id">TC-001</span>
      <span class="scenario-title">[Test case title — business readable]</span>
      <span class="tc-functional">Functional</span>
      <span class="risk-[level]">[Priority]</span>
    </div>
    <div class="scenario-body">
      <dl>
        <dt>Linked Requirement</dt>
        <dd>[AC1, R1, etc.]</dd>
        <dt>Preconditions</dt>
        <dd>[What must be true: system state, test data, user role]</dd>
        <dt>Steps</dt>
        <dd>
          <ol>
            <li>[Step 1 — specific, actionable, business language]</li>
            <li>[Step 2]</li>
            <li>[Step 3]</li>
          </ol>
        </dd>
        <dt>Test Data</dt>
        <dd>[Specific values to use]</dd>
        <dt>Expected Result</dt>
        <dd>[Observable, verifiable outcome from a user's perspective]</dd>
      </dl>
    </div>
  </div>
  <!-- Repeat for each functional test case -->

  <!-- ── Performance (skip section entirely if --no-perf or no surface) ── -->
  <h3>🔵 Performance Test Cases</h3>
  <!-- Scenarios for load, soak, concurrency, latency budgets -->

  <!-- ── Security (skip if no surface) ── -->
  <h3>🔴 Security Test Cases</h3>
  <!-- Scenarios for auth, input validation, injection, OWASP -->

  <!-- ── Privacy & PII (skip if no surface) ── -->
  <h3>🟡 Privacy & PII Test Cases</h3>
  <!-- Scenarios for data flows, consent, retention, deletion, logging leakage -->

  <!-- ── Accessibility & Usability (skip if --no-a11y or no UI surface) ── -->
  <h3>🟣 Accessibility & Usability Test Cases</h3>
  <!-- Scenarios for keyboard nav, screen reader, contrast, error recovery -->

  <!-- ── Resilience (skip if no service surface) ── -->
  <h3>⚪ Resilience Test Cases</h3>
  <!-- Scenarios for timeout, retry, partial failure, idempotency -->

  <!-- ── Compatibility (skip if no UI/API/contract surface) ── -->
  <h3>🟤 Compatibility Test Cases</h3>
  <!-- Scenarios for browser, OS, device, API version, integration contracts -->
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 9: COVERAGE MAP
     ═══════════════════════════════════════════════ -->
<section id="coverage-map">
  <h2>🗺️ Coverage Map</h2>
  <p>Matrix showing which requirements and risks each test case covers. Gaps are explicit.</p>

  <h3>Requirements → Test Cases</h3>
  <table>
    <thead>
      <tr><th>Requirement</th><th>Test Cases</th><th>Coverage Status</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>AC1 — [requirement text]</td>
        <td>TC-001, TC-003, TC-012</td>
        <td><span class="risk-low">Covered</span></td>
      </tr>
      <tr>
        <td>AC3 — [requirement text]</td>
        <td>—</td>
        <td><span class="risk-critical">Gap — no code change found</span></td>
      </tr>
    </tbody>
  </table>

  <h3>Risks → Test Cases</h3>
  <table>
    <thead>
      <tr><th>Risk</th><th>Test Cases</th><th>Mitigation Status</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>[Risk scenario]</td>
        <td>TC-005, TC-008</td>
        <td><span class="risk-low">Mitigated</span></td>
      </tr>
    </tbody>
  </table>

  <h3>Explicitly Out of Scope</h3>
  <table>
    <thead>
      <tr><th>Item</th><th>Reason</th></tr>
    </thead>
    <tbody>
      <tr><td>[What is not covered]</td><td>[Why — deferred, not applicable, or separate work item]</td></tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 10: IMPACTED AREAS
     ═══════════════════════════════════════════════ -->
<section id="impacted-areas">
  <h2>📍 Impacted Areas</h2>
  <p>Direct and indirect impact on user workflows, integrations, and data.</p>

  <table>
    <thead>
      <tr><th>Area</th><th>Impact</th><th>Direct / Indirect</th><th>Notes</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>[User workflow / integration / data surface]</td>
        <td><span class="risk-[level]">[High / Medium / Low]</span></td>
        <td>[Direct / Indirect]</td>
        <td>[Why it is impacted — business language]</td>
      </tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 11: ENVIRONMENT & ASSIGNMENT
     ═══════════════════════════════════════════════ -->
<section id="environment">
  <h2>🖥️ Environment & Assignment</h2>

  <table>
    <tbody>
      <tr><td><strong>Area Path</strong></td><td>[area path]</td></tr>
      <tr><td><strong>Iteration</strong></td><td>[iteration / sprint]</td></tr>
      <tr><td><strong>Assigned Developer</strong></td><td>[name]</td></tr>
      <tr><td><strong>Assigned Tester</strong></td><td>[name]</td></tr>
    </tbody>
  </table>

  <h3>Test Environment Requirements</h3>
  <ul>
    <li>[Environment need — staging, feature flags, mocks, external service stubs]</li>
  </ul>

  <h3>Test Data Requirements</h3>
  <ul>
    <li>[Data need — specific records, edge-case data, bulk data]</li>
  </ul>

  <h3>User Accounts Needed</h3>
  <table>
    <thead>
      <tr><th>Role</th><th>Permissions</th><th>Used In</th></tr>
    </thead>
    <tbody>
      <tr><td>[Role]</td><td>[Permissions needed]</td><td>[Which test cases]</td></tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 12: QA SIGN-OFF
     ═══════════════════════════════════════════════ -->
<section id="signoff">
  <h2>✅ QA Sign-off</h2>
  <p>Check each item to confirm testing is complete:</p>

  <div class="signoff-item"><label><input type="checkbox"> All <strong>functional test cases</strong> executed and passed</label></div>
  <div class="signoff-item"><label><input type="checkbox"> All <strong>Developer Changes Requiring Clarification</strong> resolved with developer</label></div>
  <div class="signoff-item"><label><input type="checkbox"> All <strong>critical and high-risk</strong> scenarios verified</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Regression</strong> areas verified — no regressions found</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Security test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Performance test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Privacy & PII test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Accessibility test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Resilience test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Compatibility test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Coverage map</strong> reviewed — all gaps acknowledged</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Missing requirement coverage</strong> items reviewed with PO</label></div>

  <div style="margin-top: 2rem; border-top: 2px solid #0f3460; padding-top: 1rem;">
    <p><strong>Tester:</strong> _________________________ <strong>Date:</strong> _____________</p>
    <p><strong>Sign-off status:</strong> ☐ Approved for release &nbsp; ☐ Blocked — issues found &nbsp; ☐ Conditional — see notes</p>
    <p><strong>Notes:</strong></p>
    <div style="border: 1px solid #e0e0e0; border-radius: 4px; min-height: 80px; padding: 0.5rem;"></div>
  </div>
</section>

<footer style="margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #e0e0e0; font-size: 0.8rem; color: #666; text-align: center;">
  Generated by Test Strategist Plugin — [ISO 8601 timestamp]
</footer>

</body>
</html>
```

---

## Content Rules

1. **Replace all `[bracketed]` placeholders** with actual data from the analysis
2. **Skip test case categories with no realistic surface** — do not include empty category sections
3. **Use the correct CSS classes** — `risk-critical`, `risk-high`, `risk-medium`, `risk-low` for risk badges; `tc-functional`, `tc-performance`, etc. for category badges
4. **Group test cases by category** — functional first, then the others in order
5. **Every test case must include**: steps (specific, actionable), test data, expected result (observable), linked requirement
6. **Coverage map must make gaps explicit** — never hide missing coverage
7. **Developer Changes Requiring Clarification** must appear **before** the test cases — the tester needs to know what to pause on
8. **QA Sign-off checkboxes** must be interactive (`<input type="checkbox">`)
9. **Ensure the HTML is valid** — close all tags, escape special characters in content
10. **Test printability** — the report should look clean when printed at A4/Letter size
