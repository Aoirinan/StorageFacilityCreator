# RUNBOOK.md

## Project Overview
- **GCP Project ID:** `storage-facility-creator`
- **Billing Account:** `01111A-EC63DC-E2D2E3`
- **Region:** `us-central1`
- **Marketing site host:** Vercel (project: `storage-facility-creator`)

## Cost Floor & Budget
- **Steady-state GCP cost:** ~$12-14/month (as of April 2026)
- **Budget alert:** $20/month with thresholds at 50%, 75%, 90%, 100% actual + 100% forecasted
- **Per-facility revenue:** $75/month, so unit economics are healthy

### Cost breakdown (April 2026 baseline)
| Service | Monthly | Why it exists |
|---|---|---|
| Cloud NAT | ~$5.70 | Required for QuickBooks/Intuit static IP allowlist |
| Compute Engine (VPC connector) | ~$4.20 | Two e2-micro instances for Serverless VPC Access |
| Secret Manager | ~$2-3 | 16 secrets, ~32 active versions after pruning |
| Cloud Scheduler | ~$0.90 | 10 jobs/day for automations |
| Network Intelligence Center | $0 (credited) | Auto-enabled, ~$4/mo when credit expires |

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
- **Reducing minInstances to 1 saves ~$2/mo but reduces redundancy under load. Test before changing.**

## Secret Manager
- **Convention:** Keep latest + 1 rollback version per secret. Disable older versions; destroy after 7+ days of stability.
- **Rotation method:** `firebase functions:secrets:set SECRET_NAME` followed by `y` to redeploy and auto-destroy stale.
- **Code accesses secrets via `defineSecret('NAME')` — always resolves to `latest`, no version pinning.**

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

## Known Issues / Tech Debt
- VPC connector minInstances=2 could potentially be reduced to 1 to save ~$2/mo (untested under QuickBooks load)
- `setup_secrets.ps1` references `SENDGRID_FROM_EMAIL`/`SENDGRID_FROM_NAME` as secrets, but `index.ts` uses `defineString('SENDGRID_SENDER_EMAIL')` — naming drift to align in future
- No Terraform/IaC for cloud resources; all changes via console/gcloud
- Network Intelligence Center cannot be disabled via gcloud; requires support ticket when credit expires

## Last Updated
April 30, 2026 — Initial creation after cost investigation and Secret Manager pruning
