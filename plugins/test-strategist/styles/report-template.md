# HTML Impact Analysis & Test Strategy Report Template

This template defines the 13-section structure for the HTML report produced by the `test-guide-writer` agent. Follow this template exactly when generating the report.

The report is written for **manual QA testers, product owners, and non-technical stakeholders**. The reader must learn _where the business risk is_ and _how to test it_ in plain language — never which line of code changed.

---

## Report Sections Overview

The report leads with risk and focus, then walks through context, code traceability, test cases, and sign-off.

| # | Section | Purpose |
|---|---|---|
| 1 | **Summary** | Work item title, type, severity, developer, tester, iteration, headline business risk |
| 2 | **Where Testers Should Focus First** | Top 3–5 high-risk business areas with the test case IDs that cover them — the "first hour of testing" guide |
| 3 | **Business Risk Assessment** | What could go wrong, who is affected, how severe — written for non-technical readers |
| 4 | **Impacted Areas** | Direct and indirect impact on user workflows, integrations, and data — with High / Medium / Low ratings |
| 5 | **Context Gathered** | Linked PRs, child work items, changesets, and referenced documentation discovered during analysis |
| 6 | **Code Changes Overview** | Per-PR cards translating file changes into user-visible effects — no raw diffs |
| 7 | **Requirements Coverage** | Each acceptance criterion or repro step mapped to the code changes that address it |
| 8 | **Developer Changes Requiring Clarification** | Code changes not explained by any stated requirement — flagged for discussion before testing |
| 9 | **Missing Requirement Coverage** | Requirements with no corresponding code change found |
| 10 | **Test Cases** | All test scenarios across seven categories — each one a self-contained tester instruction set with concrete test data |
| 11 | **Coverage Map** | Matrix showing which requirements and risks each test case covers, plus what is explicitly out of scope |
| 12 | **Environment & Assignment** | Area path, iteration, developer, tester, environment / data / account requirements |
| 13 | **QA Sign-off** | Interactive checklist for the tester to confirm completion |

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
      .scenario { page-break-inside: avoid; }
    }

    /* ── Typography ── */
    h1 { font-size: 1.8rem; border-bottom: 3px solid #0f3460; padding-bottom: 0.5rem; margin-bottom: 1rem; }
    h2 { font-size: 1.4rem; color: #0f3460; margin-top: 2rem; margin-bottom: 0.75rem; border-bottom: 1px solid #e0e0e0; padding-bottom: 0.3rem; }
    h3 { font-size: 1.15rem; color: #16213e; margin-top: 1.5rem; margin-bottom: 0.5rem; }
    h4 { font-size: 1rem; color: #333; margin-top: 1rem; margin-bottom: 0.3rem; }
    p, li { margin-bottom: 0.5rem; }
    code { font-family: 'SF Mono', Monaco, Consolas, monospace; font-size: 0.85em; background: #f1f3f5; padding: 1px 5px; border-radius: 3px; }

    /* ── Header ── */
    .report-header { background: #0f3460; color: #fff; padding: 1.5rem 2rem; border-radius: 8px; margin-bottom: 2rem; }
    .report-header h1 { color: #fff; border-bottom-color: rgba(255,255,255,0.3); }
    .report-meta { display: flex; flex-wrap: wrap; gap: 1.5rem; margin-top: 1rem; font-size: 0.9rem; opacity: 0.95; }
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

    /* ── PII / data tags inside test data tables ── */
    .data-tag { display: inline-block; padding: 1px 6px; border-radius: 3px; font-size: 0.7rem; font-weight: 600; margin-left: 4px; }
    .data-tag-pii  { background: #ffe0e9; color: #b00040; }
    .data-tag-pci  { background: #ffe9d6; color: #a04000; }
    .data-tag-phi  { background: #e0e9ff; color: #002080; }
    .data-tag-edge { background: #fff3cd; color: #6b4d00; }
    .data-tag-bad  { background: #f8d7da; color: #721c24; }

    /* ── Clarification Badge ── */
    .badge-clarification { background: #e83e8c; color: #fff; padding: 2px 8px; border-radius: 4px; font-weight: 600; font-size: 0.8rem; }

    /* ── Tables ── */
    table { width: 100%; border-collapse: collapse; margin: 1rem 0; font-size: 0.9rem; }
    th { background: #0f3460; color: #fff; text-align: left; padding: 0.6rem 0.8rem; }
    td { padding: 0.6rem 0.8rem; border-bottom: 1px solid #e0e0e0; vertical-align: top; }
    tr:nth-child(even) { background: #f8f9fa; }
    tr:hover { background: #e8f0fe; }

    /* ── Test data table (compact, monospaced) ── */
    .data-table th { background: #16213e; }
    .data-table td:first-child, .data-table td:nth-child(2) { font-family: 'SF Mono', Monaco, Consolas, monospace; font-size: 0.85rem; }

    /* ── Scenario Cards ── */
    .scenario { border: 1px solid #e0e0e0; border-radius: 8px; margin: 1rem 0; overflow: hidden; }
    .scenario-header { padding: 0.8rem 1rem; display: flex; align-items: center; gap: 0.8rem; border-bottom: 1px solid #e0e0e0; background: #f8f9fa; flex-wrap: wrap; }
    .scenario-id { font-weight: 700; font-family: monospace; min-width: 60px; }
    .scenario-title { flex: 1; font-weight: 600; min-width: 280px; }
    .scenario-body { padding: 1rem 1.2rem; }
    .scenario-body dt { font-weight: 600; color: #0f3460; margin-top: 0.9rem; text-transform: uppercase; font-size: 0.8rem; letter-spacing: 0.04em; }
    .scenario-body dt:first-child { margin-top: 0; }
    .scenario-body dd { margin-left: 0; margin-top: 0.25rem; }
    .scenario-body ol { margin-left: 1.5rem; }
    .scenario-body ol li { margin-bottom: 0.4rem; }

    /* ── "Why this matters" callout inside a test case ── */
    .why-callout { background: #fff8e6; border-left: 4px solid #ffc107; padding: 0.7rem 1rem; border-radius: 0 6px 6px 0; margin: 0.5rem 0 0.5rem 0; }
    .why-callout strong { color: #8a6d00; }

    /* ── Focus-first cards (Section 2) ── */
    .focus-card { border-left: 4px solid #dc3545; background: #fff5f6; padding: 1rem 1.2rem; margin: 0.8rem 0; border-radius: 0 6px 6px 0; }
    .focus-card.high   { border-left-color: #fd7e14; background: #fff8f0; }
    .focus-card.medium { border-left-color: #ffc107; background: #fffbe6; }
    .focus-card.low    { border-left-color: #28a745; background: #f0fbf3; }
    .focus-card h4 { margin-top: 0; }
    .focus-card .focus-meta { font-size: 0.85rem; color: #555; margin: 0.4rem 0; }
    .focus-card .focus-tests { font-family: monospace; font-size: 0.85rem; }

    /* ── PR Cards ── */
    .pr-card { border: 1px solid #e0e0e0; border-radius: 8px; padding: 1rem; margin: 0.8rem 0; background: #f8f9fa; }
    .pr-card h4 { margin-top: 0; }

    /* ── Clarification Cards ── */
    .clarification-card { border-left: 4px solid #e83e8c; background: #fef0f5; padding: 1rem; margin: 0.8rem 0; border-radius: 0 6px 6px 0; }

    /* ── Summary Box ── */
    .summary-box { background: #f0f4ff; border: 1px solid #b8d0ff; border-radius: 8px; padding: 1.2rem; margin: 1rem 0; }
    .summary-box .headline { font-size: 1.05rem; font-weight: 600; color: #0f3460; margin-bottom: 0.6rem; }

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
  <p class="headline">[One business sentence — what could go wrong and which users feel it.]</p>
  <p>[2-3 sentences in plain language: what was built, the overall risk posture, and the recommended testing focus.]</p>
  <p><strong>Test Cases:</strong> [total] (🟢 [n] Functional | 🔵 [n] Performance | 🔴 [n] Security | 🟡 [n] Privacy | 🟣 [n] Accessibility | ⚪ [n] Resilience | 🟤 [n] Compatibility)</p>
  <p><strong>Linked PRs:</strong> [list of PR numbers with titles]</p>
</div>

<!-- ═══════════════════════════════════════════════
     TABLE OF CONTENTS
     ═══════════════════════════════════════════════ -->
<nav class="toc no-print">
  <h2>Contents</h2>
  <ol>
    <li><a href="#focus-first">Where Testers Should Focus First</a></li>
    <li><a href="#risk">Business Risk Assessment</a></li>
    <li><a href="#impacted-areas">Impacted Areas</a></li>
    <li><a href="#context">Context Gathered</a></li>
    <li><a href="#code-changes">Code Changes Overview</a></li>
    <li><a href="#req-coverage">Requirements Coverage</a></li>
    <li><a href="#clarification">Developer Changes Requiring Clarification</a></li>
    <li><a href="#missing-coverage">Missing Requirement Coverage</a></li>
    <li><a href="#test-cases">Test Cases</a></li>
    <li><a href="#coverage-map">Coverage Map</a></li>
    <li><a href="#environment">Environment &amp; Assignment</a></li>
    <li><a href="#signoff">QA Sign-off</a></li>
  </ol>
</nav>

<!-- ═══════════════════════════════════════════════
     SECTION 2: WHERE TESTERS SHOULD FOCUS FIRST
     ═══════════════════════════════════════════════ -->
<section id="focus-first">
  <h2>🎯 Where Testers Should Focus First</h2>
  <p>The 3–5 highest-risk business areas in this change. Run these test cases first — they are the most likely to surface release-blocking issues.</p>

  <!-- One focus-card per top-risk area. CSS class matches risk level: focus-card / focus-card.high / focus-card.medium / focus-card.low -->
  <div class="focus-card">
    <h4>1. [Business area — e.g. "Checkout & coupon application"] <span class="risk-critical">Critical</span></h4>
    <p><strong>Why it's high risk:</strong> [One business sentence — what could break and what business outcome is lost.]</p>
    <p class="focus-meta"><strong>Who is affected:</strong> [Customer segment / role / partner / internal team]</p>
    <p class="focus-meta"><strong>What to verify first:</strong> [The single most important behaviour to confirm]</p>
    <p class="focus-tests"><strong>Test cases:</strong> TC-001, TC-003, TC-012 — start with TC-001</p>
  </div>
  <!-- Repeat for each top focus area, in priority order -->
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 3: BUSINESS RISK ASSESSMENT
     ═══════════════════════════════════════════════ -->
<section id="risk">
  <h2>⚠️ Business Risk Assessment</h2>

  <div class="summary-box">
    <p><strong>Overall Risk:</strong> <span class="risk-[level]">[RISK LEVEL]</span></p>
    <p>[2–3 sentence risk summary in non-technical language — what could break, who is affected, how severe, and what business consequence follows.]</p>
  </div>

  <h3>Risk Matrix</h3>
  <table>
    <thead>
      <tr><th>#</th><th>Area</th><th>Risk</th><th>Business Impact</th><th>Who Is Affected</th><th>Primary Driver</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>Risk-1</td>
        <td>[Area]</td>
        <td><span class="risk-[level]">[Level]</span></td>
        <td>[Business outcome lost if this breaks]</td>
        <td>[Users / roles / partners]</td>
        <td>[Main reason for the rating]</td>
      </tr>
    </tbody>
  </table>

  <h3>What Could Go Wrong</h3>
  <table>
    <thead>
      <tr><th>#</th><th>Scenario (Business Language)</th><th>Risk</th><th>Who Is Affected</th><th>Business Consequence</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>1</td>
        <td>[Plain-language scenario — what users experience, not what code does]</td>
        <td><span class="risk-[level]">[Risk]</span></td>
        <td>[Specific user group]</td>
        <td>[Revenue / trust / regulatory / operational consequence]</td>
      </tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 4: IMPACTED AREAS
     ═══════════════════════════════════════════════ -->
<section id="impacted-areas">
  <h2>📍 Impacted Areas</h2>
  <p>Direct and indirect impact on user workflows, integrations, and data.</p>

  <table>
    <thead>
      <tr><th>Area</th><th>Impact</th><th>Direct / Indirect</th><th>Notes (Business Language)</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>[User workflow / integration / data surface]</td>
        <td><span class="risk-[level]">[High / Medium / Low]</span></td>
        <td>[Direct / Indirect]</td>
        <td>[Why it is impacted — what users notice]</td>
      </tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 5: CONTEXT GATHERED
     ═══════════════════════════════════════════════ -->
<section id="context">
  <h2>📂 Context Gathered</h2>
  <p>Everything the agent discovered while building this report.</p>

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
     SECTION 6: CODE CHANGES OVERVIEW
     ═══════════════════════════════════════════════ -->
<section id="code-changes">
  <h2>🔄 Code Changes Overview</h2>
  <p>Code changes translated into the user-visible behaviour they affect. No raw diffs.</p>

  <!-- One card per PR -->
  <div class="pr-card">
    <h4>PR #[number] — [title]</h4>
    <p><strong>Branch:</strong> [source] → [target] | <strong>Files:</strong> [count] | <strong>+[additions]/-[deletions]</strong></p>
    <table>
      <thead>
        <tr><th>What Users Notice</th><th>Where In The Product</th><th>Underlying File(s)</th><th>Risk</th></tr>
      </thead>
      <tbody>
        <tr>
          <td>[Plain-language behaviour change — e.g. "Customers see a delivery-fee line item only when shipping outside the EU"]</td>
          <td>[Workflow / screen / integration affected]</td>
          <td><code>[path/to/file]</code> [+N/-M]</td>
          <td><span class="risk-[level]">[Risk]</span></td>
        </tr>
      </tbody>
    </table>
  </div>
  <!-- Repeat for each PR -->
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 7: REQUIREMENTS COVERAGE
     ═══════════════════════════════════════════════ -->
<section id="req-coverage">
  <h2>✅ Requirements Coverage</h2>
  <p>Each requirement (acceptance criterion or repro step) mapped to the code changes that address it.</p>

  <table>
    <thead>
      <tr><th>ID</th><th>Requirement</th><th>Addressed By</th><th>Evidence (User-Visible)</th><th>Status</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>AC1 / RS1</td>
        <td>[Requirement text]</td>
        <td>[Plain-language description of the change]</td>
        <td>[Why this change satisfies the requirement, in user terms]</td>
        <td><span class="risk-low">Covered</span></td>
      </tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 8: DEVELOPER CHANGES REQUIRING CLARIFICATION
     ═══════════════════════════════════════════════ -->
<section id="clarification">
  <h2>⚠️ Developer Changes Requiring Clarification</h2>

  <div class="warning-box">
    <p><strong>[count] code changes</strong> cannot be mapped to any stated requirement. These must be discussed with the developer before testing begins — do not guess scope.</p>
  </div>

  <div class="clarification-card">
    <h4><span class="badge-clarification">[Category emoji] [Category]</span> — [Change title]</h4>
    <dl>
      <dt>What changed (in business terms)</dt>
      <dd>[User-visible effect, even if subtle]</dd>
      <dt>Where it shows up</dt>
      <dd>[Workflow / screen / integration affected]</dd>
      <dt>Hypothesis</dt>
      <dd>[Best guess of intent — if it can be inferred]</dd>
      <dt>Question for the developer</dt>
      <dd>[The specific thing the tester needs answered before testing this area]</dd>
      <dt>Status</dt>
      <dd><strong>Needs Clarification</strong> — must be resolved before this area is tested.</dd>
    </dl>
  </div>
  <!-- Repeat for each flagged change -->
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 9: MISSING REQUIREMENT COVERAGE
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
     SECTION 10: TEST CASES
     ═══════════════════════════════════════════════ -->
<section id="test-cases">
  <h2>🧪 Test Cases</h2>
  <p>Each test case is a self-contained set of instructions for a manual tester. It includes <strong>why the scenario matters to the business</strong>, the <strong>user persona</strong>, copy-pasteable <strong>test data</strong>, the <strong>steps to run</strong>, the <strong>business outcome</strong> expected, and <strong>where to verify</strong> it. Run them in priority order: Critical → High → Medium → Low.</p>

  <!-- ── Functional ── -->
  <h3>🟢 Functional Test Cases</h3>

  <div class="scenario">
    <div class="scenario-header">
      <span class="scenario-id">TC-001</span>
      <span class="scenario-title">[Plain-language scenario from the user's perspective]</span>
      <span class="tc-functional">Functional</span>
      <span class="risk-[level]">[Priority]</span>
    </div>
    <div class="scenario-body">

      <div class="why-callout">
        <strong>Why this matters:</strong> [1–2 sentences. Business outcome verified if this passes; business loss if it fails. Affected users.]
      </div>

      <dl>
        <dt>Linked to</dt>
        <dd>Requirement: [AC1] · Risk: [Risk-3]</dd>

        <dt>User role / persona</dt>
        <dd>[Specific user — e.g. "Returning customer with active loyalty account"]</dd>

        <dt>Preconditions</dt>
        <dd>[System state, environment, feature flags, existing data]</dd>

        <dt>Test data</dt>
        <dd>
          <table class="data-table">
            <thead>
              <tr><th>Field</th><th>Sample value</th><th>Notes</th></tr>
            </thead>
            <tbody>
              <tr><td>Customer email</td><td>maria.test@example.com</td><td>Pre-seeded test customer <span class="data-tag data-tag-pii">PII</span></td></tr>
              <tr><td>Coupon code</td><td>SAVE20</td><td>Active, 20% off, no minimum</td></tr>
              <tr><td>Cart total</td><td>£125.00</td><td>Above £100 free-shipping threshold <span class="data-tag data-tag-edge">boundary</span></td></tr>
              <tr><td>Payment card</td><td>4242 4242 4242 4242</td><td>Stripe test card <span class="data-tag data-tag-pci">PCI</span></td></tr>
            </tbody>
          </table>
        </dd>

        <dt>Steps</dt>
        <dd>
          <ol>
            <li>[Step 1 — one observable user action, no code references]</li>
            <li>[Step 2]</li>
            <li>[Step 3]</li>
          </ol>
        </dd>

        <dt>Expected business outcome</dt>
        <dd>[What the user sees and what the business gains. Observable from the UI / email / receipt — not from logs alone.]</dd>

        <dt>How to verify</dt>
        <dd>
          <ul>
            <li><strong>On screen:</strong> [Specific UI cue — badge, banner, line item]</li>
            <li><strong>Confirmation:</strong> [Email subject, SMS, on-screen ID]</li>
            <li><strong>Records:</strong> [Order id pattern, audit log entry — technical hints permitted here only]</li>
          </ul>
        </dd>

        <dt>If this fails</dt>
        <dd>Capture: [screenshot, request id, timestamp]. Confirms: [Risk-3]. Escalate to: [developer / team].</dd>
      </dl>
    </div>
  </div>
  <!-- Repeat for each functional test case -->

  <!-- ── Performance (skip section entirely if --no-perf or no surface) ── -->
  <h3>🔵 Performance Test Cases</h3>
  <!-- Each test case must include: load profile (volume, duration, concurrency), acceptance threshold (p95 latency, error rate, throughput), business impact if exceeded -->

  <!-- ── Security (skip if no surface) ── -->
  <h3>🔴 Security Test Cases</h3>
  <!-- Each test case must include: attack scenario in business language ("an attacker tries to view another customer's invoices"), the test data including malicious inputs, the expected refusal/audit, and the business consequence if the test fails -->

  <!-- ── Privacy & PII (skip if no surface) ── -->
  <h3>🟡 Privacy & PII Test Cases</h3>
  <!-- Cover data flows, consent, retention, deletion, data subject rights, log redaction. Mark every PII/PCI/PHI field with the appropriate data-tag in the test data table -->

  <!-- ── Accessibility & Usability (skip if --no-a11y or no UI surface) ── -->
  <h3>🟣 Accessibility & Usability Test Cases</h3>
  <!-- Each test case must include: assistive technology / device / setting (e.g. NVDA on Firefox, iOS VoiceOver, 200% zoom, keyboard-only), the user task, and the expected experience in business language -->

  <!-- ── Resilience (skip if no service surface) ── -->
  <h3>⚪ Resilience Test Cases</h3>
  <!-- Each test case must include: the failure being simulated (e.g. payment gateway timeout), how to simulate it, the expected user-facing graceful behaviour, and the business outcome (e.g. "customer is told to retry, no double-charge occurs") -->

  <!-- ── Compatibility (skip if no UI/API/contract surface) ── -->
  <h3>🟤 Compatibility Test Cases</h3>
  <!-- Each test case must list specific browsers / OS / device versions / API versions / integration partners — never "all browsers". Include test data showing the expected response per target. -->
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 11: COVERAGE MAP
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

  <h3>Business Risks → Test Cases</h3>
  <table>
    <thead>
      <tr><th>Risk</th><th>Test Cases</th><th>Mitigation Status</th></tr>
    </thead>
    <tbody>
      <tr>
        <td>Risk-3 — [business risk]</td>
        <td>TC-005, TC-008</td>
        <td><span class="risk-low">Mitigated</span></td>
      </tr>
      <tr>
        <td>Risk-5 — [business risk]</td>
        <td>—</td>
        <td><span class="risk-high">Unmitigated</span></td>
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
     SECTION 12: ENVIRONMENT & ASSIGNMENT
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
    <li>[Environment need — staging, feature flags on/off, payment provider in sandbox, mocks, external service stubs]</li>
  </ul>

  <h3>Test Data Requirements</h3>
  <ul>
    <li>[Bulk test data — e.g. "1,000 seeded orders for performance run"]</li>
    <li>[Edge-case records — e.g. "one customer with no profile, one with expired payment method"]</li>
    <li>[Reference data — e.g. "tax rates table seeded for UK and DE"]</li>
  </ul>

  <h3>User Accounts Needed</h3>
  <table>
    <thead>
      <tr><th>Role / Persona</th><th>Permissions</th><th>Sample login</th><th>Used In</th></tr>
    </thead>
    <tbody>
      <tr><td>[Role]</td><td>[Permissions needed]</td><td><code>[username / email]</code></td><td>[Which test cases]</td></tr>
    </tbody>
  </table>
</section>

<!-- ═══════════════════════════════════════════════
     SECTION 13: QA SIGN-OFF
     ═══════════════════════════════════════════════ -->
<section id="signoff">
  <h2>✅ QA Sign-off</h2>
  <p>Check each item to confirm testing is complete:</p>

  <div class="signoff-item"><label><input type="checkbox"> All <strong>"Where Testers Should Focus First"</strong> areas verified</label></div>
  <div class="signoff-item"><label><input type="checkbox"> All <strong>functional test cases</strong> executed and passed</label></div>
  <div class="signoff-item"><label><input type="checkbox"> All <strong>Developer Changes Requiring Clarification</strong> resolved with developer</label></div>
  <div class="signoff-item"><label><input type="checkbox"> All <strong>Critical and High</strong> business risks have at least one passing test</label></div>
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

1. **Lead with risk and focus** — Section 2 ("Where Testers Should Focus First") must always appear before code changes and test cases.
2. **Replace all `[bracketed]` placeholders** with actual data from the analysis. Never ship a placeholder.
3. **Skip test case categories with no realistic surface** — do not include empty category sections.
4. **Use the correct CSS classes** — `risk-critical`, `risk-high`, `risk-medium`, `risk-low` for risk badges; `tc-functional`, `tc-performance`, etc. for category badges; `data-tag-pii`, `data-tag-pci`, `data-tag-phi`, `data-tag-edge`, `data-tag-bad` for test-data flags.
5. **Group test cases by category** — Functional first, then Performance, Security, Privacy, Accessibility, Resilience, Compatibility.
6. **Within each category, order test cases by priority** — Critical → High → Medium → Low.
7. **Every test case must include**: a `.why-callout` block, a user persona, a test-data table, observable steps, an expected business outcome, and a "how to verify" block.
8. **Test data must be concrete and copy-pasteable** — sample emails, IDs, currency values, dates, postal codes, payment cards. Mark PII/PCI/PHI fields with `data-tag` spans.
9. **Coverage map must make gaps explicit** — never hide missing coverage; show both requirement-gaps and risk-gaps.
10. **Developer Changes Requiring Clarification** must appear **before** the test cases — the tester needs to know what to pause on.
11. **QA Sign-off checkboxes** must be interactive (`<input type="checkbox">`).
12. **Ensure the HTML is valid** — close all tags, escape special characters in content (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`).
13. **Test printability** — the report should look clean when printed at A4/Letter size; test cases must not split mid-card.
