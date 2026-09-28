# Texting Onboarding V1 (Twilio A2P 10DLC)

This feature adds a guided, resumable Texting setup for per-facility Twilio
number provisioning and A2P registration. The app has three setup stages:
Business details, Messaging plan, and Review & submit. Submitted facilities
open directly to a separate approval-status dashboard.

Carrier campaign review typically takes 10–15 business days. Texting remains
disabled until both the carrier and an SFC superadmin approve the facility.
Automated registration supports LLCs, corporations, and nonprofits. Sole
proprietors must use the manual support path because Twilio does not support
self-service Sole Proprietor A2P registration through this API flow.

## Campaign rejection (30909) — resubmission checklist

A campaign rejected with error 30909 means carriers could not verify the Call-to-Action / opt-in
flow. The `messageFlow` and `description` submitted with every campaign are built per facility by
`buildCampaignMessageFlow` / `buildCampaignDescription` in
`functions-messaging-twilio/src/a2pCampaign.ts` and must always include:

1. Every opt-in path the facility actually uses, named to the facility (DBA or legal name): the
   written consent the tenant gives at rental (online rental form checkbox, or the signed rental
   agreement / move-in form in the office), recorded by staff in the software before any text,
   and the START keyword. The quoted checkbox language must match `/sms-terms`.
2. The disclosures: unchecked-by-default, consent not a condition of service, message frequency
   varies, "message and data rates may apply", STOP/HELP.
3. Publicly reviewable URLs (the live opt-in form is behind login, so reviewers need these):
   - `https://www.storagefacilitycreator.com/sms-consent-demo` — exact public reproduction of the
     opt-in checkbox screen (source: `marketing/src/app/sms-consent-demo/page.tsx`).
   - `https://www.storagefacilitycreator.com/sms-terms` — full SMS program terms.

As of 2026-09-21 the campaign description is built per facility by
`buildCampaignDescription` rather than sent as one static constant: it opens by
naming the facility's legal name (and DBA, city/state, website) so the
description reads as that facility describing itself. Evidence for why this
matters is in `docs/TWILIO_SENDER_REGISTRATION.md` — the campaign that was
approved in a single day named its business in the first clause; the one
rejected on 30909 described a class of businesses and never named the
registrant. The static `A2P_CAMPAIGN_DESCRIPTION` remains the fallback when a
facility has no stored business details.

Also as of 2026-09-21, `submitCampaignInternal` files non-sole-proprietor
facilities under `LOW_VOLUME` (Low Volume Mixed) rather than
`ACCOUNT_NOTIFICATION`. Account Notification draws the manual call-to-action
review that rejected SFC's own campaign on 30909 and costs ~$10/mo; Low Volume
Mixed is ~$1.50/mo and is the tier that was approved same-day in this account.
The ceiling is roughly 2,000 message segments/day to T-Mobile, far above what
one facility sends its own tenants. A facility that outgrows it moves to
`ACCOUNT_NOTIFICATION` as a deliberate upgrade. Note this is the Twilio A2P use
case; the `textingUseCases` the owner ticks in the wizard are the facility's own
message categories and are unrelated.

As of 2026-09-27 (branch `fix/a2p-registration-pipeline`) the campaign also
carries `optInKeywords: ['START']` with an opt-in message naming the facility,
`privacyPolicyUrl` / `termsAndConditionsUrl`, and `hasEmbeddedLinks` /
`hasEmbeddedPhone` computed from the samples. Samples are validated server-side
(2-5, each at least 20 characters) and prefixed with the facility's name.
Campaigns are filed with `messaging.v1.services(MG).usAppToPerson.create`; the
`QE...` resource SID is stored as `twilioCampaignSid` and the carrier `CM...` id
as `twilioCampaignId`. If the brand is not yet `APPROVED` when the owner
submits, nothing is filed: `a2pCampaignPending` is set and the hourly
`pollA2PRegistrationStatus` files the campaign once the brand clears.

Follow-up: the terms/privacy URLs are the platform's pages. A per-facility
public SMS terms page would match the brand better, but the facility public
site (`/w/<slug>`) has no sub-page that could host it yet.

Before resubmitting:

- Deploy the marketing site so both URLs above resolve publicly.
- Deploy `functions-messaging-twilio` so the campaign submission uses the current copy.
- Verify sample messages identify the sender (facility DBA/legal name prefix) and include
  "Reply STOP to opt out" — the wizard defaults in `lib/screens/texting_setup_screen.dart` do this.
- Prefer editing the rejected campaign in Twilio Console (keeps the approved brand SID) over
  `resubmitTextingOnboarding`, which deletes and re-creates both brand and campaign.

Consent-text sources that must stay in sync:

- `marketing/src/config/site.ts` → `SMS_CONSENT_CHECKBOX_TEXT` (used by `/sms-terms` and
  `/sms-consent-demo`)
- Flutter tenant creation / public move-in consent checkbox copy
- `TENANT_CONSENT_TEXT` in `functions-messaging-twilio/src/a2pCampaign.ts` (quoted in the
  campaign message flow)

## Facility phone numbers and A2P compliance (timing)

**When the facility gets a number (Twilio purchase + Firestore):** The final
**Reserve number & submit** action first calls `provisionPhoneNumber`, which
buys a US local SMS-capable number (optional area code), stores
`twilioPhoneNumberSid` and `twilioPhoneNumberE164` on
`facilities/{facilityId}`, ensures a per-facility Messaging Service, and
attaches that number to the service. `submitTextingOnboarding` calls the same
provisioning helper again; if a number already exists, it is reused. If
campaign submission fails after purchase, retrying reuses the reserved number.

**When outbound SMS uses that number as `From`:** Only when **all** of the following hold: the global feature flag is on, the facility has `textingOnboardingEnabled === true`, `a2pStatus` is `approved`, `textingPlatformApproved` is `true` (superadmin), and `twilioPhoneNumberE164` is set. Otherwise `sendSMS` either blocks or uses the legacy global `TWILIO_PHONE_NUMBER` when the per-facility onboarding path is not active for that facility.

**Inbound SMS:** The webhook resolves the facility by matching the inbound `To` number to `twilioPhoneNumberE164` on a facility document.

Primary implementation: `functions-messaging-twilio/src/twilioCallables.ts` (`provisionPhoneNumber`, `provisionFacilityPhoneNumber`, `submitTextingOnboarding`, `sendSMS`), `functions-messaging-twilio/src/incomingSmsWebhook.ts`, and the Flutter wizard `lib/screens/texting_setup_screen.dart`.

## Feature Flag

- Flag key: `TEXTING_ONBOARDING_V1`
- Location: Firestore `appConfig/featureFlags`
- Default: `enabled: false` (safe for production)

Example:

```json
{
  "TEXTING_ONBOARDING_V1": {
    "enabled": false
  }
}
```

## Required Firebase Function Params/Secrets

- `TWILIO_ACCOUNT_SID` (string param)
- `TWILIO_AUTH_TOKEN` (secret)
- `TWILIO_PHONE_NUMBER` (string param, legacy fallback sender)
- `TWILIO_DRY_RUN` (string param, default `false`)

Dry run mode:

- Set `TWILIO_DRY_RUN=true` for local/dev smoke testing.
- Twilio resources are stubbed with deterministic fake SIDs.
- No live Twilio write operations occur.

## New Callable Functions

- `getTextingOnboardingStatus`
- `saveTextingBusinessInfo`
- `ensureMessagingService`
- `provisionPhoneNumber`
- `createOrUpdateA2PProfile`
- `submitBrandRegistration`
- `submitCampaign`
- `submitTextingOnboarding`
- `refreshTextingOnboardingStatus`
- `resubmitTextingOnboarding`
- `setTextingPlatformApproval` (superadmin only; grants or revokes sending after carrier A2P approval)

## Data Fields (Facility)

Stored in `facilities/{facilityId}`:

- `textingOnboardingEnabled` (bool)
- `a2pStatus` (`draft|submitted|pending|approved|rejected`)
- `a2pLastError`, `a2pRejectionReason`
- `a2pSubmittedAt`, `a2pApprovedAt`, `a2pRejectedAt`, `a2pLastUpdatedAt`
- `twilioMessagingServiceSid`
- `twilioTrustProfileSid`, `twilioTrustProductSid`
- `a2pBundleProfileStatus`, `a2pBundleProductStatus` (TrustHub status of each bundle, written on
  every save, refresh and hourly poll), `a2pBundleProfilePolicySid`, `a2pBundleProductPolicySid`
- `a2pBundleReady` (both bundles passed evaluation and are with Twilio), `a2pBundleApproved`
  (both `twilio-approved`), `a2pBundleIssues` (failing fields plus evaluation and policy SIDs),
  `a2pAbandonedBundleSids` (wrong-policy bundles replaced by a fresh one, never deleted)
- `twilioBrandSid`, `twilioCampaignSid` (`QE...`), `twilioCampaignId` (`CM...`),
  `a2pCampaignStatus`, `a2pCampaignPending`, `a2pBrandStatus`
- `twilioPhoneNumberSid`, `twilioPhoneNumberE164`
- `textingPlatformApproved` (bool), `textingPlatformApprovedAt`, `textingPlatformApprovedBy` (superadmin gate for sending when onboarding is enabled)
- `textingBusinessData` (safe resumable profile; only `einLast4`, never a full EIN)
- `textingUseCases`, `textingSampleMessages`, `textingConsentConfirmedAt`

`getTextingOnboardingStatus` returns these safe saved values plus completion
signals so the Flutter flow can resume at the first incomplete stage. The form
lock comes from `describeBusinessDetailsLock` (`a2pTrustBundle.ts`):
`businessDetailsLocked` (nothing can be saved: brand filed, trust product in
review, or both bundles approved), `profileDetailsLocked` (customer profile is
with Twilio, so its fields are read-only but saving rebuilds and resubmits the
trust product; only the DBA can change) and `lockReason`.

TrustHub policies are pinned to Twilio's ISV policies (secondary customer
profile `RNdfbf3fae0e1107f8aded0e7cead80bf5`, A2P trust product
`RNb0d4771c2c98518d916a3d4cd70a8f8b`); the env overrides
`TWILIO_SECONDARY_CUSTOMER_PROFILE_POLICY_SID` / `TWILIO_A2P_TRUST_PRODUCT_POLICY_SID`
are honoured only when they match `^RN[0-9a-f]{32}$`. Pending,
approved, rejected, and live registrations go directly to the status
dashboard. The app polls only while status is `submitted` or `pending`.

## Data Fields (Tenant Consent)

Stored in `facilities/{facilityId}/tenants/{tenantId}`:

- `smsConsentStatus` (`opted_in|opted_out|unknown`)
- `smsConsentTimestamp`
- `smsConsentSource`

Inbound STOP/START updates these fields automatically.

## Safety / Rollback

1. Set `appConfig/featureFlags.TEXTING_ONBOARDING_V1.enabled = false`.
2. Deploy functions if needed (`firebase deploy --only functions`).
3. Existing SMS flow continues on legacy global Twilio number.
4. New A2P/Twilio SID fields may remain in Firestore (non-breaking).

## Verification Checklist

1. Enable feature flag for test project.
2. Open Settings -> Facility -> Texting.
3. Complete the three guided setup stages with a test facility.
4. Verify status progression:
   - `draft` -> `submitted` -> `pending` -> `approved` (or `rejected`)
5. Reload the route and confirm draft setup resumes at the first incomplete
   stage, while submitted/pending registrations open the status dashboard.
6. Verify outbound SMS is blocked for that facility unless
   `a2pStatus=approved` **and** `textingPlatformApproved=true` (when
   `textingOnboardingEnabled` is on). Before carrier approval, confirm the
   dedicated number appears after submission but messages still do not send
   from it until approvals complete.
7. After carrier approval, use a superadmin account to call `setTextingPlatformApproval` (or the in-app controls on the status dashboard) so sending is allowed.
8. With per-facility onboarding active, confirm outbound send succeeds only when the target tenant has `smsConsentStatus=opted_in` (unless using a forced/test path).
9. Send inbound STOP and confirm tenant:
   - `smsOptOut=true`
   - `smsConsentStatus=opted_out`
10. Send inbound START and confirm tenant:
   - `smsOptOut=false`
   - `smsConsentStatus=opted_in`

## Automated Tests

- Unit tests: `functions/src/test/texting_onboarding.test.ts`
- Run: `cd functions && npm test`

## Integration Smoke Script

- Script: `scripts/texting_onboarding_smoke.ps1`
- Runs save business info -> provision number -> submit onboarding -> refresh status via callable endpoints using test credentials.


## See also

- `docs/TWILIO_SENDER_REGISTRATION.md` — live registration state of every number on the account, why the shared toll-free sender needs Toll-Free Verification (not 10DLC), and prepared form answers.
