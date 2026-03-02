# Texting Onboarding V1 (Twilio A2P 10DLC)

This feature adds a self-serve `Enable Texting` wizard for per-facility Twilio number provisioning and A2P registration.

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

## Data Fields (Facility)

Stored in `facilities/{facilityId}`:

- `textingOnboardingEnabled` (bool)
- `a2pStatus` (`draft|submitted|pending|approved|rejected`)
- `a2pLastError`, `a2pRejectionReason`
- `a2pSubmittedAt`, `a2pApprovedAt`, `a2pRejectedAt`, `a2pLastUpdatedAt`
- `twilioMessagingServiceSid`
- `twilioTrustProfileSid`, `twilioTrustProductSid`
- `twilioBrandSid`, `twilioCampaignSid`
- `twilioPhoneNumberSid`, `twilioPhoneNumberE164`

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
3. Complete wizard with test facility.
4. Verify status progression:
   - `draft` -> `submitted` -> `pending` -> `approved` (or `rejected`)
5. Verify outbound SMS is blocked for that facility unless `a2pStatus=approved`.
6. Send inbound STOP and confirm tenant:
   - `smsOptOut=true`
   - `smsConsentStatus=opted_out`
7. Send inbound START and confirm tenant:
   - `smsOptOut=false`
   - `smsConsentStatus=opted_in`

## Automated Tests

- Unit tests: `functions/src/test/texting_onboarding.test.ts`
- Run: `cd functions && npm test`

## Integration Smoke Script

- Script: `scripts/texting_onboarding_smoke.ps1`
- Runs save business info -> provision number -> submit onboarding -> refresh status via callable endpoints using test credentials.

