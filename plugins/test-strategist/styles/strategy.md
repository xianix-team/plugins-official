# Output Style: Impact Analysis & Test Strategy

This style guide defines the conventions used when generating the impact analysis and test strategy. It applies to the `test-guide-writer` agent and to every comment posted on a PR, issue, or work item discussion.

The single most important rule: **write for a manual tester who has not seen the code**. Every section must answer one of two questions — _"where is the highest business risk?"_ or _"how do I actually test it?"_.

The deliverable is a **series of Markdown comments** posted on the platform — never an HTML file. The structure of the series is defined in `styles/report-template.md`.

---

## Audience

The primary readers are **manual QA testers**, **product owners**, and **non-technical stakeholders**. All output must be written in **business language**:

- Describe _what a customer would experience_, not which line of code changed.
- Describe _who is affected_ and _how their day is impacted_, not the internal mechanism.
- Use the domain vocabulary from the work item (e.g. "checkout", "policy renewal", "claim approval"), not implementation vocabulary (e.g. "service", "endpoint", "DTO", "repository").
- When a technical detail is unavoidable, place it inside the test case's "How to verify" sub-block, never in headlines, summaries, or risk descriptions.

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

1. **Headline business risk** (one sentence — what could break and who feels it). _Comment 1._
2. **Where Testers Should Focus First** — the 3–5 highest-priority business areas, each with the test case IDs that cover it. _Comment 1._
3. **Business risk assessment, impacted areas, code changes overview.** _Comment 2._
4. **Requirements coverage, clarification items, missing coverage.** _Comment 3._
5. **Per-area test cases**, one comment per category, ordered Critical → High → Medium → Low. _Comments 4..N-1._
6. **Coverage map and QA sign-off.** _Comment N._

Test cases never appear before the risk-and-focus framing.

---

## Visual Vocabulary (Markdown Only)

GitHub and Azure DevOps strip custom CSS, `<style>` blocks, inline `style="..."` attributes, and `<script>`. Use **emoji and Markdown primitives only**.

### Risk Badges

| Level | Render in Markdown | Meaning |
|---|---|---|
| **Critical** | `🔴 **Critical**` | Production outage, financial loss, regulatory breach, or data loss likely |
| **High** | `🟠 **High**` | A core user journey is broken, security exposure, or major feature unusable |
| **Medium** | `🟡 **Medium**` | Partial feature degradation, edge-case failures, or non-blocking inconvenience |
| **Low** | `🟢 **Low**` | Cosmetic issues or unlikely edge cases |

### Category Badges

| Emoji | Category | When generated |
|---|---|---|
| 🟢 | **Functional** | Always — every change must have functional test coverage |
| 🔵 | **Performance** | Change touches a service, query, or data pipeline with realistic performance exposure |
| 🔴 | **Security** | Change touches authentication, data input, API surfaces, or permission logic |
| 🟡 | **Privacy & PII** | Change handles personal, financial, or health data |
| 🟣 | **Accessibility & Usability** | Change touches any user interface |
| ⚪ | **Resilience** | Change touches a service call, queue, or external dependency |
| 🟤 | **Compatibility** | Change touches a UI, public API, integration point, or contract shared with other systems |

### Category Suppression Flags

| Flag | Effect |
|---|---|
| `--no-perf` | Skip 🔵 Performance test cases entirely |
| `--no-a11y` | Skip 🟣 Accessibility & Usability test cases entirely |

When a flag is active, omit the category from its dedicated comment (do not post an empty comment), the test case count, the coverage map, and the QA sign-off checklist.

### Test Data Tags

Tags appear in the **Notes column** of a test data table, after the explanatory text. Multiple tags are comma-separated (` · `).

| Tag | Render | Meaning |
|---|---|---|
| PII | `🔒 PII` | Personal data (name, email, address, phone, DOB) |
| PCI | `💳 PCI` | Payment card data |
| PHI | `🩺 PHI` | Health information |
| boundary | `🎯 boundary` | Value sits on an interesting boundary |
| invalid | `⚠️ invalid` | Value is deliberately invalid |

### Callouts

| Purpose | Render |
|---|---|
| "Why this matters" | `> 💡 **Why this matters:** …` (single blockquote) |
| Warning / clarification block | `> ⚠️ **${COUNT}** code change(s) cannot be mapped to any stated requirement.` |
| Pointer back to comment 1 | `[← Comment 1](${COMMENT_1_URL})` at the top of every other comment |

### Collapsibles

`<details>` / `<summary>` is the **only** HTML allowed beyond Markdown. Use it for:

- Each test case body (always — keeps the per-category comment scannable).
- Each per-PR card in the Code Changes Overview.
- The compact Context Gathered block in Comment 3.
- Each clarification item in "Developer Changes Requiring Clarification".

```markdown
<details>
<summary><strong>TC-001</strong> — Customer applies a valid coupon at checkout · 🟢 Functional · 🔴 <strong>Critical</strong></summary>

…test case body…

</details>
```

### QA Sign-Off

Markdown task lists. Both GitHub and Azure DevOps render them as live, clickable checkboxes.

```markdown
- [ ] All **"Where Testers Should Focus First"** areas verified
- [ ] All 🟢 **Functional** test cases executed and passed
```

---

## Test Case Format (Business-Oriented)

Each test case is a self-contained instruction set. It must read like a story, not like a spec.

| Field | Content |
|---|---|
| **ID** | Sequential: `TC-001`, `TC-002`, etc. Numbering is **global** across all categories. |
| **Title** | Plain-language scenario from the user's perspective. Start with a verb the user performs (e.g. "Customer applies a valid coupon at checkout"). |
| **Category badge** | Emoji + name (`🟢 Functional`) |
| **Priority badge** | Risk badge driven by the linked business risk (`🔴 **Critical**`, `🟠 **High**`, …) |
| **Why this matters** | One or two sentences in a `> 💡 **Why this matters:**` blockquote. Business outcome verified if it passes; business loss if it fails; affected users. |
| **Linked to** | Both the requirement (`AC1` / `RS1`) **and** the business risk (`Risk-N`). |
| **User role / persona** | The specific user (e.g. "Returning customer with active loyalty account"), never "a user". |
| **Preconditions** | System state, feature flags, environment, existing data. |
| **Test data** | A Markdown table with concrete sample values — see "Test Data Generation Rules" below. |
| **Steps** | Numbered observable user actions. No code, no API names. |
| **Expected business outcome** | What the user sees and what the business gains. Must be observable from UI / email / receipt — not from logs alone. |
| **How to verify** | Where the tester looks: UI cue, email/SMS, records. Technical hints (table names, log keys) are permitted **only here**. |
| **If this fails** | Short note: evidence to capture, which risk it confirms, who to escalate to. |

The whole body sits inside a `<details>` block (see `styles/report-template.md`).

### Worked Example (Functional)

```markdown
<details>
<summary><strong>TC-001</strong> — Customer applies a valid coupon at checkout · 🟢 Functional · 🔴 <strong>Critical</strong></summary>

> 💡 **Why this matters:** Customers who use a valid coupon expect the discount to be applied and the correct lower amount to be charged. If this fails, customers are charged the full price, leading to chargebacks, refund requests, and trust loss. Affects all paying customers using promotional codes.

**Linked to:** Requirement `AC1` — "Coupon discounts must reduce the cart total before tax" · Risk `Risk-3` — "Customers charged full price despite valid coupon"

**User role / persona:** Returning customer with an active account and items in the cart.

**Preconditions:**
- Storefront is in the staging environment with promotions enabled
- Coupon `SAVE20` exists, is active, and has not reached its usage limit
- Customer account `maria.test@example.com` exists and is not blocked

**Test data**

| Field | Sample value | Notes |
|---|---|---|
| Customer email | `maria.test@example.com` | Pre-seeded test customer · 🔒 PII |
| Cart contents | 2 × Wireless Headphones | Each priced at £62.50 = £125.00 |
| Coupon code | `SAVE20` | 20% off, no minimum, expires +30 days |
| Payment card | `4242 4242 4242 4242 / 12-30 / 123` | Stripe test card · 💳 PCI |
| Postal code | `SW1A 1AA` | Valid UK code in delivery zone |

**Steps**
1. Sign in as `maria.test@example.com`.
2. Add 2 × Wireless Headphones to the cart.
3. Open the cart; confirm subtotal shows `£125.00`.
4. Enter `SAVE20` in the coupon field and click Apply.
5. Proceed to checkout; enter the test card and place the order.

**Expected business outcome**
- Discount line shows `-£25.00 (SAVE20)` and total updates to `£100.00`.
- Order is created and the customer sees the order confirmation page.
- Confirmation email is delivered to `maria.test@example.com` within 1 minute.

**How to verify**
- **On screen:** discount badge `SAVE20` visible on the order summary.
- **Order admin:** order record shows `coupon_code = "SAVE20"` and `total = £100.00`.
- **Email log:** one confirmation email queued for the test customer.

**If this fails**
Capture: cart screenshot, order id, timestamp. Confirms `Risk-3`. Escalate to: checkout developer.

</details>
```

---

## Test Data Generation Rules

Every test case **must** include test data the tester can copy and use. Present it as a Markdown table. Test data must be **safe, synthetic, and realistic**.

### Always include

- **Identifiers** — emails, usernames, customer ids, order ids (use `*.test@example.com` / `Test-NNNN`)
- **Money / quantity** — currency-correct (£, $, €), with thresholds (just below / at / just above)
- **Dates and times** — relative to "today" (today, yesterday, +30 days), with edge dates (DST boundary, leap day, far past, far future) where relevant
- **Free-text fields** — short, long, with apostrophes ("O'Brien"), with non-ASCII (José, 王芳, naïve)
- **Boolean / status** — both states explicitly named
- **Geographic data** — postal codes, phone numbers, country codes in the system's actual format
- **Payment data** — known test cards (Stripe `4242 4242 4242 4242`, `4000 0000 0000 9995` for declined), never real PANs

### Boundary and edge values

For each input field whose validation matters, generate at least one value at each boundary the requirements imply:

- **Minimum** (age 18, quantity 1, amount £0.01)
- **Just below minimum** (age 17, quantity 0, amount £0.00)
- **Maximum** (max length, max amount, max items)
- **Just above maximum** (one over the limit, to confirm rejection)
- **Empty / missing**
- **Whitespace only**
- **Special characters and unicode**
- **Format-invalid** ("abc" in a numeric field, "12/13/2024" in an ISO-only field)

Mark boundary values in the Notes column with ` · 🎯 boundary`.

### Negative test data

Each high-risk area must include at least one negative test case. Use realistic invalid / malicious data:

- Expired coupons, blocked customers, suspended accounts
- SQL/script-like strings in free-text fields (`'; DROP TABLE users; --`, `<script>alert(1)</script>`)
- Wrong-currency amounts, wrong-locale dates, oversized uploads
- Disallowed roles attempting privileged actions

Mark invalid values in the Notes column with ` · ⚠️ invalid`.

### PII / privacy / payment flagging

When the change touches personal, financial, or health data:

- Use synthetic names, addresses, phone numbers — never real PII.
- Mark every sensitive field in the Notes column with the appropriate tag: `🔒 PII`, `💳 PCI`, `🩺 PHI`.
- Include data-subject rights tests where applicable (export-my-data, delete-my-account, withdraw-consent).
- Verify masking and redaction in logs and audit trails.

### Performance test data

For performance test cases include, **before** the test data table:

- **Load profile** — volume, requests per second, concurrent users, distribution (even / bursty / ramp-up), duration (short spike / sustained / soak)
- **Acceptance threshold** — p95 latency, error rate, throughput
- **Business impact if missed** — what business outcome is lost when the threshold is exceeded

### Compatibility test data

For compatibility test cases, list the **specific** browsers / OS / device versions / API versions / integration partners — never "all browsers" or "all devices".

### Accessibility test data

For accessibility test cases, state the assistive technology / device / setting (e.g. NVDA on Firefox, iOS VoiceOver, 200% browser zoom, keyboard-only) and the user task. Express the expected experience in business language.

### Resilience test data

For resilience test cases, state the failure being simulated (e.g. payment gateway timeout), how to simulate it, the expected user-facing graceful behaviour, and the business outcome (e.g. "customer is told to retry, no double-charge occurs").

---

## Where Testers Should Focus First (Comment 1)

The single most useful artefact for a time-constrained tester. For each top focus area (3–5 maximum, ordered by priority):

```markdown
### N. ${BUSINESS_AREA} — ${RISK_BADGE}

- **Why it's high risk:** ${ONE_BUSINESS_SENTENCE_WHAT_BREAKS_AND_WHAT_IS_LOST}
- **Who is affected:** ${SEGMENT_ROLE_PARTNER_OR_INTERNAL_TEAM}
- **What to verify first:** ${MOST_IMPORTANT_BEHAVIOUR_TO_CONFIRM}
- **Test cases:** `${TC_LIST}` — start with `${FIRST_TC}`
```

Use the business area name in user vocabulary ("Checkout & coupon application"), not implementation vocabulary ("PricingService").

---

## Developer Changes Requiring Clarification (Comment 3)

Code changes that could not be mapped to any stated requirement. Flagged, not tested — the tester must discuss with the developer **before testing this area begins**.

### Category Tags

| Emoji | Category | Meaning |
|---|---|---|
| 🔧 | **Refactoring** | Structural change with no new behaviour |
| 📊 | **Observability** | Logging, metrics, or monitoring additions |
| 🧹 | **Housekeeping** | Dependency updates, linting, config changes |
| 🔄 | **Tech-Debt** | Known technical debt remediation |
| ➕ | **Undocumented Feature** | New behaviour not mentioned in requirements |
| 🔀 | **Scope Creep** | Change that appears outside the scope of this work item |

### Clarification Card Format

```markdown
<details>
<summary><strong>${CHANGE_TITLE}</strong> · ${CATEGORY_EMOJI} ${CATEGORY}</summary>

- **What changed (in business terms):** ${USER_VISIBLE_EFFECT_EVEN_IF_SUBTLE}
- **Where it shows up:** ${WORKFLOW_OR_SCREEN_OR_INTEGRATION}
- **Hypothesis:** ${BEST_GUESS_OF_INTENT}
- **Question for the developer:** ${SPECIFIC_THING_TESTER_NEEDS_ANSWERED}
- **Status:** 🟣 **Needs Clarification** — must be resolved before this area is tested.

</details>
```

If there are no clarification items, replace the whole section with a single line:

> _No unexplained changes — every code change maps to a stated requirement._

---

## Coverage Map (Comment N)

Explicit traceability — gaps must be visible.

### Requirements → Test Cases

Map every requirement (AC, RS) to the test cases that cover it. Requirements with **no test case** show a `🔴 **Gap**` status with a specific reason ("No price-rounding logic found in any linked PR" — not "uncovered").

### Risks → Test Cases

Map every identified business risk to the test cases that mitigate it. Risks with **no test case** show `🟠 **Unmitigated**` (or `🔴 **Unmitigated**` if the risk is Critical).

### Explicitly Out of Scope

List items deliberately excluded from testing, with a reason (deferred / not applicable / separate work item).

---

## Business Risk Assessment (Comment 2)

Risk descriptions must use business language only:

- ❌ "The null check on line 45 might fail"
- ✅ "Customers who haven't completed profile setup will see an error when accessing the dashboard"

Each risk in the matrix must name **who is affected**, **what they experience**, and **what business consequence follows** (lost sales, support tickets, brand damage, regulatory exposure).

The "What Could Go Wrong" table phrases each scenario in user terms, with a clear business consequence column (revenue / trust / regulatory / operational).

---

## Comment Series Mechanics

The `test-guide-writer` agent produces a list of Markdown blobs — one per planned comment. Each blob is named:

```
01-overview-and-focus.md
02-risk-and-impact.md
03-requirements-and-gaps.md
04-tests-functional.md
05-tests-performance.md
06-tests-security.md
07-tests-privacy.md
08-tests-accessibility.md
09-tests-resilience.md
10-tests-compatibility.md
NN-coverage-and-signoff.md
```

(Number prefixes pad to 2 digits so files sort correctly. Categories with no surface or suppressed by a flag are not generated.)

Each blob:

- Starts with the heading `# 🧪 Impact Analysis & Test Strategy — \`[k/N]\` <Title>`.
- Includes a `[← Comment 1](${COMMENT_1_URL})` link directly under the heading on every comment except #1.
- Ends with a navigation footer linking to the previous and next comment.
- Stays under **50 KB** (split categories at test-case boundaries if needed; recompute `N`).

The provider (GitHub / Azure DevOps / Generic) is responsible for posting these blobs in order, capturing each comment's URL, and editing Comment 1's Table of Contents to deep-link to every subsequent comment.

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
11. Use only Markdown plus `<details>` / `<summary>` — no `<style>`, no inline `style="..."`, no `<script>`, no custom CSS classes. Both GitHub and Azure DevOps strip these.
12. Stay under the per-comment size budget — split a long category at a test case boundary, never inside one.
