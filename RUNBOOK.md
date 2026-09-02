# RUNBOOK.md

## Project Overview
- **GCP Project ID:** `storage-facility-creator`
- **Billing Account:** `01111A-EC63DC-E2D2E3`
- **Region:** `us-central1`
- **Marketing site host:** Vercel (project: `storage-facility-creator`)

## Cost Floor & Budget
- **Steady-state GCP cost:** ~$20/month (August 2026 actual), against a **$20/month budget** — which
  is why the 100% alert now fires most months. The budget has not moved since it was set; the
  system underneath it grew.
- **Budget alert:** $20/month with thresholds at 50%, 90% and 100%
- **Per-facility revenue:** $75/month, so unit economics are healthy

### Cost breakdown (August 2026 actual — $20.11)
Figures are gross usage cost; the bill lands at $20.11 after ~$4.79 of free-tier discount.

| Service | Monthly | Why it exists |
|---|---|---|
| Compute Engine (VPC connector) | $12.31 | Two e2-micro instances, 24/7. $8.01 vCPU + $4.30 RAM |
| Cloud NAT | $5.74 | Required for QuickBooks/Intuit static IP allowlist. $3.68 IP + $2.06 gateway |
| Secret Manager | $3.10 | 60 billed versions; only 11 are pinned by a function. See below |
| Cloud Run min instances | $5.13 | 3 public-website functions pinned warm from ~12 Aug. See below |
| Cloud Firestore reads | $3.06 | **One-off.** A load test on 31 Aug, not recurring — see the load-test report |
| Cloud Scheduler | $0.85 | 12 jobs, 3 free |

Two notes the April baseline did not have:

- **The VPC connector is the largest single line, not Cloud NAT.** The April table had it at ~$4.20,
  which undercounts it by roughly three times.
- **September will not repeat the Firestore line**, but *will* carry a full month of min instances
  rather than the 19 days August paid for, so expect roughly $20 again rather than a drop.

### Cloud Run min instances (3 functions, ~$8.36/mo at full-month rate)
`renderPublicWebsite`, `getPublicWebsiteConfig` and `routeCustomDomainRoot` each run
`minInstances: 1` (`functions-public-website/src/publicWebsite.ts`). **This is deliberate and load
bearing** — a cold start on the custom-domain lookup used to land real customers on the raw
operator app instead of the facility's site, and `web/index.html` depends on that lookup returning
inside its 2.5s safety-net timeout. Do not set these to 0 to save money.

## Critical Architecture Notes

### Cloud NAT — DO NOT DELETE
- **Resource:** `nat-us-central1` on router `router-us-central1` in `us-central1`
- **Static IP:** `nat-intuit-outbound` (34.57.12.115)
- **Purpose:** QuickBooks/Intuit OAuth and API calls require a stable outbound IP for IP allowlisting
- **Code reference:** `functions/src/index.ts` uses `sfc-serverless-connector` with `ALL_TRAFFIC` egress
- **Removing this breaks QuickBooks integration**

### VPC Access Connector
- **Name:** `sfc-serverless-connector`
- **Config:** e2-micro, minInstances 2, maxInstances 4
- **Note:** minInstances=2 means two always-on instances; first qualifies for free tier, second does not
- **minInstances cannot go below 2.** A previous version of this line suggested dropping to 1 to
  save ~$2/mo. Two is the floor Serverless VPC Access allows, and e2-micro is already the smallest
  machine type, so there is no cheaper shape of this connector. The only way to remove the cost is
  to stop needing the connector — migrating the five QuickBooks functions to 2nd gen would let them
  use Cloud Run direct VPC egress, which has no connector VMs. The NAT and its static IP stay
  either way.

## Secret Manager
- **Convention:** Keep latest + 1 rollback version per secret. Disable older versions; destroy after 7+ days of stability.
- **Rotation method:** `firebase functions:secrets:set SECRET_NAME` followed by `y` to redeploy and auto-destroy stale.
- **Deployed functions pin an exact version number. They do not follow `latest`.** The source says
  `defineSecret('NAME')`, which reads as "latest", and is why this line used to claim there was no
  pinning. What actually happens is that `latest` resolves *at deploy time* and the concrete number
  is baked into each function's binding. Measured 2026-09-02 across all 169 functions: 101 bindings
  on version `7`, 63 on `2`, 18 on `5`, 14 on `6`, and a few on `4`, `3` and `1`.
- **So "destroy after 7 days" is only safe for a version nothing is bound to.** A function pinned to
  a destroyed version does not fall back to latest; it fails to read the secret. Check first:

  ```
  gcloud functions list --project=storage-facility-creator \
    --format="value(name,secretEnvironmentVariables)" | grep SECRET_NAME
  ```

  A function only moves onto a newer version when it is redeployed, which is why rotation is
  `functions:secrets:set` *followed by a redeploy*, not the set alone.

### Actual version inventory (2026-09-02)
17 secrets, **60 billed versions** (36 enabled + 24 disabled — disabled still bills; only
`DESTROYED` stops the charge) at $0.06/version/month ≈ **$3.60/mo**. Of those, **11 are pinned by
functions and 49 are referenced by nothing** (~$2.94/mo). No function is pinned to a non-enabled
version, so nothing is broken today.

Six of the secrets are read by nothing at all, because the code declares them with `defineString`
(plain config) rather than `defineSecret`, or under a different name — `TWILIO_ACCOUNT_SID` (7
versions), `TWILIO_PHONE_NUMBER` (5), `STRIPE_ADDON_PRICE_ID` (2), `STRIPE_BASE_PRICE_ID` (2),
`SENDGRID_FROM_NAME` (1), and `SENDGRID_FROM_EMAIL` (1, where the code actually reads
`SENDGRID_SENDER_EMAIL`). These are duplicates of values that live in each package's `.env`;
Secret Manager is not their source of truth and deleting them changes no behaviour. Confirm that
before destroying, since the stored value may be the only written record of, say, the Twilio
number.

### `SENDGRID_FROM_NAME` was an email address (fixed 2026-09-02, needs a deploy)
All eleven `.env` files had `SENDGRID_FROM_NAME=support@storagefacilitycreator.com`. It is used as
the SendGrid `from.name`, so outbound mail rendered as
`support@storagefacilitycreator.com <support@storagefacilitycreator.com>`.

Most senders fall back to `facilityData?.name`, so facility-branded mail was unaffected. Three paths
have no fallback and were showing it: OTP/verification (`functions-account-security/src/otp.ts:86`)
and password reset plus admin bulk mail (`functions-admin/src/superAdminCallables.ts:476,685`) —
the three highest-trust emails the platform sends, and the ones where a malformed sender reads as
phishing.

Set back to `Storage Facility Creator` in all eleven files, matching both the code default and
`functions/.env.example`, which was correct all along. **`.env` is gitignored, so this fix is local
only and takes effect on the next deploy** — if you deploy from another machine, check there too.

### SendGrid keys (TWO keys, two systems)
- **`Firebase Functions - Production v2`** → used by Cloud Functions, stored in GCP `SENDGRID_API_KEY` secret
- **`SFC Email Service`** → used by Vercel marketing site, stored in Vercel env var `SENDGRID_API_KEY`
- These are separate keys; rotating one does not affect the other.

### OpenAI key
- **Active key name:** `sfc-prod-functions-v2`
- **Used by:** `aiAssistantChat`, `aiAssistant` Cloud Functions
- **Per-user rate limit:** 10 questions/day enforced in app code
- **OpenAI hard limit:** [check platform.openai.com → Settings → Limits]

### Marketing site (Vercel) env vars
- `SENDGRID_API_KEY` — SFC Email Service key (separate from Firebase)
- `MARKETING_LEAD_CAPTURE_KEY` — shared HMAC secret with Cloud Functions for lead capture auth
- Both are marked Sensitive in Vercel.

## Network Intelligence Center
- Cannot be cleanly disabled via UI or gcloud
- Currently $4/month, fully credited
- When credit expires, file a Google Cloud support ticket requesting NIC billing exclusion for this project

## Other Services & Limits
- **OpenAI:** Currently ~$20/mo. Hard limit set at [check & document]. Per-user rate limit: 10 questions/day.
- **Twilio:** Pay-as-you-go for SMS
- **SendGrid:** Free trial tier (~100 emails/day)
- **Stripe:** Pay-as-you-go transaction fees only

## Routine Maintenance Checklist

### Monthly (1st of month)
- [ ] Review GCP bill vs prior month, investigate any service with >25% increase
- [ ] Check OpenAI usage at platform.openai.com
- [ ] Check Anomalies tab in GCP Billing console

### Quarterly
- [ ] Audit Secret Manager versions; disable old ones after deploy verification
- [ ] Review Cloud Scheduler jobs for any that are no longer needed
- [ ] Review enabled GCP APIs for anything unused

### Annually or as needed
- [ ] Rotate API keys (Stripe, Twilio, SendGrid, OpenAI, QuickBooks)
- [ ] Review IAM roles and remove unused service accounts
- [ ] Review firewall rules

## Incident Response

### "Budget exceeded" alert
1. GCP Console → Billing → Reports → group by Service, time range = current month
2. Identify top 1-2 services driving the increase
3. Cost table → group by SKU to find specific resource
4. Check Anomalies tab for auto-flagged unusual patterns
5. If sudden spike, check audit logs for resource creation events

### Suspected leaked secret
1. Rotate immediately at the source (OpenAI/SendGrid/etc.)
2. Update GCP secret: `firebase functions:secrets:set SECRET_NAME` → y to redeploy
3. If marketing site is affected: update Vercel env var, redeploy
4. Verify functionality in production

## SendGrid API key (rotation)
- **Functions:** `firebase functions:secrets:set SENDGRID_API_KEY` then deploy. Code: `defineSecret('SENDGRID_API_KEY')` in `functions/src/index.ts`.
- **Sender / from name:** `SENDGRID_SENDER_EMAIL` and `SENDGRID_FROM_NAME` are **string params** in `functions/.env.<project-id>`, not the API secret.
- **Marketing (Vercel):** contact API uses `SENDGRID_API_KEY` in that project’s env (`marketing/.env.example`). Rotate there too if the contact form must keep working.
- **Unsubscribe tokens** are derived from the API key (`getEmailUnsubscribeSecretKey`); rotating the key invalidates old unsubscribe links until you accept that tradeoff or redesign token storage.

## Known Issues / Tech Debt
- VPC connector minInstances=2 could potentially be reduced to 1 to save ~$2/mo (untested under QuickBooks load)
- No Terraform/IaC for cloud resources; all changes via console/gcloud
- Network Intelligence Center cannot be disabled via gcloud; requires support ticket when credit expires

## Last Updated
April 30, 2026 — SendGrid rotation notes + aligned `setup_secrets.ps1` with `defineSecret` / `defineString` in `functions/src/index.ts`
