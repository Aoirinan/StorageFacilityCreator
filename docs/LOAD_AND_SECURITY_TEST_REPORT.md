# Storage Facility Creator – Comprehensive Load, Security & UX Test Report

**Generated:** 2026-02-27  
**Updated:** 2026-09-01 — added measured results from the 2026-08-31 production load run (see [Trigger amplification](#measured-trigger-amplification-2026-08-31-production-run))  
**Simulation engine:** `node scripts/simulate_100_facilities.js [N] --cost`  
**Scenarios modeled:** 100 concurrent users (baseline) and 500 concurrent users (stress spike)

---

## Table of Contents

1. [Stress Testing (100 → 500 users)](#1-stress-testing)
2. [Database Performance](#2-database-performance)
3. [Concurrency Handling](#3-concurrency-handling)
4. [Error Handling & Logging](#4-error-handling--logging)
5. [API Rate Limiting](#5-api-rate-limiting)
6. [Load Balancing & Auto-Scaling](#6-load-balancing--auto-scaling)
7. [Security Testing](#7-security-testing)
8. [Session Management](#8-session-management)
9. [User Journey & UX Testing](#9-user-journey--ux-testing)
10. [Payment Gateway Testing](#10-payment-gateway-testing)
11. [API Security](#11-api-security)
12. [Backup & Recovery](#12-backup--recovery)
13. [Cross-Browser & Mobile Testing](#13-cross-browser--mobile-testing)
14. [Third-Party Integrations](#14-third-party-integrations)
15. [Analytics & Metrics](#15-analytics--metrics)
16. [SendGrid & Twilio Cost Simulation](#16-sendgrid--twilio-cost-simulation)
17. [Server Performance Summary](#17-server-performance-summary)
18. [Recommendations & Priority Actions](#18-recommendations--priority-actions)

---

## 1. Stress Testing

### Simulation output – 100 facilities (baseline)

```
Facilities:        100
Total units:       25,375
Active tenants:    19,853
Avg units/facility:   254
Avg tenants/facility:  199
Tier mix:          small 40, medium 45, large 15

Firestore reads/day:   510,552
Firestore writes/day:    2,897
Cloud Function invocations/day: 7,077
  ├─ Trigger:    700
  ├─ Callable:   6,370
  └─ Scheduled:  7
```

### Simulation output – 500 facilities (5× stress spike)

```
Facilities:        500
Total units:       126,875
Active tenants:    99,263

Firestore reads/day:   2,552,747  (+400%)
Firestore writes/day:     14,485  (+400%)
Cloud Function invocations/day: 35,359  (+400%)
  ├─ Trigger:    3,500
  ├─ Callable:   31,852
  └─ Scheduled:  7
Stripe API calls/day:  49,705
SendGrid emails/day:   29,963
Twilio SMS/day:         5,000
```

### Performance bottlenecks identified

| Bottleneck | Severity | Detail |
|---|---|---|
| Scheduled jobs iterate all facilities in one Cloud Function | **HIGH** | A single function processing 500 facilities sequentially can exceed the 9-minute default timeout. At 100 facilities the nightly stats job reads ~148k docs; at 500 it reads ~740k. |
| `onTenantWrite` / `onUnitWrite` triggers load full unit+tenant sets | **MEDIUM** | Each trigger re-reads all units + all active tenants for the facility (~480 reads at 240-unit average). Under bulk imports this can cause thousands of parallel trigger invocations. |
| No connection pooling on Firestore (serverless model) | **LOW** | Firebase/Firestore handles connection management; cold starts add 200–800 ms latency on first request per function instance. |
| Monthly rent spike (1st of month) | **MEDIUM** | +59,701 reads and +19,953 writes in a single scheduled run at 100 facilities; +298,501 reads and +99,763 writes at 500 facilities. |

### Response time expectations under load

| Scenario | Expected p50 | Expected p95 | Risk |
|---|---|---|---|
| Manager dashboard load (100 facilities) | 300–600 ms | 1.2 s | Low |
| Manager dashboard load (500 facilities, spike) | 400–900 ms | 2.5 s | Medium |
| Tenant portal login + load | 500–800 ms | 1.8 s | Low |
| Callable: `createPaymentIntent` | 800–1,200 ms | 3 s | Medium (Stripe round-trip) |
| Callable: `aiAssistantChat` | 1,500–4,000 ms | 8 s | Medium (OpenAI round-trip) |
| Scheduled: nightly stats (100 facilities) | 2–4 min | 6 min | Medium |
| Scheduled: nightly stats (500 facilities) | 8–12 min | **TIMEOUT RISK** | **HIGH** |

### Verdict

The system handles **100 concurrent facilities** comfortably on the current architecture. Scaling to **500 facilities** requires refactoring scheduled jobs to use **Cloud Tasks** (per-facility fan-out) to avoid timeout risk. All other components (Firestore, Stripe, SendGrid, Twilio) remain within their respective service limits at 500 facilities.

---

## 2. Database Performance

### Firestore read/write profile

| Metric | 100 facilities/day | 500 facilities/day |
|---|---|---|
| Total reads | 510,552 | 2,552,747 |
| Total writes | 2,897 | 14,485 |
| Monthly rent day reads (spike) | +59,701 | +298,501 |
| Monthly rent day writes (spike) | +19,953 | +99,763 |
| Total document count | ~765,099 | ~3,825,422 |
| Blaze plan required | Yes | Yes |

### Measured: trigger amplification (2026-08-31 production run)

The projections above model reads from **user sessions only**. They do not account for
Firestore trigger fan-out. A live load run on 2026-08-31, 05:00–06:00 UTC, exposed the gap.

| Measure | Value |
|---|---|
| Tenant documents written | ~30,000 |
| `onTenantWrite` invocations | 30,005 |
| `syncPublicFacilityMapInventoryOnTenantWrite` invocations | 30,000 |
| Firestore reads in that single hour | 5,085,165 |
| Reads per one tenant write | ~167 |
| Share of the whole month's reads | 96% |
| Billed cost | $3.06 |

**Cause.** `onTenantWrite` called `computeFacilityStats()` on every write, and that function
reads the facility doc, the full `units` collection, and the `tenants` collection twice. So a
single tenant write costs `1 + units + (2 × tenants)` reads. The `LOADTEST-fac-*` facilities
were small; a real 500-unit, 500-tenant facility would cost roughly **1,500 reads per single
tenant edit**.

**Calibration.** This table projects 510,552 reads/day at 100 facilities. The actual run produced
ten times that in one hour at a comparable facility count, because
`scripts/simulate_100_facilities.js` has no model for trigger fan-out. Treat the read
projections above as a floor, not an estimate, until that model is added.

**Why it matters.** The dollar figure is trivial and the test data has since been removed. The
pattern is not: any bulk write path — `backfillContractComplianceFields`, a data import, a
migration, or a re-run of this very test — re-triggers it, and the cost scales with facility
size rather than with the size of the change. Addressed on branch
`fix/facility-stats-trigger-amplification` by collapsing a burst into one recompute; **not yet
merged or deployed** as of 2026-09-01.


### Query performance

- **Composite indexes** are defined in `firestore.indexes.json` for the most common query patterns (tenants by facility + status, invoices by due date, ledgers by tenant).
- **Reads per manager session:** ~50 (facility doc, units list, tenants list, dashboard stats, recent payments).
- **Reads per tenant portal session:** ~15 (tenant doc, unit doc, invoices, contracts).
- **Hotspot risk:** The `facilities/{id}/ledgers` subcollection grows unboundedly (~25 docs/tenant historically). At 19,853 tenants that is ~496,325 ledger docs. Queries scoped to a single facility remain fast; cross-facility aggregation queries are not used.

### Concurrency on write paths

- Firestore uses **optimistic concurrency** (document versioning). The stats trigger (`onTenantWrite`) reads and writes the `facilities/{id}/stats/current` document; if two tenant writes arrive within milliseconds for the same facility, both triggers run and the second write wins (last-write-wins on the stats doc). This is acceptable for aggregate stats but should be monitored.
- **Recommendation:** Use Firestore **transactions** or **FieldValue.increment** for all counter fields in stats documents to make concurrent increments safe.

### Data integrity under concurrent load

- Payment records are written inside Cloud Functions using `admin.firestore().runTransaction()` for the ledger + invoice update pair — this prevents double-charging.
- Autopay batch (`processAutopayPayments`) processes tenants sequentially within each facility; parallel facility processing is not implemented, which avoids cross-facility write conflicts but increases run time.

---

## 3. Concurrency Handling

### Scenario: two managers editing the same tenant simultaneously

**Current behavior:**  
Firestore does not use pessimistic locking. If Manager A and Manager B both open Tenant X's record and save changes within the same second, the last write wins. The Flutter app uses `set(..., merge: true)` or `update()` which applies field-level patches, reducing (but not eliminating) conflict risk.

**Risk level:** Medium for payment status updates; Low for profile edits.

**Recommendation:**  
For payment status fields (`isPastDue`, `balance`, `lastPaymentDate`) use `FieldValue.increment` and server-side transactions rather than client-side reads followed by writes.

### Scenario: concurrent contract signing

**Current behavior:**  
Contract signing writes a `signedAt` timestamp and `status: 'signed'` to the contract document. If two parties attempt to sign simultaneously (unlikely but possible in shared-access scenarios), both writes succeed and the last one sets the final state.

**Recommendation:**  
Wrap the contract signing write in a Firestore transaction that checks `status !== 'signed'` before committing, to make signing idempotent.

### Scenario: concurrent autopay processing

**Current behavior:**  
`processAutopayPayments` iterates tenants sequentially. Each tenant's payment is wrapped in a try/catch; a failure on one tenant does not block others. Stripe `PaymentIntent` creation is idempotent via `idempotencyKey`.

**Race condition risk:** If the scheduled job is triggered twice (e.g., a manual retry while the scheduled run is still in progress), two payment attempts could be made for the same tenant. The `idempotencyKey` passed to Stripe prevents duplicate charges at the Stripe layer, but the Firestore ledger write could still be duplicated.

**Recommendation:**  
Add a `processingLock` field to the facility document, set at job start and cleared at job end, to prevent concurrent runs of the same scheduled job for the same facility.

---

## 4. Error Handling & Logging

### Error handling coverage

| Error type | Handled? | User message | Logged? |
|---|---|---|---|
| Invalid user input (empty fields, bad email) | Yes – Flutter validators | Inline field error | No (client-side only) |
| Failed Stripe API call | Yes – try/catch in callable | `HttpsError` returned to client | Yes – `functions.logger.error` |
| Failed SendGrid send | Yes – try/catch | Silent fail or error toast | Yes – `functions.logger.error` |
| Failed Twilio SMS | Yes – try/catch | Silent fail | Yes – `functions.logger.error` |
| Firestore permission denied | Partial – caught in some flows | Generic error toast | Yes – Firestore audit log |
| OpenAI API error / timeout | Yes – try/catch in `aiAssistantChat` | "AI assistant unavailable" message | Yes |
| Stripe webhook signature mismatch | Yes – `stripe.webhooks.constructEvent` throws | 400 response | Yes |
| Unauthenticated callable invocation | Yes – `context.auth` check | `unauthenticated` HttpsError | Yes |

### Sensitive data in logs

- Sentry integration (`@sentry/node`) is initialized in `functions/src/index.ts` with a `beforeSend` hook that:
  - Removes request body from payment/Stripe/checkout endpoints.
  - Redacts `email=` query parameters.
- `functions.logger` calls do **not** log Stripe keys (validated by `validateStripeKeyMode` which logs only "Stripe mode: LIVE/TEST").
- Client-supplied Stripe key injection is blocked by `rejectClientSuppliedStripeKeys()` at the start of payment callables.

### Gaps identified

1. **No structured error codes** returned to the Flutter client for most non-payment errors — the app receives a generic string. Adding error codes would improve UX and debugging.
2. **Silent SendGrid/Twilio failures** — when an email or SMS fails, the manager is not notified in the UI. A failed-notification log or retry queue would improve reliability.
3. **No dead-letter queue** for failed scheduled job items — if a tenant's autopay fails due to a transient error, it is logged but not retried until the next scheduled run (next day).

---

## 5. API Rate Limiting

### Stripe

| Metric | 100 facilities | 500 facilities | Stripe limit |
|---|---|---|---|
| API calls/day | 9,940 | 49,705 | ~25,000 req/s (effectively unlimited for normal SaaS) |
| Payments/day | 1,588 | 7,941 | No per-day limit |
| Connect accounts | 100 | 500 | No hard limit |

**Assessment:** Well within Stripe's rate limits. Stripe's default rate limit is 100 read requests/second and 100 write requests/second per secret key. The autopay batch processes ~1,588 payments sequentially; even if each takes 3 Stripe API calls, that is ~4,764 calls in one function run — well under the per-second limit.

**Graceful handling:** All Stripe calls are wrapped in try/catch. `stripe.errors.StripeRateLimitError` is not explicitly caught separately; adding a retry with exponential backoff for `429` responses is recommended.

### SendGrid

| Metric | 100 facilities/day | 500 facilities/day | SendGrid limit (Essentials) |
|---|---|---|---|
| Emails/day | 5,993 | 29,963 | 100 emails/second (burst); 40k–100k/month plan cap |

**Assessment:** At 100 facilities, 5,993 emails/day (180k/month) exceeds the Essentials 40k/month plan — upgrade to Pro or higher is required. At 500 facilities, 899k emails/month requires a custom volume plan.

**Graceful handling:** SendGrid failures are caught and logged. There is no retry queue; transient 429s from SendGrid result in a missed email.

### Twilio

| Metric | 100 facilities/day | 500 facilities/day | Twilio limit |
|---|---|---|---|
| SMS/day | 1,000 | 5,000 | ~1 msg/sec per long-code number |

**Assessment:** At 1,000 SMS/day spread across the day, a single Twilio long-code number is sufficient. At 5,000 SMS/day concentrated in a morning reminder window, throughput may be constrained. **Recommendation:** Register a Twilio Messaging Service with multiple numbers or use a short code for high-volume sends.

**Graceful handling:** Twilio errors are caught. No retry logic exists for failed SMS.

### OpenAI

| Metric | 100 facilities | 500 facilities | OpenAI limit |
|---|---|---|---|
| AI calls/day (cap) | 2,000 | 10,000 | Tier-dependent (typically 500–10,000 RPM) |

**Assessment:** The app enforces a 20-questions/day/facility cap in `aiAssistantChat`. At 100 facilities this is 2,000 calls/day maximum — manageable. The cap prevents runaway cost.

---

## 6. Load Balancing & Auto-Scaling

### Firebase / Google Cloud Functions

Cloud Functions (2nd gen) auto-scale horizontally. Each function instance handles one request at a time. Key settings:

| Function type | Default max instances | Cold start risk | Recommendation |
|---|---|---|---|
| Callable (payment, AI, SMS) | 1,000 (GCF default) | Medium (200–800 ms) | Set `minInstances: 1` for `createPaymentIntent`, `aiAssistantChat` |
| Scheduled (nightly, autopay) | 1 | Low (runs once/day) | Set timeout to 540 s; migrate to Cloud Tasks for fan-out |
| Firestore triggers | 1,000 | Medium | No change needed at current scale |

### Firebase Hosting (Flutter web)

Static assets are served from Firebase Hosting's global CDN. There is no server to scale for the web frontend — CDN handles all traffic spikes automatically.

### Firestore

Firestore auto-scales storage and throughput. The main scaling concern is **hotspot documents** (e.g., a single facility stats doc written by many concurrent triggers). Using `FieldValue.increment` eliminates hotspot write contention.

### Auto-scaling verdict

The platform **auto-scales correctly** for the web frontend and callable functions. The only manual intervention required is:
1. Increasing scheduled function timeout to 540 s (currently at default 60 s for some jobs).
2. Migrating long-running scheduled jobs to Cloud Tasks fan-out before reaching ~300 facilities.

---

## 7. Security Testing

### Authentication

| Test | Result | Notes |
|---|---|---|
| Unauthenticated callable invocation | **BLOCKED** | All callables check `context.auth`; return `unauthenticated` HttpsError |
| Super admin endpoint access by non-admin | **BLOCKED** | `isSuperAdmin()` checks against hardcoded email list + env var |
| Client-supplied Stripe key injection | **BLOCKED** | `rejectClientSuppliedStripeKeys()` rejects any payload with key fields |
| Firestore direct write without auth | **BLOCKED** | `firestore.rules` requires `request.auth != null` for all writes |
| Brute-force login | **MITIGATED** | Firebase Auth enforces rate limiting on sign-in attempts (429 after repeated failures) |
| Session hijacking | **MITIGATED** | Firebase Auth uses short-lived JWT tokens (1 hour); refresh tokens are stored in secure storage |

### Firestore security rules

The `firestore.rules` file enforces:
- Facility data readable/writable only by authenticated users with `facilityId` matching their user profile.
- Tenant portal data readable only by the tenant's own authenticated session.
- Super admin bypass for diagnostic operations.

**Gap:** Rules should be audited to ensure no collection allows `allow read: if true` (public read). Run `firebase emulators:start` with the rules test suite to verify.

### Common vulnerability assessment

| Vulnerability | Risk | Mitigation in place |
|---|---|---|
| SQL injection | **N/A** | No SQL database; Firestore uses structured queries with typed parameters |
| NoSQL injection | **LOW** | Firestore SDK does not allow arbitrary query injection; all queries are typed |
| XSS | **LOW** | Flutter web renders via canvas (CanvasKit); no raw HTML injection surface |
| CSRF | **LOW** | Firebase callable functions use HTTPS + Firebase Auth token; no cookie-based auth |
| Stripe webhook replay | **MITIGATED** | `stripe.webhooks.constructEvent` validates signature + timestamp (5-minute window) |
| Sensitive data in logs | **MITIGATED** | Sentry `beforeSend` scrubs payment data; logger never logs keys |
| Insecure direct object reference | **MITIGATED** | All Firestore reads are scoped to `facilityId` from the authenticated user's claims |
| Exposed API keys in client bundle | **LOW RISK** | Firebase config (project ID, API key) is public by design; actual secrets (Stripe, SendGrid, Twilio, OpenAI) are stored in Firebase Secrets and never sent to the client |

### SSL/TLS

- Firebase Hosting enforces HTTPS with automatic certificate provisioning (Let's Encrypt via Google).
- All Cloud Function endpoints are HTTPS-only.
- Firestore and Firebase Auth communications are TLS-encrypted.
- Data at rest in Firestore and Firebase Storage is encrypted by Google (AES-256).

### Brute-force / credential stuffing

Firebase Auth automatically rate-limits sign-in attempts per IP. For additional protection:
- **Recommendation:** Enable Firebase App Check to require a valid app attestation before any Firebase resource access.
- **Recommendation:** Enable multi-factor authentication (MFA) for facility owner accounts (2FA implementation guide exists at `2FA_IMPLEMENTATION_GUIDE.md`).

---

## 8. Session Management

### Firebase Auth token lifecycle

| Property | Value |
|---|---|
| ID token lifetime | 1 hour |
| Refresh token lifetime | Until revoked |
| Token storage (Flutter web) | `localStorage` (Firebase default) |
| Token storage (Flutter mobile) | Secure keychain via `firebase_auth` |
| Auto-refresh | Yes – Firebase SDK refreshes silently before expiry |
| Session invalidation on logout | Yes – `auth.signOut()` clears local token; refresh token is revoked server-side |

### Simultaneous login test

Firebase Auth allows the same user to be signed in on multiple devices simultaneously. Each device holds its own ID token. This is expected behavior for facility managers who may use both desktop and mobile.

**Risk:** If a manager's account is compromised, all active sessions remain valid until the refresh token is revoked. Revoking requires a server-side call to `admin.auth().revokeRefreshTokens(uid)`.

**Recommendation:** Add a "Sign out all devices" option in the manager settings screen that calls a Cloud Function to revoke all refresh tokens for the user.

### Session expiry after inactivity

The Flutter app does not currently implement client-side inactivity timeout. Firebase Auth tokens auto-refresh in the background regardless of user activity.

**Recommendation:** Implement a client-side inactivity timer (e.g., 30 minutes) that calls `auth.signOut()` and redirects to the login screen. This is especially important for shared/kiosk devices.

### Tenant portal sessions

The tenant portal uses a short-lived access code (6-digit numeric, generated by `generateAccessCode()`) for passwordless login. The access code is stored in Firestore and checked server-side.

**Gap:** The access code does not have an explicit expiry enforced in the Cloud Function — it relies on the Firestore document TTL or manual deletion. **Recommendation:** Add a `expiresAt` field to the access code document and reject codes older than 15 minutes.

---

## 9. User Journey & UX Testing

### Onboarding flow

| Step | Expected behavior | Known issues |
|---|---|---|
| Sign up / create account | Firebase Auth email+password registration | None identified |
| Create first facility | Facility form → Firestore write → redirect to dashboard | None identified |
| Add units | Bulk unit creation or individual unit form | Performance: adding 500+ units one-by-one is slow; bulk import recommended |
| Invite team member | Email invite → Firebase Auth link | Invite email delivery depends on SendGrid |
| Connect Stripe | Stripe Connect OAuth flow | Requires live Stripe keys in production |

### Payment processing flow

| Step | Expected behavior | Known issues |
|---|---|---|
| Tenant adds card | Stripe SetupIntent → saved payment method | Works in test mode; requires live keys in production |
| Autopay enrollment | Tenant opts in → `tenantAutopay` doc created | None identified |
| Monthly charge | Scheduled job creates invoice + charges card | Race condition risk on 1st of month if job runs twice (see §3) |
| Payment confirmation email | SendGrid triggered by Cloud Function | Silent failure if SendGrid quota exceeded |
| Failed payment notification | SMS via Twilio + email via SendGrid | Both channels have no retry logic |

### Contract signing flow

| Step | Expected behavior | Known issues |
|---|---|---|
| Manager sends contract | Contract doc created with `status: pending` | None identified |
| Tenant signs | Signature captured in app → `status: signed` | Concurrent signing not protected by transaction (see §3) |
| PDF generation | `pdf-lib` generates signed PDF → Firebase Storage | Large PDFs (>10 MB) may approach Cloud Function memory limit (256 MB default) |
| DocuSign integration | Planned – not yet live | See `docs/DOCUSIGN_INTEGRATION.md` |

### Report generation

| Report | Load time (estimated) | Notes |
|---|---|---|
| Occupancy report (100 units) | < 1 s | Reads from `stats/current` doc |
| Ledger report (1,000 entries) | 1–3 s | Paginated query; first page fast |
| Export to CSV | 2–10 s | Cloud Function generates file; depends on tenant count |

### Responsive design

The Flutter web app uses CanvasKit rendering. It is responsive across screen sizes but does not use native HTML/CSS breakpoints — layout is controlled by Flutter's `LayoutBuilder` and `MediaQuery`.

| Device | Status |
|---|---|
| Desktop (1920×1080) | Fully supported |
| Laptop (1366×768) | Fully supported |
| Tablet (768×1024) | Supported; some dialogs may be cramped |
| Mobile (375×812) | Functional; data tables require horizontal scroll |

---

## 10. Payment Gateway Testing

### Stripe test scenarios

| Scenario | Test card | Expected result |
|---|---|---|
| Successful payment | `4242 4242 4242 4242` | PaymentIntent `succeeded`; ledger updated; receipt email sent |
| Card declined | `4000 0000 0000 0002` | PaymentIntent `payment_failed`; tenant notified via SMS/email |
| Insufficient funds | `4000 0000 0000 9995` | PaymentIntent `payment_failed`; retry logic not implemented |
| 3D Secure required | `4000 0025 0000 3155` | Requires redirect; tenant portal handles redirect flow |
| Refund | Stripe dashboard or API | `charge.refunded` webhook → ledger credit entry |
| Partial payment | Manual payment entry in app | Ledger records partial amount; balance updated |
| Autopay retry | Simulated by re-running autopay job | Idempotency key prevents duplicate charge at Stripe layer |

### Webhook handling

The Stripe webhook endpoint (`stripeWebhook` Express handler) processes:
- `payment_intent.succeeded` → update ledger, send receipt
- `payment_intent.payment_failed` → update tenant status, send failure notification
- `customer.subscription.updated` / `deleted` → update facility subscription status
- `invoice.payment_succeeded` / `invoice.payment_failed` → SaaS billing events

**Idempotency:** Webhook events are not deduplicated in Firestore — if Stripe retries a webhook, the handler may process it twice. **Recommendation:** Store processed webhook event IDs in a Firestore collection and skip already-processed events.

### Payment notification chain

```
Stripe webhook → Cloud Function → Firestore write → SendGrid email + Twilio SMS
```

If SendGrid or Twilio fails, the payment record is still updated in Firestore. The notification failure is logged but not retried. At scale (1,588 payments/day at 100 facilities), even a 1% SendGrid failure rate means ~16 missed receipt emails per day.

---

## 11. API Security

### Callable function security

All Cloud Functions callables enforce:

```typescript
if (!context.auth) {
  throw new functions.https.HttpsError('unauthenticated', 'Must be signed in.');
}
```

Facility-scoped operations additionally verify:
```typescript
if (context.auth.uid !== facilityOwnerId && !isSuperAdmin(context.auth.token.email)) {
  throw new functions.https.HttpsError('permission-denied', 'Not authorized for this facility.');
}
```

### JWT token validation

Firebase Auth ID tokens are validated automatically by the Firebase Functions SDK via `context.auth`. No manual JWT parsing is required or performed.

### Stripe webhook signature

```typescript
const event = stripe.webhooks.constructEvent(rawBody, sig, STRIPE_WEBHOOK_SECRET.value());
```

This validates the `Stripe-Signature` header using HMAC-SHA256. Requests without a valid signature return 400.

### Unauthorized access simulation results

| Attack vector | Result |
|---|---|
| Call `createPaymentIntent` without auth token | `unauthenticated` error (403 equivalent) |
| Call `createPaymentIntent` with valid token but wrong `facilityId` | `permission-denied` error |
| POST to `/stripeWebhook` without valid signature | 400 Bad Request |
| Read `facilities/{id}/tenants` without auth (Firestore REST) | 403 from Firestore rules |
| Inject Stripe key in callable payload | Rejected by `rejectClientSuppliedStripeKeys()` |

---

## 12. Backup & Recovery

### Firebase / Firestore backup

| Mechanism | Status | Notes |
|---|---|---|
| Firestore automated backups | **Not configured** | Must be enabled in Firebase console (Blaze plan required) |
| Firebase Storage backups | **Not configured** | Contract PDFs, uploaded documents not backed up |
| Point-in-time recovery | Available on Firestore (up to 7 days) | Must be enabled per database |
| Export to GCS | Manual / scheduled | `gcloud firestore export gs://bucket` |

**Gap:** No automated backup schedule is configured. This is a critical gap for a production SaaS.

**Recommendation:**
1. Enable Firestore **point-in-time recovery** (PITR) in the Firebase console.
2. Schedule a daily Firestore export to a Google Cloud Storage bucket using Cloud Scheduler + a Cloud Function or `gcloud` CLI.
3. Enable Firebase Storage versioning for the contract PDF bucket.
4. Test restoration quarterly: import a GCS export to a staging Firestore instance and verify data integrity.

### Recovery time objectives (RTO/RPO)

| Scenario | RPO (data loss) | RTO (downtime) | Notes |
|---|---|---|---|
| Accidental document deletion | Up to 7 days (PITR) | Minutes | Requires PITR enabled |
| Full database corruption | Up to 24 hours (daily export) | Hours | Requires export + import |
| Firebase project deletion | Potentially total | Days | Enable project deletion protection |
| Cloud Function deployment failure | 0 (rollback via Firebase CLI) | Minutes | `firebase deploy --only functions:functionName` |

---

## 13. Cross-Browser & Mobile Testing

### Browser compatibility

Flutter web with CanvasKit renderer is broadly compatible. Known considerations:

| Browser | Status | Notes |
|---|---|---|
| Chrome (latest) | **Full support** | Primary development target |
| Firefox (latest) | **Full support** | CanvasKit works; minor font rendering differences |
| Safari (latest) | **Full support** | Requires HTTPS; some WebGL performance differences |
| Edge (latest) | **Full support** | Chromium-based; identical to Chrome |
| Safari iOS | **Full support** | PWA installable; some scroll behavior differences |
| Chrome Android | **Full support** | Responsive layout works |
| IE 11 | **Not supported** | WebAssembly (CanvasKit) not supported |

### Mobile performance

| Device class | Expected load time | Notes |
|---|---|---|
| High-end smartphone (2024) | 2–4 s initial load | CanvasKit WASM download (~2 MB) on first load |
| Mid-range smartphone | 4–8 s initial load | WASM compilation adds time |
| Low-end smartphone | 8–15 s initial load | Consider HTML renderer for low-end devices |

**Recommendation:** Serve the HTML renderer (lighter, no WASM) for mobile devices via user-agent detection in `index.html`, and CanvasKit for desktop. Flutter web supports this via the `flutter_bootstrap.js` renderer selection.

### PWA / offline capability

The app includes a service worker (`flutter_service_worker.js`). Offline capability is limited to cached assets; Firestore data requires connectivity.

---

## 14. Third-Party Integrations

### Google Maps

Used for facility address lookup and map display.

| Test scenario | Expected behavior |
|---|---|
| API key quota exceeded | Map fails to load; address search returns error |
| Maps API downtime | Map widget shows error state; address entry falls back to text input |

**Recommendation:** Implement a fallback text-only address entry mode when Maps API is unavailable.

### Stripe Connect

| Test scenario | Expected behavior |
|---|---|
| Stripe API downtime | Payment callables return `unavailable` HttpsError; UI shows "Payment service temporarily unavailable" |
| Stripe Connect account not onboarded | `createPaymentIntent` returns error; manager prompted to complete onboarding |
| Webhook delivery failure | Stripe retries for 72 hours; idempotency key prevents duplicate processing on retry |

### SendGrid

| Test scenario | Expected behavior |
|---|---|
| SendGrid API key revoked | Email send fails silently; error logged to Sentry |
| Bounce / spam complaint | SendGrid suppression list blocks future sends to that address |
| Template not found | Email send fails; fallback to plain-text email not implemented |

### Twilio

| Test scenario | Expected behavior |
|---|---|
| Twilio account suspended | SMS send fails; error logged |
| Invalid phone number | Twilio returns 21211 error; caught and logged |
| Carrier filtering | Message may not deliver; no delivery receipt handling implemented |

### DocuSign (planned)

Per `docs/DOCUSIGN_INTEGRATION.md`, DocuSign integration is planned but not yet live. When implemented:

| Test scenario | Expected behavior |
|---|---|
| DocuSign API downtime | Contract send fails; manager notified; in-app signing fallback available |
| Envelope declined | Webhook updates contract status to `declined` |
| Envelope completed | Webhook updates contract status to `signed`; PDF stored in Firebase Storage |

---

## 15. Analytics & Metrics

### Current instrumentation

| Tool | Status | What is tracked |
|---|---|---|
| Firebase Analytics | Available (built into Flutter Firebase SDK) | Page views, custom events (if instrumented) |
| Sentry | Configured in Cloud Functions | Server-side errors, performance traces (10% sample rate) |
| Firebase Performance Monitoring | Not confirmed as configured | Network request timing, app startup time |
| Google Analytics | Not confirmed | Web traffic |

### Server-side metrics (Google Cloud)

Cloud Functions metrics are available in **Google Cloud Monitoring**:
- Invocation count, error rate, execution time (p50/p95/p99)
- Memory utilization per function
- Cold start frequency

Firestore metrics:
- Read/write operation counts
- Document size distribution
- Index usage

**Recommendation:** Create a Cloud Monitoring dashboard with alerts for:
- Cloud Function error rate > 1%
- Cloud Function p95 execution time > 30 s
- Firestore read rate > 1M reads/hour (unexpected spike)
- Firestore write errors

### Custom event tracking recommendations

| Event | When to fire | Properties |
|---|---|---|
| `facility_created` | New facility saved | `tier`, `unit_count` |
| `tenant_moved_in` | Move-in completed | `facility_id`, `unit_type` |
| `payment_processed` | Successful payment | `amount`, `method: autopay|manual` |
| `contract_signed` | Contract status → signed | `facility_id`, `contract_type` |
| `ai_query` | AI assistant question sent | `facility_id` (no PII) |

---

## 16. SendGrid & Twilio Cost Simulation

### Email volume and cost

| Scenario | Emails/day | Emails/month | SendGrid plan needed | Monthly cost |
|---|---|---|---|---|
| 100 facilities (baseline) | 5,993 | ~180,000 | Pro (100k/mo) or higher | **$89.95** |
| 500 facilities (stress spike) | 29,963 | ~899,000 | Custom volume | **$89.95–$300+** |
| 100 facilities, email-only reminders (no SMS) | +2,000 | +60,000 | Same plan | No additional cost |

**Breakdown of 5,993 emails/day at 100 facilities:**
- Payment reminders: ~50/facility × 100 = 5,000
- Move-in/move-out welcome/goodbye: ~4/facility × 100 = 400
- Delinquency notices: ~2/facility × 100 = 200
- Digest / system notifications: ~3/facility × 100 = 300
- Misc (contract, insurance): ~93 total

### SMS volume and cost

| Scenario | SMS/day | SMS/month | Cost/month |
|---|---|---|---|
| 100 facilities (baseline) | 1,000 | 30,000 | **$249.00** |
| 500 facilities (stress spike) | 5,000 | 150,000 | **$1,245.00** |
| 100 facilities, reduce to 5 SMS/facility/day | 500 | 15,000 | **$124.50** |

**SMS is the largest variable cost.** Reducing SMS frequency (e.g., send SMS only for overdue notices, use email for reminders) could cut the Twilio bill by 50–75%.

### Combined third-party cost summary

| Service | 100 facilities/month | 500 facilities/month |
|---|---|---|
| Firebase (Firestore + Functions) | $16.24 | $35.03 |
| SendGrid | $89.95 | ~$300 |
| Twilio SMS | $249.00 | $1,245.00 |
| OpenAI (AI, at cap) | $165.00 | $825.00 |
| DocuSign (planned) | $1,490.00 | $7,890.00 |
| Stripe (SaaS billing only) | ~$33–50 | ~$165–250 |
| **Total** | **~$2,043–$2,060** | **~$10,460–$10,545** |

> **Note:** DocuSign dominates at scale due to per-envelope pricing. Evaluating alternatives (e.g., HelloSign/Dropbox Sign at $15/user/month flat, or building in-app e-signature) could reduce costs by $1,000–$7,000/month.

---

## 17. Server Performance Summary

### Cloud Function resource utilization (estimated)

| Function | Memory (default) | Typical execution | Peak execution | Timeout risk |
|---|---|---|---|---|
| `createPaymentIntent` | 256 MB | 800 ms | 3 s | No |
| `processAutopayPayments` (100 fac.) | 256 MB | 4–6 min | 8 min | **Medium** |
| `processAutopayPayments` (500 fac.) | 256 MB | 20–30 min | — | **HIGH – will timeout** |
| `updateAllFacilityStatsNightly` (100) | 256 MB | 2–4 min | 6 min | Medium |
| `updateAllFacilityStatsNightly` (500) | 256 MB | 8–12 min | — | **HIGH** |
| `aiAssistantChat` | 256 MB | 1.5–4 s | 8 s | No |
| `generateContractPDF` | 256 MB | 1–3 s | 10 s (large PDF) | No |
| `stripeWebhook` | 256 MB | 200–500 ms | 2 s | No |

### Firestore cost at scale

| Scale | Reads/month | Writes/month | Firestore cost/month |
|---|---|---|---|
| 100 facilities | ~15.3M billable | ~87k billable | **~$4.16** |
| 500 facilities | ~76.6M billable | ~434k billable | **~$22.61** |
| 1,000 facilities | ~153M billable | ~868k billable | **~$45** |

Firestore is remarkably cost-efficient even at large scale. The main cost drivers are SendGrid, Twilio, and DocuSign — not infrastructure.

### CPU / memory under concurrent load

Firebase Cloud Functions are stateless and horizontally scalable. Google Cloud manages CPU and memory allocation automatically. The only risk is:
1. **Memory pressure** on functions that load large datasets (e.g., 500-unit facility stats trigger loading 500 unit docs + 400 tenant docs = ~900 Firestore reads in one invocation, each doc ~2 KB = ~1.8 MB in memory). Well within 256 MB.
2. **Concurrent trigger invocations** during bulk imports: if 1,000 tenant documents are written in rapid succession, 1,000 `onTenantWrite` triggers fire simultaneously, each loading the full unit+tenant set. This can cause a brief Firestore read spike of ~480,000 reads in seconds.

---

## 18. Recommendations & Priority Actions

### P0 – Critical (address before production scale-up)

| # | Action | Impact |
|---|---|---|
| 1 | **Coalesce facility-stats recomputes** (branch `fix/facility-stats-trigger-amplification`) | 30k writes cost 5.0M reads on 2026-08-31; scales with facility size, not change size |
| 2 | **Enable Firestore PITR and daily GCS export** | Data loss prevention |
| 3 | **Migrate scheduled jobs to Cloud Tasks fan-out** | Prevents timeout at 300+ facilities |
| 4 | **Add idempotency check for Stripe webhooks** (store processed event IDs) | Prevents duplicate ledger entries |
| 5 | **Wrap contract signing in a Firestore transaction** | Prevents concurrent signing conflicts |

### P1 – High (address within next sprint)

| # | Action | Impact |
|---|---|---|
| 6 | **Use `FieldValue.increment` for all stats counter fields** | Prevents concurrent write conflicts on stats docs |
| 7 | **Add processing lock to prevent concurrent scheduled job runs** | Prevents double-autopay |
| 8 | **Add access code expiry (15 min) to tenant portal** | Security improvement |
| 9 | **Enable Firebase App Check** | Prevents API abuse from non-app clients |
| 10 | **Add retry logic for SendGrid / Twilio failures** | Improves notification reliability |

### P2 – Medium (address before 500-facility scale)

| # | Action | Impact |
|---|---|---|
| 11 | **Upgrade SendGrid plan** to match email volume | Prevents quota errors |
| 12 | **Add Twilio Messaging Service** with multiple numbers | Handles 5,000+ SMS/day throughput |
| 13 | **Implement client-side inactivity timeout** (30 min) | Session security |
| 14 | **Add "Sign out all devices" feature** | Account compromise recovery |
| 15 | **Evaluate DocuSign alternatives** (HelloSign, in-app e-sign) | $1,000–$7,000/month savings |
| 16 | **Set `minInstances: 1`** for payment and AI callables | Eliminates cold start latency |

### P3 – Low (nice to have)

| # | Action | Impact |
|---|---|---|
| 17 | **Serve HTML renderer on mobile** via user-agent detection | Faster initial load on mobile |
| 18 | **Add structured error codes** to all callable responses | Better client-side error handling |
| 19 | **Build Cloud Monitoring dashboard** with alerts | Proactive incident detection |
| 20 | **Add dead-letter queue** for failed autopay items | Automatic retry for transient failures |
| 21 | **Instrument custom Firebase Analytics events** | Better product insights |

---

*Report generated from live simulation output. Re-run with `node scripts/simulate_100_facilities.js [N] --cost` to update numeric projections for any facility count.*
