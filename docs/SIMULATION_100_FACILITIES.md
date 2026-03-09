# Simulation: 100 Paying Facilities

This document models how **Storage Facility Creator** would run with **100 paying facilities** using realistic assumptions for data volume, Firestore usage, Cloud Functions, and third-party services.

---

## 1. Assumptions

### Facility mix (100 facilities)

| Tier        | Count | Units/facility | Occupancy | Tenants | Notes                    |
|------------|-------|----------------|-----------|---------|--------------------------|
| Small      | 40    | 50–150         | 75%       | ~4,000  | Single-site operators    |
| Medium     | 45    | 150–400        | 78%       | ~11,000 | Regional operators       |
| Large      | 15    | 400–800        | 80%       | ~9,000  | Multi-site / enterprise  |

**Totals (rounded):**

- **Facilities:** 100  
- **Units:** ~24,000  
- **Active tenants:** ~24,000  
- **Avg units per facility:** 240  
- **Avg tenants per facility:** 240  

### Activity assumptions (per facility per day)

- **Manager logins:** 2–4  
- **Tenant portal logins:** 5–15% of tenants (e.g. 12–36 per facility)  
- **New move-ins:** ~0.5% of units/month → ~4 move-ins/facility/month  
- **Move-outs:** similar to move-ins  
- **Payments (one-time + autopay):** ~8% of tenants pay on a given day  
- **Contract/lease actions:** ~2–3 per facility per day  
- **SMS:** ~5–20 per facility per day  
- **Emails (notifications, reminders):** ~30–80 per facility per day  

---

## 2. Firestore

### Document counts (steady state)

| Collection / path | Est. count | Notes |
|-------------------|------------|--------|
| `facilities` | 100 | Top-level |
| `facilities/{id}/units` | ~24,000 | All facilities |
| `facilities/{id}/tenants` | ~24,000 | Active tenants |
| `facilities/{id}/contracts` | ~30,000 | Current + recent (e.g. 1.25 per tenant) |
| `facilities/{id}/invoices` | ~72,000 | ~3 per active tenant (current + 2 months) |
| `facilities/{id}/ledgers` | ~500,000+ | Grows with charges/payments |
| `facilities/{id}/tenants/{id}/payments` | ~100,000+ | Payment records |
| `facilities/{id}/stats/current` | 100 | One doc per facility |
| Other (reminders, DNR, messages, etc.) | ~50,000 | Conservative |

**Rough total:** ~850,000+ documents.

### Reads/writes (estimates)

**Client-side (Flutter app):**

- **Per manager session:** 20–80 reads (facility, units, tenants, dashboard, list pages).  
- **Per tenant portal session:** 10–30 reads.  
- **Daily (100 facilities):**  
  - Manager: 100 × 3 × 50 ≈ **15,000 reads**  
  - Tenant: 100 × 24 × 15 ≈ **36,000 reads**  
  - **Total client reads:** ~**50,000–60,000/day**

**Backend (Cloud Functions):**

- Triggered by writes: `onTenantWrite`, `onUnitWrite` (each does 2 queries + 2 writes per facility).  
  - ~50 tenant writes/day × 100 facilities → 5,000 trigger runs → ~20,000 reads + ~10,000 writes from triggers alone (order of magnitude).  
- Scheduled jobs (below) add the bulk of backend reads/writes.

**Scheduled jobs (all facilities):**

Each job typically: 1 read for `facilities` + 100 × (1 + per-facility queries).

| Job | Schedule | Facilities | Per facility (approx) | Est. reads/run | Est. writes/run |
|-----|----------|------------|------------------------|----------------|-----------------|
| updateAllFacilityStatsNightly | 2 AM | 100 | units + tenants | ~500,000 | ~200 |
| scheduledGenerateMonthlyRentCharges | 1st, 00:00 UTC | 100 | tenants, ledgers | ~250,000 | ~25,000 |
| processAutopayPayments | 2 AM UTC | 100 | tenants, payment methods, ledgers | ~300,000 | ~5,000 |
| processDelinquencyAutomation | 3 AM UTC | 100 | tenants, invoices, ledgers | ~400,000 | ~2,000 |
| processPaymentReminders | 9 AM UTC | 100 | tenants | ~250,000 | ~500 |
| autoProtectMoveIn | 4 AM | 100 | tenants (filtered) | ~100,000 | ~100 |
| checkInsuranceCompliance | 4:30 AM | 100 | tenants (filtered) | ~100,000 | ~200 |
| autoProtectAudit | 1st, 5 AM | 100 | tenants | ~250,000 | ~500 |
| sendDailyDigests | 8 AM CST | 100 | varies | ~50,000 | 0 |
| resetMonthlySMSUsage | 1st, 00:00 UTC | 1 (global) | - | ~100 | ~1 |

**Rough daily backend (scheduled):** ~2–3 million reads, ~30,000–40,000 writes on a typical day; **monthly rent day** adds a large one-time spike (e.g. +250k reads, +25k writes).

**Total Firestore (ballpark):**

- **Reads:** ~2.5–3.5 million/day (scheduled + triggers + client).  
- **Writes:** ~40,000–60,000/day (excluding monthly rent day).  

Firestore free tier (50k reads, 20k writes/day) is exceeded many times over; **Blaze (pay-as-you-go)** is required.

---

## 3. Cloud Functions

### Invocations

**User-invoked (callables):**

- Auth, Stripe (SetupIntent, PaymentIntent, Connect), SMS, email, move-out, overlock, AI assistant, etc.  
- Estimate: **2,000–5,000 invocations/day** across 100 facilities (managers + tenants).

**Firestore triggers:**

- `onTenantWrite`, `onUnitWrite`: every tenant/unit create/update.  
  - ~100 tenant writes + ~80 unit writes per day → **~180 invocations/day** (low); with bulk imports or syncs, can spike to thousands.

**Scheduled (Pub/Sub):**

| Function | Invocations/day |
|----------|------------------|
| updateAllFacilityStatsNightly | 1 |
| processAutopayPayments | 1 |
| processDelinquencyAutomation | 1 |
| processPaymentReminders | 1 |
| autoProtectMoveIn | 1 |
| checkInsuranceCompliance | 1 |
| sendDailyDigests | 1 |
| updateAllFacilityStatsNightly (facility_stats) | 1 |
| resetMonthlySMSUsage | ~0.033 (monthly) |
| scheduledGenerateMonthlyRentCharges | ~0.033 (monthly) |
| autoProtectAudit | ~0.033 (monthly) |

**Total:** ~7 scheduled invocations per day + 2–3 per month.

**Rough total invocations:** **~2,200–5,200/day** (dominated by callables).

### Execution time and memory

- **Stats triggers (`onTenantWrite` / `onUnitWrite`):** Each loads all units + all active tenants for one facility. For a 500-unit facility that’s 500 + 400 ≈ 900 reads. At 240 units/facility average, ~480 reads per run. **Risk:** Cold starts and 60s timeout on very large facilities.  
- **Scheduled jobs:** Sequential `for` over 100 facilities; each facility does multiple Firestore round-trips. **Risk:** Total run can approach or exceed 9 minutes (default timeout) if facilities or tenants grow.  
- **Stripe / SendGrid / Twilio:** Network-bound; typically well under 60s per invocation.

---

## 4. Third-party services

### Stripe

- **Connect:** 100 connected accounts (one per facility).  
- **Payments:** ~8% of 24,000 tenants paying on a given day → ~2,000 payments/day; many via autopay (batched in one scheduled run).  
- **API calls:** Checkout, PaymentIntent, SetupIntent, Customer, webhooks. Estimate **5,000–15,000 Stripe API calls/day** at this scale.

### SendGrid

- **Emails:** Reminders, digests, move-in/out, delinquency, system. **3,000–8,000 emails/day** across 100 facilities.

### Twilio (SMS)

- **SMS:** ~5–20 per facility per day → **500–2,000 SMS/day**.

### OpenAI (AI Assistant)

- **Limit:** Facility owners get **20 questions per day** per account (config: `maxMessagesPerUser: 20`; facility cap `maxMessagesPerDay: 30` in app config).
- **Usage:** At 100 facilities, max **2,000 AI calls/day** if every facility uses the full 20; typical usage is lower.

---

## 5. Bottlenecks and risks

1. **Scheduled jobs iterate all 100 facilities in one run**  
   - Single 9-minute function can’t scale to many more facilities without batching (e.g. queue per facility or sharding).  
   - **Recommendation:** Move to per-facility or batched execution (e.g. Cloud Tasks) for: monthly rent, autopay, delinquency, reminders, insurance, digests, nightly stats.

2. **Stats triggers read full unit + tenant sets**  
   - Large facilities (e.g. 500+ units) can approach timeout and increase Firestore read cost.  
   - **Recommendation:** Consider incremental stats or caching if facilities grow beyond ~500 units.

3. **Firestore read cost**  
   - At ~3M reads/day, cost is significant on Blaze.  
   - **Recommendation:** Reduce redundant reads (e.g. cache facility list, avoid re-querying same tenant set in one function), use composite indexes already defined.

4. **Stripe rate limits**  
   - Stripe allows high request rates; 100 Connect accounts and ~2k payments/day are within normal usage.  
   - **Recommendation:** Keep webhook handling idempotent and within Stripe’s retry window.

5. **Single-region and cold starts**  
   - All functions in one project/region; cold starts add latency for first request.  
   - **Recommendation:** Use min instances for critical callables if latency matters.

---

## 6. Summary table (typical day, 100 facilities)

*Run `node scripts/simulate_100_facilities.js` for numeric output.*

| Resource | Estimated usage (script) | Upper bound (doc) |
|----------|--------------------------|--------------------|
| Firestore reads | ~500k/day | ~2.5–3.5M/day (if all jobs do heavy queries) |
| Firestore writes | ~3k–60k/day | Higher on 1st of month |
| Cloud Function invocations | ~7k/day | ~2k–5k callables + triggers + 7 scheduled |
| Stripe API calls | ~10k/day | ~5k–15k/day |
| SendGrid emails | ~6k/day | ~3k–8k/day |
| Twilio SMS | ~1k/day | ~500–2k/day |
| OpenAI (AI Assistant) | 2,000/day (20/facility cap) | Config: 20 questions/day per facility owner |
| DocuSign (e-sign, planned) | ~400 envelopes/month | New leases + renewals |
| Firestore doc count | ~765k | ~850k+ |

**Verdict:** The system can run with **100 paying facilities** on Firebase Blaze and current architecture. The main limits are **scheduled job design** (single function over all facilities) and **Firestore read volume**; both should be addressed before scaling to hundreds more facilities.

---

## 7. Cost estimate (what costs you money)

All figures are **monthly USD**, approximate, for **100 paying facilities** using the simulation’s typical-day usage. Prices are public pay-as-you-go (no enterprise discounts). Your actual bill depends on region, commitment discounts, and usage spikes.

### Firebase (Google Cloud, Blaze plan)

| Item | Usage (approx) | Unit price | Monthly cost |
|------|-----------------|------------|--------------|
| **Firestore reads** | ~15M/month (500k/day × 30) | $0.03 per 100k (after 50k/day free) | ~\$42 |
| **Firestore writes** | ~90k/month (3k/day × 30) + spike on 1st | $0.09 per 100k (after 20k/day free) | ~\$8 |
| **Firestore storage** | ~2–5 GiB (765k docs, small payloads) | $0.000205/GiB-month (1 GiB free) | ~\$1 |
| **Cloud Functions** | ~210k invocations/month, compute time | Invocations + GB-sec (region-dependent) | ~\$15–\$40 |
| **Firebase Hosting** | Low (static web) | 10 GB / 360 MB/day free | \$0 |
| **Firebase Auth** | No phone-auth volume assumed | Free tier | \$0 |

**Firebase subtotal: ~\$66–\$91/month** (could be higher if reads spike or functions run long).

### Stripe (your platform)

- **Connect:** No per-account fee for standard Connect; facilities pay Stripe 2.9% + 30¢ per tenant payment. You pay Stripe nothing for Connect flows if you take 0% application fee.
- **Your own billing:** If you charge facilities a subscription (e.g. SFC subscription), you pay Stripe **2.9% + 30¢** on each invoice payment (e.g. 100 facilities × 1 charge ≈ \$3 + ~\$30 = ~\$33/month in Stripe fees on ~\$X revenue).

**Stripe cost to you: ~\$0 for tenant payments; ~\$30–\$50/month** if you bill 100 facilities via Stripe for your SaaS.

### SendGrid (email)

| Item | Usage (approx) | Notes | Monthly cost |
|------|----------------|--------|--------------|
| **Transactional email** | ~180k/month (6k/day × 30) | Free tier ~3k/month | **~\$20–\$90** (Essentials/Pro or volume) |

### Twilio (SMS)

| Item | Usage (approx) | Unit price | Monthly cost |
|------|----------------|------------|--------------|
| **Outbound SMS (US)** | ~30k/month (1k/day × 30) | ~\$0.0083/msg (carrier fees can add) | **~\$250** |

SMS is the largest variable cost at this volume. Reducing reminders to email-only or per-facility SMS caps would lower this.

### OpenAI (AI Assistant)

- **Limit:** 20 questions per day per facility owner (enforced in `aiAssistantChat` via `maxMessagesPerUser` and `maxMessagesPerDay` in app config).
| Item | Usage (approx) | Assumption | Monthly cost |
|------|----------------|------------|--------------|
| **API calls** | Up to 60k/month (20 × 100 facilities × 30 days) | ~2k tokens in + 1k out per call (GPT-4o mini); actual usage often lower | **~\$50–\$150** at full use; **~\$5–\$30** at typical use |

### DocuSign (e-signature, planned)

- **Feature:** DocuSign API integration for sending lease/contract envelopes and receiving completed signatures (to replace or complement in-app signing).
| Item | Usage (approx) | Notes | Monthly cost |
|------|----------------|--------|--------------|
| **Envelopes** | ~400/month (100 facilities × ~4 contracts) | New leases, renewals, amendments | **~\$50** (Starter 40 incl.) **+\$1,440** overage at ~\$4/envelope, or **~\$300+** on higher plans with more included |

### Summary: total out-of-pocket (100 facilities)

| Category | Low | High |
|----------|-----|------|
| Firebase (Firestore + Functions) | \$66 | \$91 |
| Stripe (your SaaS billing only) | \$0 | \$50 |
| SendGrid | \$20 | \$90 |
| Twilio (SMS) | \$250 | \$280 |
| OpenAI (AI; 20/facility/day cap) | \$5 | \$150 |
| DocuSign (e-sign, planned) | \$50 | \$400+ |
| **Total** | **~\$391** | **~\$1,061** |

**Rough total: ~\$400–\$1,100/month** at 100 facilities depending on AI and DocuSign usage. **SMS (Twilio)** and **SendGrid** are the main fixed drivers; **OpenAI** at full 20 questions/facility/day increases cost; **DocuSign** adds meaningful cost once the API is integrated (plan choice and envelope volume matter). Cutting SMS (e.g. email-only reminders) could save ~\$250/month. Firestore cost grows with read volume; optimizing scheduled jobs and caching would reduce it.

Run the script with cost output:  
`node scripts/simulate_100_facilities.js 100 --cost`

---

## 8. Running the numeric simulation

A small script is provided to print these estimates with configurable facility count and tier mix:

```bash
node scripts/simulate_100_facilities.js
```

Optional: pass facility count (e.g. `200`) or add `--cost` for a monthly cost estimate (e.g. `node scripts/simulate_100_facilities.js 100 --cost`).
