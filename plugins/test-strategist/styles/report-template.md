# Markdown Comment-Series Template — Impact Analysis & Test Strategy

This template defines the structure of the **Markdown comment series** posted by the `test-guide-writer` agent on a pull request, issue, or work item discussion. The full report is split into a logical sequence of comments so that:

- No single comment exceeds the platform comment-body limit (GitHub ≈ 65 KB, Azure DevOps ≈ 150 KB).
- Each comment is **self-contained** — readable on its own with a `[k/N]` header.
- The first comment carries a **Table of Contents** that deep-links to every other comment.
- The reader sees **risk and focus areas first**, before any test cases.

There is no HTML report. The Markdown comment series is the deliverable.

---

## Audience

The reader is a **manual QA tester, product owner, or non-technical stakeholder**. Every word must answer one of two questions:

1. **Where is the highest business risk in this change?**
2. **How do I actually test it?**

Never describe which line of code changed. Always describe what a user would see and what the business outcome is.

---

## Comment Series Structure

A typical run produces **5 to 8 comments**. Categories with no realistic surface in the change (and categories suppressed by `--no-perf` / `--no-a11y`) are skipped — they do not get a comment.

| # | Comment Title | Always Present? | Contents |
|---|---|---|---|
| 1 | `[1/N] Overview & Focus Areas` | Yes | Header, headline business risk, **Where Testers Should Focus First**, test case count summary, linked PRs, **Table of Contents** (back-filled with comment URLs) |
| 2 | `[2/N] Risk & Impact` | Yes | Business Risk Assessment (overall + risk matrix + What Could Go Wrong), Impacted Areas, Code Changes Overview |
| 3 | `[3/N] Requirements & Gaps` | Yes | Requirements Coverage, Developer Changes Requiring Clarification, Missing Requirement Coverage, Context Gathered (compact) |
| 4..N-1 | `[k/N] Test Cases: <Category>` | Per non-empty category | One comment per non-empty category. If a category exceeds the size budget, split into `Part 1 / Part 2` comments — never split a single test case across comments. |
| N | `[N/N] Coverage Map & QA Sign-off` | Yes | Coverage Map (req → TC, risk → TC, out-of-scope), Environment & Assignment, **QA Sign-off** as Markdown task list |

### Test Case Category Order (Comments 4..N-1)

Within a category, order test cases **Critical → High → Medium → Low**.

| Order | Emoji | Category | Suppressed by | When to include |
|---|---|---|---|---|
| 1 | 🟢 | **Functional** | — | Always |
| 2 | 🔵 | **Performance** | `--no-perf` | Service / query / data pipeline / API endpoint / file upload / search |
| 3 | 🔴 | **Security** | — | Auth flows, input forms, file uploads, API surfaces, permission checks |
| 4 | 🟡 | **Privacy & PII** | — | Personal, financial, or health data |
| 5 | 🟣 | **Accessibility & Usability** | `--no-a11y` | Any UI surface |
| 6 | ⚪ | **Resilience** | — | Service calls, queues, external APIs, payment / shipping providers |
| 7 | 🟤 | **Compatibility** | — | Public APIs, SDK contracts, shared schemas, browsers, mobile platforms |

### Size Budget

Aim for **≤ 50 KB per comment** (well under GitHub's 65,536-character limit, well under Azure DevOps' 150 KB limit). When a category's test cases exceed this:

1. Split at a **test case boundary** — never inside a test case.
2. Suffix the comment title with ` — Part 1 of 2`, ` — Part 2 of 2`, etc.
3. Recompute `N` so all `[k/N]` headers reflect the final total.

---

## Visual Vocabulary (Markdown Only)

GitHub and Azure DevOps strip custom CSS. Use emoji and Markdown primitives instead.

### Risk Badges

| Level | Render |
|---|---|
| Critical | `🔴 **Critical**` |
| High | `🟠 **High**` |
| Medium | `🟡 **Medium**` |
| Low | `🟢 **Low**` |

### Category Badges

Use the emoji from the category-order table above as a prefix in headings, summaries, and inline references.

### Test Data Tags

Tags appear in the **Notes column** of a test data table, after the explanatory text. Multiple tags are comma-separated.

| Tag | Render | Meaning |
|---|---|---|
| PII | `🔒 PII` | Personal data (name, email, address, phone, DOB) |
| PCI | `💳 PCI` | Payment card data |
| PHI | `🩺 PHI` | Health information |
| boundary | `🎯 boundary` | Value sits on an interesting boundary |
| invalid | `⚠️ invalid` | Value is deliberately invalid |

### "Why This Matters" Callout

Always a single blockquote, bold prefix:

```markdown
> 💡 **Why this matters:** Customers who use a valid coupon expect the discount to be applied and the correct lower amount to be charged. If this fails, customers are charged the full price, leading to chargebacks and trust loss.
```

### Focus-First Card

Use a level-3 heading with a numbered prefix and the highest risk badge inline. Follow with a short labelled list:

```markdown
### 1. Checkout & coupon application — 🔴 **Critical**

- **Why it's high risk:** A miscalculated coupon discount means customers are charged the wrong amount — direct revenue impact and refund spike.
- **Who is affected:** All paying customers using promotional codes.
- **What to verify first:** Apply `SAVE20` on a £125 cart and confirm the total drops to £100 and the order is created.
- **Test cases:** `TC-001`, `TC-003`, `TC-012` — start with `TC-001`.
```

### QA Sign-Off Checklist

Use Markdown task lists. They render as live checkboxes on GitHub and Azure DevOps:

```markdown
- [ ] All **"Where Testers Should Focus First"** areas verified
- [ ] All 🟢 **Functional** test cases executed and passed
- [ ] All **Developer Changes Requiring Clarification** resolved with the developer
- [ ] All **Critical** and **High** business risks have at least one passing test
```

### Collapsible Test Case Cards

Wrap every test case body in a `<details>` block so the comment stays scannable. Both GitHub and Azure DevOps render `<details>` / `<summary>` reliably.

```markdown
<details>
<summary><strong>TC-001</strong> — Customer applies a valid coupon at checkout · 🟢 Functional · 🔴 <strong>Critical</strong></summary>

> 💡 **Why this matters:** …

**Linked to:** Requirement `AC1` · Risk `Risk-3`
**User role / persona:** Returning customer with an active loyalty account.
**Preconditions:**
- Storefront in staging with promotions enabled
- Coupon `SAVE20` is active and not at usage limit
- Customer `maria.test@example.com` exists and is not blocked

**Test data**

| Field | Sample value | Notes |
|---|---|---|
| Customer email | `maria.test@example.com` | Pre-seeded test customer · 🔒 PII |
| Cart total | `£125.00` | Above £100 free-shipping threshold · 🎯 boundary |
| Coupon code | `SAVE20` | 20% off, no minimum, expires +30 days |
| Payment card | `4242 4242 4242 4242` | Stripe test card · 💳 PCI |

**Steps**
1. Sign in as `maria.test@example.com`.
2. Add 2 × Wireless Headphones to the cart.
3. Open the cart; confirm subtotal shows `£125.00`.
4. Enter `SAVE20` in the coupon field and click Apply.
5. Proceed to checkout; enter the test card and place the order.

**Expected business outcome**
- Discount line shows `-£25.00 (SAVE20)` and total updates to `£100.00`.
- Order is created and the customer sees the order confirmation page.
- Confirmation email is delivered within 1 minute.

**How to verify**
- **On screen:** discount badge `SAVE20` visible on the order summary.
- **Order admin:** order record shows `coupon_code = "SAVE20"` and `total = £100.00`.
- **Email log:** one confirmation email queued for the test customer.

**If this fails**
Capture: cart screenshot, order id, timestamp. Confirms `Risk-3`. Escalate to: checkout developer.

</details>
```

---

## Comment 1 — Overview & Focus Areas

```markdown
# 🧪 Impact Analysis & Test Strategy — `[1/N]` Overview & Focus Areas

> **Work Item:** [#${WORK_ITEM_ID}](${WORK_ITEM_URL}) — ${WORK_ITEM_TITLE}
> **Type:** ${TYPE} · **Severity:** ${SEVERITY} · **Priority:** ${PRIORITY}
> **Developer:** ${DEVELOPER} · **Tester:** ${TESTER} · **Iteration:** ${ITERATION}
> **Overall Risk:** ${RISK_EMOJI} **${RISK_LEVEL}**

## Headline

${HEADLINE_BUSINESS_SENTENCE}

${TWO_OR_THREE_SENTENCES_PLAIN_LANGUAGE_OVERVIEW}

## Test Cases

**${TOTAL_COUNT}** total — 🟢 ${N_FUNC} Functional · 🔵 ${N_PERF} Performance · 🔴 ${N_SEC} Security · 🟡 ${N_PRIV} Privacy · 🟣 ${N_A11Y} Accessibility · ⚪ ${N_RES} Resilience · 🟤 ${N_COMPAT} Compatibility

(Categories with `0` count are omitted from the per-category comments below.)

## Linked Pull Requests

- [#${PR_NUMBER}](${PR_URL}) — ${PR_TITLE} (${PR_STATE})

## 🎯 Where Testers Should Focus First

The 3–5 highest-risk business areas in this change. Run these first — they are most likely to surface release-blocking issues.

### 1. ${AREA_1} — ${RISK_BADGE_1}

- **Why it's high risk:** ${ONE_BUSINESS_SENTENCE}
- **Who is affected:** ${USERS_OR_PARTNERS}
- **What to verify first:** ${MOST_IMPORTANT_BEHAVIOUR}
- **Test cases:** `${TC_LIST}` — start with `${FIRST_TC}`

### 2. ${AREA_2} — ${RISK_BADGE_2}

…

---

## 📑 Contents

1. [Overview & Focus Areas](#) (this comment)
2. [Risk & Impact](${COMMENT_2_URL})
3. [Requirements & Gaps](${COMMENT_3_URL})
4. [Test Cases: 🟢 Functional](${COMMENT_4_URL})
5. [Test Cases: 🔵 Performance](${COMMENT_5_URL})
…
N. [Coverage Map & QA Sign-off](${COMMENT_N_URL})

> _The Contents links are populated after every comment is posted. If you see `…` placeholders, the post-edit step did not complete — refresh in a moment._
```

The TOC is **back-filled** by the posting flow once every other comment has been posted and its URL captured. See `providers/github.md` and `providers/azure-devops.md`.

---

## Comment 2 — Risk & Impact

```markdown
# 🧪 Impact Analysis & Test Strategy — `[2/N]` Risk & Impact

[← Comment 1](${COMMENT_1_URL})

## ⚠️ Business Risk Assessment

**Overall Risk:** ${RISK_EMOJI} **${RISK_LEVEL}**

${TWO_OR_THREE_SENTENCE_RISK_SUMMARY_IN_BUSINESS_LANGUAGE}

### Risk Matrix

| # | Area | Risk | Business Impact | Who Is Affected | Primary Driver |
|---|---|---|---|---|---|
| `Risk-1` | ${AREA} | 🔴 **Critical** | ${IMPACT} | ${USERS} | ${DRIVER} |

### What Could Go Wrong

| # | Scenario (Business Language) | Risk | Who Is Affected | Business Consequence |
|---|---|---|---|---|
| 1 | ${SCENARIO} | 🔴 **Critical** | ${USERS} | ${REVENUE_TRUST_REGULATORY_OPERATIONAL} |

## 📍 Impacted Areas

| Area | Impact | Direct / Indirect | Notes (Business Language) |
|---|---|---|---|
| ${AREA} | 🔴 **High** | Direct | ${WHAT_USERS_NOTICE} |

## 🔄 Code Changes Overview

One section per linked PR. The per-file table is collapsible to keep the comment scannable.

<details>
<summary><strong>PR #${PR_NUMBER}</strong> — ${PR_TITLE} · ${BRANCH} → ${BASE} · ${FILE_COUNT} files · +${ADDITIONS}/-${DELETIONS}</summary>

| What Users Notice | Where In The Product | Underlying File(s) | Risk |
|---|---|---|---|
| ${BEHAVIOUR_CHANGE} | ${WORKFLOW_OR_SCREEN} | `${FILE_PATH}` `+N/-M` | 🟠 **High** |

</details>

[← Comment 1](${COMMENT_1_URL}) · [Comment 3 →](${COMMENT_3_URL})
```

---

## Comment 3 — Requirements & Gaps

```markdown
# 🧪 Impact Analysis & Test Strategy — `[3/N]` Requirements & Gaps

[← Comment 1](${COMMENT_1_URL}) · [← Comment 2](${COMMENT_2_URL})

## ✅ Requirements Coverage

Each requirement (acceptance criterion or repro step) mapped to the code changes that address it.

| ID | Requirement | Addressed By | Evidence (User-Visible) | Status |
|---|---|---|---|---|
| `AC1` | ${REQUIREMENT_TEXT} | ${PLAIN_LANGUAGE_CHANGE} | ${WHAT_A_USER_OBSERVES} | 🟢 **Covered** |

## ⚠️ Developer Changes Requiring Clarification

> **${COUNT}** code change(s) cannot be mapped to any stated requirement. Discuss with the developer **before testing begins** — do not guess scope.

<details>
<summary><strong>${CHANGE_TITLE}</strong> · ${CATEGORY_EMOJI} ${CATEGORY}</summary>

- **What changed (in business terms):** ${USER_VISIBLE_EFFECT}
- **Where it shows up:** ${WORKFLOW_OR_SCREEN}
- **Hypothesis:** ${BEST_GUESS}
- **Question for the developer:** ${SPECIFIC_QUESTION}
- **Status:** 🟣 **Needs Clarification** — must be resolved before this area is tested.

</details>

(If there are no clarification items, replace this section with the single line: _"No unexplained changes — every code change maps to a stated requirement."_)

## 🔍 Missing Requirement Coverage

Requirements with no corresponding code change found.

| ID | Requirement | Why It Appears Uncovered | Severity |
|---|---|---|---|
| `AC3` | ${REQUIREMENT_TEXT} | ${SPECIFIC_REASON_NOT_GENERIC} | 🟠 **High** |

## 📂 Context Gathered

<details>
<summary><strong>Linked Pull Requests, Child Work Items, Changesets, Documentation</strong></summary>

**Linked Pull Requests**

| PR | Title | State | Branch | Files |
|---|---|---|---|---|
| [#${PR_NUMBER}](${PR_URL}) | ${PR_TITLE} | ${STATE} | `${BRANCH}` | ${COUNT} |

**Child Work Items**

| ID | Title | Type | State |
|---|---|---|---|
| [#${ID}](${URL}) | ${TITLE} | ${TYPE} | ${STATE} |

**Referenced Documentation**

- `${PATH}` — ${BRIEF_DESCRIPTION}

</details>

[← Comment 1](${COMMENT_1_URL}) · [Comment 4 →](${COMMENT_4_URL})
```

---

## Comment k (4..N-1) — Test Cases per Category

One comment per non-empty category. If a category's content exceeds the size budget, split into `Part 1 of 2`, `Part 2 of 2`, … with the same header pattern.

```markdown
# 🧪 Impact Analysis & Test Strategy — `[${k}/N]` Test Cases: 🟢 Functional

[← Comment 1](${COMMENT_1_URL})

> Run in priority order: 🔴 Critical → 🟠 High → 🟡 Medium → 🟢 Low.
> Every test case below links to at least one requirement **and** one business risk.

<details>
<summary><strong>TC-001</strong> — ${PLAIN_LANGUAGE_TITLE} · 🟢 Functional · 🔴 <strong>Critical</strong></summary>

> 💡 **Why this matters:** ${ONE_OR_TWO_BUSINESS_SENTENCES}

**Linked to:** Requirement `${AC_OR_RS}` · Risk `${RISK_N}`
**User role / persona:** ${SPECIFIC_USER_NOT_GENERIC}
**Preconditions:**
- ${PRECONDITION_1}
- ${PRECONDITION_2}

**Test data**

| Field | Sample value | Notes |
|---|---|---|
| ${FIELD} | `${VALUE}` | ${DESCRIPTION} · 🔒 PII |
| ${FIELD} | `${VALUE}` | ${DESCRIPTION} · 🎯 boundary |

**Steps**
1. ${OBSERVABLE_USER_ACTION_1}
2. ${OBSERVABLE_USER_ACTION_2}

**Expected business outcome**
- ${WHAT_USER_SEES_AND_BUSINESS_GAINS}

**How to verify**
- **On screen:** ${SPECIFIC_UI_CUE}
- **Confirmation:** ${EMAIL_OR_SMS_OR_ID}
- **Records:** `${TABLE_OR_LOG_KEY}` (technical hints permitted **only here**)

**If this fails**
Capture: ${EVIDENCE}. Confirms `${RISK_N}`. Escalate to: ${TEAM_OR_DEVELOPER}.

</details>

<details>
<summary><strong>TC-002</strong> — … · 🟢 Functional · 🟠 <strong>High</strong></summary>
…
</details>

[← Comment 1](${COMMENT_1_URL}) · [Comment ${k+1} →](${NEXT_COMMENT_URL})
```

### Category-specific extra fields

Inside the `<details>` body of a test case, **before** the "Test data" section, include category-specific fields where relevant.

| Category | Extra fields |
|---|---|
| 🔵 Performance | **Load profile** (volume / duration / concurrency), **Acceptance threshold** (p95 latency / error rate / throughput), **Business impact if missed** |
| 🔴 Security | **Attack scenario** (in business language: "an attacker tries to view another customer's invoices"), **Test data** including malicious inputs, **Expected refusal & audit trail** |
| 🟡 Privacy & PII | **Data flow** (what is collected, where it flows, where it is stored), **Consent / retention / deletion expectation**, **Log redaction expectation** |
| 🟣 Accessibility | **Assistive technology / setting** (e.g. NVDA on Firefox, iOS VoiceOver, 200% zoom, keyboard-only), **User task**, **Expected experience in business language** |
| ⚪ Resilience | **Failure being simulated** (e.g. payment gateway timeout), **How to simulate it**, **Expected user-facing graceful behaviour**, **Business outcome** (e.g. "no double-charge occurs") |
| 🟤 Compatibility | **Specific** browsers / OS / device versions / API versions / partners — never "all browsers" |

---

## Comment N — Coverage Map & QA Sign-off

```markdown
# 🧪 Impact Analysis & Test Strategy — `[N/N]` Coverage Map & QA Sign-off

[← Comment 1](${COMMENT_1_URL})

## 🗺️ Coverage Map

### Requirements → Test Cases

| Requirement | Test Cases | Coverage Status |
|---|---|---|
| `AC1` — ${REQUIREMENT_TEXT} | `TC-001`, `TC-003`, `TC-012` | 🟢 **Covered** |
| `AC3` — ${REQUIREMENT_TEXT} | — | 🔴 **Gap — no code change found** |

### Business Risks → Test Cases

| Risk | Test Cases | Mitigation Status |
|---|---|---|
| `Risk-3` — ${BUSINESS_RISK} | `TC-005`, `TC-008` | 🟢 **Mitigated** |
| `Risk-5` — ${BUSINESS_RISK} | — | 🟠 **Unmitigated** |

### Explicitly Out of Scope

| Item | Reason |
|---|---|
| ${WHAT_IS_NOT_COVERED} | ${DEFERRED_NOT_APPLICABLE_OR_SEPARATE_WORK_ITEM} |

## 🖥️ Environment & Assignment

| Field | Value |
|---|---|
| **Area Path** | ${AREA_PATH} |
| **Iteration** | ${ITERATION} |
| **Assigned Developer** | ${DEVELOPER} |
| **Assigned Tester** | ${TESTER} |

**Test Environment Requirements**
- ${ENVIRONMENT_NEED}

**Test Data Requirements**
- ${BULK_RECORDS}
- ${EDGE_CASE_RECORDS}
- ${REFERENCE_DATA}

**User Accounts Needed**

| Role / Persona | Permissions | Sample login | Used In |
|---|---|---|---|
| ${ROLE} | ${PERMISSIONS} | `${LOGIN}` | `${TC_LIST}` |

## ✅ QA Sign-off

Tick each item once verified — these checkboxes are interactive on GitHub and Azure DevOps.

- [ ] All **"Where Testers Should Focus First"** areas verified
- [ ] All 🟢 **Functional** test cases executed and passed
- [ ] All **Developer Changes Requiring Clarification** resolved with the developer
- [ ] All 🔴 **Critical** and 🟠 **High** business risks have at least one passing test
- [ ] **Regression** areas verified — no regressions found
- [ ] 🔴 **Security** test cases executed (if applicable)
- [ ] 🔵 **Performance** test cases executed (if applicable)
- [ ] 🟡 **Privacy & PII** test cases executed (if applicable)
- [ ] 🟣 **Accessibility** test cases executed (if applicable)
- [ ] ⚪ **Resilience** test cases executed (if applicable)
- [ ] 🟤 **Compatibility** test cases executed (if applicable)
- [ ] **Coverage map** reviewed — all gaps acknowledged
- [ ] **Missing requirement coverage** items reviewed with PO

---

**Tester:** _____________________ · **Date:** ____________
**Sign-off status:** ☐ Approved for release · ☐ Blocked — issues found · ☐ Conditional — see notes
**Notes:**
> _(write notes here)_

[← Comment 1](${COMMENT_1_URL})
```

---

## Content Rules

1. **Lead with risk and focus** — Comment 1's "Where Testers Should Focus First" must always appear before any test cases (which start at Comment 4).
2. **Replace every `${PLACEHOLDER}`** with real data from the analysis. Never ship a placeholder.
3. **Skip categories with no realistic surface** — do not generate empty test-case comments. Recompute `N` accordingly.
4. **Honour suppression flags** — `--no-perf` removes Performance from category comments, the count summary, the coverage map, and the sign-off checklist; same for `--no-a11y`.
5. **Group test cases by category, one comment per category** — Functional first, then Performance, Security, Privacy, Accessibility, Resilience, Compatibility.
6. **Within each category, order test cases Critical → High → Medium → Low.**
7. **Every test case must include all 12 fields** — Why this matters · Linked to · Persona · Preconditions · Test data · Steps · Expected business outcome · How to verify · If this fails · category-specific extras where applicable. No exceptions.
8. **Test data must be concrete, copy-pasteable, and synthetic** — emails, IDs, currencies, dates, postal codes, payment cards. Mark sensitive fields with the data tags (`🔒 PII` / `💳 PCI` / `🩺 PHI`) and notable values (`🎯 boundary` / `⚠️ invalid`) in the Notes column.
9. **Coverage map must make gaps explicit** — show requirement gaps and risk gaps with severity. Hidden gaps are worse than missing tests.
10. **Developer Changes Requiring Clarification appears in Comment 3** — before any test cases. Testers need to know what to pause on.
11. **QA Sign-off uses Markdown task lists** — `- [ ]` — interactive on both GitHub and Azure DevOps.
12. **Use `<details>` / `<summary>`** for test case bodies, per-PR cards, and the "Context Gathered" block to keep comments scannable.
13. **Stay under the size budget** — target ≤ 50 KB per comment. Split a category into `Part 1 of 2`, `Part 2 of 2`, etc., at a test-case boundary.
14. **No raw diffs, no method names, no internal jargon** — file paths are permitted only inside the "Underlying File(s)" cell of the per-PR table and inside the "How to verify" sub-block of a test case.
15. **Every test case links to at least one requirement AND one business risk** — no orphan test cases.
