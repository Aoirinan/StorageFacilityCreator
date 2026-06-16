# Texting Onboarding V1 (Twilio A2P 10DLC)

This feature adds a self-serve `Enable Texting` wizard for per-facility Twilio number provisioning and A2P registration.

## Facility phone numbers and A2P compliance (timing)

**When the facility gets a number (Twilio purchase + Firestore):** During the wizard, **before** Twilio/carrier campaign approval finishes. Step 3 calls `provisionPhoneNumber`, which buys a US local SMS-capable number (optional area code), stores `twilioPhoneNumberSid` and `twilioPhoneNumberE164` on `facilities/{facilityId}`, ensures a per-facility Messaging Service, and attaches that number to the service. `submitTextingOnboarding` calls the same provisioning helper again; if a number already exists, it is reused.

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
- `twilioBrandSid`, `twilioCampaignSid`
- `twilioPhoneNumberSid`, `twilioPhoneNumberE164`
- `textingPlatformApproved` (bool), `textingPlatformApprovedAt`, `textingPlatformApprovedBy` (superadmin gate for sending when onboarding is enabled)

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
5. Verify outbound SMS is blocked for that facility unless `a2pStatus=approved` **and** `textingPlatformApproved=true` (when `textingOnboardingEnabled` is on). Before carrier approval, confirm the dedicated number appears on the facility after Step 3 but messages still do not send from it until approvals complete.
6. After carrier approval, use a superadmin account to call `setTextingPlatformApproval` (or the in-app controls on the status card) so sending is allowed.
7. With per-facility onboarding active, confirm outbound send succeeds only when the target tenant has `smsConsentStatus=opted_in` (unless using a forced/test path).
8. Send inbound STOP and confirm tenant:
   - `smsOptOut=true`
   - `smsConsentStatus=opted_out`
9. Send inbound START and confirm tenant:
   - `smsOptOut=false`
   - `smsConsentStatus=opted_in`

## Automated Tests

- Unit tests: `functions/src/test/texting_onboarding.test.ts`
- Run: `cd functions && npm test`

## Integration Smoke Script

- Script: `scripts/texting_onboarding_smoke.ps1`
- Runs save business info -> provision number -> submit onboarding -> refresh status via callable endpoints using test credentials.

