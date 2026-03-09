# Storage Facility Creator – Complete Cost Analysis

**Generated:** 2026-02-27  
**Source:** Live simulation via `node scripts/simulate_100_facilities.js [N] --cost`

---

## Key Corrections from Previous Report

- **DocuSign is NOT used.** The platform has a fully built-in e-signature system using `pdf-lib` (server-side PDF merging) + the `signature` Flutter package (canvas signature pad) + Firebase Storage. **Cost: $0/month.**
- **OpenAI cost recalculated** using actual token counts: `gpt-4o-mini` at $0.150/1M input tokens, $0.600/1M output tokens, with 1,500 input tokens + 380 output tokens per call (matching `MAX_OUTPUT_TOKENS = 380` in the code). The OpenAI Moderation API (called on every AI message) is **free**.
- **Stripe SaaS billing fees added** — you pay Stripe 2.9% + $0.30 per facility subscription charge each month.
- **Sentry added** — error monitoring is integrated in both Cloud Functions (`@sentry/node`) and Flutter (`sentry_flutter`). Team plan: ~$26/month.
- **Firebase Storage added** — contract PDFs (~500 KB each, ~4/facility/month) stored in Firebase Storage. Within free tier at all modeled scales.

---

## What the Platform Actually Uses

| Service | Purpose | Paid? |
|---|---|---|
| **Firebase Hosting** | Flutter web app (static CDN) | Free tier sufficient |
| **Cloud Firestore** | Primary database | Blaze pay-as-you-go |
| **Firebase Storage** | Contract PDFs, uploaded docs | Free tier sufficient at current scale |
| **Firebase Auth** | User authentication | Free |
| **Cloud Functions** | All backend logic (~80+ functions) | Pay-as-you-go |
| **Firebase App Check** | Protects all callables from abuse | Free (reCAPTCHA Enterprise free tier) |
| **Stripe Connect** | Tenant rent payments (facility owners collect) | 0 cost to you; facilities pay Stripe directly |
| **Stripe Billing** | Your SaaS subscriptions ($75/mo/facility) | 2.9% + $0.30 per charge |
| **SendGrid** | All transactional email | Usage-based |
| **Twilio** | Outbound + inbound SMS | $0.0083/message (US long-code) |
| **OpenAI** | AI assistant (`gpt-4o-mini`) + Moderation API | Per-token (moderation is free) |
| **pdf-lib** | Built-in e-signature PDF merging | Free (npm package, no API cost) |
| **Sentry** | Error monitoring (backend + frontend) | ~$26/month (Team plan) |
| **nodemailer** | Listed as dependency; SendGrid is primary | Free |

**NOT used (despite documentation):** DocuSign, Amazon SES, Google Maps API (not confirmed in code).

---

## Built-In E-Signature System

The platform does **not** use DocuSign or any third-party e-signature service. The complete signing flow is:

1. **Flutter app** — `ContractSigningScreen` uses the `signature ^6.3.0` package to render a canvas-based signature pad. The tenant draws their signature with a mouse or stylus.
2. **Cloud Function** — `mergeSignatureIntoPdf` receives the PDF + signature PNG + placement coordinates and uses `pdf-lib` to embed the signature image and typed name/date overlays directly into the PDF.
3. **Firebase Storage** — the signed PDF is uploaded and a download URL is stored in the contract document.
4. **Firestore trigger** — `onContractSigned` fires when the contract status changes to `signed`, sending a confirmation email via SendGrid.
5. **Token-based access** — tenants receive a unique `signingToken` link and can sign without creating an account.

**Total cost of e-signature: $0/month** (only Firebase Storage bandwidth, which is within the free tier).

---

## SMS Cost Controls Built Into the Code

The code has hard-coded spending guards on Twilio:

```
SMS_LIMIT_PER_TENANT    = 4 messages/month per tenant
SMS_LIMIT_PER_FACILITY  = 1,000 messages/month per facility
SMS_LIMIT_PER_ACCOUNT   = 3,000 messages/month per account
SMS_COST_PER_MESSAGE    = $0.01 (conservative estimate used for cap math)
SMS_MAX_COST_PER_FACILITY = $40/month hard cap
```

These limits are enforced in Firestore transactions before every SMS send. The monthly counter resets on the 1st of each month via `resetMonthlySMSUsage`.

At the hard cap of $40/facility/month, **100 facilities = maximum $4,000/month Twilio spend**. In practice the simulation shows ~$249/month at 100 facilities (well under the cap).

---

## Cost Breakdown by Scale

All figures are **monthly USD**. Revenue = your SaaS MRR at $75/facility/month.

### 1 Facility (just starting out)

| Line item | Cost |
|---|---|
| Firebase (Firestore + Functions) | $12.00 |
| Firebase Storage | $0.00 |
| SendGrid | $0.00 (under free tier) |
| Twilio SMS | $2.49 |
| OpenAI (AI assistant) | $0.27 |
| E-signature (built-in) | $0.00 |
| Stripe SaaS fees | $2.48 |
| Sentry | $26.00 |
| **TOTAL COSTS** | **$43.24/month** |
| **Your SaaS Revenue** | **$75/month** |
| **Net** | **+$31.76/month** |

> Note: Cloud Functions has a ~$12 base cost because the compute (GB-seconds) floor doesn't scale to zero for scheduled jobs.

---

### 10 Facilities

| Line item | Cost |
|---|---|
| Firebase (Firestore + Functions) | $12.10 |
| Firebase Storage | $0.00 |
| SendGrid | $19.95 (19k emails/mo) |
| Twilio SMS | $24.90 (3k SMS/mo) |
| OpenAI (AI assistant) | $2.72 (6k calls/mo) |
| E-signature (built-in) | $0.00 |
| Stripe SaaS fees | $24.75 |
| Sentry | $26.00 |
| **TOTAL COSTS** | **$110.41/month** |
| **Your SaaS Revenue** | **$750/month** |
| **Net** | **+$639.59/month** |

---

### 25 Facilities

| Line item | Cost |
|---|---|
| Firebase (Firestore + Functions) | $12.74 |
| Firebase Storage | $0.00 |
| SendGrid | $49.00 (45k emails/mo) |
| Twilio SMS | $62.25 (8k SMS/mo) |
| OpenAI (AI assistant) | $6.79 (15k calls/mo) |
| E-signature (built-in) | $0.00 |
| Stripe SaaS fees | $61.88 |
| Sentry | $26.00 |
| **TOTAL COSTS** | **$218.66/month** |
| **Your SaaS Revenue** | **$1,875/month** |
| **Net** | **+$1,656.34/month** |

---

### 50 Facilities

| Line item | Cost |
|---|---|
| Firebase (Firestore + Functions) | $13.96 |
| Firebase Storage | $0.00 |
| SendGrid | $49.00 (90k emails/mo) |
| Twilio SMS | $124.50 (15k SMS/mo) |
| OpenAI (AI assistant) | $13.59 (30k calls/mo) |
| E-signature (built-in) | $0.00 |
| Stripe SaaS fees | $123.75 |
| Sentry | $26.00 |
| **TOTAL COSTS** | **$350.81/month** |
| **Your SaaS Revenue** | **$3,750/month** |
| **Net** | **+$3,399.19/month** |

---

### 100 Facilities ← Primary target scenario

| Line item | Cost | Notes |
|---|---|---|
| Firestore reads | $4.16 | 13.88M billable reads/month |
| Firestore writes | $0.00 | Under free tier |
| Firestore storage | $0.00 | Under free tier |
| Cloud Functions | $12.08 | ~213k invocations/month |
| Firebase Storage | $0.00 | ~200 MB/month new PDFs |
| **Firebase subtotal** | **$16.24** | |
| SendGrid | $89.95 | 180k emails/month — requires Pro plan |
| Twilio SMS | $249.00 | 30k SMS/month @ $0.0083/msg |
| OpenAI (gpt-4o-mini) | $27.18 | 60k calls/mo, 1,500 in + 380 out tokens |
| E-signature (built-in) | $0.00 | pdf-lib + Firebase Storage |
| Stripe SaaS fees | $247.50 | 2.9%+$0.30 × 100 charges |
| Sentry | $26.00 | Team plan |
| **TOTAL COSTS** | **$655.88/month** | |
| **Your SaaS Revenue** | **$7,500/month** | 100 × $75 |
| **Net profit** | **+$6,844.12/month** | Before your own salary/overhead |

---

### Scaling summary table

| Facilities | Monthly Costs | Your Revenue | Net |
|---|---|---|---|
| 1 | $43 | $75 | +$32 |
| 10 | $110 | $750 | +$640 |
| 25 | $219 | $1,875 | +$1,656 |
| 50 | $351 | $3,750 | +$3,399 |
| **100** | **$656** | **$7,500** | **+$6,844** |
| 200 (projected) | ~$1,100 | $15,000 | ~+$13,900 |
| 500 (projected) | ~$2,400 | $37,500 | ~+$35,100 |

> Cost grows sub-linearly because Firebase and Cloud Functions have base costs that don't scale 1:1 with facility count. Revenue grows linearly at $75/facility. **Margins improve significantly at scale.**

---

## Cost Driver Analysis

### What costs the most at 100 facilities

1. **Stripe SaaS fees: $247.50/month (37.7% of costs)**  
   You pay Stripe 2.9% + $0.30 on each facility's $75/month subscription charge. This is unavoidable if you use Stripe for billing. At scale, consider ACH/bank transfer billing (0.8% capped at $5) to reduce this to ~$80/month for 100 facilities.

2. **Twilio SMS: $249.00/month (37.9% of costs)**  
   The largest variable cost. The code has a $40/facility/month hard cap. At 10 SMS/facility/day the cost is $249/month. Reducing to email-only reminders (or SMS only for overdue notices) could cut this to $50–100/month.

3. **SendGrid: $89.95/month (13.7% of costs)**  
   180k emails/month requires the Pro plan ($89.95). At 100 facilities this is fixed-tier pricing — sending 90k or 180k costs the same. Efficient.

4. **OpenAI: $27.18/month (4.1% of costs)**  
   Surprisingly cheap. `gpt-4o-mini` is very cost-effective. The 20-questions/day/facility cap keeps this predictable. Even at full usage (2,000 calls/day), cost is only $27/month.

5. **Firebase: $16.24/month (2.5% of costs)**  
   Extremely efficient. Firestore, Cloud Functions, Hosting, and Storage together cost only $16/month at 100 facilities.

6. **Sentry: $26.00/month (4.0% of costs)**  
   Fixed cost for error monitoring. Worth it for production reliability.

---

## Cost Optimization Opportunities

| Opportunity | Current cost | Optimized cost | Savings |
|---|---|---|---|
| Switch SaaS billing to ACH (Stripe) | $247.50 | ~$80 | **~$167/month** |
| Reduce SMS to overdue-only (not reminders) | $249.00 | ~$80 | **~$169/month** |
| Downgrade SendGrid if email volume drops | $89.95 | $49.00 | **~$41/month** |
| Use Sentry free tier (5k errors/mo) if error rate is low | $26.00 | $0 | **$26/month** |
| **Total potential savings** | | | **~$403/month** |

With all optimizations, costs at 100 facilities could be as low as **~$253/month** against $7,500 revenue — a **97% gross margin**.

---

## What You Do NOT Pay For

- **E-signatures** — built-in, $0
- **DocuSign** — not integrated
- **Google Maps** — not confirmed as used in production code
- **Amazon SES** — referenced in some Flutter service files but SendGrid is the active provider
- **Tenant Stripe fees** — tenants pay Stripe directly through Connect; you receive 0% application fee by default
- **Firebase Auth** — free for email/password auth at any volume
- **Firebase App Check** — free (reCAPTCHA Enterprise free tier covers normal usage)

---

## Revenue Model Summary

Your SaaS pricing is hardcoded in the Cloud Functions:

- **$75/month** — base plan (first facility)
- **$75/month** — each additional facility (quantity add-on)
- **30-day free trial** — no credit card required

Two subscription modes exist:
1. **Account-level** — one subscription covers all facilities under an account
2. **Per-facility** — each facility has its own subscription and payment method

At 100 paying facilities: **$7,500 MRR** → **$90,000 ARR**  
At 500 paying facilities: **$37,500 MRR** → **$450,000 ARR**

---

*Re-run with `node scripts/simulate_100_facilities.js [N] --cost` to update projections for any facility count.*
