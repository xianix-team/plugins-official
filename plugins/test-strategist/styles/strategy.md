# Output Style: Impact Analysis & Test Strategy

This style guide defines the conventions used when generating the impact analysis and test strategy report. It applies to the `test-guide-writer` agent and to any markdown summary posted on the platform.

The single most important rule: **write for a manual tester who has not seen the code**. Every section of the report must answer two questions for them — _"where is the highest business risk?"_ and _"how do I actually test it?"_.

---

## Audience

The primary readers are **manual QA testers**, **product owners**, and **non-technical stakeholders**. All output must be written in **business language**:

- Describe _what a customer would experience_, not which line of code changed.
- Describe _who is affected_ and _how their day is impacted_, not the internal mechanism.
- Use the domain vocabulary from the work item (e.g. "checkout", "policy renewal", "claim approval"), not implementation vocabulary (e.g. "service", "endpoint", "DTO", "repository").
- When a technical detail is unavoidable, place it in a tester-only "How to verify" sub-block, never in the headline.

### Forbidden phrasing

| ❌ Avoid | ✅ Prefer |
|---|---|
| "The `applyDiscount()` method now branches on `cart.totalCents`" | "Discounts are now calculated against the full cart value before tax" |
| "Validates the request DTO against the schema" | "Rejects orders with missing or malformed billing addresses" |
| "Adds a null check on `user.profile`" | "Customers who haven't completed profile setup no longer see an error on the dashboard" |
| "Modifies the retry policy in `OrderService.cs`" | "If the payment gateway is briefly unreachable, the order is retried up to 3 times before showing the customer an error" |
| "Touches the auth middleware" | "Affects who can sign in, what they can access, and how their session is renewed" |

---

## Risk-First Ordering

The report is risk-driven. Manual testers must see _what to focus on first_ before they see test cases.

The required order for the reader's eye is:

1. **Headline business risk** (one sentence — what could break and who feels it).
2. **Where Testers Should Focus First** — the 3–5 highest-priority business areas, each with the test case IDs that cover it.
3. **Per-area details and test cases**, ordered Critical → High → Medium → Low.

Test cases never appear before the risk-and-focus framing.

---

## Test Case Categories

Seven categories, each with a color-coded badge. Categories with no realistic surface in the current change must be **skipped entirely** — never generate empty sections.

| Emoji | Badge Class | Category | When to include |
|---|---|---|---|
| 🟢 | `tc-functional` | **Functional** | Always — every change must have functional test coverage |
| 🔵 | `tc-performance` | **Performance** | Change touches a service, query, or data pipeline with realistic performance exposure |
| 🔴 | `tc-security` | **Security** | Change touches authentication, data input, API surfaces, or permission logic |
| 🟡 | `tc-privacy` | **Privacy & PII** | Change handles personal, financial, or health data |
| 🟣 | `tc-accessibility` | **Accessibility & Usability** | Change touches any user interface |
| ⚪ | `tc-resilience` | **Resilience** | Change touches a service call, queue, or external dependency |
| 🟤 | `tc-compatibility` | **Compatibility** | Change touches a UI, public API, integration point, or contract shared with other systems |

### Category Suppression Flags

| Flag | Effect |
|---|---|
| `--no-perf` | Skip 🔵 Performance test cases entirely |
| `--no-a11y` | Skip 🟣 Accessibility & Usability test cases entirely |

When a flag is active, omit the category from the report, the coverage map, and the QA sign-off checklist.

---

## Test Case Format (Business-Oriented)

Each test case is a self-contained instruction set for a manual tester. It must read like a story, not like a spec.

| Field | Content |
|---|---|
| **ID** | Sequential: `TC-001`, `TC-002`, etc. Numbering is global across all categories. |
| **Title** | Plain-language scenario from the user's perspective. Start with a verb the user performs (e.g. "Customer applies a valid coupon at checkout"). |
| **Category badge** | One of the 7 badges above |
| **Priority** | Risk badge: `risk-critical`, `risk-high`, `risk-medium`, `risk-low` — driven by the linked business risk |
| **Why this matters** | One or two sentences. The business outcome that is verified if the test passes, and the business loss that occurs if it fails. Identifies the affected user group. |
| **Linked to** | Both the requirement (AC, RS) **and** the business risk (Risk-N) this case covers. |
| **User role / persona** | The specific kind of user who runs this scenario (e.g. "Returning customer with active loyalty account" or "Customer service agent with refund permission"). |
| **Preconditions** | System state and configuration that must be true before the test starts (e.g. feature flag on, payment provider in sandbox, customer account exists). |
| **Test data** | A small table of concrete sample values — see "Test Data Generation Rules" below. |
| **Steps** | Numbered actions a tester performs. Each step is one observable user action. No code, no API names. |
| **Expected business outcome** | What the user sees and what the business gains if the test passes. Must be observable. |
| **How to verify** | Where the tester looks: UI cue, email/SMS, database row, audit log, downstream system. May contain technical hints (table names, log keys) — but only here. |
| **If this fails** | Optional — what evidence to capture (screenshot, request id, timestamp), what risk it confirms, who to escalate to. |

### Worked Example (Functional)

```
TC-001 — Customer applies a valid coupon at checkout       🟢 Functional   🔴 Critical

Why this matters
  Customers who use a valid coupon expect the discount to be applied and the
  correct lower amount to be charged. If this fails, customers are charged the
  full price, leading to chargebacks, refund requests, and trust loss. Affects
  all paying customers using promotional codes.

Linked to
  Requirement: AC1 — "Coupon discounts must reduce the cart total before tax"
  Risk: Risk-3 — "Customers charged full price despite valid coupon"

User role / persona
  Returning customer with an active account and items in the cart.

Preconditions
  - Storefront is in the staging environment with promotions enabled
  - Coupon SAVE20 exists, is active, and has not reached its usage limit
  - Customer account `maria.test@example.com` exists and is not blocked

Test data
  | Field         | Sample value                | Notes                                |
  |---------------|-----------------------------|--------------------------------------|
  | Customer email| maria.test@example.com      | Pre-seeded test customer             |
  | Cart contents | 2 × Wireless Headphones     | Each priced at £62.50 = £125.00      |
  | Coupon code   | SAVE20                      | 20% off, no minimum, expires +30 days|
  | Payment card  | 4242 4242 4242 4242 / 12-30 | Stripe test card, CVV 123            |
  | Postal code   | SW1A 1AA                    | Valid UK code in delivery zone       |

Steps
  1. Sign in as maria.test@example.com.
  2. Add 2 × Wireless Headphones to the cart.
  3. Open the cart; confirm subtotal shows £125.00.
  4. Enter SAVE20 in the coupon field and click Apply.
  5. Proceed to checkout; enter the test card and place the order.

Expected business outcome
  - Discount line shows "-£25.00 (SAVE20)" and total updates to £100.00.
  - Order is created and the customer sees the order confirmation page.
  - Confirmation email is delivered to maria.test@example.com within 1 minute.

How to verify
  - On screen: discount badge "SAVE20" visible on the order summary.
  - Order admin: order record shows coupon_code = "SAVE20" and total = £100.00.
  - Email log: one confirmation email queued for the test customer.

If this fails
  - Capture: cart screenshot, order id, timestamp.
  - Confirms: Risk-3. Escalate to checkout developer with the order id.
```

---

## Test Data Generation Rules

Every test case **must** include test data the tester can copy and use. Where the data is non-trivial, present it as a table. Test data must be **safe, synthetic, and realistic**.

### Always include

For each test case, generate sample values for:

- **Identifiers** — emails, usernames, customer ids, order ids, account numbers (use the `*.test@example.com` / `Test-NNNN` pattern)
- **Money / quantity** — currency-correct (£, $, €) with both whole and fractional values; include thresholds (just below / at / just above)
- **Dates and times** — relative to "today" (today, yesterday, +30 days), include edge dates (DST boundary, leap day, far past, far future) where relevant
- **Free-text fields** — short, long, with spaces, with apostrophes ("O'Brien"), with non-ASCII (José, 王芳, naïve)
- **Boolean / status** — both states explicitly named
- **Geographic data** — postal codes, phone numbers, country codes in the formats the system actually uses
- **Payment data** — use known test cards (Stripe `4242 4242 4242 4242`, `4000 0000 0000 9995` for declined), never real PANs

### Boundary and edge values

For each input field whose validation matters, generate at least one value at each boundary the requirements imply:

- **Minimum** (e.g. age 18, quantity 1, amount £0.01)
- **Just below minimum** (age 17, quantity 0, amount £0.00)
- **Maximum** (max length, max amount, max items)
- **Just above maximum** (one over the limit, to confirm rejection)
- **Empty / missing**
- **Whitespace only**
- **Special characters and unicode**
- **Format-invalid** (e.g. "abc" in a numeric field, "12/13/2024" in an ISO-only field)

### Negative test data

Each high-risk area must include at least one negative test case with deliberately invalid or malicious data:

- Expired coupon, blocked customer, suspended account
- SQL/script-like strings in free-text fields (`'; DROP TABLE users; --`, `<script>alert(1)</script>`)
- Wrong-currency amounts, wrong-locale dates, oversized uploads
- Disallowed roles trying privileged actions

### PII and privacy data

When the change touches personal, financial, or health data:

- Use synthetic names, addresses, phone numbers — never real PII
- Clearly mark each field as PII / PCI / PHI in the test data table
- Include data-subject rights tests where applicable (export-my-data, delete-my-account, withdraw-consent)
- Verify masking and redaction in logs and audit trails

### Performance test data

For performance test cases, specify:

- **Volume** — number of records, requests per second, concurrent users
- **Distribution** — even, bursty, ramp-up
- **Duration** — short spike, sustained, soak
- **Acceptance threshold** — p95 latency, error rate, throughput

### Compatibility test data

For compatibility test cases, list the **specific** browsers / OS / device versions / API versions / integration partners to verify against — not "all browsers".

---

## Where Testers Should Focus First

Every report must surface the highest-risk business areas in a dedicated section _before_ the test cases. For each top focus area, include:

- **Area** (e.g. "Checkout & coupon application")
- **Why it's high risk** (one business sentence)
- **Who is affected** (which users / customers / partners)
- **Test cases that cover it** (TC-001, TC-005, TC-012)
- **Suggested order** (which one to run first)

This is the single most useful artefact for a time-constrained manual tester — it tells them where to spend their first hour.

---

## Developer Changes Requiring Clarification

These are code changes that could not be mapped to any stated requirement. They are flagged, not tested — the tester must discuss with the developer before testing.

### Category Tags

Each clarification item is tagged with a category:

| Emoji | Category | Meaning |
|---|---|---|
| 🔧 | **Refactoring** | Structural change with no new behaviour |
| 📊 | **Observability** | Logging, metrics, or monitoring additions |
| 🧹 | **Housekeeping** | Dependency updates, linting, config changes |
| 🔄 | **Tech-Debt** | Known technical debt remediation |
| ➕ | **Undocumented Feature** | New behaviour not mentioned in requirements |
| 🔀 | **Scope Creep** | Change that appears outside the scope of this work item |

### Clarification Card Format

```
[Category emoji] [Category] — [Change title]
  What changed (in business terms): [User-visible effect, even if subtle]
  Where it shows up:                [The user-facing area / workflow affected]
  Hypothesis:                       [Best guess of intent — if possible]
  Question for the developer:       [The specific thing the tester needs answered]
  Status: Needs Clarification
```

---

## Coverage Map

The coverage map provides explicit traceability and makes gaps visible.

### Requirements → Test Cases

Map every requirement (AC, RS) to the test cases that cover it. Requirements with **no test case** must show a "Gap" status with severity.

### Risks → Test Cases

Map every identified business risk to the test cases that mitigate it. Risks with **no test case** must show "Unmitigated" with severity.

### Explicitly Out of Scope

List items deliberately excluded from testing, with a reason (deferred, not applicable, separate work item).

---

## Business Risk Assessment

Risk descriptions must use business language only:

- ❌ "The null check on line 45 might fail"
- ✅ "Customers who haven't completed profile setup will see an error when accessing the dashboard"

Risk levels:

| Level | CSS Class | Meaning |
|---|---|---|
| **Critical** | `risk-critical` | Production outage, financial loss, regulatory breach, or data loss likely |
| **High** | `risk-high` | A core user journey is broken, security exposure, or major feature unusable |
| **Medium** | `risk-medium` | Partial feature degradation, edge-case failures, or non-blocking inconvenience |
| **Low** | `risk-low` | Cosmetic issues or unlikely edge cases |

Each risk must name **who is affected**, **what they experience**, and **what business consequence follows** (lost sales, support tickets, brand damage, regulatory exposure).

---

## Report Filename

The report must always be written to:

```
impact-analysis-report.html
```

---

## Markdown Summary (for platform comments)

When posting a comment on a PR or issue, use this condensed format. The summary is for a tester glancing at the PR — it must lead with risk and focus areas, not test counts.

```markdown
## 🧪 Impact Analysis & Test Strategy

**Work Item:** #[id] — [title]
**Overall Risk:** [RISK LEVEL]
**Headline:** [One business sentence — what could break and who feels it]

### Where Testers Should Focus First
1. **[Area]** — [why it's high risk; covered by TC-001, TC-003]
2. **[Area]** — [why; covered by TC-005, TC-008]
3. **[Area]** — [why; covered by TC-012]

### Test Cases
[total] (🟢 [n] Functional | 🔵 [n] Performance | 🔴 [n] Security | 🟡 [n] Privacy | 🟣 [n] Accessibility | ⚪ [n] Resilience | 🟤 [n] Compatibility)

### Developer Changes Requiring Clarification
[count] items flagged — review with the developer before testing begins.

### Coverage Gaps
[bullet list of requirements / risks not covered, with severity]

> Full report with steps, test data, and verification details: `impact-analysis-report.html`
```

---

## General Rules

1. Lead with business risk and focus areas — never lead with file paths or test counts.
2. Every test case must include a **Why this matters**, a **user persona**, **test data**, and an **expected business outcome**.
3. Generate concrete, copy-pasteable, synthetic test data — including boundary, negative, and PII-safe values.
4. Never invent requirements — only test against what was stated in the work item and what was discovered in the code.
5. Never guess what an unclear change does — flag it in "Developer Changes Requiring Clarification".
6. Coverage map must be honest — show gaps, not just coverage.
7. Every test case must link to at least one requirement **and** at least one business risk.
8. Categories with no surface are omitted, not listed as empty.
9. Use `--no-perf` and `--no-a11y` flags to suppress categories.
10. Technical detail (table names, log keys, request paths) is permitted only inside the **How to verify** sub-block of a test case — never in titles, summaries, or risk descriptions.
