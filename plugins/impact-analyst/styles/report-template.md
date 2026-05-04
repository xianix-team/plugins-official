# HTML Impact Analysis & Test Strategy Report Template

This template defines the 14-section structure for the HTML report produced by the `report-writer` agent. Follow this template exactly when generating the report.

The report is written for **QA engineers, product owners, and non-technical stakeholders**.

---

## Report Sections Overview

| # | Section | Source Agent | Notes |
|---|---|---|---|
| 1 | **Summary** | orchestrator | Entry point ref, date, overall risk badge, test case count, linked PRs |
| 2 | **Context Gathered** | orchestrator | PRs, child work items, changesets, referenced docs |
| 3 | **Code Changes Overview** | change-analyst | Per-PR file cards, no raw diffs |
| 4 | **Blast Radius & Dependency Map** | dependency-tracer | Direct callers, data flows, transitive deps — N/A if fast-path |
| 5 | **Affected Features & User Journeys** | feature-mapper | Routes, UI pages, user scenarios, confirmed-safe list — N/A if fast-path |
| 6 | **Requirements Coverage** | change-analyst | Req → code mapping — N/A if no work item |
| 7 | **Developer Changes Requiring Clarification** | change-analyst | Unexplained changes — N/A if no work item |
| 8 | **Missing Requirement Coverage** | change-analyst | Requirements with no code change — N/A if no work item |
| 9 | **Business Risk Assessment** | risk-assessor | Risk matrix + "what could go wrong" |
| 10 | **Test Cases** | report-writer | 7 categories, TC-001 format |
| 11 | **Coverage Map** | report-writer | Req→TC, Risk→TC, out-of-scope |
| 12 | **Impacted Areas** | risk-assessor | High/Medium/Low ratings |
| 13 | **Environment & Assignment** | requirement-collector | N/A if no work item |
| 14 | **QA Sign-off** | report-writer | Interactive checkboxes |

---

## HTML Structure

The report must be a **self-contained HTML document** with inline CSS. No external dependencies.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Impact Analysis — [entry-type] #[entry-id] [title]</title>
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
      .scenario { page-break-inside: avoid; }
      h2 { page-break-before: auto; }
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

    /* ── Blast Radius Badge ── */
    .blast-isolated { background: #28a745; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.85rem; }
    .blast-moderate { background: #ffc107; color: #1a1a2e; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.85rem; }
    .blast-wide     { background: #dc3545; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.85rem; }

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

    /* ── Dependency Cards ── */
    .dep-card { border: 1px solid #e0e0e0; border-radius: 8px; padding: 1rem; margin: 0.8rem 0; background: #f8f9fa; }

    /* ── Clarification Cards ── */
    .clarification-card { border-left: 4px solid #e83e8c; background: #fef0f5; padding: 1rem; margin: 0.8rem 0; border-radius: 0 6px 6px 0; }

    /* ── Summary Box ── */
    .summary-box { background: #f0f4ff; border: 1px solid #b8d0ff; border-radius: 8px; padding: 1.2rem; margin: 1rem 0; }

    /* ── Warning Box ── */
    .warning-box { background: #fff3cd; border: 1px solid #ffc107; border-radius: 8px; padding: 1.2rem; margin: 1rem 0; }

    /* ── NA Box ── */
    .na-box { background: #f8f9fa; border: 1px solid #dee2e6; border-radius: 8px; padding: 1rem; margin: 1rem 0; color: #6c757d; font-style: italic; }

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
  <h1>🧪 Impact Analysis — [entry-type] #[entry-id] [title]</h1>
  <div class="report-meta">
    <span>📅 Generated: [ISO 8601 timestamp]</span>
    <span>🔍 Entry: [PR / Issue / Work Item] #[id]</span>
    <span>🏷️ Type: [Bug / PBI / Feature / Issue / PR-only]</span>
    <span>⚠️ Severity: [severity or N/A]</span>
    <span>📊 Priority: [priority or N/A]</span>
    <span>👨‍💻 Developer: [assigned developer or N/A]</span>
    <span>🧪 Tester: [assigned tester or N/A]</span>
    <span>📦 Iteration: [iteration path / milestone or N/A]</span>
    <span>⚠️ Overall Risk: <span class="risk-[level]">[RISK LEVEL]</span></span>
    <span>💥 Blast Radius: <span class="blast-[isolated|moderate|wide]">[category] — [N] files</span></span>
  </div>
</div>

<div class="summary-box">
  <p>[2-3 sentences: what was built/changed, the blast radius, overall risk posture, and testing recommendation]</p>
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
    <li><a href="#blast-radius">Blast Radius &amp; Dependency Map</a></li>
    <li><a href="#features">Affected Features &amp; User Journeys</a></li>
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

  <h3>Linked Pull Requests</h3>
  <table>
    <thead><tr><th>PR</th><th>Title</th><th>State</th><th>Branch</th><th>Files</th></tr></thead>
    <tbody>
      <tr><td>#[pr-number]</td><td>[PR title]</td><td>[Open/Merged/Closed]</td><td>[branch-name]</td><td>[file count]</td></tr>
    </tbody>
  </table>

  <!-- Include only if child work items exist -->
  <h3>Child Work Items</h3>
  <table>
    <thead><tr><th>ID</th><th>Title</th><th>Type</th><th>State</th></tr></thead>
    <tbody>
      <tr><td>#[id]</td><td>[title]</td><td>[type]</td><td>[state]</td></tr>
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

  <div class="pr-card">
    <h4>PR #[number] — [title]</h4>
    <p><strong>Branch:</strong> [source] → [target] | <strong>Files:</strong> [count] | <strong>+[additions]/-[deletions]</strong> | <strong>Scope:</strong> [small/medium/large] | <strong>Nature:</strong> [feature/bugfix/refactor/etc.]</p>
    <table>
      <thead><tr><th>File</th><th>Category</th><th>Magnitude</th><th>Area</th><th>Risk</th><th>Behavioral Impact</th></tr></thead>
      <tbody>
        <tr><td><code>[path/to/file]</code></td><td>[Modified logic]</td><td>[Medium]</td><td>[Area]</td><td><span class="risk-[level]">[Risk]</span></td><td>[What changed in business terms]</td></tr>
      </tbody>
    </table>
  </div>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 4: BLAST RADIUS & DEPENDENCY MAP (NEW)
     ═══════════════════════════════════════════════ -->
<section id="blast-radius">
  <h2>💥 Blast Radius &amp; Dependency Map</h2>

  <div class="summary-box">
    <p><strong>Directly changed:</strong> [N] files &nbsp;|&nbsp; <strong>Direct callers (1st degree):</strong> [N] files &nbsp;|&nbsp; <strong>Indirect dependents (2nd degree):</strong> [N] files</p>
    <p><strong>Total blast radius:</strong> [N] files — <span class="blast-[isolated|moderate|wide]">[isolated / moderate / wide]</span></p>
  </div>

  <h3>Direct Callers</h3>
  <table>
    <thead><tr><th>Changed File</th><th>Caller</th><th>Relationship</th><th>Risk Note</th></tr></thead>
    <tbody>
      <tr><td><code>[changed-file]</code></td><td><code>[caller-file]</code></td><td>[imports X()]</td><td>[Why this matters]</td></tr>
    </tbody>
  </table>

  <h3>Data Flows</h3>
  <table>
    <thead><tr><th>Changed File</th><th>Data Store / API / Queue</th><th>Direction</th><th>Description</th></tr></thead>
    <tbody>
      <tr><td><code>[file]</code></td><td>[users table / POST /api/... / queue-name]</td><td>[Read/Write/Serves/Consumes]</td><td>[Description]</td></tr>
    </tbody>
  </table>

  <h3>External Integrations</h3>
  <ul>
    <li>[Third-party API / service / system — what changed about the interaction]</li>
  </ul>

  <h3>Compound Risk</h3>
  <p>[Files that are BOTH changed AND depended upon by other changed files — these multiply risk]</p>

  <!-- If fast-path or budget exceeded: -->
  <!-- <div class="na-box">N/A — fast-path analysis (trivial change)</div> -->
  <!-- <div class="warning-box">⚠️ Tool budget reached — blast radius may be incomplete</div> -->
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 5: AFFECTED FEATURES & USER JOURNEYS (NEW)
     ═══════════════════════════════════════════════ -->
<section id="features">
  <h2>🗺️ Affected Features &amp; User Journeys</h2>

  <h3>Impacted User-Facing Features</h3>
  <table>
    <thead><tr><th>Feature / User Flow</th><th>Impact Type</th><th>How It's Affected</th><th>Changed Files</th></tr></thead>
    <tbody>
      <tr><td>[User login]</td><td>[Direct logic change]</td><td>[Login validation logic modified]</td><td><code>src/auth/login.ts</code></td></tr>
    </tbody>
  </table>

  <h3>Affected Routes / Endpoints</h3>
  <table>
    <thead><tr><th>Method</th><th>Route</th><th>Handler</th><th>What Changed</th></tr></thead>
    <tbody>
      <tr><td>POST</td><td>/api/auth/login</td><td><code>src/auth/login.ts</code></td><td>[What changed]</td></tr>
    </tbody>
  </table>

  <h3>User Scenarios to Test</h3>
  <ol>
    <li><strong>[Feature name]</strong>
      <ul>
        <li>Scenario: [User does X, expects Y]</li>
        <li>Scenario: [User does X under condition Z, expects W]</li>
      </ul>
    </li>
  </ol>

  <h3>Confirmed Safe (Not Impacted)</h3>
  <ul>
    <li>[Feature] — [Why it is confirmed safe]</li>
  </ul>

  <!-- If fast-path: -->
  <!-- <div class="na-box">N/A — fast-path analysis (trivial change)</div> -->
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 6: REQUIREMENTS COVERAGE
     ═══════════════════════════════════════════════ -->
<section id="req-coverage">
  <h2>✅ Requirements Coverage</h2>

  <!-- If no work item: <div class="na-box">N/A — no work item linked. Test cases are anchored to risks and user scenarios.</div> -->

  <table>
    <thead><tr><th>ID</th><th>Requirement</th><th>Addressed By</th><th>Evidence</th><th>Status</th></tr></thead>
    <tbody>
      <tr>
        <td>AC1 / RS1</td>
        <td>[Requirement text]</td>
        <td>[File(s) + change description]</td>
        <td>[Why this change satisfies the requirement]</td>
        <td><span class="risk-low">Covered</span></td>
      </tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 7: DEVELOPER CHANGES REQUIRING CLARIFICATION
     ═══════════════════════════════════════════════ -->
<section id="clarification">
  <h2>⚠️ Developer Changes Requiring Clarification</h2>

  <!-- If no work item: <div class="na-box">N/A — no work item linked.</div> -->

  <div class="warning-box">
    <p><strong>[count] code changes</strong> cannot be mapped to any stated requirement. These must be discussed with the developer before testing begins.</p>
  </div>

  <div class="clarification-card">
    <h4><span class="badge-clarification">[Category emoji] [Category]</span> — [Change title]</h4>
    <dl>
      <dt>Change</dt><dd>[Plain-language description of what the code does differently]</dd>
      <dt>Location</dt><dd>[File and functional area affected]</dd>
      <dt>Hypothesis</dt><dd>[What the agent believes the intent is]</dd>
      <dt>Status</dt><dd><strong>Needs Clarification</strong> — must be resolved before this area is tested</dd>
    </dl>
  </div>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 8: MISSING REQUIREMENT COVERAGE
     ═══════════════════════════════════════════════ -->
<section id="missing-coverage">
  <h2>🔍 Missing Requirement Coverage</h2>

  <!-- If no work item: <div class="na-box">N/A — no work item linked.</div> -->

  <table>
    <thead><tr><th>ID</th><th>Requirement</th><th>Why It Appears Uncovered</th><th>Severity</th></tr></thead>
    <tbody>
      <tr>
        <td>AC3</td>
        <td>[Requirement text]</td>
        <td>[No code change found / May be covered elsewhere / Not yet implemented]</td>
        <td><span class="risk-[level]">[Severity]</span></td>
      </tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 9: BUSINESS RISK ASSESSMENT
     ═══════════════════════════════════════════════ -->
<section id="risk">
  <h2>⚠️ Business Risk Assessment</h2>

  <div class="summary-box">
    <p><strong>Overall Risk:</strong> <span class="risk-[level]">[RISK LEVEL]</span></p>
    <p>[2-3 sentence risk summary in non-technical language]</p>
  </div>

  <h3>Risk Matrix</h3>
  <table>
    <thead><tr><th>Area</th><th>Risk</th><th>Impact</th><th>Complexity</th><th>Coverage</th><th>Blast Radius</th><th>Primary Driver</th></tr></thead>
    <tbody>
      <tr><td>[Area]</td><td><span class="risk-[level]">[Level]</span></td><td>[Business impact]</td><td>[Complexity]</td><td>[Coverage status]</td><td>[isolated/moderate/wide]</td><td>[Main reason]</td></tr>
    </tbody>
  </table>

  <h3>What Could Go Wrong</h3>
  <table>
    <thead><tr><th>#</th><th>Scenario</th><th>Risk</th><th>Who Is Affected</th><th>How Severe</th></tr></thead>
    <tbody>
      <tr><td>1</td><td>[Business-language scenario]</td><td><span class="risk-[level]">[Risk]</span></td><td>[Users affected]</td><td>[Severity]</td></tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 10: TEST CASES
     ═══════════════════════════════════════════════ -->
<section id="test-cases">
  <h2>🧪 Test Cases</h2>

  <h3>🟢 Functional Test Cases</h3>
  <div class="scenario">
    <div class="scenario-header">
      <span class="scenario-id">TC-001</span>
      <span class="scenario-title">[Test case title — business readable]</span>
      <span class="tc-functional">Functional</span>
      <span class="risk-[level]">[P0/P1/P2 → critical/high/medium]</span>
    </div>
    <div class="scenario-body">
      <dl>
        <dt>Linked Requirement</dt><dd>[AC1 / RS2 / Risk-3 / Scenario-4]</dd>
        <dt>Preconditions</dt><dd>[System state, test data, user role]</dd>
        <dt>Steps</dt>
        <dd><ol>
          <li>[Step 1 — specific, actionable, business language]</li>
          <li>[Step 2]</li>
          <li>[Step 3]</li>
        </ol></dd>
        <dt>Test Data</dt><dd>[Specific values to use]</dd>
        <dt>Expected Result</dt><dd>[Observable, verifiable outcome from a user's perspective]</dd>
      </dl>
    </div>
  </div>

  <!-- ── Performance (skip section entirely if --no-perf or performance_surface: false) ── -->
  <h3>🔵 Performance Test Cases</h3>

  <!-- ── Security (skip if security_surface: false) ── -->
  <h3>🔴 Security Test Cases</h3>

  <!-- ── Privacy & PII (skip if privacy_surface: false) ── -->
  <h3>🟡 Privacy &amp; PII Test Cases</h3>

  <!-- ── Accessibility (skip if --no-a11y or ui_surface: false) ── -->
  <h3>🟣 Accessibility &amp; Usability Test Cases</h3>

  <!-- ── Resilience (skip if resilience_surface: false) ── -->
  <h3>⚪ Resilience Test Cases</h3>

  <!-- ── Compatibility (skip if compatibility_surface: false) ── -->
  <h3>🟤 Compatibility Test Cases</h3>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 11: COVERAGE MAP
     ═══════════════════════════════════════════════ -->
<section id="coverage-map">
  <h2>🗺️ Coverage Map</h2>

  <h3>Requirements → Test Cases</h3>
  <table>
    <thead><tr><th>Requirement</th><th>Test Cases</th><th>Coverage Status</th></tr></thead>
    <tbody>
      <tr><td>AC1 — [text]</td><td>TC-001, TC-003</td><td><span class="risk-low">Covered</span></td></tr>
      <tr><td>AC3 — [text]</td><td>—</td><td><span class="risk-critical">Gap — no code change found</span></td></tr>
    </tbody>
  </table>

  <h3>Risks → Test Cases</h3>
  <table>
    <thead><tr><th>Risk</th><th>Test Cases</th><th>Mitigation Status</th></tr></thead>
    <tbody>
      <tr><td>[Risk scenario]</td><td>TC-005, TC-008</td><td><span class="risk-low">Mitigated</span></td></tr>
    </tbody>
  </table>

  <h3>Explicitly Out of Scope</h3>
  <table>
    <thead><tr><th>Item</th><th>Reason</th></tr></thead>
    <tbody>
      <tr><td>[What is not covered]</td><td>[Why — deferred, not applicable, or separate work item]</td></tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 12: IMPACTED AREAS
     ═══════════════════════════════════════════════ -->
<section id="impacted-areas">
  <h2>📍 Impacted Areas</h2>
  <table>
    <thead><tr><th>Area</th><th>Impact</th><th>Direct / Indirect</th><th>Notes</th></tr></thead>
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
     SECTION 13: ENVIRONMENT & ASSIGNMENT
     ═══════════════════════════════════════════════ -->
<section id="environment">
  <h2>🖥️ Environment &amp; Assignment</h2>

  <table>
    <tbody>
      <tr><td><strong>Area Path</strong></td><td>[area path or N/A]</td></tr>
      <tr><td><strong>Iteration</strong></td><td>[iteration / sprint or N/A]</td></tr>
      <tr><td><strong>Assigned Developer</strong></td><td>[name or N/A]</td></tr>
      <tr><td><strong>Assigned Tester</strong></td><td>[name or N/A]</td></tr>
    </tbody>
  </table>

  <h3>Test Environment Requirements</h3>
  <ul><li>[Environment need — staging, feature flags, mocks, external service stubs]</li></ul>

  <h3>Test Data Requirements</h3>
  <ul><li>[Data need — specific records, edge-case data, bulk data]</li></ul>

  <h3>User Accounts Needed</h3>
  <table>
    <thead><tr><th>Role</th><th>Permissions</th><th>Used In</th></tr></thead>
    <tbody>
      <tr><td>[Role]</td><td>[Permissions needed]</td><td>[Which test cases]</td></tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 14: QA SIGN-OFF
     ═══════════════════════════════════════════════ -->
<section id="signoff">
  <h2>✅ QA Sign-off</h2>
  <p>Check each item to confirm testing is complete:</p>

  <div class="signoff-item"><label><input type="checkbox"> All <strong>functional test cases</strong> executed and passed</label></div>
  <div class="signoff-item"><label><input type="checkbox"> All <strong>Developer Changes Requiring Clarification</strong> resolved with developer</label></div>
  <div class="signoff-item"><label><input type="checkbox"> All <strong>critical and high-risk</strong> scenarios verified</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Blast radius</strong> areas spot-checked — no regressions in dependent modules</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Affected features</strong> verified end-to-end</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Security test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Performance test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Privacy &amp; PII test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Accessibility test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Resilience test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Compatibility test cases</strong> executed (if applicable)</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Coverage map</strong> reviewed — all gaps acknowledged</label></div>
  <div class="signoff-item"><label><input type="checkbox"> <strong>Missing requirement coverage</strong> items reviewed with PO (if applicable)</label></div>

  <div style="margin-top: 2rem; border-top: 2px solid #0f3460; padding-top: 1rem;">
    <p><strong>Tester:</strong> _________________________ <strong>Date:</strong> _____________</p>
    <p><strong>Sign-off status:</strong> ☐ Approved for release &nbsp; ☐ Blocked — issues found &nbsp; ☐ Conditional — see notes</p>
    <p><strong>Notes:</strong></p>
    <div style="border: 1px solid #e0e0e0; border-radius: 4px; min-height: 80px; padding: 0.5rem;"></div>
  </div>
</section>

<footer style="margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #e0e0e0; font-size: 0.8rem; color: #666; text-align: center;">
  Generated by Impact Analyst Plugin — [ISO 8601 timestamp]
</footer>

</body>
</html>
```

---

## Content Rules

1. **Replace all `[bracketed]` placeholders** with actual data from the analysis
2. **Skip test case categories with no realistic surface** — do not include empty category sections
3. **Use the correct CSS classes** — `risk-critical`, `risk-high`, `risk-medium`, `risk-low`; `tc-functional`, `tc-performance`, etc.; `blast-isolated`, `blast-moderate`, `blast-wide`
4. **Group test cases by category** — functional first, then the others in order
5. **Every test case must include**: steps (specific, actionable), test data, expected result (observable), linked requirement
6. **Coverage map must make gaps explicit** — never hide missing coverage
7. **Developer Changes Requiring Clarification** must appear **before** the test cases
8. **QA Sign-off checkboxes** must be interactive (`<input type="checkbox">`)
9. **Ensure the HTML is valid** — close all tags, escape special characters
10. **Timestamped filename** — always `impact-analysis-{YYYY-MM-DD}-{entry-id}.html`
11. **Print-ready** — `@media print` block must be present; report must look clean at A4/Letter
